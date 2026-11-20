// Vite plugin acting as the sandbox's dev server: JSON API over the WoW install and the profile folder,
// plus a file watcher on AddOns that tells the page to reload.
import fs from 'node:fs';
import path from 'node:path';
import { spawn, type ChildProcess } from 'node:child_process';
import type { Plugin, ViteDevServer } from 'vite';
import type { IncomingMessage, ServerResponse } from 'node:http';
import {
  resolvePaths, listAddons, readAddon, listCharacters, readSavedVariables, writeSavedVariables,
  resetSavedVariables, readJson, writeJson, loadSettings, isValidAddonName, readWtfAccountSavedVariables, type Settings,
} from './addons.ts';
import {
  listUseCases, resolveUseCase, writeUseCase, writeFixture, listFixtures, videoPath, usecasesDir, isValidName,
} from './usecases.ts';

const MAX_BODY = 64 * 1024 * 1024;

function readBody(req: IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on('data', (c: Buffer) => {
      size += c.length;
      if (size > MAX_BODY) { reject(new Error('Body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); } catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}

function send(res: ServerResponse, status: number, body: unknown) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify(body));
}

interface VideoJob { id: string; proc: ChildProcess; last: Record<string, unknown> }

export function sandboxServer(): Plugin {
  const paths = resolvePaths(process.cwd());
  let job: VideoJob | null = null;
  return {
    name: 'addon-sandbox-server',
    configureServer(server: ViteDevServer) {
      // Exports one use case as .mp4 by running scripts/video.ts against this server; progress goes to the page.
      const startVideo = (id: string) => {
        const port = server.config.server.port ?? 5199;
        const host = typeof server.config.server.host === 'string' ? server.config.server.host : '127.0.0.1';
        const script = path.join(process.cwd(), 'scripts', 'video.ts');
        const proc = spawn(process.execPath, ['--experimental-strip-types', '--no-warnings', script, id, '--url', `http://${host}:${port}`, '--json-progress'],
          { cwd: process.cwd(), stdio: ['ignore', 'pipe', 'pipe'] });
        const j: VideoJob = { id, proc, last: { id, phase: 'starting' } };
        job = j;
        let buf = '';
        let errText = '';
        proc.stdout!.on('data', (chunk: Buffer) => {
          buf += chunk.toString('utf8');
          let i;
          while ((i = buf.indexOf('\n')) >= 0) {
            const line = buf.slice(0, i).trim();
            buf = buf.slice(i + 1);
            if (!line.startsWith('{')) continue;
            try {
              const msg = { id, ...JSON.parse(line) };
              j.last = msg;
              server.ws.send({ type: 'custom', event: 'sandbox:video', data: msg });
            } catch { /* not a progress line */ }
          }
        });
        proc.stderr!.on('data', (chunk: Buffer) => { errText = (errText + chunk.toString('utf8')).slice(-4000); });
        proc.on('close', (code) => {
          if (code !== 0 && j.last.phase !== 'error') {
            const msg = { id, phase: 'error', error: errText.trim().split('\n').slice(-3).join(' ') || `exit code ${code}` };
            j.last = msg;
            server.ws.send({ type: 'custom', event: 'sandbox:video', data: msg });
          }
          if (job === j) job = null;
        });
      };

      server.middlewares.use('/api', async (req, res) => {
        try {
          const url = new URL(req.url ?? '/', 'http://local');
          const parts = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
          const method = req.method ?? 'GET';
          const settings = loadSettings(paths);

          if (parts[0] === 'state' && method === 'GET') {
            return send(res, 200, {
              paths, settings, characters: listCharacters(paths),
              addonsDirFound: fs.existsSync(paths.addonsDir),
            });
          }
          if (parts[0] === 'settings' && method === 'POST') {
            const body = await readBody(req) as Partial<Settings>;
            const next = { ...settings, ...body };
            writeJson(paths, 'settings.json', next);
            return send(res, 200, next);
          }
          if (parts[0] === 'addons' && method === 'GET') return send(res, 200, listAddons(paths));
          if (parts[0] === 'addon' && parts[1] && method === 'GET') {
            if (!isValidAddonName(parts[1])) return send(res, 400, { error: 'bad addon name' });
            const addon = readAddon(paths, parts[1]);
            return addon ? send(res, 200, addon) : send(res, 404, { error: `Addon ${parts[1]} not found` });
          }
          if (parts[0] === 'sv' && parts[1]) {
            if (!isValidAddonName(parts[1])) return send(res, 400, { error: 'bad addon name' });
            if (!settings.character) return send(res, 400, { error: 'No character selected' });
            if (method === 'GET') return send(res, 200, readSavedVariables(paths, parts[1], settings.character));
            if (method === 'POST' && parts[2] === 'reset') {
              resetSavedVariables(paths, parts[1], settings.character);
              return send(res, 200, { ok: true });
            }
            if (method === 'POST') {
              writeSavedVariables(paths, parts[1], settings.character, await readBody(req));
              return send(res, 200, { ok: true });
            }
          }
          // SandboxDump's export, as the game wrote it (WTF, read-only).
          if (parts[0] === 'dump' && method === 'GET') {
            if (!settings.character) return send(res, 400, { error: 'No character selected' });
            return send(res, 200, readWtfAccountSavedVariables(paths, 'SandboxDump', settings.character));
          }
          // Use cases: profile/usecases/<Addon>/<name>.usecase.json
          if (parts[0] === 'usecases' && method === 'GET') return send(res, 200, listUseCases(paths));
          if (parts[0] === 'usecase' && parts[1] && parts[2]) {
            if (!isValidName(parts[1]) || !isValidName(parts[2])) return send(res, 400, { error: 'bad use case id' });
            if (method === 'GET') return send(res, 200, resolveUseCase(paths, parts[1], parts[2]));
            if (method === 'POST') {
              const body = await readBody(req) as { useCase: unknown };
              return send(res, 200, { ok: true, file: writeUseCase(paths, parts[1], parts[2], body.useCase) });
            }
          }
          if (parts[0] === 'fixture' && parts[1] && method === 'POST') {
            const body = await readBody(req) as { path: string; text: string };
            return send(res, 200, { ok: true, file: writeFixture(paths, parts[1], body.path, body.text) });
          }
          if (parts[0] === 'fixtures' && parts[1] && method === 'GET') return send(res, 200, listFixtures(paths, parts[1]));
          if (parts[0] === 'video' && method === 'POST' && !parts[1]) {
            const body = await readBody(req) as { id: string };
            const [addon, name] = String(body.id ?? '').split('/');
            if (!addon || !name || !isValidName(addon) || !isValidName(name)) return send(res, 400, { error: 'bad use case id' });
            if (job) return send(res, 409, { error: `Already exporting ${job.id}; one video at a time` });
            startVideo(`${addon}/${name}`);
            return send(res, 200, { ok: true });
          }
          if (parts[0] === 'video' && parts[1] === 'status' && method === 'GET') return send(res, 200, job?.last ?? null);
          if (parts[0] === 'video' && parts[1] === 'file' && parts[2] && parts[3] && method === 'GET') {
            const file = videoPath(paths, parts[2], parts[3]);
            if (!fs.existsSync(file)) return send(res, 404, { error: 'No video yet' });
            res.statusCode = 200;
            res.setHeader('Content-Type', 'video/mp4');
            res.setHeader('Content-Length', String(fs.statSync(file).size));
            res.setHeader('Cache-Control', 'no-store');
            fs.createReadStream(file).pipe(res);
            return;
          }
          if (parts[0] === 'world') {
            if (method === 'GET') return send(res, 200, readJson(paths, 'world.json', null));
            if (method === 'POST') { writeJson(paths, 'world.json', await readBody(req)); return send(res, 200, { ok: true }); }
          }
          send(res, 404, { error: `No route ${method} ${url.pathname}` });
        } catch (e) {
          send(res, 500, { error: String((e as Error)?.message ?? e) });
        }
      });

      // Live reload: tell the page which addon changed; it saves SavedVariables and restarts the VM.
      if (fs.existsSync(paths.addonsDir)) {
        const pending = new Map<string, string>();
        let timer: NodeJS.Timeout | null = null;
        try {
          fs.watch(paths.addonsDir, { recursive: true }, (_event, filename) => {
            if (!filename || !/\.(lua|xml|toc)$/i.test(filename)) return;
            const addon = filename.split(path.sep)[0];
            pending.set(addon, filename);
            if (timer) clearTimeout(timer);
            timer = setTimeout(() => {
              for (const [name, file] of pending) server.ws.send({ type: 'custom', event: 'sandbox:changed', data: { addon: name, file } });
              pending.clear();
            }, 150);
          });
        } catch (e) {
          server.config.logger.warn(`[sandbox] file watching unavailable: ${(e as Error).message}`);
        }
      }
      // Use case files edited by hand or by an LLM: refresh the page's list (and a playing use case).
      const ucDir = usecasesDir(paths);
      fs.mkdirSync(ucDir, { recursive: true });
      try {
        let ucTimer: NodeJS.Timeout | null = null;
        const changed = new Set<string>();
        fs.watch(ucDir, { recursive: true }, (_event, filename) => {
          if (!filename) return;
          const parts = filename.split(path.sep);
          if (parts.length < 2) return;
          const name = parts[parts.length - 1].replace(/\.usecase\.json$/, '');
          changed.add(`${parts[0]}/${parts.length === 2 ? name : '*'}`);
          if (ucTimer) clearTimeout(ucTimer);
          ucTimer = setTimeout(() => {
            for (const key of changed) {
              const [addon, n] = key.split('/');
              server.ws.send({ type: 'custom', event: 'sandbox:usecases', data: { addon, name: n } });
            }
            changed.clear();
          }, 200);
        });
      } catch (e) {
        server.config.logger.warn(`[sandbox] use case watching unavailable: ${(e as Error).message}`);
      }
      server.config.logger.info(`[sandbox] AddOns: ${paths.addonsDir}\n[sandbox] profile: ${paths.profileDir}`);
    },
  };
}
