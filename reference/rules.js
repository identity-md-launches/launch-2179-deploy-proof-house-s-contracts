// ARTIFACTS reference renderer, written from "the rules (generative constitution)" R1–R9.
// Integer steps use exact 32-bit arithmetic (Math.imul), so a 256-bit seed folds the same way in any language.
'use strict';
const PALETTES = [
  ["SUNSET",[[300,75,50],[340,82,52],[20,85,52],[45,88,52],[180,55,58]]],["AURORA",[[280,70,46],[315,75,50],[185,80,48],[150,75,50]]],
  ["NEON",[[320,88,52],[15,85,52],[55,88,52],[100,80,48]]],["TROPIC",[[175,78,46],[155,80,44],[45,85,52],[5,80,54]]],
  ["PLASMA",[[270,72,44],[320,82,50],[15,85,50],[50,88,54]]],["OCEAN",[[220,82,42],[195,80,46],[175,78,50],[145,72,54]]],
  ["MIAMI",[[325,82,54],[10,85,54],[50,85,52],[185,80,52]]],["ELECTRIC",[[265,78,46],[230,82,48],[195,85,50],[150,78,52]]],
  ["FIRE",[[355,82,44],[20,85,48],[40,88,52],[55,88,58]]],["PRISM",[[355,80,50],[25,82,52],[55,85,52],[140,72,48],[210,78,48],[280,75,48]]],
  ["BRUISE",[[280,72,40],[315,75,44],[345,72,50],[20,72,54]]],["VAPOR",[[200,80,52],[280,72,52],[325,78,54],[40,80,56]]],
  ["EMBER",[[45,88,54],[355,82,46]]],["ICE",[[190,80,54],[232,82,44]]],["ROSE",[[330,80,56],[278,72,46]]],["LIME",[[95,80,50],[158,75,44]]],
  ["DUSK",[[235,72,46],[12,82,54]]],["MAGMA",[[10,85,42],[25,90,50],[45,92,58]]],["JADE",[[165,75,42],[150,72,48],[118,65,52]]],
  ["ULTRA",[[275,80,48],[245,82,52],[305,78,55]]],["STORM",[[220,48,48],[262,42,52],[190,52,55]]],["CITRUS",[[95,85,52],[68,88,54],[45,90,56]]],
  ["BERRY",[[330,75,46],[300,70,44],[356,72,48]]],["LAGOON",[[186,80,46],[196,82,52],[160,72,52]]],["MARS",[[16,78,44],[30,74,48],[40,68,54]]],
  ["COSMIC",[[250,80,40],[284,75,46],[322,72,52],[212,78,48]]],["GOLD",[[48,90,52],[42,88,58],[54,84,64]]],
  ["TWILIGHT",[[255,70,42],[316,72,50],[26,82,56]]],["ACID",[[80,88,50],[112,82,48],[170,78,52]]],["COBALT",[[226,85,48],[200,82,54]]],
  ["BLOOD",[[356,85,40],[338,80,48]]],["SEAFOAM",[[160,70,54],[182,68,58]]],["PEACH",[[26,82,60],[344,70,62]]],["VOID",[[260,75,38],[228,70,44]]],
].map(([name, stops]) => ({ name, stops }));
const TITLES = ["SPECTRUM","CHROMA","BLOOM","STIPPLE","DRIFT","HALFTONE","PRISM","RADIATE","FIELD","FLUX"];
const DIRS = ["VERTICAL","HORIZONTAL","DIAGONAL","RADIAL","ANTIDIAG","CONIC","DIAMOND","SPIRAL"];
const PRISM = [[355,82,52],[18,86,54],[46,88,56],[92,76,50],[150,74,50],[192,80,52],[232,80,52],[288,78,54],[330,80,54]];

// R2
function mulberry32(a) { return function () { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
// R1: fold the seed (BigInt, up to 256 bits) to 32 bits, then multiply mod 2^32.
const low32 = (seed) => Number(BigInt(seed) & 0xffffffffn);
const mix = (s, a, x, b, y, c) => (Math.imul(s, a) + Math.imul(x, b) + Math.imul(y, c)) >>> 0;

const ss = (t) => t * t * (3 - 2 * t);
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
function reduceStops(s, k) { if (k >= s.length) return s; if (k <= 1) return [s[0]]; const o = []; for (let i = 0; i < k; i++) o.push(s[Math.round(i * (s.length - 1) / (k - 1))]); return o; }
function grad(st, t, pos) { const n = st.length; if (t <= pos[0]) return st[0]; if (t >= pos[n - 1]) return st[n - 1]; for (let i = 0; i < n - 1; i++) { if (t >= pos[i] && t <= pos[i + 1]) { const s = ss((t - pos[i]) / (pos[i + 1] - pos[i])); const a = st[i], b = st[i + 1]; let dh = b[0] - a[0]; if (dh > 180) dh -= 360; else if (dh < -180) dh += 360; return [a[0] + dh * s, a[1] + (b[1] - a[1]) * s, a[2] + (b[2] - a[2]) * s]; } } return st[n - 1]; }
function tForDir(d, nx, ny, cx, cy, rs) { if (d === 0) return ny; if (d === 1) return nx; if (d === 2) return (nx + ny) / 2; if (d === 3) { const dx = nx - cx, dy = ny - cy; return Math.min(1, Math.sqrt(dx * dx + dy * dy) * rs); } if (d === 4) return ((1 - nx) + ny) / 2; if (d === 5) { const a = Math.atan2(ny - cy, nx - cx); return (a + Math.PI) / (2 * Math.PI); } if (d === 6) return Math.min(1, (Math.abs(nx - cx) + Math.abs(ny - cy)) * rs * 1.1); const dx = nx - cx, dy = ny - cy, dd = Math.sqrt(dx * dx + dy * dy), an = (Math.atan2(dy, dx) + Math.PI) / (2 * Math.PI), v = dd * rs * 1.4 + an; return v - Math.floor(v); }

// The framed sheet (R8), as in artifacts-art/framed.
const W = 1080, FX = 200, FY = 220, FBW = 680, FBH = 640, GAP = 3.2;
const menuY = FY + 30, menuDiv = FY + 46, statusDiv = FY + FBH - 46, statusY = FY + FBH - 27;
const artL = FX + 18, artR = FX + FBW - 18, artT = menuDiv + 14, artB = statusDiv - 14;
const COLS = 156, ROWS = 146, cw = (artR - artL) / COLS, chh = (artB - artT) / ROWS;

// R3
function traits(seed) {
  const s = low32(seed), rng = mulberry32(Math.imul(s, 2654435761) >>> 0);
  const pal = PALETTES[Math.floor(rng() * 34)];
  const title = TITLES[Math.floor(rng() * 10)];
  const ms = pal.stops.length, rm = rng();
  const k = ms <= 2 ? 2 : rm < 0.33 ? 2 : rm < 0.66 ? Math.min(3, ms) : ms;
  const stops = reduceStops(pal.stops, k), n = stops.length, pos = [0];
  for (let i = 1; i < n - 1; i++) pos.push(i / (n - 1) + (rng() - 0.5) * 0.22);
  pos.push(1); pos.sort((a, b) => a - b);
  const dir = Math.floor(rng() * 8), cx = 0.3 + rng() * 0.4, cy = 0.3 + rng() * 0.4, rs = 1.0 + rng() * 0.6, flip = rng() < 0.4;
  const amp = 4 + rng() * 9, f1 = 0.06 + rng() * 0.12, f2 = 0.02 + rng() * 0.05, p1 = rng() * 6.28, p2 = rng() * 6.28, baseD = 0.6 + rng() * 0.3;
  return { s, pal, title, k, stops, pos, dir, cx, cy, rs, flip, amp, f1, f2, p1, p2, baseD };
}

// R7 (editions) and R9 (THE SOURCE): returns the dots in row order.
function dots(seed, master) {
  const out = [];
  const T = master ? null : traits(seed);
  for (let y = 0; y < ROWS; y++) { const ny = y / (ROWS - 1);
    for (let x = 0; x < COLS; x++) { const nx = x / (COLS - 1);
      let t, dr, tt, c;
      if (master) {
        t = nx * 0.6 + ny * 0.4;
        dr = Math.sin(x * 0.07 + y * 0.05 + 1.3) * 8 + Math.sin(x * 0.03 + y * 0.025 + 3.9) * 8 * 0.6;
        tt = clamp(t + dr * 0.004, 0, 1);
        c = grad(PRISM, tt, [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1]);
      } else {
        t = tForDir(T.dir, nx, ny, T.cx, T.cy, T.rs); if (T.flip) t = 1 - t;
        dr = Math.sin(x * T.f1 + y * 0.05 + T.p1) * T.amp + Math.sin(x * T.f2 + y * 0.025 + T.p2) * T.amp * 0.6;
        tt = clamp(t + dr * 0.005, 0, 1);
        c = grad(T.stops, tt, T.pos);
      }
      let h = c[0] + dr * 0.4, sat = c[1], l = c[2];
      const nz = master ? mulberry32((7777 + x * 19349663 + y * 83492791) >>> 0)() : mulberry32(mix(T.s, 73856093, x, 19349663, y, 83492791))();
      l += (nz - 0.5) * 4; sat += (nz - 0.5) * 4; h += (nz - 0.5) * 3;
      const vibr = sat / 95, ld = (master ? 0.7 : T.baseD) * (0.55 + vibr * 0.55);
      const g = master ? mulberry32((7778 + x * 3266489917 + y * 668265263) >>> 0)() : mulberry32(mix(T.s, 2246822519 | 0, x, 3266489917 | 0, y, 668265263))();
      if (g > ld) continue;
      out.push({ x, y, cx: artL + (x + 0.5) * cw, cy: artT + (y + 0.5) * chh, r: cw * (0.08 + vibr * (master ? 0.2 : 0.18)),
        h: ((h % 360) + 360) % 360, s: master ? clamp(sat, 58, 95) : clamp(sat, 55, 95), l: master ? clamp(l, 36, 66) : clamp(l, 36, 64) });
    }
  }
  return { dots: out, T };
}
// R8 / R9: the framed sheet as one SVG file, in the exact form of artifacts-art/framed.
function svg(seed, master) {
  const { dots: ds, T } = dots(seed, master);
  const circles = ds.map((d) => `<circle cx="${d.cx.toFixed(1)}" cy="${d.cy.toFixed(1)}" r="${d.r.toFixed(2)}" fill="hsl(${Math.round(d.h)},${Math.round(d.s)}%,${Math.round(d.l)}%)"/>`).join('');
  const text = (x, y, anchor, str) => `<text x="${x.toFixed(1)}" y="${y.toFixed(1)}" font-size="12.5" text-anchor="${anchor}" xml:space="preserve">${str}</text>`;
  const line = (y) => `<line x1="${(FX + GAP).toFixed(1)}" y1="${y.toFixed(1)}" x2="${(FX + FBW - GAP).toFixed(1)}" y2="${y.toFixed(1)}" stroke="#1a1a1a" stroke-width="1.2"/>`;
  const menu = 'File   View   ' + (master ? 'Reveal' : 'Run');
  const title = master ? 'ARTIFACTS  ◆  MASTER' : T.title;
  const statusL = master ? 'THE SOURCE' : `${T.pal.name}  ·  ${T.k}C  ·  ${DIRS[T.dir]}`;
  const statusR = master ? 'FIDELITY · MAX · 1/1' : 'SEED ' + String(Number(BigInt(seed))).padStart(3, '0');
  const frame = '<g fill="#1a1a1a" font-family="Menlo, ui-monospace, monospace" dominant-baseline="middle" letter-spacing="0.5">'
    + `<rect x="${FX}" y="${FY}" width="${FBW}" height="${FBH}" fill="none" stroke="#1a1a1a" stroke-width="1.3"/>`
    + `<rect x="${(FX + GAP).toFixed(1)}" y="${(FY + GAP).toFixed(1)}" width="${(FBW - 2 * GAP).toFixed(1)}" height="${(FBH - 2 * GAP).toFixed(1)}" fill="none" stroke="#1a1a1a" stroke-width="1.3"/>`
    + text(FX + 18, menuY, 'start', menu) + text(FX + FBW - 18, menuY, 'end', title)
    + (master ? line(menuDiv - 3) : '') + line(menuDiv) + line(statusDiv) + (master ? line(statusDiv + 3) : '')
    + text(FX + 18, statusY, 'start', statusL) + text(FX + FBW - 18, statusY, 'end', statusR)
    + '</g>';
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${W}" width="${W}" height="${W}"><rect width="${W}" height="${W}" fill="#ffffff"/>${circles}${frame}</svg>`;
}

module.exports = { dots, traits, svg, DIRS };
