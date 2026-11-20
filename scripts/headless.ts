// Shared setup for Node runs (check and tests): reads addons and SavedVariables from disk, never writes.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Sandbox, type AddonBundle, type SavedVariablesText } from '../src/core/sandbox.ts';
import { resolveLoadOrder } from '../src/core/loadorder.ts';
import { defaultWorld } from '../src/core/world.ts';
import { resolvePaths, listAddons, readAddon, readAddonDir, readSavedVariables, readJson, loadSettings } from '../server/addons.ts';
import { Runner, loadUseCase, SCREEN } from '../src/core/runner.ts';
import { resolveUseCase, parseUseCaseRef, listUseCases } from '../server/usecases.ts';
import type { ResolvedUseCase } from '../src/core/usecase.ts';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export function runtimeSources() {
  const dir = path.join(root, 'src', 'runtime');
  return fs.readdirSync(dir).filter((f) => f.endsWith('.lua')).sort()
    .map((name) => ({ name, code: fs.readFileSync(path.join(dir, name), 'utf8') }));
}

// Rough text metrics without a browser: average glyph width by font.
export const nodeMetrics = {
  measure(font: string, size: number, text: string) {
    const plain = text.replace(/\|c[0-9a-fA-F]{8}|\|r|\|H.-\|h|\|h/g, '').replace(/\|T[^|]*\|t/g, 'MM');
    const factor = /ARIALN/i.test(font) ? 0.45 : 0.52;
    return plain.length * size * factor;
  },
  lines(font: string, size: number, text: string, width: number) {
    let lines = 0;
    for (const para of text.split('\n')) lines += Math.max(1, Math.ceil(nodeMetrics.measure(font, size, para) / Math.max(width, 1)));
    return lines;
  },
};

export interface HeadlessLog {
  chat: string[]; errors: { message: string; stack: string }[]; warnings: string[]; missing: string[]; events: string[]; sounds: string[];
}

export async function loadHeadless(opts: { addons?: string[]; dirs?: string[]; useSV?: boolean; world?: unknown; beforeLoad?: (sb: Sandbox) => void } = {}) {
  const paths = resolvePaths(root);
  const settings = loadSettings(paths);
  const log: HeadlessLog = { chat: [], errors: [], warnings: [], missing: [], events: [], sounds: [] };
  const sandbox = await Sandbox.create({
    runtime: runtimeSources(),
    metrics: nodeMetrics,
    callbacks: {
      chat: (t) => log.chat.push(t.replace(/\|c[0-9a-fA-F]{8}|\|r/g, '').replace(/\|T[^|]*\|t/g, '')),
      error: (message, stack) => log.errors.push({ message, stack }),
      warn: (m) => log.warnings.push(m),
      missing: (n) => log.missing.push(n),
      event: (n, a) => log.events.push(a ? `${n}(${a})` : n),
      sound: (id) => log.sounds.push(id),
      reload: () => log.chat.push('[reload requested]'),
      fstack: () => {}, etrace: () => {}, openChat: () => {}, insertChat: () => false,
    },
  });
  sandbox.setScreen(1365, 768, 1920, 1080);
  sandbox.setWorld(opts.world ?? readJson(paths, 'world.json', null) ?? defaultWorld(settings.character));

  const installed = listAddons(paths);
  const { order, missing } = resolveLoadOrder(opts.addons ?? settings.addons, installed);
  const bundles: AddonBundle[] = [];
  const sv: Record<string, SavedVariablesText> = {};
  for (const name of order) {
    const addon = readAddon(paths, name);
    if (!addon) continue;
    bundles.push(addon);
    if (opts.useSV !== false && settings.character) {
      const s = readSavedVariables(paths, name, settings.character);
      sv[name] = { account: s.account, character: s.character };
    }
  }
  // Extra addon folders outside AddOns (e.g. tools/SandboxDump), loaded after the others.
  for (const dir of opts.dirs ?? []) {
    const addon = readAddonDir(path.resolve(dir));
    if (addon) bundles.push(addon);
  }
  opts.beforeLoad?.(sandbox);
  const started = performance.now();
  sandbox.loadAddons(bundles, sv, installed.map((a) => ({
    name: a.name, title: a.title, notes: a.notes, interface: a.interface, loadOnDemand: a.loadOnDemand,
    deps: a.deps, optDeps: a.optDeps, meta: a.meta,
  })), false);
  return { sandbox, log, loadMs: performance.now() - started, missingDeps: missing, paths, settings };
}

// ---------------------------------------------------------------------------
// Use cases
// ---------------------------------------------------------------------------

export function resolveUseCaseRef(ref: string): ResolvedUseCase {
  const paths = resolvePaths(root);
  const { addon, name } = parseUseCaseRef(paths, ref);
  return resolveUseCase(paths, addon, name);
}

export function allUseCaseRefs(addon?: string): string[] {
  return listUseCases(resolvePaths(root)).filter((u) => !addon || u.addon === addon).map((u) => u.id);
}

// A fresh sandbox with the use case's world, addons and SavedVariables, and a runner wired to its output.
export async function loadUseCaseHeadless(resolved: ResolvedUseCase, log?: (line: string) => void) {
  const paths = resolvePaths(root);
  let runner: Runner | null = null;
  const sandbox = await Sandbox.create({
    runtime: runtimeSources(),
    metrics: nodeMetrics,
    callbacks: {
      chat: (t) => runner?.onChat(t),
      error: (message, stack) => runner?.onError(message, stack),
      warn: (m) => runner?.warnings.push(m), missing: () => {}, event: () => {}, sound: () => {},
      reload: () => {}, fstack: () => {}, etrace: () => {}, openChat: () => {}, insertChat: () => false,
    },
  });
  sandbox.setScreen(SCREEN.w, SCREEN.h, 1920, 1080);
  runner = new Runner({ id: resolved.id, useCase: resolved.useCase, sandbox, log });
  const installed = listAddons(paths);
  const { order, missing } = resolveLoadOrder(resolved.useCase.addons, installed);
  const errors = [...resolved.errors, ...missing.map((m) => `Addon not installed: ${m}`)];
  const bundles: AddonBundle[] = [];
  for (const name of order) { const a = readAddon(paths, name); if (a) bundles.push(a); }
  const started = performance.now();
  if (!errors.length) {
    loadUseCase(sandbox, resolved, bundles, installed.map((a) => ({
      name: a.name, title: a.title, notes: a.notes, interface: a.interface, loadOnDemand: a.loadOnDemand,
      deps: a.deps, optDeps: a.optDeps, meta: a.meta,
    })));
  }
  return { sandbox, runner, errors, loadMs: performance.now() - started };
}
