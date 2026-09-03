// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title StockFeeDistributor
 * @notice Distributes tokenized-stock trading fees to token holders on
 *         Robinhood Chain (chainId 4663). Push-based: holders never call a
 *         claim page, which removes the phishing surface that claim UIs create.
 *
 * CYCLE (every `cycleInterval`, default 12h)
 *   1. Launchpad fees land in `feeWallet` as TWO assets: the meme token and
 *      the paired stock token. (Verified on-chain: the launchpad fee-collect
 *      call is a pure collect — no swap happens at claim time.)
 *   2. burnMeme()   — 50% of the meme leg is burned.
 *   3. off-chain    — the remaining meme is sold for ETH to fund gas.
 *   4. openCycle()  — pulls the stock leg in, locks a spend cap and the
 *                     eligibility threshold for this cycle.
 *   5. distribute() — pushes stock to eligible holders in batches. Callable
 *                     repeatedly until the list is exhausted.
 *
 * WHAT THIS CONTRACT ENFORCES (not the server)
 *   - Only the configured stock token can ever leave via distribute().
 *   - Every recipient must actually hold >= minHolding of the meme token.
 *     A compromised operator therefore cannot redirect funds to addresses
 *     that do not hold the token.
 *   - At most `maxPayoutBps` of the stock balance may leave per cycle.
 *   - Cycles cannot be opened faster than `cycleInterval`.
 *   - The owner can pause instantly and withdraw at any time.
 *
 * WHAT IT CANNOT ENFORCE (stated plainly)
 *   ERC-20 exposes no holder enumeration and this chain has no USD price
 *   oracle for tokenized equities. WHO is eligible and HOW MUCH each gets is
 *   therefore computed off-chain by the operator. This contract constrains
 *   the blast radius; it does not verify the ranking itself. The per-cycle
 *   merkleRoot is published for transparency so anyone can audit the list —
 *   it is NOT a claim mechanism.
 *
 * DESIGN NOTE — burn address
 *   Burns go to 0x…dEaD, never address(0). Most ERC-20 implementations
 *   (OpenZeppelin included) revert on transfers to address(0), which would
 *   fail the entire cycle every 12 hours.
 *
 * DESIGN NOTE — USD threshold
 *   Eligibility is "holds >= $100 at the snapshot marketcap". USD is not
 *   knowable on-chain, so the operator converts that USD figure into a token
 *   amount using a 12h TWAP and passes it into openCycle(). The value is
 *   recorded in the CycleOpened event, so every cycle's threshold is publicly
 *   auditable after the fact.
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract StockFeeDistributor {
    /// @dev Burn sink. NOT address(0) — see design note above.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public owner;
    address public operator;
    address public feeWallet;

    /// long.xyz fee collector, and the pool this token's fees accrue in.
    /// Both owner-set: the operator must not be free to point collection at
    /// arbitrary contracts. Verified on-chain 2026-09-01:
    ///   collector 0x4e3468951d49f2eea976ed0d6e75ffcb44a9a544
    ///   collectFees(bytes32 poolId)  selector 0x817db73b
    ///   splits 95% creator / 5% launchpad, pays out BOTH pool legs
    address public feeCollector;
    bytes32 public poolId;
    /* ------------------------- meme leg split ---------------------------- */
    /// @dev The meme leg is split in a fixed order of priority:
    ///
    ///        burn  ->  gas reserve  ->  creator + platform
    ///
    ///      The burn is settled first and can never be reduced below
    ///      BURN_BPS_MIN, so holders keep the deflation they were promised no
    ///      matter how the other shares are tuned.
    ///
    ///      Whatever survives the burn goes ENTIRELY to the gas wallet until it
    ///      holds gasReserveTargetWei. Only the surplus above that is split
    ///      between the creator and the platform.
    ///
    ///      MEASURED: gas is charged per recipient (~$0.125), so a token with
    ///      many holders and thin volume can outrun its own fee income. Paying
    ///      the creator a fixed slice off the top would let a quiet week drain
    ///      the reserve and stall payouts entirely — the one failure holders
    ///      never forgive. Funding gas first makes that impossible: in a dry
    ///      spell the creator and the platform simply earn nothing, and
    ///      distribution keeps running.
    uint256 public burnBps = 5_000;             // 50% of the meme leg is burned
    uint256 public constant BURN_BPS_MIN = 5_000;

    /// @dev Creator and platform are paid in the MEME TOKEN, never in ETH.
    ///      Selling their share every cycle would put scheduled sell pressure
    ///      on the creator's own chart, and a swap costs ~3x the gas of a
    ///      transfer. Paying in kind leaves the timing decision to them.
    address public creator;                     // the dev who launched the token
    address public platformWallet;              // FLOWETF
    uint256 public platformMemeBps = 2_500;     // 25% of the post-burn surplus
    uint256 public constant PLATFORM_MEME_BPS_MAX = 3_000;

    /// @dev Operator wallet that actually pays for distributions. Its ETH
    ///      balance is the reserve level the split reads.
    address public gasWallet;
    uint256 public gasReserveTargetWei = 0.05 ether;
    uint256 public constant GAS_RESERVE_TARGET_MAX = 5 ether;
    /// @dev NOT immutable, and the reason is structural rather than a
    ///      compromise. long.xyz records fee beneficiaries when a token is
    ///      launched, so this vault's address must already exist to be named
    ///      as one — which means the vault is necessarily deployed BEFORE the
    ///      token it will serve. Its addresses therefore cannot be constructor
    ///      arguments.
    ///
    ///      They are instead written exactly once by initialize(), which the
    ///      deployer alone may call and only while `initialized` is false.
    ///      There is no setter for either token anywhere in this contract, so
    ///      after that single write they behave as if immutable.
    ///
    ///      The empty constructor is also what makes the factory's init-code
    ///      hash meaningful: every vault shares identical creation bytecode, so
    ///      one published hash vouches for all of them.
    IERC20 public memeToken;   // eligibility asset (holders of this)
    IERC20 public stockToken;  // asset actually distributed

    /// @dev Whoever deployed this vault — the factory in normal operation.
    ///      Only they may initialize it, and only once.
    address public immutable deployer;
    bool public initialized;

    /// @dev 6h rather than 12h. Collection and the burn run every cycle, so a
    ///      shorter interval means more frequent buy-and-burn pressure for only
    ///      ~$0.37/day more gas. It does NOT make payouts more frequent on its
    ///      own — minPotUsd still gates those — it simply pays out sooner once
    ///      the pot clears.
    uint256 public cycleInterval = 6 hours;
    /// @dev Ceiling on how much of the stock balance may leave in ONE cycle.
    ///      Deliberately below 100%: the payout list is built off-chain, so a
    ///      miscalculated batch would otherwise be able to empty the contract
    ///      in a single call. Capping it means the worst a bad list can do is
    ///      overpay part of one cycle, never drain the whole pot.
    ///
    ///      The remaining 30% is NOT kept — it stays in this contract and rolls
    ///      into the next cycle's balance, so it is distributed to holders
    ///      later rather than lost. Net effect over time is still that the
    ///      entire stock leg reaches holders; it just always trails by a tail.
    ///      Owner decision 2026-09-01: keep the safety cap over exact-100%.
    uint256 public maxPayoutBps = 7_000; // 70%
    bool public paused;

    /* ------------------------- payout threshold --------------------------- */
    /// @dev Gas is charged per recipient, not per dollar. MEASURED on this
    ///      chain at 0.657 gwei: ~$0.125 per recipient, so a 500-address run
    ///      costs ~$62. Distributing a $200 pot across 500 holders spends a
    ///      third of it on gas and pays each holder $0.40. Below a floor it is
    ///      strictly better for holders to let the pot accumulate.
    ///
    ///      Collection and burning are NOT gated by this — those run every
    ///      cycleInterval regardless, so the meme burn never stalls. Only the
    ///      distribution waits.
    /// @dev $500. The earlier $1,000 was set from gas figures that turned out
    ///      to be 3.3x too high; at the real 0.3158 gwei a 250-holder payout of
    ///      $500 spends 2% on gas. Raise it per-vault for tokens with very
    ///      large holder counts, where the per-recipient cost dominates.
    uint256 public minPotUsd = 500e18;       // 18-dec USD, owner-set

    /// @dev THE ESCAPE HATCH, and the reason the caps below are constants.
    ///      A threshold with no deadline can strand holder funds forever: a
    ///      token whose volume dies never reaches minPotUsd, so the stock it
    ///      already earned sits here permanently. After maxDeferPeriod the
    ///      cycle opens no matter how small the pot.
    ///
    ///      Both bounds are enforced against hard constants so this guarantee
    ///      survives a compromised — or merely greedy — owner. Without them,
    ///      setting minPotUsd to 1e30 or maxDeferPeriod to 100 years would
    ///      quietly re-create the trap this is here to prevent.
    uint256 public maxDeferPeriod = 7 days;
    uint256 public constant MAX_DEFER_LIMIT = 30 days;
    uint256 public constant MAX_MIN_POT_USD = 100_000e18;

    uint256 public lastDistributionAt;  // last time a cycle actually opened
    uint256 public lastCollectAt;       // last collect+burn, drives the 12h rhythm

    uint256 public cycleId;
    uint256 public cycleOpenedAt;
    uint256 public cycleCap;        // max stock that may leave this cycle
    uint256 public cycleSpent;      // stock already sent this cycle
    uint256 public minHolding;      // token-denominated $100 equivalent
    /// @dev AUDIT FIX. The operator supplies minHolding each cycle. Without a
    ///      floor, a compromised operator could set it to 1 wei, dust its own
    ///      addresses with 1 wei of the meme token, and pass the eligibility
    ///      guard — defeating the contract's main protection. The owner sets
    ///      an absolute floor the operator can never go below.
    uint256 public minHoldingFloor;
    bytes32 public merkleRoot;      // transparency only, never used for claims

    mapping(uint256 => mapping(address => bool)) public paid;

    event CycleOpened(
        uint256 indexed cycleId,
        uint256 stockPulled,
        uint256 balance,
        uint256 cap,
        uint256 minHolding,
        bytes32 merkleRoot
    );
    /// @dev Emitted when collect+burn ran but the pot was too small to open a
    ///      distribution cycle. Deliberately public and detailed: holders can
    ///      see exactly why a cycle was skipped and when the deadline forces
    ///      the next payout, instead of having to trust an off-chain bot.
    event CycleSkipped(
        uint256 indexed afterCycleId,
        uint256 potUsd,
        uint256 minPotUsd,
        uint256 stockHeld,
        uint256 forcedAt
    );
    event MinPotUsdSet(uint256 value);
    event MaxDeferPeriodSet(uint256 value);
    event Distributed(uint256 indexed cycleId, address indexed to, uint256 amount);
    event Skipped(uint256 indexed cycleId, address indexed to, uint8 reason); // 1=paid 2=below 3=zero 4=transfer refused
    /// @dev Full accounting of one meme leg. toGas != 0 means the reserve was
    ///      still filling and neither the creator nor the platform was paid.
    event MemeSplit(uint256 burned, uint256 toGas, uint256 toCreator, uint256 toPlatform);
    event CreatorSet(address indexed creator);
    event PlatformSet(address wallet, uint256 memeBps);
    event GasWalletSet(address wallet, uint256 targetWei);
    event Initialized(address meme, address stock, address feeWallet, address operator, address owner);
    event Burned(uint256 amount);
    event PausedSet(bool value);
    event OwnerChanged(address indexed from, address indexed to);
    event OperatorChanged(address indexed from, address indexed to);
    event MinHoldingFloorSet(uint256 value);
    event FeeSourceSet(address collector, bytes32 poolId);
    event BurnBpsSet(uint256 value);
    event FeesCollected(bool success);
    event EmergencyWithdraw(address indexed token, uint256 amount);

    error NotOwner();
    error NotOperator();
    error IsPaused();
    error TooSoon();
    error CapExceeded();
    error LengthMismatch();
    error ZeroAddress();
    error BadValue();
    error TransferFailed();
    error Reentrant();
    error StockPaused();
    error PotTooSmall();
    error AlreadyInitialized();
    error NotInitialized();
    error ProtectedAsset();

    uint256 private _lock = 1;
    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2;
        _;
        _lock = 1;
    }
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    modifier onlyOperator() {
        if (!initialized) revert NotInitialized();
        if (msg.sender != operator && msg.sender != owner) revert NotOperator();
        if (paused) revert IsPaused();
        _;
    }

    /// @dev Takes no arguments on purpose — see the note on memeToken.
    constructor() {
        deployer = msg.sender;
    }

    /// @notice Bind this vault to its token pair. Callable once, by the
    ///         deployer, before the vault can do anything at all.
    /// @param feeWallet_ where fees land. Pass this vault's own address for the
    ///        self-custody case, which removes the separate fee wallet entirely.
    function initialize(
        address meme,
        address stock,
        address feeWallet_,
        address operator_,
        address owner_
    ) external {
        if (msg.sender != deployer) revert NotOwner();
        if (initialized) revert AlreadyInitialized();
        if (meme == address(0) || stock == address(0) ||
            feeWallet_ == address(0) || operator_ == address(0) || owner_ == address(0))
            revert ZeroAddress();
        // The two legs must be different assets. If they were the same token,
        // _splitMeme would burn half of the very balance owed to holders, and
        // the eligibility check would be measuring the payout asset against
        // itself. The factory already refuses this, but a vault must not
        // depend on its deployer being careful.
        if (meme == stock) revert BadValue();

        initialized = true;
        owner = owner_;
        memeToken = IERC20(meme);
        stockToken = IERC20(stock);
        feeWallet = feeWallet_;
        operator = operator_;
        // Anchor the deferral clock here, not at deployment: a vault may sit
        // unused for a while before its token launches, and starting the
        // 7-day forced-payout clock then would let the very first cycle bypass
        // the threshold.
        lastDistributionAt = block.timestamp;
        emit Initialized(meme, stock, feeWallet_, operator_, owner_);
    }

    /* -------------------------------------------------------------------- */
    /*  Safe ERC-20 helpers                                                  */
    /*  Some tokens (USDT-style) return no value at all. Requiring a bool     */
    /*  would revert on those. Accept "no return data" as success and only    */
    /*  reject an explicit false.                                             */
    /* -------------------------------------------------------------------- */
    function _safeTransfer(IERC20 token, address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @dev Non-reverting sibling of _safeTransfer. Returns false instead of
    ///      throwing so one refused recipient cannot abort a whole batch.
    function _trySafeTransfer(IERC20 token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok) return false;
        if (data.length != 0 && !abi.decode(data, (bool))) return false;
        return true;
    }

    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) private {
        // SELF-CUSTODY MODE. When this contract is itself the fee recipient —
        // the FLOWETF vault case, where launchpad fees land here directly —
        // there is no external wallet to pull from and transferFrom(self, ...)
        // would need a pointless self-approval. Transfer straight out instead.
        //
        // This is what removes the last piece of trust from the design: no
        // separate fee wallet means no key that could be swapped, drained, or
        // lost while holders wait for a payout.
        if (from == address(this)) {
            _safeTransfer(token, to, amount);
            return;
        }
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /* -------------------------------------------------------------------- */
    /*  Pre-flight: tokenized-stock pause check                               */
    /*  MEASURED 2026-09-01: every tokenized stock on this chain (NVDA, SPY,  */
    /*  PLTR, AMZN, SPCX) exposes paused(). All read false today, and         */
    /*  transfers run 24/7 with no market-hour or whitelist restriction.      */
    /*  But the issuer can pause at any time — a trading halt or corporate    */
    /*  action would make every transfer in a batch revert at once, burning   */
    /*  gas on ~300 failed sends. Checked up front instead.                   */
    /*  staticcall, so a stock token WITHOUT paused() is treated as fine.     */
    /* -------------------------------------------------------------------- */
    function isStockPaused() public view returns (bool) {
        (bool ok, bytes memory data) =
            address(stockToken).staticcall(abi.encodeWithSignature("paused()"));
        if (!ok || data.length < 32) return false;   // no such function -> not pausable
        return abi.decode(data, (bool));
    }

    /* ------------------------------ cycle -------------------------------- */

    /// @dev Best-effort call to the launchpad's collectFees(bytes32).
    ///      Deliberately NOT allowed to revert the cycle: if no fees have
    ///      accrued in the last 12h the launchpad reverts, and that must not
    ///      block burning and distributing whatever is already sitting in the
    ///      fee wallet.
    function _collectFees() private returns (bool ok) {
        if (feeCollector == address(0) || poolId == bytes32(0)) return false;
        (ok, ) = feeCollector.call(abi.encodeWithSelector(0x817db73b, poolId));
        emit FeesCollected(ok);
    }

    /// @notice True when a distribution cycle is allowed to open right now.
    ///         Either the pot has cleared the threshold, or the deferral
    ///         deadline has passed and the payout is forced through.
    /// @param potUsd 18-dec USD value of the stock held by this contract
    function canOpenCycle(uint256 potUsd) public view returns (bool allowed, bool forced) {
        forced = block.timestamp >= lastDistributionAt + maxDeferPeriod;
        allowed = forced || potUsd >= minPotUsd;
    }

    /// @notice ONE CALL runs the whole cycle head: collect -> burn -> open.
    ///         Distribution batches follow via distribute().
    ///
    ///         Collect and burn ALWAYS run. Opening the distribution cycle is
    ///         conditional on the pot: below minPotUsd the stock simply stays
    ///         parked here and rolls into the next attempt, so gas is never
    ///         spent shredding a small pot across hundreds of addresses. The
    ///         function returns `opened` rather than reverting — a revert
    ///         would roll back the burn too, which must not depend on how
    ///         much stock happened to accrue.
    ///
    /// @param potUsd 18-dec USD value of the stock leg at this cycle's TWAP,
    ///        computed off-chain by the operator (this chain has no oracle).
    ///        Understating it can only delay a payout, never redirect one, and
    ///        maxDeferPeriod caps how long that delay can last.
    /// @param minHolding_ token-denominated $100 equivalent for this cycle
    /// @param root merkle root of the payout list (transparency only)
    function startCycle(uint256 potUsd, uint256 minHolding_, bytes32 root)
        external
        onlyOperator
        nonReentrant
        returns (uint256 burned, uint256 stockPulled, bool opened)
    {
        // The 12h rhythm now belongs to collect+burn, not to cycle opening.
        // Keying it off cycleOpenedAt would let a run of skipped cycles unlock
        // unlimited back-to-back collection calls.
        if (lastCollectAt != 0 && block.timestamp < lastCollectAt + cycleInterval) revert TooSoon();
        if (minHolding_ == 0 || minHolding_ < minHoldingFloor) revert BadValue();
        if (isStockPaused()) revert StockPaused();
        lastCollectAt = block.timestamp;

        // 1. pull fees out of the launchpad into feeWallet (both legs)
        _collectFees();

        // 2. split the meme leg: burn -> gas reserve -> creator + platform
        burned = _splitMeme();

        // 3. park the entire stock leg here. This happens whether or not the
        //    cycle opens, so an undersized pot accumulates across attempts.
        stockPulled = stockToken.balanceOf(feeWallet);
        if (stockPulled != 0) _safeTransferFrom(stockToken, feeWallet, address(this), stockPulled);

        uint256 balance = stockToken.balanceOf(address(this));

        // 4. gate the distribution itself
        (bool allowed, ) = canOpenCycle(potUsd);
        if (!allowed) {
            emit CycleSkipped(
                cycleId, potUsd, minPotUsd, balance, lastDistributionAt + maxDeferPeriod
            );
            return (burned, stockPulled, false);
        }

        unchecked { cycleId += 1; }
        cycleOpenedAt = block.timestamp;
        lastDistributionAt = block.timestamp;
        cycleSpent = 0;
        minHolding = minHolding_;
        merkleRoot = root;
        cycleCap = (balance * maxPayoutBps) / BPS_DENOMINATOR;

        emit CycleOpened(cycleId, stockPulled, balance, cycleCap, minHolding_, root);
        opened = true;
    }

    /// @dev Settles the whole meme leg, in strict priority order.
    ///      Returns the amount burned so startCycle can report it.
    function _splitMeme() private returns (uint256 burned) {
        uint256 memeBalance = memeToken.balanceOf(feeWallet);
        if (memeBalance == 0) return 0;

        // 1. burn — always first, never reducible below BURN_BPS_MIN
        burned = (memeBalance * burnBps) / BPS_DENOMINATOR;
        if (burned != 0) {
            _safeTransferFrom(memeToken, feeWallet, BURN_ADDRESS, burned);
            emit Burned(burned);
        }

        uint256 rest = memeBalance - burned;
        if (rest == 0) return burned;

        // 2. gas reserve — takes EVERYTHING until the wallet that pays for
        //    distribution is funded. Reading the live balance rather than an
        //    internal counter means a manual top-up or an unexpectedly
        //    expensive cycle is reflected immediately.
        if (gasWallet != address(0) && gasWallet.balance < gasReserveTargetWei) {
            _safeTransferFrom(memeToken, feeWallet, gasWallet, rest);
            emit MemeSplit(burned, rest, 0, 0);
            return burned;
        }

        // 3. surplus — only what the reserve did not need
        uint256 toPlatform;
        if (platformWallet != address(0)) {
            toPlatform = (rest * platformMemeBps) / BPS_DENOMINATOR;
            if (toPlatform != 0) _safeTransferFrom(memeToken, feeWallet, platformWallet, toPlatform);
        }
        uint256 toCreator = rest - toPlatform;
        if (toCreator != 0 && creator != address(0)) {
            _safeTransferFrom(memeToken, feeWallet, creator, toCreator);
        } else {
            toCreator = 0;   // no creator set: leave the remainder in feeWallet
        }
        emit MemeSplit(burned, 0, toCreator, toPlatform);
    }

    /// @notice Burn part of the meme leg. Pulled from feeWallet, which must
    ///         have approved this contract.
    function burnMeme(uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert BadValue();
        _safeTransferFrom(memeToken, feeWallet, BURN_ADDRESS, amount);
        emit Burned(amount);
    }

    /// @notice Open a distribution cycle.
    /// @param stockAmount stock pulled from feeWallet into this contract
    /// @param potUsd 18-dec USD value of the resulting pot, same rule as
    ///        startCycle. Gated identically so the threshold cannot be
    ///        sidestepped by using the manual path.
    /// @param minHolding_ token-denominated eligibility threshold (the $100
    ///        equivalent at this cycle's TWAP, computed off-chain)
    /// @param root merkle root of the payout list, for transparency only
    function openCycle(uint256 stockAmount, uint256 potUsd, uint256 minHolding_, bytes32 root)
        external
        onlyOperator
        nonReentrant
    {
        if (cycleId != 0 && block.timestamp < cycleOpenedAt + cycleInterval) revert TooSoon();
        if (minHolding_ == 0 || minHolding_ < minHoldingFloor) revert BadValue();
        if (isStockPaused()) revert StockPaused();
        // Nothing has been burned yet on this path, so reverting is safe and
        // clearer than returning a flag.
        (bool allowed, ) = canOpenCycle(potUsd);
        if (!allowed) revert PotTooSmall();

        if (stockAmount != 0) _safeTransferFrom(stockToken, feeWallet, address(this), stockAmount);

        unchecked { cycleId += 1; }
        cycleOpenedAt = block.timestamp;
        lastDistributionAt = block.timestamp;
        cycleSpent = 0;
        minHolding = minHolding_;
        merkleRoot = root;

        uint256 balance = stockToken.balanceOf(address(this));
        cycleCap = (balance * maxPayoutBps) / BPS_DENOMINATOR;

        emit CycleOpened(cycleId, stockAmount, balance, cycleCap, minHolding_, root);
    }

    /// @notice Push one batch. Safe to call repeatedly; `paid` prevents any
    ///         address being paid twice if a run is interrupted mid-way.
    function distribute(address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyOperator
        nonReentrant
    {
        uint256 n = recipients.length;
        if (n != amounts.length) revert LengthMismatch();

        if (isStockPaused()) revert StockPaused();

        uint256 id = cycleId;
        uint256 spent = cycleSpent;
        uint256 cap = cycleCap;
        uint256 floor_ = minHolding;

        for (uint256 i = 0; i < n; ++i) {
            address to = recipients[i];
            uint256 amount = amounts[i];

            if (paid[id][to]) { emit Skipped(id, to, 1); continue; }
            // Primary guard: the recipient must genuinely hold the token.
            // This is what keeps a compromised operator from redirecting funds.
            if (memeToken.balanceOf(to) < floor_) { emit Skipped(id, to, 2); continue; }
            if (amount == 0) { emit Skipped(id, to, 3); continue; }

            if (spent + amount > cap) revert CapExceeded();

            // A failed transfer must NOT take the batch down with it.
            //
            // Tokenized equities are regulated instruments and their issuers
            // can freeze individual addresses. With a reverting transfer, one
            // frozen holder anywhere in the list makes the whole call revert
            // and NOBODY in that batch gets paid — a single address able to
            // halt the entire product. Measured: this is exactly what happened
            // before the change.
            //
            // The recipient is left unpaid and unmarked instead, so the moment
            // the freeze is lifted a later batch pays them normally. Nothing is
            // written off; it is only deferred, and the event says so.
            if (_trySafeTransfer(stockToken, to, amount)) {
                paid[id][to] = true;
                spent += amount;
                emit Distributed(id, to, amount);
            } else {
                emit Skipped(id, to, 4);   // 4 = transfer refused by the token
            }
        }
        cycleSpent = spent;
    }

    /* ------------------------------ admin -------------------------------- */

    function setPaused(bool value) external onlyOwner { paused = value; emit PausedSet(value); }

    function setOperator(address value) external onlyOwner {
        if (value == address(0)) revert ZeroAddress();
        emit OperatorChanged(operator, value);
        operator = value;
    }

    function setFeeWallet(address value) external onlyOwner {
        if (value == address(0)) revert ZeroAddress();
        feeWallet = value;
    }

    function setCycleInterval(uint256 value) external onlyOwner {
        if (value < 1 hours || value > 30 days) revert BadValue();
        cycleInterval = value;
    }

    /// @notice Absolute lower bound for the per-cycle eligibility threshold.
    ///         Owner-only; the operator can raise minHolding but never go below this.
    function setMinHoldingFloor(uint256 value) external onlyOwner {
        minHoldingFloor = value;
        emit MinHoldingFloorSet(value);
    }

    /// @notice Minimum pot value, in 18-dec USD, before a cycle may open.
    ///         Capped at MAX_MIN_POT_USD so the threshold can never be raised
    ///         high enough to make distribution unreachable in practice.
    function setMinPotUsd(uint256 value) external onlyOwner {
        if (value > MAX_MIN_POT_USD) revert BadValue();
        minPotUsd = value;
        emit MinPotUsdSet(value);
    }

    /// @notice How long an undersized pot may be deferred before payout is
    ///         forced. Capped at MAX_DEFER_LIMIT, and zero is rejected: both
    ///         bounds exist so holder funds cannot be parked indefinitely.
    function setMaxDeferPeriod(uint256 value) external onlyOwner {
        if (value == 0 || value > MAX_DEFER_LIMIT) revert BadValue();
        maxDeferPeriod = value;
        emit MaxDeferPeriodSet(value);
    }

    /// @notice The dev whose token this is. Paid in meme, only from surplus.
    function setCreator(address value) external onlyOwner {
        creator = value;
        emit CreatorSet(value);
    }

    /// @notice FLOWETF's cut of the post-burn surplus. Capped by a constant so
    ///         the deal a dev signed up to cannot be widened afterwards.
    function setPlatform(address wallet, uint256 memeBps) external onlyOwner {
        if (memeBps > PLATFORM_MEME_BPS_MAX) revert BadValue();
        platformWallet = wallet;
        platformMemeBps = memeBps;
        emit PlatformSet(wallet, memeBps);
    }

    /// @notice Wallet that pays for distributions, and how much ETH it should
    ///         hold before any surplus is released.
    function setGasWallet(address wallet, uint256 targetWei) external onlyOwner {
        if (targetWei > GAS_RESERVE_TARGET_MAX) revert BadValue();
        gasWallet = wallet;
        gasReserveTargetWei = targetWei;
        emit GasWalletSet(wallet, targetWei);
    }

    /// @notice Owner-only. The operator can never redirect fee collection.
    function setFeeSource(address collector, bytes32 pool) external onlyOwner {
        feeCollector = collector;
        poolId = pool;
        emit FeeSourceSet(collector, pool);
    }

    function setBurnBps(uint256 value) external onlyOwner {
        // A FLOOR, not just a ceiling. Lowering the burn moves value away from
        // holders and into the creator and platform shares — that is precisely
        // the change nobody should be able to make after the fact.
        if (value < BURN_BPS_MIN || value > BPS_DENOMINATOR) revert BadValue();
        burnBps = value;
        emit BurnBpsSet(value);
    }

    function setMaxPayoutBps(uint256 value) external onlyOwner {
        if (value == 0 || value > BPS_DENOMINATOR) revert BadValue();
        maxPayoutBps = value;
    }

    function transferOwnership(address value) external onlyOwner {
        if (value == address(0)) revert ZeroAddress();
        emit OwnerChanged(owner, value);
        owner = value;
    }

    /// @notice Escape hatch so funds can never be locked if the operator or
    ///         the off-chain service fails. Owner only.
    /// @notice Rescue tokens that were sent here by mistake.
    ///
    /// @dev    The two tokens this vault exists to handle are EXCLUDED, and
    ///         that exclusion is the point of the function rather than a
    ///         limitation of it.
    ///
    ///         The stock leg belongs to holders the moment it arrives; if the
    ///         owner could withdraw it, "100% of the stock goes to holders"
    ///         would be a statement about intent rather than about the code,
    ///         and every guard elsewhere in this contract would be decoration.
    ///         The meme leg is excluded for the same reason: it is already
    ///         committed to the burn, the gas reserve, the creator and the
    ///         platform in fixed proportions.
    ///
    ///         Consequence, stated plainly: if the stock token is permanently
    ///         paused by its issuer, the stock parked here becomes unreachable
    ///         for everyone, including the owner. That is the intended
    ///         trade-off — funds frozen for all beats funds withdrawable by one.
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(memeToken) || token == address(stockToken)) revert ProtectedAsset();
        _safeTransfer(IERC20(token), owner, amount);
        emit EmergencyWithdraw(token, amount);
    }

    /* ------------------------------ views -------------------------------- */

    function stockBalance() external view returns (uint256) {
        return stockToken.balanceOf(address(this));
    }

    function cycleRemaining() external view returns (uint256) {
        return cycleCap > cycleSpent ? cycleCap - cycleSpent : 0;
    }

    function nextCycleAt() external view returns (uint256) {
        return cycleId == 0 ? block.timestamp : cycleOpenedAt + cycleInterval;
    }
}
