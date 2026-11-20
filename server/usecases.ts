// Use case files: profile/usecases/<Addon>/<name>.usecase.json, fixtures under profile/usecases/<Addon>/fixtures/,
// exported videos under profile/videos/<Addon>/. Resolving a use case loads its world and SavedVariables fixtures.
import fs from 'node:fs';
import path from 'node:path';
import type { SandboxPaths } from './addons.ts';
import { defaultWorld } from '../src/core/world.ts';
import { validateUseCase, useCaseId, type UseCase, type ResolvedUseCase } from '../src/core/usecase.ts';

export function usecasesDir(paths: SandboxPaths) { return path.join(paths.profileDir, 'usecases'); }
export function videosDir(paths: SandboxPaths) { return path.join(paths.profileDir, 'videos'); }

const NAME = /^[A-Za-z0-9][\w .\-]*$/;
export function isValidName(name: string) { return NAME.test(name) && !name.includes('..'); }

function inside(base: string, rel: string) {
  const p = path.resolve(base, rel);
  if (p !== path.resolve(base) && !p.startsWith(path.resolve(base) + path.sep)) throw new Error(`Path escapes the use case folder: ${rel}`);
  return p;
}

export interface UseCaseSummary {
  id: string; addon: string; name: string; title: string; summary?: string; steps: number; addons: string[];
  errors: string[]; modified: number; video?: { modified: number; size: number };
}

export function listUseCases(paths: SandboxPaths): UseCaseSummary[] {
  const root = usecasesDir(paths);
  const out: UseCaseSummary[] = [];
  for (const addon of safeReaddir(root).sort()) {
    const dir = path.join(root, addon);
    if (!isDir(dir)) continue;
    for (const file of safeReaddir(dir).sort()) {
      if (!file.endsWith('.usecase.json')) continue;
      const name = file.replace(/\.usecase\.json$/, '');
      const full = path.join(dir, file);
      let uc: any = null;
      let errors: string[] = [];
      try { uc = JSON.parse(fs.readFileSync(full, 'utf8')); errors = validateUseCase(uc); }
      catch (e) { errors = [`Invalid JSON: ${(e as Error).message}`]; }
      const video = videoPath(paths, addon, name);
      const vst = fs.existsSync(video) ? fs.statSync(video) : null;
      out.push({
        id: useCaseId(addon, file), addon, name, title: uc?.title ?? name, summary: uc?.summary,
        steps: Array.isArray(uc?.steps) ? uc.steps.length : 0, addons: Array.isArray(uc?.addons) ? uc.addons : [addon],
        errors, modified: fs.statSync(full).mtimeMs, video: vst ? { modified: vst.mtimeMs, size: vst.size } : undefined,
      });
    }
  }
  return out;
}

export function useCasePath(paths: SandboxPaths, addon: string, name: string) {
  if (!isValidName(addon) || !isValidName(name)) throw new Error(`Bad use case id: ${addon}/${name}`);
  return path.join(usecasesDir(paths), addon, `${name}.usecase.json`);
}

export function videoPath(paths: SandboxPaths, addon: string, name: string) {
  if (!isValidName(addon) || !isValidName(name)) throw new Error(`Bad use case id: ${addon}/${name}`);
  return path.join(videosDir(paths), addon, `${name}.mp4`);
}

// "VendorPrinter/find-a-flip", "VendorPrinter/find-a-flip.usecase.json" or a file path -> addon + name
export function parseUseCaseRef(paths: SandboxPaths, ref: string): { addon: string; name: string } {
  if (ref.endsWith('.usecase.json') && fs.existsSync(ref)) {
    const abs = path.resolve(ref);
    return { addon: path.basename(path.dirname(abs)), name: path.basename(abs).replace(/\.usecase\.json$/, '') };
  }
  const clean = ref.replace(/\.usecase\.json$/, '');
  const [addon, ...rest] = clean.split('/');
  if (!addon || !rest.length) throw new Error(`Use case "${ref}": expected <Addon>/<name>, e.g. VendorPrinter/vendor-tab`);
  return { addon, name: rest.join('/') };
}

function readFixture(dir: string, rel: string, errors: string[], what: string): string | null {
  try {
    const file = inside(dir, rel);
    if (!fs.existsSync(file)) { errors.push(`${what}: fixture not found: ${rel} (looked in ${dir})`); return null; }
    return fs.readFileSync(file, 'utf8');
  } catch (e) { errors.push(`${what}: ${(e as Error).message}`); return null; }
}

function setPath(obj: any, dotted: string, value: unknown) {
  const keys = dotted.split('.');
  let t = obj;
  for (const k of keys.slice(0, -1)) {
    if (typeof t[k] !== 'object' || t[k] === null) t[k] = {};
    t = t[k];
  }
  t[keys[keys.length - 1]] = value;
}

// Reads the use case and everything its setup points at. Never throws for content problems: they go in `errors`.
export function resolveUseCase(paths: SandboxPaths, addon: string, name: string): ResolvedUseCase {
  const file = useCasePath(paths, addon, name);
  const dir = path.dirname(file);
  const errors: string[] = [];
  let useCase: UseCase;
  try { useCase = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (e) {
    const msg = fs.existsSync(file) ? `Invalid JSON in ${file}: ${(e as Error).message}` : `No use case at ${file}`;
    return { id: `${addon}/${name}`, addon, name, useCase: { title: name, addons: [addon], steps: [] }, world: defaultWorld(null), savedVariables: {}, errors: [msg] };
  }
  errors.push(...validateUseCase(useCase));
  const setup = useCase.setup ?? {};

  let world: any = defaultWorld(null);
  const loadWorld = (ref: string) => {
    if (ref === 'default') return defaultWorld(null);
    const text = readFixture(dir, ref, errors, 'setup.world');
    if (text == null) return defaultWorld(null);
    try { return JSON.parse(text); } catch (e) { errors.push(`setup.world: ${ref} is not valid JSON: ${(e as Error).message}`); return defaultWorld(null); }
  };
  if (typeof setup.world === 'string') world = loadWorld(setup.world);
  else if (setup.world && typeof setup.world === 'object') {
    const w = setup.world as Record<string, any>;
    if ('base' in w || 'set' in w) {
      world = loadWorld(typeof w.base === 'string' ? w.base : 'default');
      for (const [p, v] of Object.entries(w.set ?? {})) setPath(world, p, v);
    } else world = w;
  }

  const savedVariables: ResolvedUseCase['savedVariables'] = {};
  for (const [a, sv] of Object.entries(setup.savedVariables ?? {})) {
    const pick = (v: string | undefined, kind: string) => {
      if (v === undefined) return null;
      return /\.lua$/i.test(v.trim()) ? readFixture(dir, v.trim(), errors, `setup.savedVariables.${a}.${kind}`) : v;
    };
    savedVariables[a] = { account: pick(sv?.account, 'account'), character: pick(sv?.character, 'character') };
  }
  return { id: `${addon}/${name}`, addon, name, useCase, world, savedVariables, errors };
}

export function writeUseCase(paths: SandboxPaths, addon: string, name: string, useCase: unknown) {
  const file = useCasePath(paths, addon, name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(useCase, null, 2) + '\n');
  return file;
}

// rel is relative to the addon's use case folder, e.g. "fixtures/scanned.world.json"
export function writeFixture(paths: SandboxPaths, addon: string, rel: string, text: string) {
  if (!isValidName(addon)) throw new Error(`Bad addon name: ${addon}`);
  if (!/^fixtures\/[\w .\-]+\.(json|lua)$/.test(rel)) throw new Error(`Fixtures go in fixtures/ and end in .json or .lua: ${rel}`);
  const file = inside(path.join(usecasesDir(paths), addon), rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
  return file;
}

export function listFixtures(paths: SandboxPaths, addon: string) {
  if (!isValidName(addon)) return [];
  const dir = path.join(usecasesDir(paths), addon, 'fixtures');
  return safeReaddir(dir).filter((f) => /\.(json|lua)$/.test(f)).sort().map((f) => {
    const st = fs.statSync(path.join(dir, f));
    return { path: `fixtures/${f}`, size: st.size, modified: st.mtimeMs };
  });
}

function safeReaddir(dir: string) { try { return fs.readdirSync(dir); } catch { return []; } }
function isDir(p: string) { try { return fs.statSync(p).isDirectory(); } catch { return false; } }
