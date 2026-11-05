// Privacy scan for the built docs site. Mirrors the repository scan:
// no IP address, email, key pattern, or account detail in any page.
import { readFileSync, existsSync } from 'node:fs';
import { globSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = fileURLToPath(new URL('.', import.meta.url));
const root = path.resolve(here, '..');
const dir = process.argv[2] ?? path.join(root, 'dist');

const IPV4 = /(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])/;
const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;
const SECRET = [
  /BEGIN [A-Z ]*PRIVATE KEY/,
  /ssh-(?:rsa|ed25519)/,
  /vultr[_-]?inference[_-]?api[_-]?key/i,
  /api[_-]?key\s*[:=]\s*['"][^'"]+['"]/i,
];

if (!existsSync(dir)) {
  console.error(`privacy: FAIL missing build output ${dir}`);
  process.exit(1);
}

const files = globSync('**/*.html', { cwd: dir });
if (files.length === 0) {
  console.error('privacy: FAIL no pages built');
  process.exit(1);
}

let bad = 0;
const stripToText = (html) =>
  html
    .replace(/<svg[\s\S]*?<\/svg>/g, ' ')
    .replace(/<style[\s\S]*?<\/style>/g, ' ')
    .replace(/<script[\s\S]*?<\/script>/g, ' ')
    .replace(/<[^>]+>/g, ' ');
const hrefs = (html) =>
  [...html.matchAll(/(?:href|src|content)="([^"]+)"/g)].map((m) => m[1]).join('\n');
for (const f of files) {
  const html = readFileSync(path.join(dir, f), 'utf8');
  // Visible text carries the claims. Link targets carry the addresses.
  // SVG path data and style blocks are drawing code, not content.
  const text = `${stripToText(html)}\n${hrefs(html)}`
    .replace(/\bVULTR_INFERENCE_API_KEY\b/g, '')
    .replace(/<vm-public-ip>/g, '')
    .replace(/@<[^>]+>/g, '');
  const hits = [];
  if (IPV4.test(text)) hits.push('IP address');
  if (EMAIL.test(text)) hits.push('email');
  for (const re of SECRET) if (re.test(text)) hits.push(`key pattern ${re}`);
  if (hits.length > 0) {
    console.error(`privacy: FAIL ${f} contains ${hits.join(', ')}`);
    bad += 1;
  }
}
if (bad > 0) process.exit(1);
console.log(`privacy: OK (${files.length} pages clean)`);
