// keccak-256, written out in full because the page must stay self-contained:
// the Artifact/CSP rules forbid loading a library, and SubtleCrypto offers
// SHA-256 but not keccak. Needed to predict CREATE2 vault addresses locally so
// salt mining is instant instead of one RPC round-trip per attempt.
//
// Verified against the empty-string vector and against the deployed factory's
// own predictVault() before being trusted for anything.
export function keccak256(bytes) {
  const RC = [
    0x00000001n, 0x00008082n, 0x800000000000808an, 0x8000000080008000n,
    0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
    0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
    0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
    0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
    0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
  ];
  const R = [
    [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56], [27, 20, 39, 8, 14],
  ];
  const M = (1n << 64n) - 1n;
  const rol = (x, n) => ((x << BigInt(n)) | (x >> BigInt(64 - n))) & M;

  const rate = 136;                       // 1088 bits for keccak-256
  const A = Array.from({ length: 5 }, () => new Array(5).fill(0n));

  // pad10*1 with the keccak (not SHA-3) domain byte
  const len = bytes.length;
  const padded = new Uint8Array(Math.ceil((len + 1) / rate) * rate);
  padded.set(bytes);
  padded[len] = 0x01;
  padded[padded.length - 1] |= 0x80;

  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate / 8; i++) {
      let lane = 0n;
      for (let b = 7; b >= 0; b--) lane = (lane << 8n) | BigInt(padded[off + i * 8 + b]);
      A[i % 5][(i / 5) | 0] ^= lane;
    }
    for (let round = 0; round < 24; round++) {
      const C = new Array(5), D = new Array(5);
      for (let x = 0; x < 5; x++) C[x] = A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4];
      for (let x = 0; x < 5; x++) D[x] = C[(x + 4) % 5] ^ rol(C[(x + 1) % 5], 1);
      for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) A[x][y] ^= D[x];

      const B = Array.from({ length: 5 }, () => new Array(5).fill(0n));
      for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) {
        B[y][(2 * x + 3 * y) % 5] = rol(A[x][y], R[x][y]);
      }
      for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) {
        A[x][y] = B[x][y] ^ (~B[(x + 1) % 5][y] & M & B[(x + 2) % 5][y]);
      }
      A[0][0] ^= RC[round];
    }
  }

  const outBytes = new Uint8Array(32);
  for (let i = 0; i < 4; i++) {
    let lane = A[i % 5][(i / 5) | 0];
    for (let b = 0; b < 8; b++) { outBytes[i * 8 + b] = Number(lane & 0xffn); lane >>= 8n; }
  }
  return outBytes;
}

export const hexToBytes = (h) => {
  h = h.replace(/^0x/, '');
  const o = new Uint8Array(h.length / 2);
  for (let i = 0; i < o.length; i++) o[i] = parseInt(h.substr(i * 2, 2), 16);
  return o;
};
export const bytesToHex = (b) =>
  '0x' + Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');

/** The factory binds the salt to the creator; mirror that exactly. */
export function effectiveSalt(salt, creator) {
  const enc = hexToBytes(pad(creator) + pad(salt));
  return bytesToHex(keccak256(enc)).slice(2);
}

/** CREATE2 address, matching the factory's predictVault(). */
export function predictVault(factory, salt, creator, initCodeHash) {
  const pre = 'ff' + factory.replace(/^0x/, '') +
    effectiveSalt(salt, creator) + initCodeHash.replace(/^0x/, '');
  return '0x' + bytesToHex(keccak256(hexToBytes(pre))).slice(26);
}

export const pad = (v) => String(v).replace(/^0x/, '').padStart(64, '0');
