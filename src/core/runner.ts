// Use case runner: plays a use case against a Sandbox, one step at a time, on a fixed 30 fps clock.
// The same pacing runs everywhere (headless check, page player, video), so the sandbox sees the same time and the
// same input in all three; only rendering differs. Steps are generators that yield seconds to wait (0 = next frame).
import type { Sandbox, TargetMatch, AddonBundle, InstalledAddon } from './sandbox.ts';
import { toLua } from './lua.ts';
import {
  actionOf, describeAssertion, describeStep, describeTarget,
  type Assertion, type ResolvedUseCase, type Step, type Target, type UseCase, type WorldAction,
} from './usecase.ts';

export const FPS = 30;
export const FRAME = 1 / FPS;
export const SCREEN = { w: 1365, h: 768 };

type Rect = [number, number, number, number];

export interface ViewState {
  cursor: { x: number; y: number } | null;
  pressed: boolean;
  ripple: { x: number; y: number; t: number } | null;   // t = display time of the click
  caption: { text: string; rect: Rect | null } | null;
  spotlight: Rect | null;
  chat: string | null;                                    // the chat box while a slash command is typed
  badge: string | null;                                   // "45 s later"
  title: { title: string; summary?: string; addons: string[] } | null;
  check: { ok: boolean; text: string; t: number } | null;  // last expect result (the player shows it briefly)
}

export type StepStatus = 'pending' | 'running' | 'passed' | 'failed';
export interface StepResult { status: StepStatus; info?: string; start?: number; end?: number }
export interface Failure { step: number; message: string; candidates?: string[] }

export class StepError extends Error {
  candidates?: string[];
  constructor(message: string, candidates?: string[]) { super(message); this.candidates = candidates; }
}

export interface RunnerOptions {
  id: string;
  useCase: UseCase;
  sandbox: Sandbox;
  screen?: { w: number; h: number };
  log?: (line: string) => void;
}

type Gen = Generator<number, void, number>;

const plain = (s: string) => s.replace(/\|c[0-9a-fA-F]{8}|\|r|\|T[^|]*\|t|\|H.-\|h|\|h/g, '').replace(/\s+/g, ' ').trim();
const clamp = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), hi);
const ease = (k: number) => (k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2);

// Seconds to read a caption comfortably (about 190 words a minute, at least 2 s).
export function readTime(text: string | undefined): number {
  if (!text) return 0;
  const words = text.trim().split(/\s+/).length;
  return clamp(1.4 + words * 0.3, 2, 10);
}

function fmtSeconds(s: number) {
  if (s < 90) return `${Math.round(s)} s`;
  if (s < 5400) return `${Math.round(s / 60)} min`;
  return `${(s / 3600).toFixed(1)} h`;
}

// Edit distance on short strings, for "did you mean" suggestions.
function distance(a: string, b: string) {
  if (a === b) return 0;
  const m = a.length, n = b.length;
  if (!m || !n) return Math.max(m, n);
  let prev = Array.from({ length: n + 1 }, (_, j) => j);
  for (let i = 1; i <= m; i++) {
    const cur = [i];
    for (let j = 1; j <= n; j++) cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    prev = cur;
  }
  return prev[n];
}

export function closest(want: string, options: string[], max = 6): string[] {
  const w = want.toLowerCase();
  const words = w.split(/\W+/).filter(Boolean);
  const scored = [...new Set(options)].map((o) => {
    const l = o.toLowerCase();
    const overlap = words.filter((x) => l.includes(x)).length / Math.max(words.length, 1);
    const d = distance(w, l.slice(0, Math.max(w.length + 8, 12))) / Math.max(w.length, 1);
    return { o, score: overlap * 2 - d };
  });
  return scored.sort((a, b) => b.score - a.score).slice(0, max).filter((s) => s.score > -0.8).map((s) => s.o);
}

function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== typeof b || a === null || b === null || typeof a !== 'object') return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const ka = Object.keys(a as object), kb = Object.keys(b as object);
  if (ka.length !== kb.length) return false;
  return ka.every((k) => deepEqual((a as any)[k], (b as any)[k]));
}

export class Runner {
  readonly id: string;
  readonly useCase: UseCase;
  readonly sandbox: Sandbox;
  readonly screen: { w: number; h: number };
  view: ViewState = { cursor: null, pressed: false, ripple: null, caption: null, spotlight: null, chat: null, badge: null, title: null, check: null };
  displayTime = 0;
  sandboxTime = 0;
  stepIndex = -1;                 // -1 = intro (login settle and title card)
  results: StepResult[];
  done = false;
  failure: Failure | null = null;
  chapters: { t: number; title: string }[] = [];
  chat: string[] = [];
  chatLines: { text: string; t: number }[] = [];   // raw lines with colour codes, for the in-game chat frame
  errors: { message: string; stack: string }[] = [];
  warnings: string[] = [];
  lines: string[] = [];           // per-step log
  pauseAfterStep = false;
  paused = false;
  stopAt = Infinity;              // fast-forward: pause before this step index
  private gen: Gen | null = null;
  private introStarted = false;
  private pending = 0;
  private timeScale = 1;
  private errorsSeen = 0;
  private log?: (line: string) => void;

  constructor(opts: RunnerOptions) {
    this.id = opts.id;
    this.useCase = opts.useCase;
    this.sandbox = opts.sandbox;
    this.screen = opts.screen ?? SCREEN;
    this.log = opts.log;
    this.results = opts.useCase.steps.map(() => ({ status: 'pending' as StepStatus }));
  }

  // Driver callbacks (forward the sandbox's chat and error output here).
  onChat(text: string) {
    this.chat.push(plain(text));
    this.chatLines.push({ text, t: this.displayTime });
    if (this.chat.length > 2000) this.chat.splice(0, 500);
    if (this.chatLines.length > 200) this.chatLines.splice(0, 100);
  }
  onError(message: string, stack: string) { this.errors.push({ message, stack }); }

  get finished() { return this.done || this.failure !== null; }

  // Advance by one frame of display time. With render, returns the render JSON when something changed.
  tick(dt = FRAME, render = false): string {
    if (this.finished || this.paused) return '';
    this.pump(dt);
    const sdt = dt * this.timeScale;
    let rest = sdt;
    while (rest > 0.25 + 1e-9) { this.sandbox.advance(0.25, 0.25); rest -= 0.25; }
    let json = '';
    if (render) json = this.sandbox.frame(rest);
    else if (rest > 0) this.sandbox.advance(rest, rest);
    this.displayTime += dt;
    this.sandboxTime += sdt;
    this.checkErrors();
    return json;
  }

  // Run without rendering until the use case ends, fails, or reaches `stopAt` (used by Back and the dry run).
  fastForward(stopAt = Infinity, maxSeconds = 3600): void {
    this.stopAt = stopAt;
    this.paused = false;
    const limit = this.displayTime + maxSeconds;
    while (!this.finished && !this.paused && this.displayTime < limit) this.tick(FRAME, false);
    this.stopAt = Infinity;
  }

  private checkErrors() {
    if (this.errors.length > this.errorsSeen) {
      const fresh = this.errors.slice(this.errorsSeen);
      this.errorsSeen = this.errors.length;
      for (const e of fresh) this.note(`Lua error: ${e.message}`);
      if (!this.useCase.allowErrors && !this.failure) {
        this.fail(new StepError(`Lua error${this.stepIndex < 0 ? ' while loading' : ''}: ${fresh[0].message}`));
      }
    }
  }

  private note(line: string) {
    const prefix = this.stepIndex < 0 ? 'setup' : `step ${this.stepIndex + 1}`;
    const l = `[${this.displayTime.toFixed(2)}s] ${prefix}: ${line}`;
    this.lines.push(l);
    this.log?.(l);
  }

  private fail(e: unknown) {
    const err = e instanceof StepError ? e : new StepError(String((e as Error)?.message ?? e));
    if (!(e instanceof StepError)) this.note(`internal error: ${(e as Error)?.stack ?? e}`);
    this.failure = { step: this.stepIndex, message: err.message, candidates: err.candidates };
    if (this.stepIndex >= 0) {
      const r = this.results[this.stepIndex];
      r.status = 'failed';
      r.end = this.displayTime;
    }
    this.gen = null;
    this.view.caption = null;
    this.view.spotlight = null;
    this.view.chat = null;
    this.view.badge = null;
    this.timeScale = 1;
    this.note(`FAILED: ${err.message}`);
  }

  private pump(dt: number) {
    this.pending -= dt;
    for (let guard = 0; guard < 1000; guard++) {
      if (!this.gen) {
        if (!this.startNext()) return;
      }
      if (this.pending > 0) return;
      let r: IteratorResult<number, void>;
      try { r = this.gen!.next(dt); }
      catch (e) { this.fail(e); return; }
      if (r.done) {
        this.finishStep();
        if (this.paused || this.finished) return;
        continue;
      }
      const v = r.value;
      if (v <= 0) { this.pending = 1e-9; return; }
      this.pending += v;
    }
  }

  private startNext(): boolean {
    if (!this.introStarted) {
      this.introStarted = true;
      this.chapters.push({ t: 0, title: this.useCase.title });
      this.gen = this.intro();
      return true;
    }
    const next = this.stepIndex + 1;
    if (next >= this.useCase.steps.length) {
      this.done = true;
      this.view.caption = null;
      this.view.spotlight = null;
      this.note('done');
      return false;
    }
    if (next >= this.stopAt) { this.paused = true; return false; }
    this.stepIndex = next;
    const step = this.useCase.steps[next];
    this.results[next] = { status: 'running', start: this.displayTime };
    if (step.say) this.chapters.push({ t: this.displayTime, title: step.say });
    this.note(describeStep(step));
    this.gen = this.runStep(step);
    this.pending = 0;
    return true;
  }

  private finishStep() {
    this.gen = null;
    this.timeScale = 1;
    if (this.stepIndex >= 0) {
      const r = this.results[this.stepIndex];
      if (r.status === 'running') r.status = 'passed';
      r.end = this.displayTime;
      this.view.caption = null;
      this.view.spotlight = null;
      this.view.badge = null;
      if (this.pauseAfterStep) this.paused = true;
      if (this.stepIndex + 1 >= this.stopAt) this.paused = true;
    }
  }

  // ---------------------------------------------------------------------------
  // Steps
  // ---------------------------------------------------------------------------
  private *intro(): Gen {
    const wait = this.useCase.setup?.wait ?? 3;
    this.view.title = { title: this.useCase.title, summary: this.useCase.summary, addons: this.useCase.addons };
    if (wait > 0) yield wait;
    this.view.title = null;
    this.view.cursor = { x: Math.round(this.screen.w / 2), y: Math.round(this.screen.h * 0.62) };
  }

  private *runStep(step: Step): Gen {
    const start = this.displayTime;
    const read = step.say ? (step.hold ?? readTime(step.say)) : 0;
    const a = actionOf(step);
    switch (a) {
      case 'say': yield* this.sayStep(step, read); return;
      case 'click': yield* this.clickStep(step, read); break;
      case 'hover': yield* this.hoverStep(step, read); return;
      case 'drag': yield* this.dragStep(step); break;
      case 'scroll': yield* this.scrollStep(step); break;
      case 'slash': yield* this.slashStep(step); break;
      case 'type': yield* this.typeStep(step); break;
      case 'key': yield* this.keyStep(step); break;
      case 'world': this.caption(step.say, null); this.world(step.world!); yield 0.5; break;
      case 'event': this.caption(step.say, null); this.sandbox.fireEvent(step.event!, step.args ?? ''); yield 0.3; break;
      case 'run': this.caption(step.say, null); this.sandbox.run(step.run!); yield 0.3; break;
      case 'wait': yield* this.waitStep(step); break;
      case 'expect': this.caption(step.say, null); this.expect(step.expect!); break;
    }
    const rest = read - (this.displayTime - start);
    if (rest > 0.05) yield rest;
  }

  // What a caption points at: the whole button when the text sits in a control, else the text itself.
  private focusRect(m: TargetMatch): Rect {
    const c = m.clickRect;
    if (c && m.kind !== 'point' && c[2] * c[3] <= 60000 && c[2] * c[3] >= m.rect[2] * m.rect[3]) return c;
    return m.rect;
  }

  private caption(text: string | undefined, rect: Rect | null) {
    if (!text) return;
    this.view.caption = { text, rect };
    this.view.spotlight = rect;
  }

  private *sayStep(step: Step, read: number): Gen {
    let rect: Rect | null = null;
    if (step.at) {
      const m = this.resolve(step.at, false);
      rect = this.focusRect(m);
      this.result(`points at ${m.name ?? describeTarget(step.at)}`);
    }
    this.caption(step.say, rect);
    yield Math.max(read, 0.5);
  }

  private *clickStep(step: Step, read: number): Gen {
    const m = this.resolve(step.click!);
    if (m.kind !== 'point' && !m.clickName) {
      throw new StepError(`${describeTarget(step.click)} is shown, but nothing clickable is under it (no mouse-enabled frame)`);
    }
    if (m.covered) this.warn(`${describeTarget(step.click)} is covered by ${m.covered}; the click lands there`);
    this.result(`-> ${m.clickName ?? m.name ?? 'nothing'} at ${Math.round(m.point[0])},${Math.round(m.point[1])}`);
    this.caption(step.say, this.focusRect(m));
    const moved = yield* this.moveTo(m.point[0], m.point[1]);
    const before = step.say ? clamp(read * 0.4 - moved, 0.15, 3) : 0.15;
    yield before;
    const button = step.button ?? 'LeftButton';
    const clicks = step.double ? 2 : 1;
    for (let i = 0; i < clicks; i++) {
      this.sandbox.mouseDown(button, !!step.shift, !!step.ctrl, !!step.alt);
      this.view.pressed = true;
      this.view.ripple = { x: m.point[0], y: m.point[1], t: this.displayTime };
      yield 0.09;
      this.sandbox.mouseUp(button, !!step.shift, !!step.ctrl, !!step.alt);
      this.view.pressed = false;
      if (i + 1 < clicks) yield 0.1;
    }
    yield 0.35;
  }

  private *hoverStep(step: Step, read: number): Gen {
    const start = this.displayTime;
    const m = this.resolve(step.hover!);
    this.result(`over ${m.clickName ?? m.name ?? '?'}`);
    this.caption(step.say, this.focusRect(m));
    yield* this.moveTo(m.point[0], m.point[1]);
    const hold = step.hold ?? Math.max(1.5, read - (this.displayTime - start));
    yield hold;
  }

  private *dragStep(step: Step): Gen {
    const m = this.resolve(step.drag!);
    let dest: [number, number];
    const to = step.to!;
    if ('dx' in to || 'dy' in to) {
      const d = to as { dx?: number; dy?: number };
      dest = [m.point[0] + (d.dx ?? 0), m.point[1] + (d.dy ?? 0)];
    } else dest = this.resolve(to as Target).point;
    this.result(`${m.name ?? '?'} from ${m.point.map(Math.round).join(',')} to ${dest.map(Math.round).join(',')}`);
    this.caption(step.say, this.focusRect(m));
    yield* this.moveTo(m.point[0], m.point[1]);
    yield 0.15;
    this.sandbox.mouseDown('LeftButton', !!step.shift, !!step.ctrl, !!step.alt);
    this.view.pressed = true;
    yield 0.12;
    yield* this.moveTo(dest[0], dest[1], 0.9);
    yield 0.1;
    this.sandbox.mouseUp('LeftButton', !!step.shift, !!step.ctrl, !!step.alt);
    this.view.pressed = false;
    yield 0.4;
  }

  private *scrollStep(step: Step): Gen {
    const m = this.resolve(step.scroll!);
    this.caption(step.say, this.focusRect(m));
    yield* this.moveTo(m.point[0], m.point[1]);
    const delta = step.delta ?? -1;
    let handled = false;
    for (let i = 0; i < Math.abs(delta); i++) {
      handled = this.sandbox.mouseWheel(Math.sign(delta)) || handled;
      yield 0.15;
    }
    if (!handled) this.warn(`nothing under ${describeTarget(step.scroll)} takes the mouse wheel`);
    yield 0.3;
  }

  private *slashStep(step: Step): Gen {
    this.caption(step.say, null);
    const text = step.slash!;
    this.view.chat = '';
    for (const ch of text) { this.view.chat += ch; yield 0.045; }
    yield 0.25;
    this.view.chat = null;
    const cmd = text.split(/\s+/)[0].toLowerCase();
    if (!/^\/(run|script|dump|reload|reloadui|fstack|etrace|eventtrace|help)$/.test(cmd)
      && !this.sandbox.slashCommands().some((c) => c.aliases.some((a) => a.toLowerCase() === cmd))) {
      throw new StepError(`${cmd} is not a slash command any loaded addon registered`,
        this.sandbox.slashCommands().flatMap((c) => c.aliases).slice(0, 12));
    }
    const before = this.chat.length;
    this.sandbox.chat(text);
    yield 0.6;
    const said = this.chat.slice(before);
    if (said.length) this.result(`chat: ${said.slice(0, 2).join(' | ').slice(0, 120)}`);
  }

  private *typeStep(step: Step): Gen {
    let first = true;
    for (const ch of step.type!) {
      const ok = this.sandbox.char(ch);
      if (first && !ok) throw new StepError('Nothing has keyboard focus to type into; click the edit box first');
      first = false;
      yield 0.06;
    }
    yield 0.3;
  }

  private *keyStep(step: Step): Gen {
    this.sandbox.keyDown(step.key!, !!step.shift, !!step.ctrl, !!step.alt);
    yield 0.06;
    this.sandbox.keyUp(step.key!, !!step.shift, !!step.ctrl, !!step.alt);
    yield 0.35;
  }

  private *waitStep(step: Step): Gen {
    this.caption(step.say, null);
    if (typeof step.wait === 'number') {
      const n = step.wait;
      if (n <= 3) { yield n; return; }
      const show = 2;
      this.timeScale = n / show;
      this.view.badge = `${fmtSeconds(n)} later`;
      yield show;
      this.timeScale = 1;
      this.view.badge = null;
      return;
    }
    const { for: check, timeout = 30 } = step.wait!;
    const startSandbox = this.sandboxTime;
    const startDisplay = this.displayTime;
    let last = '';
    for (;;) {
      const err = this.tryAssert(check);
      if (!err) break;
      last = err.message;
      if (this.sandboxTime - startSandbox > timeout) {
        this.timeScale = 1;
        this.view.badge = null;
        throw new StepError(`Waited ${timeout} s and still: ${last}`, err.candidates);
      }
      if (this.displayTime - startDisplay > 1 && this.timeScale === 1) {
        this.timeScale = 6;
        this.view.badge = 'Fast-forwarding…';
      }
      yield 0;
    }
    if (this.timeScale !== 1) this.view.badge = `${fmtSeconds(this.sandboxTime - startSandbox)} later`;
    this.timeScale = 1;
    this.result(`after ${(this.sandboxTime - startSandbox).toFixed(1)} s`);
    yield 0.4;
  }

  // Cursor glide with easing; mouseMove every frame so OnEnter/OnLeave fire along the way. Returns seconds taken.
  private *moveTo(x: number, y: number, minDur = 0): Generator<number, number, number> {
    const from = this.view.cursor ?? { x: this.screen.w / 2, y: this.screen.h * 0.62 };
    const dist = Math.hypot(x - from.x, y - from.y);
    if (dist < 1) { this.view.cursor = { x, y }; this.sandbox.mouseMove(x, y); return 0; }
    const dur = Math.max(clamp(0.3 + dist / 1500, 0.35, 0.9), minDur);
    const start = this.displayTime;
    for (;;) {
      const k = clamp((this.displayTime - start) / dur, 0, 1);
      const e = ease(k);
      const px = from.x + (x - from.x) * e, py = from.y + (y - from.y) * e;
      this.view.cursor = { x: px, y: py };
      this.sandbox.mouseMove(px, py);
      if (k >= 1) break;
      yield 0;
    }
    return this.displayTime - start;
  }

  private warn(text: string) { this.warnings.push(`step ${this.stepIndex + 1}: ${text}`); this.note(`warning: ${text}`); }
  private result(info: string) {
    if (this.stepIndex >= 0) this.results[this.stepIndex].info = info;
    this.note(info);
  }

  // ---------------------------------------------------------------------------
  // Targets and checks
  // ---------------------------------------------------------------------------
  // forAction: the target will be clicked or hovered, so text with nothing clickable under it (a tooltip line)
  // loses to text that is in a control.
  resolve(t: Target, forAction = true): TargetMatch {
    const r = this.sandbox.find(t as Record<string, unknown>);
    if (r.error) throw new StepError(r.error, this.suggestFrames(t));
    let ms = r.matches;
    if (forAction && 'text' in t) {
      const live = ms.filter((m) => m.clickName && !m.covered);
      if (live.length) ms = live;
    }
    if (!ms.length) {
      if ('text' in t) {
        throw new StepError(`No visible text matches "${t.text}"${t.within ? ` inside ${t.within}` : ''}`,
          closest(t.text, this.sandbox.texts().map((x) => x.text)));
      }
      throw new StepError(`${describeTarget(t)} is not visible`);
    }
    if ('text' in t) {
      const exact = ms.filter((m) => m.exact);
      if (exact.length) ms = exact;
      if (t.nth) {
        if (t.nth > ms.length) throw new StepError(`Only ${ms.length} visible match${ms.length === 1 ? '' : 'es'} for "${t.text}", nth is ${t.nth}`, ms.map((m) => m.text ?? ''));
        return ms[t.nth - 1];
      }
      if (ms.length > 1) {
        const ids = new Set(ms.map((m) => m.clickId ?? -(m.ownerId ?? 0)));
        if (ids.size > 1) {
          throw new StepError(`"${t.text}" matches ${ms.length} things on screen; add "nth" (1 = topmost) or "within"`,
            ms.slice(0, 8).map((m, i) => `nth ${i + 1}: "${m.text}" at ${Math.round(m.point[0])},${Math.round(m.point[1])} in ${m.clickName ?? m.name}`));
        }
      }
    }
    return ms[0];
  }

  private suggestFrames(t: Target): string[] | undefined {
    if (!('frame' in t) && !('path' in t) && !('within' in t)) return undefined;
    const want = 'frame' in t ? t.frame : 'path' in t ? t.path : (t as any).within;
    return closest(String(want), this.sandbox.namedFrames().map((f) => f.name));
  }

  private tryAssert(a: Assertion): StepError | null {
    try { this.assert(a); return null; } catch (e) { return e instanceof StepError ? e : new StepError(String(e)); }
  }

  private assert(a: Assertion) {
    if (a.shown) this.resolveAny(a.shown);
    if (a.hidden) {
      const r = this.sandbox.find(a.hidden as Record<string, unknown>);
      const ms = 'text' in a.hidden && r.matches.some((m) => m.exact) ? r.matches.filter((m) => m.exact) : r.matches;
      const nth = 'text' in a.hidden && a.hidden.nth ? a.hidden.nth : 1;
      if (ms.length >= nth) throw new StepError(`${describeTarget(a.hidden)} is still shown (${ms[nth - 1].text ?? ms[nth - 1].name})`);
    }
    if (a.tooltip || a.noTooltip) {
      const tips = this.sandbox.tooltips();
      const lines = tips.flatMap((t) => t.lines);
      if (a.noTooltip && tips.length) throw new StepError(`A tooltip is showing: ${lines.slice(0, 3).join(' / ')}`);
      if (a.tooltip) {
        if (!tips.length) throw new StepError('No tooltip is showing');
        const all = lines.join('\n').toLowerCase();
        for (const want of [a.tooltip].flat()) {
          if (!all.includes(plain(want).toLowerCase())) throw new StepError(`The tooltip has no "${want}"`, lines.slice(0, 12));
        }
      }
    }
    if (a.chat) {
      const want = plain(a.chat).toLowerCase();
      if (!this.chat.some((l) => l.toLowerCase().includes(want))) throw new StepError(`No chat line contains "${a.chat}"`, this.chat.slice(-8));
    }
    if (a.lua) {
      const r = this.sandbox.eval(a.lua);
      if (r.error) throw new StepError(`Lua check failed to run: ${r.error}`);
      if (a.equals !== undefined) {
        if (!deepEqual(r.value ?? null, a.equals)) throw new StepError(`${a.lua} is ${JSON.stringify(r.value ?? null)}, expected ${JSON.stringify(a.equals)}`);
      } else if (r.value === undefined || r.value === null || r.value === false) {
        throw new StepError(`${a.lua} is ${JSON.stringify(r.value ?? null)}, expected true`);
      }
    }
    if (a.noErrors && this.errors.length) throw new StepError(`${this.errors.length} Lua error(s): ${this.errors[0].message}`);
  }

  // Like resolve, but several matches are fine (it only has to be visible).
  private resolveAny(t: Target) {
    if ('text' in t && !t.nth) {
      const r = this.sandbox.find(t as Record<string, unknown>);
      if (r.error) throw new StepError(r.error);
      if (r.matches.length) return r.matches[0];
      throw new StepError(`No visible text matches "${t.text}"${t.within ? ` inside ${t.within}` : ''}`,
        closest(t.text, this.sandbox.texts().map((x) => x.text)));
    }
    return this.resolve(t);
  }

  private expect(a: Assertion) {
    const err = this.tryAssert(a);
    const text = describeAssertion(a);
    this.view.check = { ok: !err, text, t: this.displayTime };
    if (err) throw err;
    this.result(`ok: ${text}`);
  }

  // ---------------------------------------------------------------------------
  // World actions
  // ---------------------------------------------------------------------------
  private world(w: WorldAction) {
    const sb = this.sandbox;
    const lit = (v: unknown) => toLua(v);
    if ('open' in w) {
      const world = sb.worldJSON();
      const pick = (list: { name: string }[]) => {
        if (w.index) return w.index;
        if (!w.name) return 1;
        const i = list.findIndex((x) => x.name.toLowerCase().includes(w.name!.toLowerCase()));
        if (i < 0) throw new StepError(`No ${w.open} named "${w.name}" in the world`, list.map((x) => x.name));
        return i + 1;
      };
      switch (w.open) {
        case 'merchant': sb.openMerchant(pick(world.merchants ?? [])); break;
        case 'ah': sb.openAH(); break;
        case 'loot': sb.openLoot(pick(world.loot ?? [])); break;
        case 'profession': {
          const names = Object.keys(world.professions ?? {});
          const name = names.find((n) => n.toLowerCase() === (w.name ?? '').toLowerCase());
          if (!name) throw new StepError(`No profession "${w.name}" in the world`, names);
          sb.openProfession(name);
          break;
        }
        case 'mail': sb.openMail(); break;
        case 'bags': sb.run('if OpenAllBags then OpenAllBags() else ToggleAllBags() end'); break;
      }
    } else if ('close' in w) {
      switch (w.close) {
        case 'merchant': sb.closeMerchant(); break;
        case 'ah': sb.closeAH(); break;
        case 'loot': sb.closeLoot(); break;
        case 'profession': sb.closeProfession(); break;
        case 'mail': sb.closeMail(); break;
        case 'bags': sb.run('if CloseAllBags then CloseAllBags() end'); break;
      }
    } else if ('combat' in w) sb.setCombat(w.combat);
    else if ('money' in w) sb.setWorldValue('player.money', Math.round(w.money));
    else if ('give' in w) sb.run(`SANDBOX.AddItem(${Math.floor(w.give.item)}, ${Math.floor(w.give.count ?? 1)})`);
    else if ('take' in w) sb.run(`SANDBOX.RemoveItem(${Math.floor(w.take.item)}, ${Math.floor(w.take.count ?? 1)})`);
    else if ('buy' in w) sb.buyFromAH(w.buy.item, w.buy.count ?? 1);
    else if ('sell' in w) sb.sellOnAH(w.sell.item, w.sell.count ?? 1, w.sell.price);
    else if ('aura' in w) {
      if (w.aura.add !== undefined) sb.run(`SANDBOX.ApplyAura(${lit(w.aura.add)}, ${w.aura.remaining !== undefined ? Number(w.aura.remaining) : 'nil'})`);
      else sb.run(`SANDBOX.RemoveAura(${lit(w.aura.remove)})`);
    } else if ('cast' in w) sb.run(`SANDBOX.CastSpell(${lit(w.cast)})`);
    else if ('hit' in w) sb.run(`SANDBOX.Hit(${lit(w.hit.from)}, ${lit(w.hit.to)}, ${Number(w.hit.amount ?? 100)}${w.hit.spell ? `, ${lit(w.hit.spell)}` : ''})`);
    else if ('set' in w) for (const [path, value] of Object.entries(w.set)) sb.setWorldValue(path, value);
    this.result('ok');
  }
}

// ---------------------------------------------------------------------------
// Failure report: everything an LLM needs to fix the step, as plain text
// ---------------------------------------------------------------------------
export function failureReport(runner: Runner): string {
  const uc = runner.useCase;
  const f = runner.failure;
  const out: string[] = [];
  out.push(`Use case: ${runner.id} — "${uc.title}"`);
  if (!f) { out.push(runner.done ? 'Result: passed' : 'Result: not finished'); return out.join('\n'); }
  if (f.step < 0) out.push('Failed during setup (loading and login)');
  else {
    const step = uc.steps[f.step];
    out.push(`Failed at step ${f.step + 1} of ${uc.steps.length}: ${describeStep(step)}`);
    out.push(`Step JSON: ${JSON.stringify(step)}`);
  }
  out.push(`Error: ${f.message}`);
  if (f.candidates?.length) out.push('Closest matches:', ...f.candidates.map((c) => `  ${c}`));
  out.push('', `Steps passed: ${runner.results.filter((r) => r.status === 'passed').length}`);
  try {
    const texts = runner.sandbox.texts();
    out.push('', `Visible text on screen (${texts.length}; target with {"text": ...}):`);
    for (const t of texts.slice(0, 80)) {
      const where = `${Math.round(t.rect[0])},${Math.round(t.rect[1])}`;
      const click = t.clickName ? ` -> click hits ${t.clickName}` : '';
      out.push(`  "${t.text.slice(0, 70)}" at ${where} in ${t.owner}${click}${t.covered ? ` (covered by ${t.covered})` : ''}`);
    }
    if (texts.length > 80) out.push(`  ... ${texts.length - 80} more`);
    const tips = runner.sandbox.tooltips();
    for (const tt of tips) out.push('', `Tooltip ${tt.name}:`, ...tt.lines.map((l) => `  ${l}`));
  } catch (e) { out.push(`(could not read the screen: ${(e as Error).message})`); }
  if (runner.chat.length) out.push('', 'Chat (last 15):', ...runner.chat.slice(-15).map((l) => `  ${l}`));
  if (runner.errors.length) {
    out.push('', `Lua errors (${runner.errors.length}):`);
    for (const e of runner.errors.slice(0, 5)) out.push(`  ${e.message}`, ...e.stack.split('\n').slice(0, 5).map((l) => `      ${l.trim()}`));
  }
  if (runner.warnings.length) out.push('', 'Warnings:', ...runner.warnings.map((w) => `  ${w}`));
  out.push('', 'Log:', ...runner.lines.slice(-25).map((l) => `  ${l}`));
  return out.join('\n');
}

// ---------------------------------------------------------------------------
// Loading a use case session (browser and Node share this; they differ in how bundles are fetched)
// ---------------------------------------------------------------------------
// World, then the addons with the use case's SavedVariables (none for addons it doesn't list), then setup.run.
export function loadUseCase(sb: Sandbox, resolved: ResolvedUseCase, bundles: AddonBundle[], installed: InstalledAddon[]) {
  sb.setWorld(resolved.world);
  const sv: Record<string, { account: string | null; character: string | null }> = {};
  for (const b of bundles) sv[b.name] = resolved.savedVariables[b.name] ?? { account: null, character: null };
  sb.loadAddons(bundles, sv, installed, false);
  if (resolved.useCase.setup?.run) sb.run(resolved.useCase.setup.run);
}
