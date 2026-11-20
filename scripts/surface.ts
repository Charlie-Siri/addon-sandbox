// Surface report: what an LLM needs to write use cases for an addon, as Markdown. Slash commands, events,
// SavedVariables, the world, and what is on screen (with ready-to-use targets) after login and after each command.
//
// Usage: npm run surface -- <Addon> [--run "/cmd args"]... [--setup <Addon>/<usecase>] [--fresh] [--json]
//   default state: your sandbox profile (world + SavedVariables), like npm run check
//   --setup: the world and SavedVariables of an existing use case (its fixtures)
//   --fresh: the default world and no SavedVariables (a new install)
//   --run:   commands to try (default: each of the addon's slash commands, bare and with "help")
// Writes nothing.
import { Sandbox, type VisibleText } from '../src/core/sandbox.ts';
import { defaultWorld } from '../src/core/world.ts';
import { loadHeadless, loadUseCaseHeadless, resolveUseCaseRef, runtimeSources, nodeMetrics } from './headless.ts';
import { listFixtures } from '../server/usecases.ts';
import { resolvePaths } from '../server/addons.ts';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
let addon = '';
const runs: string[] = [];
let setupRef = '';
let fresh = false;
let json = false;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--run') runs.push(args[++i]);
  else if (a === '--setup') setupRef = args[++i];
  else if (a === '--fresh') fresh = true;
  else if (a === '--json') json = true;
  else addon = a;
}
if (!addon) {
  console.error('Usage: npm run surface -- <Addon> [--run "/cmd"]... [--setup <Addon>/<usecase>] [--fresh] [--json]');
  process.exit(2);
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// What the runtime defines before any addon loads, so the report shows only the addon's own commands and frames.
async function baseline() {
  const sb = await Sandbox.create({
    runtime: runtimeSources(), metrics: nodeMetrics,
    callbacks: { chat: () => {}, error: () => {}, warn: () => {}, missing: () => {}, event: () => {}, sound: () => {},
      reload: () => {}, fstack: () => {}, etrace: () => {}, openChat: () => {}, insertChat: () => false },
  });
  sb.setScreen(1365, 768, 1920, 1080);
  sb.setWorld(defaultWorld(null));
  const slash = new Set(sb.slashCommands().map((c) => c.key));
  sb.close();
  return { slash };
}

interface Session { sandbox: Sandbox; chat: string[]; errors: string[]; loaded: string[] }

async function open(): Promise<Session> {
  const chat: string[] = [];
  const errors: string[] = [];
  if (setupRef) {
    const resolved = resolveUseCaseRef(setupRef);
    const s = await loadUseCaseHeadless(resolved);
    if (s.errors.length) throw new Error(`--setup ${setupRef}: ${s.errors.join('; ')}`);
    const sb = s.sandbox;
    // forward the runner's capture into ours
    const r = s.runner;
    const origChat = r.onChat.bind(r), origErr = r.onError.bind(r);
    r.onChat = (t) => { origChat(t); chat.push(r.chat[r.chat.length - 1]); };
    r.onError = (m, st) => { origErr(m, st); errors.push(m); };
    for (const l of r.chat) chat.push(l);
    for (const e of r.errors) errors.push(e.message);
    sb.advance(2);
    return { sandbox: sb, chat, errors, loaded: sb.loadOrder };
  }
  const s = await loadHeadless({ addons: [addon], useSV: !fresh, world: fresh ? defaultWorld(null) : undefined });
  s.sandbox.advance(2);
  return {
    sandbox: s.sandbox, loaded: s.sandbox.loadOrder,
    get chat() { return s.log.chat; }, get errors() { return s.log.errors.map((e) => e.message); },
  } as Session;
}

function targetsOf(texts: VisibleText[]) {
  // the same text in different click targets needs nth
  const byText = new Map<string, VisibleText[]>();
  for (const t of texts) {
    const key = t.text.toLowerCase();
    byText.set(key, [...(byText.get(key) ?? []), t]);
  }
  return texts.map((t) => {
    const same = byText.get(t.text.toLowerCase())!;
    const ambiguous = new Set(same.map((x) => x.clickId ?? -x.ownerId)).size > 1;
    const target: Record<string, unknown> = { text: t.text.length > 60 ? t.text.slice(0, 60) : t.text };
    if (ambiguous) target.nth = same.indexOf(t) + 1;
    return { text: t.text, at: [Math.round(t.rect[0]), Math.round(t.rect[1])], clickable: !!t.clickName, clicks: t.clickName ?? null, target };
  });
}

function screenTable(texts: VisibleText[], limit = 70): string[] {
  const rows = targetsOf(texts);
  const out = ['| Text | At (x,y) | Click hits | Target |', '| --- | --- | --- | --- |'];
  for (const r of rows.slice(0, limit)) {
    const text = r.text.length > 50 ? r.text.slice(0, 49) + '…' : r.text;
    out.push(`| ${text.replace(/\|/g, '\\|')} | ${r.at.join(',')} | ${r.clicks ?? '—'} | \`${JSON.stringify(r.target)}\` |`);
  }
  if (rows.length > limit) out.push(`| … ${rows.length - limit} more | | | |`);
  return out;
}

const base = await baseline();
const first = await open();
const sb = first.sandbox;
const paths = resolvePaths(root);
const slash = sb.slashCommands().filter((c) => !base.slash.has(c.key));
const events = sb.registeredEvents();
const toc = sb.addonToc(addon);
const svNames: { name: string; scope: string }[] = [
  ...(toc?.savedVariables ?? []).map((n: string) => ({ name: n, scope: 'account' })),
  ...(toc?.savedVariablesPerCharacter ?? []).map((n: string) => ({ name: n, scope: 'character' })),
];
const world = sb.worldJSON();
const loginTexts = sb.texts();
const commands = runs.length ? runs : slash.flatMap((c) => c.aliases.length ? [c.aliases[0], `${c.aliases[0]} help`] : []);

const afterCommands: { cmd: string; chat: string[]; errors: string[]; texts: VisibleText[]; newFrames: string[]; tooltip: string[] }[] = [];
const loginFrames = new Set(sb.namedFrames().map((f) => f.name));
for (const cmd of commands) {
  const s = await open();
  const chatBefore = s.chat.length, errBefore = s.errors.length;
  const framesBefore = new Set(s.sandbox.namedFrames().map((f) => f.name));
  s.sandbox.chat(cmd);
  s.sandbox.advance(1.5);
  afterCommands.push({
    cmd, chat: s.chat.slice(chatBefore), errors: s.errors.slice(errBefore), texts: s.sandbox.texts(),
    newFrames: s.sandbox.namedFrames().map((f) => f.name).filter((n) => !framesBefore.has(n)),
    tooltip: s.sandbox.tooltips().flatMap((t) => t.lines),
  });
  s.sandbox.close();
}

if (json) {
  console.log(JSON.stringify({
    addon, loaded: first.loaded, state: setupRef ? `setup ${setupRef}` : fresh ? 'fresh' : 'profile',
    slash, events, savedVariables: svNames.map((v) => ({ ...v, shape: sb.shape(v.name, 2).value ?? null })),
    fixtures: listFixtures(paths, addon), errors: first.errors,
    login: { texts: targetsOf(loginTexts), frames: [...loginFrames] },
    commands: afterCommands.map((c) => ({ ...c, texts: targetsOf(c.texts) })),
  }, null, 2));
  process.exit(0);
}

const out: string[] = [];
out.push(`# Surface: ${addon}`, '');
out.push(`State: ${setupRef ? `the setup of use case ${setupRef}` : fresh ? 'default world, no SavedVariables (fresh install)' : 'your sandbox profile (world and SavedVariables)'}. Loaded: ${first.loaded.join(', ')}. Screen: 1365x768 UI units.`);
if (first.errors.length) out.push('', `**Lua errors while loading (${first.errors.length}):**`, ...first.errors.slice(0, 5).map((e) => `- ${e}`));
out.push('', '## Slash commands', '');
if (slash.length) for (const c of slash) out.push(`- ${c.aliases.join(', ')} (SlashCmdList.${c.key})`);
else out.push('None registered.');
out.push('', '## Events the addon listens to', '', events.length ? events.join(', ') : 'None.');
out.push('', '## SavedVariables', '');
if (!svNames.length) out.push('None declared in the TOC.');
for (const v of svNames) {
  const shape = sb.shape(v.name, 2);
  out.push(`- \`${v.name}\` (${v.scope}): ${shape.value === undefined ? 'nil' : '`' + JSON.stringify(shape.value).slice(0, 400) + '`'}`);
}
out.push('', `## Fixtures in profile/usecases/${addon}/fixtures`, '');
const fx = listFixtures(paths, addon);
if (fx.length) for (const f of fx) out.push(`- \`${f.path}\` (${Math.round(f.size / 1024)} KB)`);
else out.push('None yet. Save some from the sandbox World tab ("Save world as fixture", "Save SavedVariables as fixture"), or use "default" for the world and leave savedVariables out for a fresh install.');
out.push('', '## World', '');
const p = world.player ?? {};
out.push(`- Player: ${p.name}-${p.realm}, level ${p.level} ${p.race} ${String(p.class ?? '').toLowerCase()}, ${p.money}c, ${p.zone}`);
out.push(`- Merchants: ${(world.merchants ?? []).map((m: any) => `${m.name} (${m.items.length} items)`).join(', ') || 'none'}`);
out.push(`- Auction House: ${Object.keys(world.auctions ?? {}).length} items listed`);
out.push(`- Professions: ${Object.entries(world.professions ?? {}).map(([n, pr]: [string, any]) => `${n} (${Object.keys(pr.recipes ?? {}).length} recipes)`).join(', ') || 'none'}`);
out.push(`- Loot sources: ${(world.loot ?? []).map((l: any) => l.name).join(', ') || 'none'}`);
const spells = Object.entries(world.spells ?? {});
if (spells.length) out.push(`- Known spells: ${spells.filter(([, s]: [string, any]) => s.known !== false).map(([id, s]: [string, any]) => `${s.name} (${id})`).join(', ')}`);
const auras = world.auras ?? [];
out.push(`- Buffs on the player: ${auras.length ? auras.map((a: any) => `${a.name ?? a.spellId} (${a.remaining}s)`).join(', ') : 'none'}`);
const bagItems: string[] = [];
for (const bag of Object.values(world.bags ?? {}) as any[]) for (const slot of Object.values(bag.slots ?? {}) as any[]) {
  bagItems.push(`${world.items?.[slot.id]?.name ?? slot.id} x${slot.count}`);
}
out.push(`- Bags: ${bagItems.join(', ') || 'empty'}`);
out.push('', '## Screen after login', '');
if (loginTexts.length) out.push(...screenTable(loginTexts));
else out.push('Nothing visible.');
for (const c of afterCommands) {
  out.push('', `## After \`${c.cmd}\``, '');
  if (c.chat.length) out.push('Chat:', '', '```', ...c.chat.slice(0, 25), '```', '');
  if (c.errors.length) out.push(`**Lua errors:** ${c.errors.slice(0, 3).join('; ')}`, '');
  if (c.newFrames.length) out.push(`Frames shown: ${c.newFrames.join(', ')}`, '');
  if (c.texts.length) out.push(...screenTable(c.texts));
  else out.push('Nothing visible.');
}
out.push('', '---', 'Write use cases in profile/usecases/' + addon + '/<name>.usecase.json (format: docs/USECASES.md), then check: `npm run check -- --usecase ' + addon + '/<name> --report`.');
console.log(out.join('\n'));
sb.close();
