// Bundles the extension into dist/ (load that folder as an unpacked extension).
// Usage: node scripts/build.mjs [--zip]
import { build } from 'esbuild';
import { cpSync, mkdirSync, rmSync, readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dist = join(root, 'dist');
rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });

const common = { bundle: true, target: 'chrome120', sourcemap: 'linked', logLevel: 'warning', legalComments: 'none' };
await build({ ...common, entryPoints: [join(root, 'src/background/index.ts')], outfile: join(dist, 'background.js'), format: 'esm' });
await build({ ...common, entryPoints: [join(root, 'src/ui/popup.ts')], outfile: join(dist, 'popup.js'), format: 'iife' });

for (const f of ['popup.html', 'popup.css']) cpSync(join(root, 'src/ui', f), join(dist, f));
cpSync(join(root, 'assets/icons'), join(dist, 'icons'), { recursive: true });
const manifest = JSON.parse(readFileSync(join(root, 'manifest.json'), 'utf8'));
writeFileSync(join(dist, 'manifest.json'), JSON.stringify(manifest, null, 2));

if (process.argv.includes('--zip')) {
  const out = join(root, 'ekagrachit-chrome-extension.zip');
  rmSync(out, { force: true });
  execFileSync('zip', ['-qr', out, '.'], { cwd: dist });
  console.log(`wrote ${out}`);
}
console.log(`built ${dist}`);
