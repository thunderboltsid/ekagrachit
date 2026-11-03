// Renders the Ekagrachit app icon (1024×1024 PNG) without dependencies:
// a deep indigo squircle on the macOS icon grid, a quiet ring, and one warm
// focal point. scripts/build-app.sh turns it into AppIcon.icns.
//   node scripts/make-app-icon.mjs [out.png] [size]   (default: 1024)
//   node scripts/make-app-icon.mjs --extension        (Chrome toolbar/store icons)
import { deflateSync } from 'node:zlib';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const C = 512; // design space is 1024×1024; output is scaled
let ringW = 15;
const R = 412; // squircle half-size: 824 pt body inside the 1024 canvas (Apple grid)
const N = 5; // superellipse exponent ≈ Apple's continuous-corner squircle

const mix = (a, b, t) => a + (b - a) * t;
const clamp = (x, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, x));
const smooth = (e0, e1, x) => { const t = clamp((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t); };
// Signed "distance-ish" to the superellipse boundary, in pixels (negative inside).
const sq = (x, y) => (Math.pow(Math.abs(x / R), N) + Math.pow(Math.abs(y / R), N)) ** (1 / N) * R - R;

function shade(x, y) {
  // returns [r,g,b,a] premultiplied-free, 0..1
  const dx = x - C, dy = y - C;
  const d = sq(dx, dy);
  const r = Math.hypot(dx, dy);
  // Shadow outside the body
  if (d > 0) {
    const sd = sq(dx, dy - 14);
    const a = 0.32 * (1 - smooth(0, 34, sd));
    return [0.02, 0.02, 0.06, a];
  }
  // Body: vertical gradient, indigo -> night
  const t = (y - (C - R)) / (2 * R);
  let cr = mix(0.25, 0.07, t), cg = mix(0.27, 0.08, t), cb = mix(0.62, 0.20, t);
  // Soft vignette toward the edges
  const v = smooth(R * 0.55, R * 1.05, r);
  cr *= 1 - 0.25 * v; cg *= 1 - 0.25 * v; cb *= 1 - 0.18 * v;
  // Warm glow around the focal point
  const glow = Math.exp(-((r / 210) ** 2)) * 0.55;
  cr = mix(cr, 1.0, glow * 0.55); cg = mix(cg, 0.62, glow * 0.45); cb = mix(cb, 0.28, glow * 0.25);
  // The ring: a thin, slightly luminous circle
  const ringR = 262;
  const ring = 1 - smooth(ringW - 2.2, ringW + 2.2, Math.abs(r - ringR) * 2);
  cr = mix(cr, 0.93, ring * 0.82); cg = mix(cg, 0.93, ring * 0.82); cb = mix(cb, 0.98, ring * 0.82);
  // The focal point: warm amber dot with a lighter core
  const dotR = 74;
  const dot = 1 - smooth(dotR - 1.6, dotR + 1.6, r);
  const core = Math.exp(-((r / 40) ** 2));
  const dr = mix(1.0, 1.0, core), dg = mix(0.66, 0.90, core), db = mix(0.22, 0.62, core);
  cr = mix(cr, dr, dot); cg = mix(cg, dg, dot); cb = mix(cb, db, dot);
  // Top sheen (subtle glass highlight)
  const sheen = (1 - smooth(-R, -R * 0.1, dy)) * 0.07 * (1 - smooth(-6, 0, d));
  cr = mix(cr, 1, sheen); cg = mix(cg, 1, sheen); cb = mix(cb, 1, sheen);
  // Hairline inner edge for definition
  const edge = (1 - smooth(0.5, 3, -d)) * 0.18;
  cr = mix(cr, 1, edge); cg = mix(cg, 1, edge); cb = mix(cb, 1, edge);
  return [cr, cg, cb, 1];
}

const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc32 = (buf) => { let c = 0xffffffff; for (const v of buf) c = crcTable[(c ^ v) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
const chunk = (type, data) => {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
};
function render(S, out) {
  const k = 1024 / S; // design units per output pixel
  ringW = Math.max(15, 1.6 * k); // keep the ring visible at toolbar sizes
  const ss = S <= 64 ? 6 : 3;
  const raw = Buffer.alloc(S * (S * 4 + 1));
  for (let y = 0; y < S; y++) {
    raw[y * (S * 4 + 1)] = 0;
    for (let x = 0; x < S; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let sy = 0; sy < ss; sy++) for (let sx = 0; sx < ss; sx++) {
        const [pr, pg, pb, pa] = shade((x + (sx + 0.5) / ss) * k, (y + (sy + 0.5) / ss) * k);
        r += pr * pa; g += pg * pa; b += pb * pa; a += pa;
      }
      const o = y * (S * 4 + 1) + 1 + x * 4;
      if (a > 0) { r /= a; g /= a; b /= a; }
      raw[o] = Math.round(clamp(r) * 255);
      raw[o + 1] = Math.round(clamp(g) * 255);
      raw[o + 2] = Math.round(clamp(b) * 255);
      raw[o + 3] = Math.round(clamp(a / (ss * ss)) * 255);
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(S, 0); ihdr.writeUInt32BE(S, 4); ihdr[8] = 8; ihdr[9] = 6;
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]));
  console.log(`wrote ${out} (${S}px)`);
}

if (process.argv[2] === '--extension') {
  for (const s of [16, 32, 48, 128]) render(s, join(root, `extensions/chrome/assets/icons/${s}.png`));
} else {
  render(Number(process.argv[3] ?? 1024), process.argv[2] ?? join(root, 'apps/macos/Resources/AppIcon-1024.png'));
}
