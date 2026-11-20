// Use cases tab: list, player (play, pause, next, back, restart, speed, step list, failure report), in-page check,
// video export with progress, record mode, and fixture saving. Also the recorder API the video exporter drives.
import { Runner, FRAME, failureReport } from './core/runner.ts';
import { describeStep, type ResolvedUseCase, type Step, type Target, type UseCase } from './core/usecase.ts';
import type { Sandbox } from './core/sandbox.ts';
import { UseCaseView } from './ucview.ts';
import { h, $, storageGet, storageSet } from './dom.ts';

export interface SessionHooks { chat(text: string): void; error(message: string, stack: string): void }
export interface UseCaseHost {
  api: { get<T>(url: string): Promise<T>; post(url: string, body: unknown): Promise<any> };
  sandbox(): Sandbox | null;
  // Replace the running session with the use case's (the user's session is saved first, once).
  // `attach` runs after the sandbox exists and before addons load, so load-time output reaches the runner.
  startUseCase(resolved: ResolvedUseCase, attach: (sb: Sandbox) => SessionHooks): Promise<Sandbox>;
  // A sandbox that is not drawn (checks).
  createDetached(resolved: ResolvedUseCase, attach: (sb: Sandbox) => SessionHooks): Promise<Sandbox>;
  endUseCase(): Promise<void>;
  applyRender(json: string): void;
  forceRender(): void;
  screen(): { w: number; h: number };
  systemLine(text: string, warn?: boolean): void;
  setStatus(text: string): void;
  selectTab(name: string): void;
  loadedAddons(): string[];
}

interface Summary {
  id: string; addon: string; name: string; title: string; summary?: string; steps: number; addons: string[];
  errors: string[]; modified: number; video?: { modified: number; size: number };
}
interface CheckResult { ok: boolean; message: string; report: string; passed: number; total: number; seconds: number }
interface VideoProgress { id: string; phase: string; frame?: number; total?: number; eta?: number; error?: string; file?: string; size?: number; seconds?: number }

let host: UseCaseHost;
let view: UseCaseView;
let list: Summary[] = [];
let listError = '';
const checks = new Map<string, CheckResult | 'running'>();
const videos = new Map<string, VideoProgress>();
let player: Player | null = null;
let recorder: Recorder | null = null;

export function initUseCases(h: UseCaseHost) {
  host = h;
  view = new UseCaseView($('uc-layer'));
  if (import.meta.hot) {
    import.meta.hot.on('sandbox:usecases', (d: { addon: string; name: string }) => {
      refreshList();
      if (player && player.resolved.id === `${d.addon}/${d.name}`) restartPlayer();
    });
    import.meta.hot.on('sandbox:video', (p: VideoProgress) => {
      videos.set(p.id, p);
      if (p.phase === 'done') { host.systemLine(`Video saved: ${p.file} (${((p.size ?? 0) / 1048576).toFixed(1)} MB, ${p.seconds?.toFixed(1)} s)`); refreshList(); }
      if (p.phase === 'error') host.systemLine(`Video export failed: ${p.error}`, true);
      renderTab();
    });
  }
  refreshList();
}

export function playerActive() { return player !== null; }
// An addon file or the use case itself changed: load it again from the start.
export async function restartPlayer() {
  const p = player;
  if (!p) return;
  try {
    const fresh = await host.api.get<ResolvedUseCase>(`/api/usecase/${p.resolved.id}`);
    if (!fresh.errors.length) p.resolved = fresh;
    else host.systemLine(`${p.resolved.id} has problems now: ${fresh.errors[0]}`, true);
  } catch { /* keep the old copy */ }
  host.systemLine(`Restarting ${p.resolved.id}`);
  p.restart();
}
export function playerTick(dt: number) { player?.tick(dt); }
export function getRecorder() { return recorder; }

export async function refreshList() {
  try { list = await host.api.get<Summary[]>('/api/usecases'); listError = ''; }
  catch (e) { listError = (e as Error).message; }
  renderTab();
}

// ---------------------------------------------------------------------------
// Player
// ---------------------------------------------------------------------------
type PlayerState = 'loading' | 'playing' | 'stepping' | 'paused' | 'done' | 'failed';

class Player {
  resolved: ResolvedUseCase;
  runner: Runner | null = null;
  state: PlayerState = 'loading';
  speed = Number(storageGet('sandbox.uc.speed', '1')) || 1;
  private acc = 0;
  private sig = '';
  private loadToken = 0;

  constructor(resolved: ResolvedUseCase) { this.resolved = resolved; }

  // stopAt < 0: from the very beginning (intro shown); else fast-forward to the start of step stopAt, paused.
  async load(stopAt: number, autoplay: boolean) {
    const token = ++this.loadToken;
    this.state = 'loading';
    this.runner = null;
    view.clear();
    renderTab();
    let runner: Runner | null = null;
    await host.startUseCase(this.resolved, (sb) => {
      runner = new Runner({ id: this.resolved.id, useCase: this.resolved.useCase, sandbox: sb, screen: host.screen() });
      return { chat: (t) => runner!.onChat(t), error: (m, s) => runner!.onError(m, s) };
    });
    if (token !== this.loadToken || !runner) return;
    this.runner = runner;
    const r = runner as Runner;
    if (stopAt >= 0) {
      host.setStatus(`Use case: ${this.resolved.useCase.title} · rewinding…`);
      await new Promise((res) => setTimeout(res, 0));
      r.fastForward(stopAt);
      host.forceRender();
      view.render(r.view, r.displayTime, host.screen(), r.chatLines);
    }
    this.acc = 0;
    this.state = r.failure ? 'failed' : r.done ? 'done' : autoplay ? 'playing' : 'paused';
    if (autoplay) { r.paused = false; r.pauseAfterStep = false; }
    this.status();
    renderTab();
  }

  tick(dt: number) {
    const r = this.runner;
    if (!r) return;
    if (this.state === 'playing' || this.state === 'stepping') {
      this.acc += Math.min(dt, 0.25) * this.speed;
      let json = '';
      let n = 0;
      while (this.acc >= FRAME && n < 10) {
        const j = r.tick(FRAME, true);
        if (j) json = j;
        this.acc -= FRAME;
        n++;
        if (r.finished || r.paused) break;
      }
      if (this.acc > FRAME * 10) this.acc = 0;
      if (json) host.applyRender(json);
      if (r.failure) { this.state = 'failed'; host.systemLine(`Use case failed at step ${r.failure.step + 1}: ${r.failure.message}`, true); }
      else if (r.done) this.state = 'done';
      else if (r.paused) this.state = 'paused';
    }
    view.render(r.view, r.displayTime, host.screen(), r.chatLines);
    const sig = `${this.state}|${r.stepIndex}|${r.results.map((x) => x.status[0]).join('')}`;
    if (sig !== this.sig) { this.sig = sig; this.status(); renderPlayer(); }
  }

  position(): number {
    const r = this.runner;
    if (!r || r.stepIndex < 0) return 0;
    return r.results[r.stepIndex]?.status === 'running' ? r.stepIndex : r.stepIndex + 1;
  }

  play() {
    if (!this.runner || this.state === 'loading') return;
    if (this.state === 'done' || this.state === 'failed') { this.load(-1, true); return; }
    this.runner.pauseAfterStep = false;
    this.runner.paused = false;
    this.state = 'playing';
    renderPlayer();
  }
  pause() { if (this.state === 'playing' || this.state === 'stepping') { this.state = 'paused'; renderPlayer(); } }
  next() {
    if (!this.runner || this.state === 'loading' || this.state === 'done' || this.state === 'failed') return;
    this.runner.pauseAfterStep = true;
    this.runner.paused = false;
    this.state = 'stepping';
    renderPlayer();
  }
  back() { this.seek(Math.max(0, this.position() - 1)); }
  seek(step: number) { this.load(step, false); }
  restart() { this.load(-1, true); }
  setSpeed(s: number) { this.speed = s; storageSet('sandbox.uc.speed', String(s)); }

  status() {
    const r = this.runner;
    const uc = this.resolved.useCase;
    host.setStatus(`Use case: ${uc.title} · ${this.where().toLowerCase()} (changes in this session are not saved)`);
  }

  // "Step 3 of 14" while it runs, "Paused before step 3 of 14" between steps.
  where(): string {
    const r = this.runner;
    const n = this.resolved.useCase.steps.length;
    if (!r) return 'Loading…';
    if (this.state === 'done') return `Finished · ${r.displayTime.toFixed(1)} s`;
    if (this.state === 'failed') return `Failed at step ${(r.failure?.step ?? 0) + 1} of ${n}`;
    if (r.stepIndex < 0 && this.state !== 'paused') return 'Intro';
    const running = r.results[r.stepIndex]?.status === 'running';
    const step = Math.min(running ? r.stepIndex + 1 : this.position() + 1, n);
    return `${this.state === 'paused' ? 'Paused before step' : 'Step'} ${step} of ${n} · ${r.displayTime.toFixed(1)} s`;
  }
}

async function play(id: string, autoplay = true) {
  try {
    const resolved = await host.api.get<ResolvedUseCase>(`/api/usecase/${id}`);
    if (resolved.errors.length) {
      host.systemLine(`${id} has problems: ${resolved.errors.join('; ')}`, true);
      checks.set(id, { ok: false, message: resolved.errors[0], report: resolved.errors.join('\n'), passed: 0, total: resolved.useCase.steps.length, seconds: 0 });
      renderTab();
      return;
    }
    if (recorder) { host.systemLine('Stop recording first.', true); return; }
    player = new Player(resolved);
    await player.load(-1, autoplay);
  } catch (e) { host.systemLine(`Could not play ${id}: ${(e as Error).message}`, true); }
}

async function exitPlayer() {
  player = null;
  view.clear();
  renderTab();
  await host.endUseCase();
}

// ---------------------------------------------------------------------------
// Check (runs in a detached sandbox, in chunks so the page stays responsive)
// ---------------------------------------------------------------------------
async function check(id: string) {
  checks.set(id, 'running');
  renderTab();
  const started = performance.now();
  try {
    const resolved = await host.api.get<ResolvedUseCase>(`/api/usecase/${id}`);
    if (resolved.errors.length) throw new Error(resolved.errors.join('\n'));
    let runner: Runner | null = null;
    const sb = await host.createDetached(resolved, (s) => {
      runner = new Runner({ id, useCase: resolved.useCase, sandbox: s });
      return { chat: (t) => runner!.onChat(t), error: (m, st) => runner!.onError(m, st) };
    });
    const r = runner as unknown as Runner;
    while (!r.finished) {
      for (let i = 0; i < 150 && !r.finished; i++) r.tick(FRAME, false);
      await new Promise((res) => setTimeout(res, 0));
      if (r.displayTime > 3600) break;
    }
    const passed = r.results.filter((x) => x.status === 'passed').length;
    checks.set(id, {
      ok: r.done, passed, total: resolved.useCase.steps.length, seconds: r.displayTime,
      message: r.done ? `passed in ${((performance.now() - started) / 1000).toFixed(1)} s` : `step ${r.failure!.step + 1}: ${r.failure!.message}`,
      report: failureReport(r),
    });
    sb.close();
  } catch (e) {
    checks.set(id, { ok: false, message: (e as Error).message.split('\n')[0], report: (e as Error).message, passed: 0, total: 0, seconds: 0 });
  }
  renderTab();
}

async function exportVideo(id: string) {
  videos.set(id, { id, phase: 'starting' });
  renderTab();
  try { await host.api.post('/api/video', { id }); }
  catch (e) { videos.set(id, { id, phase: 'error', error: (e as Error).message }); renderTab(); }
}

// ---------------------------------------------------------------------------
// Record mode: your clicks, drags, wheel, typing, slash commands and World tab actions become steps
// ---------------------------------------------------------------------------
interface Recorded { at: number; step: Step }

export class Recorder {
  addon: string;
  name: string;
  steps: Recorded[] = [];
  private down: { x: number; y: number; target: Target; mods: Mods; button: string } | null = null;
  private typed = '';
  private typedAt = 0;
  private restore: (() => void)[] = [];
  private fixtures: { world: string; sv: Record<string, { account?: string; character?: string }> };

  constructor(addon: string, name: string, fixtures: Recorder['fixtures']) {
    this.addon = addon;
    this.name = name;
    this.fixtures = fixtures;
  }

  private push(step: Step) {
    this.flushTyping();
    this.steps.push({ at: performance.now(), step });
    renderTab();
  }

  // Best target for whatever is under a point: unique visible text in the clicked frame, else names, else the point.
  target(x: number, y: number): Target {
    const sb = host.sandbox()!;
    const info = sb.describePoint(x, y);
    if (info.hitId !== undefined) {
      const texts = [...new Set(info.texts ?? [])].filter((t) => t.length <= 60)
        .sort((a, b) => Number(/[a-z]/i.test(b)) - Number(/[a-z]/i.test(a)));
      for (const text of texts) {
        const r = sb.find({ text });
        const live = r.matches.filter((m) => m.clickName && !m.covered);   // as playback resolves clicks
        const pool = live.length ? live : r.matches;
        const exact = pool.filter((m) => m.exact);
        const ms = exact.length ? exact : pool;
        const i = ms.findIndex((m) => m.clickId === info.hitId);
        if (i < 0) continue;
        const ids = new Set(ms.map((m) => m.clickId ?? -(m.ownerId ?? 0)));
        return ids.size === 1 ? { text } : { text, nth: i + 1 };
      }
      if (info.global) return { frame: info.global };
      if (info.path) return { path: info.path };
    }
    return { point: [Math.round(x), Math.round(y)] };
  }

  pointerDown(x: number, y: number, button: string, mods: Mods) {
    this.flushTyping();
    this.down = { x, y, target: this.target(x, y), mods, button };
  }

  pointerUp(x: number, y: number) {
    const d = this.down;
    this.down = null;
    if (!d) return;
    const dx = Math.round(x - d.x), dy = Math.round(y - d.y);
    const m: Partial<Step> = {};
    if (d.mods.shift) m.shift = true;
    if (d.mods.ctrl) m.ctrl = true;
    if (d.mods.alt) m.alt = true;
    if (Math.hypot(dx, dy) > 4) this.push({ drag: d.target, to: { dx, dy }, ...m });
    else {
      const last = this.steps[this.steps.length - 1];
      if (last && last.step.click && JSON.stringify(last.step.click) === JSON.stringify(d.target) && performance.now() - last.at < 350 && !last.step.double) {
        last.step.double = true;
        renderTab();
        return;
      }
      this.push({ click: d.target, ...(d.button !== 'LeftButton' ? { button: d.button as Step['button'] } : {}), ...m });
    }
  }

  wheel(x: number, y: number, delta: number) {
    const target = this.target(x, y);
    const last = this.steps[this.steps.length - 1];
    if (last?.step.scroll && JSON.stringify(last.step.scroll) === JSON.stringify(target) && Math.sign(last.step.delta ?? 0) === Math.sign(delta)) {
      last.step.delta = (last.step.delta ?? 0) + delta;
      last.at = performance.now();
      renderTab();
      return;
    }
    this.push({ scroll: target, delta });
  }

  slash(text: string) { this.push({ slash: text }); }

  key(key: string, mods: Mods, char: string | null, handled: boolean) {
    if (!handled) return;
    if (char && char.length === 1 && !mods.ctrl && !mods.alt) {
      if (!this.typed) this.typedAt = performance.now();
      this.typed += char;
      return;
    }
    if (key === 'BACKSPACE' && this.typed) { this.typed = this.typed.slice(0, -1); return; }
    this.push({ key, ...(mods.shift ? { shift: true } : {}), ...(mods.ctrl ? { ctrl: true } : {}), ...(mods.alt ? { alt: true } : {}) });
  }

  private flushTyping() {
    if (!this.typed) return;
    const text = this.typed;
    this.typed = '';
    this.steps.push({ at: this.typedAt, step: { type: text } });
  }

  world(step: Step) { this.push(step); }

  // Wrap the sandbox's world methods so World tab actions are recorded too.
  hook(sb: Sandbox) {
    const wrap = <K extends keyof Sandbox>(name: K, make: (...args: any[]) => Step | null) => {
      const orig = (sb as any)[name].bind(sb);
      (sb as any)[name] = (...args: any[]) => { const s = make(...args); if (s) this.world(s); return orig(...args); };
      this.restore.push(() => { (sb as any)[name] = orig; });
    };
    const nameAt = (key: 'merchants' | 'loot', i: number) => sb.worldJSON()[key]?.[i - 1]?.name as string | undefined;
    wrap('openMerchant', (i: number) => ({ world: { open: 'merchant', name: nameAt('merchants', i) } }));
    wrap('openLoot', (i: number) => ({ world: { open: 'loot', name: nameAt('loot', i) } }));
    wrap('openAH', () => ({ world: { open: 'ah' } }));
    wrap('openProfession', (name: string) => ({ world: { open: 'profession', name } }));
    wrap('openMail', () => ({ world: { open: 'mail' } }));
    wrap('closeMerchant', () => ({ world: { close: 'merchant' } }));
    wrap('closeAH', () => ({ world: { close: 'ah' } }));
    wrap('closeLoot', () => ({ world: { close: 'loot' } }));
    wrap('closeProfession', () => ({ world: { close: 'profession' } }));
    wrap('closeMail', () => ({ world: { close: 'mail' } }));
    wrap('setCombat', (on: boolean) => ({ world: { combat: on } }));
    wrap('buyFromAH', (item: number, count: number) => ({ world: { buy: { item, count } } }));
    wrap('sellOnAH', (item: number, count: number, price: number) => ({ world: { sell: { item, count, price } } }));
    wrap('setWorldValue', (path: string, value: unknown) => (path === 'player.money' ? { world: { money: value as number } } : { world: { set: { [path]: value } } }));
    wrap('fireEvent', (event: string, args: string) => ({ event, ...(args ? { args } : {}) }));
  }

  unhook() { for (const r of this.restore.splice(0)) r(); }

  build(): UseCase {
    this.flushTyping();
    const steps: Step[] = [];
    let prev = this.steps[0]?.at ?? 0;
    for (const r of this.steps) {
      const gap = (r.at - prev) / 1000;
      if (gap > 3) steps.push({ wait: Math.min(60, Math.round(gap * 2) / 2) });
      steps.push(r.step);
      prev = r.at;
    }
    return {
      title: this.name,
      summary: `Recorded in the sandbox on ${new Date().toISOString().slice(0, 10)}. Add captions (say) and checks (expect).`,
      addons: host.loadedAddons(),
      setup: { world: this.fixtures.world, savedVariables: this.fixtures.sv, wait: 2 },
      steps: steps.length ? steps : [{ say: 'Nothing was recorded.' }],
    };
  }
}
interface Mods { shift: boolean; ctrl: boolean; alt: boolean }

const slug = (s: string) => s.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60);

// Saves the running session's world and SavedVariables as fixtures; returns the setup entries that use them.
export async function saveFixtures(addon: string, name: string, what: { world?: boolean; sv?: boolean } = { world: true, sv: true }) {
  const sb = host.sandbox();
  if (!sb) throw new Error('The sandbox is not running');
  const out: { world: string; sv: Record<string, { account?: string; character?: string }> } = { world: 'default', sv: {} };
  if (what.world) {
    const path = `fixtures/${name}.world.json`;
    await host.api.post(`/api/fixture/${encodeURIComponent(addon)}`, { path, text: JSON.stringify(sb.worldJSON(), null, 1) });
    out.world = path;
  }
  if (what.sv) {
    const sv = sb.serializeSavedVariables();
    for (const [a, data] of Object.entries(sv)) {
      const entry: { account?: string; character?: string } = {};
      for (const kind of ['account', 'character'] as const) {
        const text = data[kind];
        if (!text) continue;
        const path = `fixtures/${name}.${a}.${kind}.lua`;
        await host.api.post(`/api/fixture/${encodeURIComponent(addon)}`, { path, text });
        entry[kind] = path;
      }
      if (entry.account || entry.character) out.sv[a] = entry;
    }
  }
  return out;
}

function askName(what: string, fallback: string): string | null {
  const v = prompt(what, fallback);
  if (v === null) return null;
  const s = slug(v);
  return s || null;
}

export function fixtureButtons(status: HTMLElement) {
  const addonOf = () => host.loadedAddons()[0] ?? 'Sandbox';
  const save = (what: { world?: boolean; sv?: boolean }, label: string) => async () => {
    const addon = prompt('Which addon\'s use cases is this fixture for?', addonOf());
    if (!addon) return;
    const name = askName(`Fixture name (saved in profile/usecases/${addon}/fixtures/)`, 'my-setup');
    if (!name) return;
    try {
      const r = await saveFixtures(addon.trim(), name, what);
      const files = [what.world ? r.world : null, ...Object.values(r.sv).flatMap((e) => [e.account, e.character])].filter(Boolean);
      status.textContent = `${label}: ${files.join(', ') || 'nothing to save'}`;
    } catch (e) { status.textContent = `Could not save: ${(e as Error).message}`; }
  };
  return h('div', { class: 'row wrap' },
    h('button', { onclick: save({ world: true }, 'World saved') }, 'Save world as fixture'),
    h('button', { onclick: save({ sv: true }, 'SavedVariables saved') }, 'Save SavedVariables as fixture'));
}

async function startRecording() {
  if (player) { host.systemLine('Exit the use case first; recording starts from your own session.', true); return; }
  const sb = host.sandbox();
  if (!sb) return;
  const addon = prompt('Record a use case for which addon?', host.loadedAddons()[0] ?? '');
  if (!addon) return;
  const name = askName('Name for the use case (file name)', 'my-use-case');
  if (!name) return;
  try {
    const fixtures = await saveFixtures(addon.trim(), name);
    recorder = new Recorder(addon.trim(), name, fixtures);
    recorder.hook(sb);
    host.systemLine(`Recording ${addon}/${name}: the world and SavedVariables were saved as its fixtures. Click Stop and save when done.`);
    host.selectTab('usecases');
    renderTab();
  } catch (e) { host.systemLine(`Could not start recording: ${(e as Error).message}`, true); }
}

async function stopRecording(save: boolean) {
  const r = recorder;
  if (!r) return;
  recorder = null;
  r.unhook();
  if (save) {
    const uc = r.build();
    try {
      await host.api.post(`/api/usecase/${encodeURIComponent(r.addon)}/${encodeURIComponent(r.name)}`, { useCase: uc });
      host.systemLine(`Saved profile/usecases/${r.addon}/${r.name}.usecase.json (${uc.steps.length} steps). Ask an LLM to add captions and checks.`);
    } catch (e) { host.systemLine(`Could not save the recording: ${(e as Error).message}`, true); }
  }
  await refreshList();
}

// ---------------------------------------------------------------------------
// Tab UI
// ---------------------------------------------------------------------------
function section(title: string, ...children: (Node | null | false | undefined)[]) {
  return h('section', { class: 'card' }, h('h3', {}, title), ...children);
}
function btn(label: string, onclick: () => void, cls = '', title = '') {
  return h('button', { class: cls, onclick, title: title || undefined }, label);
}

function videoCell(u: Summary) {
  const p = videos.get(u.id);
  if (p && p.phase !== 'done' && p.phase !== 'error') {
    const pct = p.total ? Math.round(((p.frame ?? 0) / p.total) * 100) : 0;
    const eta = p.eta !== undefined ? ` · ${Math.ceil(p.eta)} s left` : '';
    const label = p.phase === 'recording' ? `Recording ${p.frame ?? 0}/${p.total ?? '?'} frames (${pct}%)${eta}`
      : p.phase === 'dry-run' ? 'Timing the use case…' : p.phase === 'encoding' ? 'Writing the .mp4…' : 'Starting Chrome…';
    return h('div', { class: 'uc-progress' }, h('div', { class: 'uc-bar' }, h('i', { style: `width:${pct}%` })), h('span', { class: 'muted small' }, label));
  }
  if (p?.phase === 'error') return h('div', { class: 'small uc-bad' }, `Export failed: ${p.error}`);
  return null;
}

let tabRendering = false;
export function renderTab() {
  if (!host || tabRendering) return;
  tabRendering = true;
  try {
    const body = $('tab-usecases');
    const scroll = body.scrollTop;
    body.replaceChildren();
    if (player) body.append(playerCard());
    if (recorder) body.append(recorderCard());

    const groups = new Map<string, Summary[]>();
    for (const u of list) groups.set(u.addon, [...(groups.get(u.addon) ?? []), u]);
    const listBody = h('div', { class: 'uc-list' });
    if (listError) listBody.append(h('div', { class: 'small uc-bad' }, listError));
    if (!list.length && !listError) {
      listBody.append(h('div', { class: 'muted small' },
        'No use cases yet. Record one below, or ask an LLM to write profile/usecases/<Addon>/<name>.usecase.json (guide: docs/USECASES.md).'));
    }
    for (const [addon, items] of groups) {
      listBody.append(h('div', { class: 'label' }, addon));
      for (const u of items) {
        const c = checks.get(u.id);
        const status = c === 'running' ? h('span', { class: 'muted small' }, 'checking…')
          : c ? h('span', { class: `small ${c.ok ? 'uc-ok' : 'uc-bad'}`, title: c.report }, c.ok ? `✓ ${c.message}` : `✗ ${c.message}`)
          : u.errors.length ? h('span', { class: 'small uc-bad', title: u.errors.join('\n') }, `✗ ${u.errors.length} problem${u.errors.length === 1 ? '' : 's'} in the file`) : null;
        const p = videos.get(u.id);
        const busy = !!p && p.phase !== 'done' && p.phase !== 'error';
        listBody.append(h('div', { class: `uc-item${player?.resolved.id === u.id ? ' active' : ''}` },
          h('div', { class: 'row' },
            h('div', { class: 'grow' }, h('div', { class: 'uc-title' }, u.title), h('div', { class: 'muted small' }, `${u.name} · ${u.steps} steps`)),
            btn('▶', () => play(u.id), 'primary small', 'Play in the sandbox'),
            btn('Check', () => check(u.id), 'small', 'Run headless in the page: pass or fail per step'),
            btn(busy ? '…' : 'Export', () => { if (!busy) exportVideo(u.id); }, 'small', 'Export as .mp4 (1080p, 30 fps)')),
          u.summary ? h('div', { class: 'small muted' }, u.summary) : null,
          status ? h('div', {}, status, c && c !== 'running' && !c.ok
            ? btn('Copy failure report', () => navigator.clipboard.writeText(c.report).then(() => host.systemLine('Failure report copied.')), 'small') : null) : null,
          videoCell(u),
          u.video ? h('div', { class: 'small' }, h('a', { href: `/api/video/file/${u.id}?v=${Math.round(u.video.modified)}`, target: '_blank' },
            `Open video (${(u.video.size / 1048576).toFixed(1)} MB)`)) : null));
      }
    }
    body.append(section('Use cases', listBody, h('div', { class: 'row' }, btn('Refresh', () => refreshList(), 'small'),
      h('span', { class: 'muted small' }, 'profile/usecases/<Addon>/*.usecase.json'))));
    if (!recorder) {
      body.append(section('Record',
        h('div', { class: 'muted small' }, 'Turns what you do in the game view into a draft use case: clicks, drags, the mouse wheel, typing, slash commands and World tab actions. Your current world and SavedVariables become its fixtures.'),
        h('div', { class: 'row' }, btn('● Record a new use case', () => startRecording(), player ? '' : 'primary'))));
    }
    body.scrollTop = scroll;
  } finally { tabRendering = false; }
}

function renderPlayer() {
  const card = document.getElementById('uc-player');
  if (!card || !player) { renderTab(); return; }
  card.replaceWith(playerCard());
}

function playerCard() {
  const p = player!;
  const r = p.runner;
  const uc = p.resolved.useCase;
  const playing = p.state === 'playing' || p.state === 'stepping';
  const speed = h('select', { class: 'small', onchange: (e: Event) => p.setSpeed(Number((e.target as HTMLSelectElement).value)) }) as HTMLSelectElement;
  for (const s of [0.5, 1, 1.5, 2, 4]) speed.append(h('option', { value: s, selected: s === p.speed }, `${s}x`));
  const controls = h('div', { class: 'row wrap uc-controls' },
    btn('⏮', () => p.restart(), 'small', 'Restart from the beginning'),
    btn('◀', () => p.back(), 'small', 'Back one step'),
    playing ? btn('⏸ Pause', () => p.pause(), 'small primary') : btn('▶ Play', () => p.play(), 'small primary'),
    btn('Next ▶|', () => p.next(), 'small', 'Run the next step, then pause'),
    speed,
    h('span', { class: 'spacer' }),
    btn('✕ Exit', () => exitPlayer(), 'small', 'Back to your own session'));
  const steps = h('ol', { class: 'uc-steps' });
  uc.steps.forEach((s, i) => {
    const res = r?.results[i];
    const st = res?.status ?? 'pending';
    const current = r && (i === r.stepIndex && st === 'running' || (p.state === 'paused' && i === p.position()));
    const icon = st === 'passed' ? '✓' : st === 'failed' ? '✗' : st === 'running' ? '●' : '○';
    steps.append(h('li', { class: `uc-step ${st}${current ? ' current' : ''}`, title: 'Rewind to this step', onclick: () => p.seek(i) },
      h('span', { class: 'uc-icon' }, icon),
      h('span', { class: 'grow' }, h('span', {}, describeStep(s)), s.say ? h('span', { class: 'muted small uc-say' }, s.say) : null,
        st === 'failed' && r?.failure ? h('span', { class: 'small uc-bad' }, r.failure.message) : null)));
  });
  const failure = r?.failure ? h('div', { class: 'uc-failure' },
    h('div', { class: 'small uc-bad' }, `${r.failure.step < 0 ? 'Setup' : `Step ${r.failure.step + 1}`}: ${r.failure.message}`),
    r.failure.candidates?.length ? h('div', { class: 'small muted' }, `Closest: ${r.failure.candidates.slice(0, 5).join(' · ')}`) : null,
    btn('Copy failure report', () => navigator.clipboard.writeText(failureReport(r)).then(() => host.systemLine('Failure report copied: paste it to the LLM.')), 'small'))
    : null;
  const where = p.where();
  return h('section', { class: 'card uc-player', id: 'uc-player' },
    h('h3', {}, 'Now playing'),
    h('div', { class: 'uc-title' }, uc.title),
    h('div', { class: 'muted small' }, `${p.resolved.id} · ${where}`),
    controls, failure, steps);
}

function recorderCard() {
  const r = recorder!;
  const steps = h('ol', { class: 'uc-steps' });
  for (const s of r.steps.slice(-40)) steps.append(h('li', { class: 'uc-step passed' }, h('span', { class: 'uc-icon' }, '•'), h('span', { class: 'grow' }, describeStep(s.step))));
  return h('section', { class: 'card uc-recording' },
    h('h3', {}, '● Recording'),
    h('div', { class: 'uc-title' }, `${r.addon}/${r.name}`),
    h('div', { class: 'muted small' }, `${r.steps.length} steps so far. Use the game view, the chat box and the World tab as usual.`),
    h('div', { class: 'row' }, btn('■ Stop and save', () => stopRecording(true), 'primary small'), btn('Discard', () => stopRecording(false), 'small danger')),
    steps);
}

// ---------------------------------------------------------------------------
// Video recorder API (the page opened with ?record=<Addon>/<name> by scripts/video.ts)
// ---------------------------------------------------------------------------
export function recorderApi(id: string) {
  let runner: Runner | null = null;
  let resolved: ResolvedUseCase | null = null;
  view.showChecks = false;
  async function session(): Promise<Runner> {
    let r: Runner | null = null;
    await host.startUseCase(resolved!, (sb) => {
      r = new Runner({ id, useCase: resolved!.useCase, sandbox: sb, screen: host.screen() });
      return { chat: (t) => r!.onChat(t), error: (m, s) => r!.onError(m, s) };
    });
    return r as unknown as Runner;
  }
  return {
    async prepare() {
      resolved = await host.api.get<ResolvedUseCase>(`/api/usecase/${id}`);
      if (resolved.errors.length) return { ok: false, error: resolved.errors.join('\n') };
      await document.fonts.ready;
      // Dry run: the same pacing without drawing, for the frame count and chapters.
      const dry = await session();
      dry.fastForward();
      if (dry.failure) return { ok: false, error: `Step ${dry.failure.step + 1}: ${dry.failure.message}`, report: failureReport(dry) };
      const frames = Math.round(dry.displayTime / FRAME);
      const chapters = dry.chapters;
      runner = await session();
      host.forceRender();
      view.clear();
      return { ok: true, frames, chapters, title: resolved.useCase.title, seconds: dry.displayTime };
    },
    frame() {
      const r = runner!;
      const json = r.tick(FRAME, true);
      if (json) host.applyRender(json);
      view.render(r.view, r.displayTime, host.screen(), r.chatLines);
      return { done: r.done, failed: r.failure ? `Step ${r.failure.step + 1}: ${r.failure.message}` : null, t: r.displayTime };
    },
    // After the last step: keep the picture moving (timers, fades) without new actions.
    hold() {
      const r = runner!;
      const json = r.sandbox.frame(FRAME);
      if (json) host.applyRender(json);
      r.displayTime += FRAME;
      view.render(r.view, r.displayTime, host.screen(), r.chatLines);
    },
  };
}
