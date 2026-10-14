// Proves rules.js draws the framed art exactly: rebuilds each framed SVG file from the rules alone
// and compares it with the original, byte for byte.
// Usage: node check-framed.js [folder of framed-NNN.svg / framed-MASTER.svg] [--write <out folder>]
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { svg } = require('./rules.js');
const args = process.argv.slice(2);
const writeAt = args.indexOf('--write');
const outDir = writeAt >= 0 ? args.splice(writeAt, 2)[1] : null;
const dir = args[0] || path.join(__dirname, 'framed');
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
let files = 0, same = 0;
for (const file of fs.readdirSync(dir).filter((f) => /^framed-(\d{3}|MASTER)\.svg$/.test(f)).sort()) {
  const original = fs.readFileSync(path.join(dir, file));
  const master = file.includes('MASTER');
  const rebuilt = Buffer.from(svg(master ? 0n : BigInt(file.match(/\d{3}/)[0]), master), 'utf8');
  if (outDir) fs.writeFileSync(path.join(outDir, file), rebuilt);
  const ok = Buffer.compare(original, rebuilt) === 0;
  files++; same += ok;
  console.log(`${file}  ${ok ? 'IDENTICAL' : 'DIFFERENT'}  ${original.length} bytes  sha256 ${sha(original).slice(0, 16)}… ${ok ? '=' : '≠'} ${sha(rebuilt).slice(0, 16)}…`);
}
console.log(`${same} of ${files} files rebuilt byte-for-byte from the rules`);
process.exit(same === files ? 0 : 1);
