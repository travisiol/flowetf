# FLOWETF

Hold the token. Earn real stock.

Automatic stock distributions for [long.xyz](https://long.xyz) tokens on Robinhood
Chain. A long.xyz pool collects fees in whatever it is anchored to — usually a
tokenized stock. FLOWETF puts a vault in the fee-receiver position and pushes
that stream to holders every six hours. Nobody claims, nobody signs.

## What this is

Four hand-written HTML pages. No build step, no framework, no dependencies, no
bundler — every page carries its own CSS and JS inline and runs from a plain
file server.

```
index.html          the landing page: the pair, the cycle ring, the
                    fee-receiver check, how it works, the FAQ
docs/index.html     how it works in full — launch mode, manual mode, the
                    cycle, the burn, the fee table, the rules the contracts
                    enforce
launch/index.html   the four-step launcher: metadata, anchor, vault, launch
t/index.html        per-token page, read with ?a=0x…

keccak.js           keccak-256 as an ES module, shared by the launch and
                    token pages. Predicts CREATE2 vault addresses locally so
                    salt mining costs no RPC round-trips
anchors.json        the assets a pool can be anchored to (symbol, address,
                    name, kind, decimals)
tokens.json         class-2 tokens only — teams who point their fee stream
                    at us voluntarily. Class-1 tokens are read from the
                    factory on-chain and are deliberately not editable here
launch.template     calldata template for the long.xyz launcher
vault.initcode      vault creation bytecode
src/*.sol           the contract sources the docs link to
ipfs/<cid>          locally pinned artwork, served by content hash

Caddyfile           production config: static files plus the relays below
dev-server.mjs      the same thing locally — node dev-server.mjs
```

## Running it

```bash
node dev-server.mjs
```

Then open <http://localhost:4173>. Zero dependencies; Node 18+ for `fetch`.

## The three server endpoints

Everything else is a file. These three cannot be, and both `Caddyfile` and
`dev-server.mjs` implement the first two identically — if you change one,
change the other.

| Path | Method | Why it cannot be a file |
|---|---|---|
| `/rpc` | POST | Robinhood is a US broker and its RPC endpoint appears to be geo-restricted — a direct browser fetch fails outright on some networks. Relaying it through this origin makes the page work everywhere. Reads go through the connected wallet when there is one, and fall back to this. |
| `/ipfs/<cid>` | GET | Avoids CORS and the public gateway rate limit. Content addressed by its own hash can never change, so it is cached for a year. Locally pinned files win; anything else is relayed. |
| `/api/upload`, `/api/metadata` | POST | Image and metadata pinning for the launch flow. **Not implemented here** — point them at your own pinning service. Both are optional: a launch with no image and no description never calls them. |

`/api/upload` takes raw image bytes and returns `{ uri, url, pinned, bytes }`.
`/api/metadata` takes `{ name, description, imageUri, ...socials }` and returns
`{ uri }`.

`/holders/<token>.json` is a holder snapshot read by the token page to show who
a cycle would pay. Shape:

```json
{ "token": "0x…", "block": 53400689, "updatedAt": "…Z",
  "holders": [["0x…", "50750198190044144172597440"], …] }
```

**These are generated, and the two checked in here are stale copies of the
original deployment's.** Regenerate them on a schedule against your own tokens.
Their absence is handled — the page just shows an empty payout list.

## Before this goes live

The site is a faithful copy of a working deployment, so it still carries that
deployment's addresses and handles. Each of these is a real value pointing at
something that is not yours yet:

- **`X_URL`** — `https://x.com/FlowETF_RH`, in `index.html` and `launch/index.html`.
  A placeholder in the original too; set it once, in both files.
- **`OFFICIAL`** in `index.html` — the token whose vault drives the cycle ring
  and which the grid marks `OFFICIAL`. Currently `0xef8f…b1ad`.
- **`FACTORY` / `HOOK` / `EXPLORER`** — the deployed factory, the long.xyz fee
  hook, and the block explorer. The hook is long.xyz's and stays; the factory is
  the one you deploy.
- **`flowetf.xyz`** — the origin, in the `og:url` meta, in `resolveUri()` on two
  pages, and in the `Caddyfile` site address.
- **`src/FlowetfFactory.sol`** — renamed from `LongetfFactory` for consistency.
  Note that renaming a contract changes its compiled bytecode, so this source no
  longer matches the factory currently deployed at the address above. It matches
  a factory you deploy under the new name. `StockFeeDistributor` is unchanged.

## What the contracts enforce

- The vault can only send the one stock token it was deployed with.
- Only to addresses that genuinely hold your token.
- At most 70% of the balance per cycle.
- No withdraw-to-owner path on the distribution side.

Not audited by an outside firm.

## Disclaimer

FLOWETF distributes trading fees generated by long.xyz pools. Not an investment
product, not a fund, not affiliated with Robinhood, long.xyz, or any issuer of
the underlying stocks. Payouts depend entirely on trading activity and can be
zero. Tokenized stocks can be paused by their issuer, which pauses distribution
with them. Nothing here is financial advice.
