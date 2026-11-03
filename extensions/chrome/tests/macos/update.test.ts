/**
 * Automatic updates, end to end on macOS: the real app, installed in a
 * temporary folder, checks a local feed, downloads an archive of a "9.9.9"
 * build, verifies it and replaces itself.
 *
 *   - an archive signed with the wrong key is refused (nothing changes);
 *   - a correctly signed one is installed: the old process quits, the bundle
 *     is swapped, the new version is running, nothing is left behind.
 *
 * Uses a throwaway Ed25519 key (handed to the app through its test hooks),
 * never the release key. Env: EK_APP (path to the built Ekagrachit.app).
 */
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { type ChildProcess, execFileSync, spawn } from 'node:child_process';
import { createHash, generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const APP = resolve(process.env.EK_APP ?? '');
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function waitFor<T>(fn: () => T | Promise<T>, ok: (v: T) => boolean, ms: number, label: string): Promise<T> {
  const end = Date.now() + ms;
  let last: T = await fn();
  while (!ok(last)) {
    if (Date.now() > end) throw new Error(`timed out waiting for ${label}; last=${JSON.stringify(last)}`);
    await sleep(250);
    last = await fn();
  }
  return last;
}

function keyPair(): { priv: KeyObject; pubRaw: string } {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const der = publicKey.export({ format: 'der', type: 'spki' }) as Buffer;
  return { priv: privateKey, pubRaw: der.subarray(der.length - 32).toString('base64') };
}

const plistVersion = (app: string) =>
  execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleShortVersionString', join(app, 'Contents/Info.plist')], { encoding: 'utf8' }).trim();
const pidsOf = (app: string): number[] => {
  try {
    return execFileSync('pgrep', ['-f', join(app, 'Contents/MacOS/Ekagrachit')], { encoding: 'utf8' }).trim().split('\n').filter(Boolean).map(Number);
  } catch {
    return [];
  }
};

describe('automatic updates (real app, local feed)', { skip: !existsSync(APP) && 'EK_APP not built' }, () => {
  const root = mkdtempSync(join(tmpdir(), 'ek-update-'));
  const installed = join(root, 'Applications', 'Ekagrachit.app');
  const support = join(root, 'support');
  const trusted = keyPair();
  const stranger = keyPair();
  let zip: Buffer;
  let manifest = '';
  let server: Server;
  let port = 0;
  let proc: ChildProcess | null = null;
  let log = '';

  const launchInstalled = () => {
    log = '';
    proc = spawn(join(installed, 'Contents/MacOS/Ekagrachit'), [], {
      env: {
        ...process.env,
        EKAGRACHIT_UPDATE_FEED: `http://127.0.0.1:${port}/update.json`,
        EKAGRACHIT_UPDATE_PUBLIC_KEY: trusted.pubRaw,
        EKAGRACHIT_UPDATE_CHECK_NOW: '1',
        EKAGRACHIT_SUPPORT_DIR: support,
        EKAGRACHIT_SOCKET: join(support, 'b.sock'),
        EKAGRACHIT_NO_SETUP_WINDOW: '1',
        EKAGRACHIT_NO_HOST_REGISTRATION: '1',
        EKAGRACHIT_ALLOW_WITHOUT_ACCESSIBILITY: '1',
        EKAGRACHIT_LOG_STDERR: '1',
      },
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    proc.stderr!.on('data', (d: Buffer) => { log += d.toString(); });
  };
  const publish = (key: KeyObject) => {
    manifest = JSON.stringify({
      version: '9.9.9',
      url: `http://127.0.0.1:${port}/Ekagrachit-9.9.9.zip`,
      sha256: createHash('sha256').update(zip).digest('hex'),
      signature: sign(null, zip, key).toString('base64'),
    });
  };

  before(async () => {
    try { execFileSync('pkill', ['-x', 'Ekagrachit']); } catch { /* none running */ }
    mkdirSync(join(root, 'Applications'), { recursive: true });
    mkdirSync(support, { recursive: true, mode: 0o700 });
    execFileSync('ditto', [APP, installed]);
    // The "new version": the same app, renumbered and re-signed (ad hoc).
    const next = join(root, 'next', 'Ekagrachit.app');
    execFileSync('ditto', [APP, next]);
    execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Set :CFBundleShortVersionString 9.9.9', join(next, 'Contents/Info.plist')]);
    execFileSync('codesign', ['--force', '--deep', '--sign', '-', next]);
    const zipPath = join(root, 'Ekagrachit-9.9.9.zip');
    execFileSync('ditto', ['-c', '-k', '--keepParent', next, zipPath]);
    zip = readFileSync(zipPath);
    server = createServer((req, res) => {
      if (req.url === '/update.json') { res.setHeader('content-type', 'application/json'); res.end(manifest); return; }
      if (req.url === '/Ekagrachit-9.9.9.zip') { res.setHeader('content-type', 'application/zip'); res.end(zip); return; }
      res.statusCode = 404;
      res.end();
    });
    await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
    port = (server.address() as AddressInfo).port;
  });

  after(async () => {
    proc?.kill('SIGKILL');
    for (const pid of pidsOf(installed)) { try { process.kill(pid, 'SIGKILL'); } catch { /* gone */ } }
    server?.close();
    rmSync(root, { recursive: true, force: true });
  });

  test('an update signed with another key is refused', { timeout: 60_000 }, async () => {
    publish(stranger.priv);
    launchInstalled();
    await waitFor(() => log, (l) => /updates: .*(signature|rejected)/.test(l), 30_000, 'the signature check');
    assert.match(log, /signature does not verify/);
    await sleep(3000);
    assert.equal(plistVersion(installed), plistVersion(APP), 'the installed app is unchanged');
    assert.ok(proc!.exitCode === null, 'the app keeps running');
    proc!.kill('SIGKILL');
    await waitFor(() => pidsOf(installed).length, (n) => n === 0, 10_000, 'app stopped');
  });

  test('a correctly signed update installs itself and relaunches', { timeout: 120_000 }, async () => {
    publish(trusted.priv);
    launchInstalled();
    const oldPid = proc!.pid!;
    await waitFor(() => log, (l) => l.includes('updates: installing 9.9.9'), 60_000, 'install to start');
    await waitFor(() => proc!.exitCode !== null || proc!.signalCode !== null, (v) => v, 20_000, 'old version to quit');
    await waitFor(() => plistVersion(installed), (v) => v === '9.9.9', 20_000, 'bundle swapped to 9.9.9');
    const running = await waitFor(() => pidsOf(installed), (p) => p.length > 0 && !p.includes(oldPid), 20_000, 'new version running');
    console.log(`updated in place: pid ${oldPid} -> ${running.join(',')}`);
    assert.ok(!existsSync(`${installed}.previous`), 'no backup left behind');
    execFileSync('codesign', ['--verify', '--deep', '--strict', installed]);
  });
});
