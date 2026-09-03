/* FLOWETF — local dev server. No dependencies; `node dev-server.mjs`.
 *
 * Serves the static files and stands in for the two relays the pages expect on
 * their own origin, so the site behaves locally the way it does in production:
 *
 *   /rpc          POST -> the Robinhood Chain JSON-RPC endpoint
 *   /ipfs/<cid>   GET  -> a locally pinned file, else a public gateway
 *
 * This mirrors Caddyfile exactly. If you change one, change the other.
 * /api/upload and /api/metadata are not implemented here: they need a pinning
 * service, and a launch with no image and no description never calls them.
 */
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize, resolve } from 'node:path';

const ROOT = resolve(import.meta.dirname);
const PORT = Number(process.env.PORT) || 4173;
const RPC_UPSTREAM = 'https://rpc.mainnet.chain.robinhood.com';
const IPFS_GATEWAY = 'https://ipfs.io';

/* .js must be here and must be a JavaScript type: keccak.js is imported as an
   ES module, and a module served as octet-stream is refused outright under the
   spec's strict MIME check. Caddy's own table already gets this right. */
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.sol': 'text/plain; charset=utf-8',
  '.template': 'text/plain; charset=utf-8',
  '.initcode': 'text/plain; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
};

/* Pinned IPFS files are named by their hash and so have no extension. The type
   has to come from the bytes, or the browser is handed octet-stream for the
   artwork on the landing page. */
function sniff(buf) {
  if (buf.length > 3 && buf[0] === 0xff && buf[1] === 0xd8) return 'image/jpeg';
  if (buf.length > 8 && buf.subarray(0, 8).toString('hex') === '89504e470d0a1a0a') return 'image/png';
  if (buf.length > 12 && buf.subarray(0, 4).toString() === 'RIFF' && buf.subarray(8, 12).toString() === 'WEBP') return 'image/webp';
  if (buf.length > 5 && buf.subarray(0, 4).toString() === 'GIF8') return 'image/gif';
  const head = buf.subarray(0, 256).toString('utf8').trimStart();
  if (head.startsWith('<svg') || head.startsWith('<?xml')) return 'image/svg+xml';
  if (head.startsWith('{') || head.startsWith('[')) return 'application/json; charset=utf-8';
  return 'application/octet-stream';
}

function body(req) {
  return new Promise((ok, no) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => ok(Buffer.concat(chunks)));
    req.on('error', no);
  });
}

/* Resolution order matches Caddy's try_files: the exact path, then the path as
   a directory holding an index.html, then the path with .html appended. */
async function findFile(pathname) {
  const rel = normalize(decodeURIComponent(pathname)).replace(/^(\.\.[/\\])+/, '');
  const base = join(ROOT, rel);
  if (!base.startsWith(ROOT)) return null;          // no escaping the root
  for (const candidate of [base, join(base, 'index.html'), base + '.html']) {
    try {
      const s = await stat(candidate);
      if (s.isFile()) return candidate;
    } catch {}
  }
  return null;
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname;

  try {
    if (p === '/rpc') {
      const up = await fetch(RPC_UPSTREAM, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: await body(req),
      });
      const text = await up.text();
      res.writeHead(up.status, { 'content-type': 'application/json; charset=utf-8' });
      return res.end(text);
    }

    const file = await findFile(p === '/' ? '/index.html' : p);

    if (!file && p.startsWith('/ipfs/')) {
      const up = await fetch(IPFS_GATEWAY + p);
      const buf = Buffer.from(await up.arrayBuffer());
      res.writeHead(up.status, {
        'content-type': up.headers.get('content-type') || 'application/octet-stream',
        'cache-control': 'public, max-age=31536000, immutable',
      });
      return res.end(buf);
    }

    if (!file) {
      res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
      return res.end('404');
    }

    const data = await readFile(file);
    res.writeHead(200, {
      'content-type': TYPES[extname(file)] || sniff(data),
      'cache-control': p.startsWith('/ipfs/') ? 'public, max-age=31536000, immutable' : 'no-cache',
    });
    res.end(data);
  } catch (e) {
    res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('upstream error: ' + e.message);
  }
});

server.listen(PORT, () => console.log(`FLOWETF on http://localhost:${PORT}`));
