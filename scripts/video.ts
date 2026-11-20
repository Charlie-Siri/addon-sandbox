// Video export: plays a use case in headless Chrome frame by frame (fake time, so no frame is ever dropped), captures
// each frame and pipes it into ffmpeg (H.264 .mp4, 1080p, 30 fps), with a title card and one chapter per caption.
//
// Usage: npm run video -- <Addon>/<name> [--url http://127.0.0.1:5199] [--out file.mp4] [--json-progress]
//   Without --url it uses a running dev server on 5199, or starts its own.
//   Output: profile/videos/<Addon>/<name>.mp4
// Needs Google Chrome (or Chromium) and ffmpeg with libx264. SANDBOX_CHROME=/path/to/chrome overrides the browser.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';
import { resolvePaths } from '../server/addons.ts';
import { videoPath, parseUseCaseRef } from '../server/usecases.ts';

const FPS = 30;
const HOLD_SECONDS = 1.5;
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const args = process.argv.slice(2);
let ref = '';
let url = '';
let out = '';
let jsonProgress = false;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--url') url = args[++i];
  else if (a === '--out') out = args[++i];
  else if (a === '--json-progress') jsonProgress = true;
  else ref = a;
}
if (!ref) {
  console.error('Usage: npm run video -- <Addon>/<name> [--url http://127.0.0.1:5199] [--out file.mp4]');
  process.exit(2);
}

const paths = resolvePaths(root);
const { addon, name } = parseUseCaseRef(paths, ref);
const id = `${addon}/${name}`;
const outFile = out ? path.resolve(out) : videoPath(paths, addon, name);

let lastBar = 0;
function emit(msg: Record<string, unknown>) {
  if (jsonProgress) { console.log(JSON.stringify(msg)); return; }
  const now = Date.now();
  if (msg.phase === 'recording' && now - lastBar < 200 && msg.frame !== msg.total) return;
  lastBar = now;
  if (msg.phase === 'recording') {
    const pct = msg.total ? (Number(msg.frame) / Number(msg.total)) : 0;
    const width = 30;
    const bar = '█'.repeat(Math.round(pct * width)).padEnd(width, '░');
    const eta = msg.eta !== undefined ? `  ${Math.ceil(Number(msg.eta))} s left` : '';
    process.stderr.write(`\r  ${bar} ${String(Math.round(pct * 100)).padStart(3)}%  frame ${msg.frame}/${msg.total}${eta}   `);
    if (msg.frame === msg.total) process.stderr.write('\n');
  } else if (msg.phase === 'error') {
    process.stderr.write(`\n  Export failed: ${msg.error}\n`);
  } else if (msg.phase === 'done') {
    process.stderr.write(`  Saved ${msg.file} (${(Number(msg.size) / 1048576).toFixed(1)} MB, ${Number(msg.seconds).toFixed(1)} s, ${msg.chapters} chapters) in ${msg.took} s\n`);
  } else {
    process.stderr.write(`  ${msg.message ?? msg.phase}\n`);
  }
}

function findChrome(): string | null {
  const candidates = [process.env.SANDBOX_CHROME, '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/opt/google/chrome/chrome',
    '/usr/bin/chromium', '/usr/bin/chromium-browser', '/snap/bin/chromium',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].filter(Boolean) as string[];
  return candidates.find((c) => fs.existsSync(c)) ?? null;
}

async function serverUp(u: string) {
  try { const r = await fetch(`${u}/api/state`, { signal: AbortSignal.timeout(1500) }); return r.ok; } catch { return false; }
}

function run(cmd: string, argv: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, argv, { stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    p.stderr.on('data', (d: Buffer) => { err += d.toString(); });
    p.on('error', reject);
    p.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`${cmd} exited with ${code}: ${err.trim().slice(-500)}`))));
  });
}

function metaEscape(s: string) { return s.replace(/[=;#\\\n]/g, (c) => (c === '\n' ? ' ' : `\\${c}`)); }

async function main() {
  const started = Date.now();
  let viteServer: { close(): Promise<void> } | null = null;
  if (!url) {
    if (await serverUp('http://127.0.0.1:5199')) url = 'http://127.0.0.1:5199';
    else {
      emit({ phase: 'starting', message: 'Starting a dev server…' });
      const { createServer } = await import('vite');
      const server = await createServer({ root, configFile: path.join(root, 'vite.config.ts'), logLevel: 'error', server: { port: 5299, strictPort: false } });
      await server.listen();
      viteServer = server;
      url = (server.resolvedUrls?.local[0] ?? 'http://127.0.0.1:5299/').replace(/\/$/, '');
    }
  }
  const chrome = findChrome();
  emit({ phase: 'starting', message: `Opening ${id} in ${chrome ? path.basename(chrome) : 'Chrome'}…` });
  const browser = await chromium.launch({
    headless: true,
    ...(chrome ? { executablePath: chrome } : { channel: 'chrome' }),
    args: ['--hide-scrollbars', '--force-device-scale-factor=1', '--disable-gpu-vsync', '--font-render-hinting=none'],
  });
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sandbox-video-'));
  const tmpVideo = path.join(tmpDir, 'video.mp4');
  const metaFile = path.join(tmpDir, 'chapters.txt');
  try {
    const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
    const pageErrors: string[] = [];
    page.on('pageerror', (e) => pageErrors.push(e.message));
    await page.goto(`${url}/?record=${encodeURIComponent(id)}`, { waitUntil: 'load' });
    await page.waitForFunction(() => (window as any).__uc !== undefined, null, { timeout: 30000 });
    emit({ phase: 'dry-run', message: 'Timing the use case…' });
    const info = await page.evaluate(() => (window as any).__uc.prepare()) as
      { ok: boolean; error?: string; report?: string; frames: number; chapters: { t: number; title: string }[]; title: string; seconds: number };
    if (!info.ok) {
      if (info.report && !jsonProgress) process.stderr.write(`\n${info.report}\n`);
      throw new Error(info.error ?? 'the use case did not load');
    }
    const holdFrames = Math.round(HOLD_SECONDS * FPS);
    const total = info.frames + holdFrames;
    const cdp = await page.context().newCDPSession(page);

    fs.mkdirSync(path.dirname(outFile), { recursive: true });
    const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'mjpeg', '-i', '-',
      '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-pix_fmt', 'yuv420p', '-r', String(FPS), '-movflags', '+faststart', tmpVideo],
      { stdio: ['pipe', 'ignore', 'pipe'] });
    let ffErr = '';
    ff.stderr!.on('data', (d: Buffer) => { ffErr += d.toString(); });
    const ffDone = once(ff, 'close');
    ff.on('error', (e) => { ffErr += String(e); });

    const capture = async () => {
      const shot = await cdp.send('Page.captureScreenshot', { format: 'jpeg', quality: 92, optimizeForSpeed: true });
      const buf = Buffer.from(shot.data, 'base64');
      if (!ff.stdin!.write(buf)) await once(ff.stdin!, 'drain');
    };

    const recStart = Date.now();
    let frame = 0;
    let done = false;
    const limit = Math.round(info.frames * 1.1) + FPS * 5;
    while (!done && frame < limit) {
      const r = await page.evaluate(() => (window as any).__uc.frame()) as { done: boolean; failed: string | null };
      if (r.failed) throw new Error(`The use case failed while recording: ${r.failed}`);
      await capture();
      frame++;
      done = r.done;
      if (frame % 5 === 0 || done) {
        const elapsed = (Date.now() - recStart) / 1000;
        emit({ phase: 'recording', frame, total, eta: (elapsed / frame) * (total - frame) });
      }
    }
    for (let i = 0; i < holdFrames; i++) {
      await page.evaluate(() => (window as any).__uc.hold());
      await capture();
      frame++;
      if (frame % 5 === 0 || i === holdFrames - 1) {
        const elapsed = (Date.now() - recStart) / 1000;
        emit({ phase: 'recording', frame: Math.min(frame, total), total, eta: (elapsed / frame) * Math.max(0, total - frame) });
      }
    }
    ff.stdin!.end();
    emit({ phase: 'encoding', message: 'Writing the .mp4…' });
    const [code] = await ffDone;
    if (code !== 0) throw new Error(`ffmpeg failed: ${ffErr.trim().slice(-500)}`);
    if (pageErrors.length) emit({ phase: 'warning', message: `Page errors while recording: ${pageErrors.slice(0, 3).join('; ')}` });

    // Chapters: the title card, then one per caption.
    const seconds = frame / FPS;
    const chapters = info.chapters.filter((c, i, all) => i + 1 >= all.length || all[i + 1].t - c.t >= 0.5);
    const meta = [';FFMETADATA1', `title=${metaEscape(info.title)}`, `comment=${metaEscape(`Addon Sandbox use case ${id}`)}`];
    chapters.forEach((c, i) => {
      const start = Math.round(c.t * 1000);
      const end = Math.round((i + 1 < chapters.length ? chapters[i + 1].t : seconds) * 1000);
      if (end <= start) return;
      meta.push('[CHAPTER]', 'TIMEBASE=1/1000', `START=${start}`, `END=${end}`, `title=${metaEscape(c.title.length > 90 ? c.title.slice(0, 87) + '...' : c.title)}`);
    });
    fs.writeFileSync(metaFile, meta.join('\n') + '\n');
    await run('ffmpeg', ['-y', '-loglevel', 'error', '-i', tmpVideo, '-i', metaFile, '-map', '0', '-map_metadata', '1', '-map_chapters', '1',
      '-c', 'copy', '-movflags', '+faststart', outFile]);
    const size = fs.statSync(outFile).size;
    emit({ phase: 'done', file: path.relative(root, outFile), size, seconds, chapters: chapters.length, took: Math.round((Date.now() - started) / 1000) });
  } finally {
    await browser.close().catch(() => {});
    fs.rmSync(tmpDir, { recursive: true, force: true });
    if (viteServer) await viteServer.close().catch(() => {});
  }
}

main().catch((e) => {
  emit({ phase: 'error', error: (e as Error).message });
  process.exitCode = 1;
});
