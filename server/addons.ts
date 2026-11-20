// File access for the sandbox: reads the WoW install (AddOns, WTF) and owns the sandbox profile folder.
// The WoW install is only ever read. Everything the sandbox writes goes under profile/.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { parseToc, type TocInfo } from '../src/core/toc.ts';

export interface SandboxPaths {
  wowDir: string;      // the flavor folder, e.g. .../World of Warcraft/_forever_
  addonsDir: string;
  wtfDir: string;
  profileDir: string;  // sandbox-owned copy of SavedVariables, world state and settings
}

export interface CharacterRef { account: string; realm: string; name: string }

export interface Settings {
  addons: string[];            // addons to load, in the user's chosen set (dependencies are added automatically)
  character: CharacterRef | null;
}

const DEFAULT_WOW_DIR = path.join(os.homedir(),
  'Faugus/battlenet/drive_c/Program Files (x86)/World of Warcraft/_forever_');

export function resolvePaths(root: string): SandboxPaths {
  const wowDir = process.env.SANDBOX_WOW_DIR || DEFAULT_WOW_DIR;
  return {
    wowDir,
    addonsDir: path.join(wowDir, 'Interface', 'AddOns'),
    wtfDir: path.join(wowDir, 'WTF'),
    profileDir: process.env.SANDBOX_PROFILE_DIR || path.join(root, 'profile'),
  };
}

// Flavor-specific TOC suffixes, most specific first. Unverified for Forever: confirm against the client in Phase 0.
const TOC_SUFFIXES = ['_Forever', '-Forever', '_Mainline', '-Mainline', ''];
const TEXT_EXT = new Set(['.lua', '.xml', '.toc']);

function findToc(dir: string, name: string): string | null {
  let entries: string[];
  try { entries = fs.readdirSync(dir); } catch { return null; }
  const lower = new Map(entries.map((e) => [e.toLowerCase(), e]));
  for (const suffix of TOC_SUFFIXES) {
    const hit = lower.get(`${name}${suffix}.toc`.toLowerCase());
    if (hit) return path.join(dir, hit);
  }
  return null;
}

export interface AddonSummary extends Omit<TocInfo, 'files'> { name: string; tocFile: string; fileCount: number }

// Parsed TOCs keyed by path, reused while the file's mtime and size are unchanged.
const tocCache = new Map<string, { key: string; info: TocInfo }>();
function parseTocFile(file: string): TocInfo {
  const st = fs.statSync(file);
  const key = `${st.mtimeMs}:${st.size}`;
  const hit = tocCache.get(file);
  if (hit && hit.key === key) return hit.info;
  const info = parseToc(fs.readFileSync(file, 'utf8'));
  tocCache.set(file, { key, info });
  return info;
}

export function listAddons(paths: SandboxPaths): AddonSummary[] {
  let dirs: fs.Dirent[];
  try { dirs = fs.readdirSync(paths.addonsDir, { withFileTypes: true }); } catch { return []; }
  const out: AddonSummary[] = [];
  for (const d of dirs) {
    if (!d.isDirectory() && !d.isSymbolicLink()) continue;
    const toc = findToc(path.join(paths.addonsDir, d.name), d.name);
    if (!toc) continue;
    // File lists stay out of the summary (some addons list thousands); readAddon has them.
    // Metadata is capped too: QuestieDB keeps its whole database (15 MB) in "## " lines.
    const { files, meta, ...info } = parseTocFile(toc);
    const shortMeta: Record<string, string> = {};
    let budget = 16_000;
    for (const [k, v] of Object.entries(meta)) {
      if (k.length + v.length > budget) break;
      shortMeta[k] = v;
      budget -= k.length + v.length;
    }
    out.push({ name: d.name, tocFile: path.basename(toc), fileCount: files.length, meta: shortMeta, ...info });
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

// Every text file of an addon, keyed by lower-case forward-slash path (WoW resolves paths case-insensitively).
export function readAddon(paths: SandboxPaths, name: string) {
  return readAddonDir(safeJoin(paths.addonsDir, name), name);
}

export function readAddonDir(dir: string, name = path.basename(dir)) {
  const tocPath = findToc(dir, name);
  if (!tocPath) return null;
  const files: Record<string, { path: string; text: string }> = {};
  const walk = (abs: string, rel: string) => {
    for (const e of fs.readdirSync(abs, { withFileTypes: true })) {
      const childAbs = path.join(abs, e.name);
      const childRel = rel ? `${rel}/${e.name}` : e.name;
      const stat = fs.statSync(childAbs);
      if (stat.isDirectory()) walk(childAbs, childRel);
      else if (TEXT_EXT.has(path.extname(e.name).toLowerCase())) {
        files[childRel.toLowerCase()] = { path: childRel, text: fs.readFileSync(childAbs, 'utf8') };
      }
    }
  };
  walk(dir, '');
  return { name, tocFile: path.basename(tocPath), toc: parseTocFile(tocPath), files };
}

// Accounts and characters that have a WTF folder, newest first.
export function listCharacters(paths: SandboxPaths): (CharacterRef & { modified: number })[] {
  const out: (CharacterRef & { modified: number })[] = [];
  const accountsDir = path.join(paths.wtfDir, 'Account');
  for (const account of safeReaddir(accountsDir)) {
    const accountDir = path.join(accountsDir, account);
    for (const realm of safeReaddir(accountDir)) {
      const realmDir = path.join(accountDir, realm);
      if (realm === 'SavedVariables' || !isDir(realmDir)) continue;
      for (const name of safeReaddir(realmDir)) {
        const svDir = path.join(realmDir, name, 'SavedVariables');
        if (!isDir(svDir)) continue;
        out.push({ account, realm, name, modified: fs.statSync(svDir).mtimeMs });
      }
    }
  }
  return out.sort((a, b) => b.modified - a.modified);
}

function svRelPaths(addon: string, ch: CharacterRef) {
  return {
    account: path.join('Account', ch.account, 'SavedVariables', `${addon}.lua`),
    character: path.join('Account', ch.account, ch.realm, ch.name, 'SavedVariables', `${addon}.lua`),
  };
}

type SvSource = 'sandbox' | 'wtf' | null;

// The sandbox copy if one exists, else the real WTF file as a read-only seed.
export function readSavedVariables(paths: SandboxPaths, addon: string, ch: CharacterRef) {
  const rel = svRelPaths(addon, ch);
  const pick = (r: string): { text: string | null; from: SvSource } => {
    const sandbox = path.join(paths.profileDir, 'WTF', r);
    if (fs.existsSync(sandbox)) return { text: fs.readFileSync(sandbox, 'utf8'), from: 'sandbox' };
    const real = path.join(paths.wtfDir, r);
    if (fs.existsSync(real)) return { text: fs.readFileSync(real, 'utf8'), from: 'wtf' };
    return { text: null, from: null };
  };
  const account = pick(rel.account);
  const character = pick(rel.character);
  return { account: account.text, character: character.text, from: { account: account.from, character: character.from } };
}

// The real WTF copy only (used for SandboxDump's export, which the game writes).
export function readWtfAccountSavedVariables(paths: SandboxPaths, addon: string, ch: CharacterRef) {
  const file = path.join(paths.wtfDir, svRelPaths(addon, ch).account);
  return fs.existsSync(file) ? { text: fs.readFileSync(file, 'utf8'), modified: fs.statSync(file).mtimeMs } : null;
}

export function writeSavedVariables(paths: SandboxPaths, addon: string, ch: CharacterRef,
  data: { account?: string | null; character?: string | null }) {
  const rel = svRelPaths(addon, ch);
  for (const key of ['account', 'character'] as const) {
    const text = data[key];
    if (text == null) continue;
    const file = path.join(paths.profileDir, 'WTF', rel[key]);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, text);
  }
}

// Drops the sandbox copies; the next load seeds from WTF again.
export function resetSavedVariables(paths: SandboxPaths, addon: string, ch: CharacterRef) {
  const rel = svRelPaths(addon, ch);
  for (const r of [rel.account, rel.character]) fs.rmSync(path.join(paths.profileDir, 'WTF', r), { force: true });
}

export function readJson<T>(paths: SandboxPaths, file: string, fallback: T): T {
  try { return JSON.parse(fs.readFileSync(path.join(paths.profileDir, file), 'utf8')) as T; } catch { return fallback; }
}

export function writeJson(paths: SandboxPaths, file: string, value: unknown) {
  fs.mkdirSync(paths.profileDir, { recursive: true });
  fs.writeFileSync(path.join(paths.profileDir, file), JSON.stringify(value, null, 2));
}

export function loadSettings(paths: SandboxPaths): Settings {
  const s = readJson<Partial<Settings>>(paths, 'settings.json', {});
  const character = s.character ?? listCharacters(paths)[0] ?? null;
  return { addons: s.addons ?? ['VendorPrinter'], character: character && { account: character.account, realm: character.realm, name: character.name } };
}

// Rejects names that would escape the base folder.
function safeJoin(base: string, name: string) {
  const p = path.resolve(base, name);
  if (!p.startsWith(path.resolve(base) + path.sep)) throw new Error(`Invalid path: ${name}`);
  return p;
}

function safeReaddir(dir: string) { try { return fs.readdirSync(dir); } catch { return []; } }
function isDir(p: string) { try { return fs.statSync(p).isDirectory(); } catch { return false; } }

export function isValidAddonName(name: string) { return /^[\w .\-]+$/.test(name) && !name.includes('..'); }
