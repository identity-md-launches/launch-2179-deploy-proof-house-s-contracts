# ARTIFACTS — the rules (generative constitution)

The ruleset by which every piece is made. Deterministic: render(seed) → image, always identical. Source of truth is Artifact Art/artifact.html; these rules formalize it so any implementation (incl. on-chain Solidity) matches byte-for-art.

Order of operations and every constant below are normative — do not drift.

## R0 · Principle
The algorithm is public; the seed is the only secret. Output is a pure function of the seed (and, for the living version, block.timestamp). Same inputs → same pixels, forever, for anyone.

## R1 · Seed
256-bit, CSPRNG, off-chain, never derivable from public data (tokenId, block, address, index). Audit Finding #1.
The seed is folded to a 32-bit render key: key = (seed * 2654435761) >>> 0.

## R2 · RNG (locked)
mulberry32(a) — the only PRNG. Three independent, position-addressed streams per cell:

```
mulberry32(a): a|=0; a=a+0x6D2B79F5|0;
  t = Math.imul(a ^ a>>>15, 1|a);
  t = t + Math.imul(t ^ t>>>7, 61|t) ^ t;
  return ((t ^ t>>>14) >>> 0) / 4294967296;
```

- Trait stream: rng = mulberry32(key) — draws consumed in the exact order of R3.
- Noise stream (per cell): mulberry32((seed*73856093 + x*19349663 + y*83492791) >>> 0)
- Density stream (per cell): mulberry32((seed*2246822519 + x*3266489917 + y*668265263) >>> 0)

## R3 · Trait derivation — exact draw order
From the trait stream rng, in this order (no reordering — the sequence IS the identity):

1. palette = PALETTES[floor(rng()*34)]
2. title = TITLES[floor(rng()*10)]
3. rm = rng() → color-count k: if palette.stops ≤ 2 → k=2; else rm<0.33 → 2, rm<0.66 → min(3, stops), else → all stops.
4. stops = reduceStops(palette.stops, k) (R5), then positions: pos=[0]; for i=1..n-2: pos.push(i/(n-1) + (rng()-0.5)*0.22); pos.push(1); sort ascending.
5. direction = floor(rng()*8) (R6)
6. cx = 0.3 + rng()*0.4, cy = 0.3 + rng()*0.4 (radial/field center)
7. rs = 1.0 + rng()*0.6 (radial scale)
8. flip = rng() < 0.4
9. amp = 4 + rng()*9, f1 = 0.06 + rng()*0.12, f2 = 0.02 + rng()*0.05, p1 = rng()*6.28, p2 = rng()*6.28 (two-octave drift)
10. baseD = 0.6 + rng()*0.3 (base density)

Public traits (shown in the frame + metadata): title, palette name, k, direction. Everything else is derived and sealed with the seed.

## R4 · Vocabularies (fixed sets)
- 34 palettes — harmonized HSL stop-lists (SUNSET, AURORA, NEON, TROPIC, PLASMA, OCEAN, MIAMI, ELECTRIC, FIRE, PRISM, BRUISE, VAPOR, EMBER, ICE, ROSE, LIME, DUSK, MAGMA, JADE, ULTRA, STORM, CITRUS, BERRY, LAGOON, MARS, COSMIC, GOLD, TWILIGHT, ACID, COBALT, BLOOD, SEAFOAM, PEACH, VOID). Exact stops in artifact.html.
- 10 titles — SPECTRUM, CHROMA, BLOOM, STIPPLE, DRIFT, HALFTONE, PRISM, RADIATE, FIELD, FLUX.
- 8 directions — 0 VERTICAL, 1 HORIZONTAL, 2 DIAGONAL, 3 RADIAL, 4 ANTIDIAG, 5 CONIC, 6 DIAMOND, 7 SPIRAL.

## R5 · Gradient
- reduceStops(stops, k): k evenly-indexed stops (round(i*(len-1)/(k-1))).
- grad(stops, t, pos): piecewise over positions; segment eased by smoothstep; hue takes the shorter arc (wrap ±360); S and L linear.

## R6 · Direction field t = tForDir(dir, nx, ny, cx, cy, rs)
nx,ny ∈ [0,1].

```
0 VERTICAL   ny
1 HORIZONTAL nx
2 DIAGONAL   (nx+ny)/2
3 RADIAL     min(1, hypot(nx-cx, ny-cy) * rs)
4 ANTIDIAG   ((1-nx)+ny)/2
5 CONIC      (atan2(ny-cy, nx-cx)+π) / 2π
6 DIAMOND    min(1, (|nx-cx|+|ny-cy|) * rs * 1.1)
7 SPIRAL     v = hypot·rs·1.4 + angle;  v - floor(v)
```

## R7 · The dot field (editions)
Grid COLS = 156 × ROWS = 146. For each cell (x,y):

1. nx=x/(COLS-1), ny=y/(ROWS-1); t=tForDir(...); if flip, t=1-t.
2. Drift: dr = sin(x·f1 + y·0.05 + p1)·amp + sin(x·f2 + y·0.025 + p2)·amp·0.6.
3. tt = clamp(t + dr·0.005, 0, 1); (h,s,l) = grad(stops, tt, pos); h += dr·0.4.
4. Per-cell noise: nz = noiseStream(x,y); l += (nz-.5)·4; s += (nz-.5)·4; h += (nz-.5)·3.
5. Density test: vibr = s/95; ld = baseD·(0.55 + vibr·0.55); if densityStream(x,y) > ld → no dot (paper shows through).
6. Dot: radius r = cw·(0.08 + vibr·0.18) at cell center; fill hsl(h mod 360, clamp(s,55,95)%, clamp(l,36,64)%).

(cw = cell width from the locked layout; frame font pinned at 11px advance 6.6015625.)

## R8 · The frame (part of the art — not chrome)
Baked into the render output. OS-window:
- Double-line border, window centered on the sheet.
- Menu bar: File  View  Run (left) · title (right).
- Status bar: PALETTE · kC · DIRECTION (left) · SEED nnn (right). The status bar carries the piece's identity; the frame travels with every render at any resolution.

## R9 · THE SOURCE (master) — the exceptions
- t = nx·0.6 + ny·0.4 (full-prism diagonal); stops = PRISM 9-stop, positions [0,⅛,…,1].
- Drift fixed: amp=8, f1=.07, f2=.03, p1=1.3, p2=3.9; tt uses dr·0.004.
- Noise/density streams keyed from 7777 / 7778 (not a seed).
- Density 0.7; radius cw·(0.08 + vibr·0.2); clamps s∈[58,95], l∈[36,66].
- Frame: title ARTIFACTS ◆ MASTER, menu File View **Reveal**, status THE SOURCE · FIDELITY · MAX · 1/1.
- Carries a write-once revealed bool — the only piece that can become public.

## R10 · Animation (on-chain, no JS)
Marketplaces render NFTs as `<img>` SVG where JS never runs → animate with SMIL only. Wrap the dot group in one hue-rotate:

```
<filter id="flow"><feColorMatrix type="hueRotate" values="0">
  <animate attributeName="values" from="0" to="360" dur="11s" repeatCount="indefinite"/>
</feColorMatrix></filter>
<g filter="url(#flow)"> …dots… </g>   <!-- frame stays outside, unaffected -->
```

~259 bytes, constant regardless of dot count.

## R11 · Evolution (the second clock)
Living render is render(seed, E) where E derives from block.timestamp over a ~1-year cycle. Identity (R3 traits) is seed-locked and never changes; the "weather" evolves:
- p1 += E·2π·2, p2 += E·2π·3 (flow pattern morphs)
- hue baseline += E·360 (editions bounded ~±; master full turn)
- density breathes ×(1 + 0.12·sin(E·2π))

Deterministic and verifiable from seed + block. No re-rolls, no new token — the same piece, alive.

## R12 · Fixed vs. living

| Fixed forever (identity) | Lives / changes |
|---|---|
| seed, palette, direction, title, color-count | flow pattern (drift phase) |
| the frame + its labels | hue baseline |
| determinism of the algorithm | density breath |
| | the fast shimmer (R10) |

## R13 · Access (pointer)
Only ciphertext_seed + per-owner wrapped_K are on-chain; viewing is an off-chain signature gated to the owner; render is client-side; seed discarded after. Full rules in SEED-SECURITY-SPEC.md.

## The short version
One algorithm. 256 seeds. The seed picks a palette, a direction, a character — then lays a halftone spectrum inside its own window, signs it with its traits, and (as a living piece) drifts its weather with the chain while its identity never moves. Encrypted, so only the owner sees it. One of the 256 can choose, once and forever, to be seen by everyone.

---

## Implementation notes (added with the reference renderer; they pin down the rules, they don't change them)

- **The framed pieces are the ground truth for the sheet and frame.** The pieces in `reference/framed/` use a 1080 × 1080 white sheet; the window at (200, 220), 680 × 640, with a second border inset 3.2; Menlo 12.5 px text with 0.5 letter-spacing; menu text at y = 250, dividers at y = 266 and 814, status text at y = 833; the dot field from x = 218 to 862 and y = 280 to 800. (`artifact.html` draws a 1080 × 900 sheet with the title in the top border, and R7's 11 px note comes from it.)
- **Integer arithmetic.** R1 and R2 are written in JavaScript number terms. For a 256-bit seed, every product is taken mod 2^32 on the seed's low 32 bits (in JavaScript, `Math.imul`). This gives identical results for seeds 0–255, so no existing piece changes, and it is the only reading under which JavaScript and Solidity agree for real seeds.
- **Output rounding**, as in the framed SVGs: `cx` and `cy` to 1 decimal, `r` to 2 decimals, `hsl(round(h), round(s)%, round(l)%)`, dots in row order.
- **Acceptance test.** `reference/rules.js` rebuilds all 11 pieces in `reference/framed/` byte for byte (188,333 dots); `node reference/check-framed.js` proves it. Any other implementation, including the on-chain renderer, must pass the same test.
