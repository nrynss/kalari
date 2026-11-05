// Render every diagrams/*.mmd to inline SVG at build time.
// Light and dark variants share the same structure. No Mermaid runs in the
// browser and no diagram loads from a CDN.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { globSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const diagramsDir = path.join(root, 'diagrams');
const outDir = path.join(root, 'src', 'data', 'diagrams');
mkdirSync(outDir, { recursive: true });

const chromeCandidates = [
  process.env.CHROME_PATH,
  '/usr/bin/google-chrome-stable',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
].filter(Boolean);
const chrome = chromeCandidates.find((p) => existsSync(p));
if (!chrome) {
  console.error('diagrams: FAIL no Chrome binary found; set CHROME_PATH');
  process.exit(1);
}
const puppeteerConfig = path.join(outDir, 'puppeteer.json');
writeFileSync(puppeteerConfig, JSON.stringify({ executablePath: chrome, args: ['--no-sandbox'] }));

const names = globSync('*.mmd', { cwd: diagramsDir }).map((f) => path.basename(f, '.mmd'));
if (names.length === 0) {
  console.error('diagrams: FAIL no .mmd sources');
  process.exit(1);
}
for (const name of names) {
  for (const [variant, config] of [
    ['light', 'light.json'],
    ['dark', 'dark.json'],
  ]) {
    const input = path.join(diagramsDir, `${name}.mmd`);
    const output = path.join(outDir, `${name}-${variant}.svg`);
    execFileSync(
      'npx',
      [
        'mmdc',
        '-i',
        input,
        '-o',
        output,
        '--configFile',
        path.join(diagramsDir, config),
        '--puppeteerConfigFile',
        puppeteerConfig,
        '--backgroundColor',
        'transparent',
      ],
      { cwd: root, stdio: 'pipe' },
    );
    let svg = readFileSync(output, 'utf8');
    // mmdc adds width and max-width styles that fight the responsive wrapper.
    svg = svg.replace(/ style="max-width:[^"]*"/, '');
    svg = svg.replace(/ width="[^"]*"/, '');
    svg = svg.replace('<svg ', '<svg width="100%" ');
    if (!svg.includes('<svg')) {
      console.error(`diagrams: FAIL ${name} ${variant} is not SVG`);
      process.exit(1);
    }
    writeFileSync(output, svg);
  }
  console.log(`diagrams: rendered ${name} light and dark`);
}

// Record the diagram set so pages fail loudly when one goes missing.
const manifest = Object.fromEntries(names.map((n) => [n, [`${n}-light.svg`, `${n}-dark.svg`]]));
writeFileSync(path.join(outDir, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log(`diagrams: OK (${names.length} diagrams)`);
