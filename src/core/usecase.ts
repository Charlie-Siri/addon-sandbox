// Use case format: types, validation (precise messages for an LLM to fix), the JSON Schema, and one-line step
// descriptions. Shared by the browser player, the headless checker and the video recorder.

export type Target =
  | { text: string; within?: string; nth?: number }
  | { frame: string }
  | { path: string }
  | { point: [number, number] };

export interface Assertion {
  shown?: Target;
  hidden?: Target;
  tooltip?: string | string[];
  noTooltip?: boolean;
  chat?: string;
  lua?: string;
  equals?: unknown;
  noErrors?: boolean;
}

export type WorldAction =
  | { open: 'merchant' | 'ah' | 'loot' | 'profession' | 'mail' | 'bags'; name?: string; index?: number }
  | { close: 'merchant' | 'ah' | 'loot' | 'profession' | 'mail' | 'bags' }
  | { combat: boolean }
  | { money: number }
  | { give: { item: number; count?: number } }
  | { take: { item: number; count?: number } }
  | { buy: { item: number; count?: number } }
  | { sell: { item: number; count?: number; price: number } }
  | { aura: { add?: number | string; remove?: number | string; remaining?: number } }
  | { cast: number | string }
  | { hit: { from: string; to: string; amount?: number; spell?: string } }
  | { set: Record<string, unknown> };

export interface Step {
  say?: string;
  at?: Target;          // what a standalone caption points at
  hold?: number;        // seconds a caption or hover stays (default: reading time)
  slash?: string;
  click?: Target;
  hover?: Target;
  drag?: Target;
  to?: Target | { dx: number; dy: number };
  type?: string;
  key?: string;
  scroll?: Target;
  delta?: number;
  world?: WorldAction;
  event?: string;
  args?: string;
  wait?: number | { for: Assertion; timeout?: number };
  run?: string;
  expect?: Assertion;
  button?: 'LeftButton' | 'RightButton' | 'MiddleButton';
  shift?: boolean;
  ctrl?: boolean;
  alt?: boolean;
  double?: boolean;
  note?: string;        // for authors; ignored
}

export interface Setup {
  world?: string | 'default' | { base?: string; set?: Record<string, unknown> } | Record<string, unknown>;
  savedVariables?: Record<string, { account?: string; character?: string }>;
  run?: string;
  wait?: number;
}

export interface UseCase {
  title: string;
  summary?: string;
  addons: string[];
  setup?: Setup;
  steps: Step[];
  allowErrors?: boolean;
}

// The one action key a step performs (a step with only `say` is a caption).
export const ACTIONS = ['slash', 'click', 'hover', 'drag', 'type', 'key', 'scroll', 'world', 'event', 'wait', 'run', 'expect'] as const;
export type ActionName = typeof ACTIONS[number] | 'say';

export function actionOf(step: Step): ActionName {
  for (const a of ACTIONS) if ((step as any)[a] !== undefined) return a;
  return 'say';
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------
const STEP_KEYS = new Set(['say', 'at', 'hold', ...ACTIONS, 'to', 'delta', 'args', 'button', 'shift', 'ctrl', 'alt', 'double', 'note']);
const ASSERT_KEYS = new Set(['shown', 'hidden', 'tooltip', 'noTooltip', 'chat', 'lua', 'equals', 'noErrors']);
const WORLD_OPEN = ['merchant', 'ah', 'loot', 'profession', 'mail', 'bags'];
const BUTTONS = ['LeftButton', 'RightButton', 'MiddleButton'];
const KEYS = /^(ESCAPE|ENTER|BACKSPACE|DELETE|LEFT|RIGHT|UP|DOWN|HOME|END|TAB|SPACE|PAGEUP|PAGEDOWN|F\d{1,2}|[A-Z0-9])$/;

const isObj = (v: unknown): v is Record<string, any> => typeof v === 'object' && v !== null && !Array.isArray(v);
const isNum = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);
const short = (v: unknown) => { const s = JSON.stringify(v); return s && s.length > 80 ? s.slice(0, 77) + '...' : s; };

export function validateTarget(t: unknown, where: string, errors: string[]) {
  if (!isObj(t)) { errors.push(`${where}: a target must be an object like {"text":"AH sale"}, got ${short(t)}`); return; }
  const kinds = ['text', 'frame', 'path', 'point'].filter((k) => t[k] !== undefined);
  if (kinds.length !== 1) { errors.push(`${where}: a target needs exactly one of text, frame, path or point (got ${kinds.join(', ') || 'none'})`); return; }
  const k = kinds[0];
  for (const key of Object.keys(t)) {
    if (![k, ...(k === 'text' ? ['within', 'nth'] : [])].includes(key)) errors.push(`${where}: unknown target field "${key}"${k !== 'text' && (key === 'within' || key === 'nth') ? ' (only text targets take within/nth)' : ''}`);
  }
  if (k === 'point') {
    if (!Array.isArray(t.point) || t.point.length !== 2 || !t.point.every(isNum)) errors.push(`${where}.point: must be [x, y] in UI units from the top-left`);
  } else if (typeof t[k] !== 'string' || !t[k].trim()) errors.push(`${where}.${k}: must be a non-empty string`);
  if (t.within !== undefined && typeof t.within !== 'string') errors.push(`${where}.within: must be a frame name`);
  if (t.nth !== undefined && !(Number.isInteger(t.nth) && t.nth >= 1)) errors.push(`${where}.nth: must be a whole number from 1`);
}

function validateAssertion(a: unknown, where: string, errors: string[]) {
  if (!isObj(a)) { errors.push(`${where}: must be an object like {"shown":{"text":"Done"}}`); return; }
  const keys = Object.keys(a);
  if (!keys.length) errors.push(`${where}: empty; use shown, hidden, tooltip, noTooltip, chat, lua or noErrors`);
  for (const k of keys) if (!ASSERT_KEYS.has(k)) errors.push(`${where}: unknown check "${k}" (allowed: ${[...ASSERT_KEYS].join(', ')})`);
  if (a.shown !== undefined) validateTarget(a.shown, `${where}.shown`, errors);
  if (a.hidden !== undefined) validateTarget(a.hidden, `${where}.hidden`, errors);
  if (a.tooltip !== undefined && typeof a.tooltip !== 'string' && !(Array.isArray(a.tooltip) && a.tooltip.every((s: unknown) => typeof s === 'string'))) {
    errors.push(`${where}.tooltip: a string or a list of strings the tooltip must contain`);
  }
  if (a.chat !== undefined && typeof a.chat !== 'string') errors.push(`${where}.chat: a string some chat line must contain`);
  if (a.lua !== undefined && typeof a.lua !== 'string') errors.push(`${where}.lua: a Lua expression`);
  if (a.equals !== undefined && a.lua === undefined) errors.push(`${where}.equals: only with lua`);
  for (const k of ['noErrors', 'noTooltip']) if (a[k] !== undefined && a[k] !== true) errors.push(`${where}.${k}: must be true`);
}

function validateWorld(w: unknown, where: string, errors: string[]) {
  if (!isObj(w)) { errors.push(`${where}: must be an object like {"open":"ah"}`); return; }
  const kinds = ['open', 'close', 'combat', 'money', 'give', 'take', 'buy', 'sell', 'aura', 'cast', 'hit', 'set'].filter((k) => w[k] !== undefined);
  if (kinds.length !== 1) { errors.push(`${where}: needs exactly one of open, close, combat, money, give, take, buy, sell, aura, cast, hit, set (got ${kinds.join(', ') || 'none'})`); return; }
  const k = kinds[0];
  const v = w[k];
  if (k === 'open' || k === 'close') {
    if (!WORLD_OPEN.includes(v)) errors.push(`${where}.${k}: one of ${WORLD_OPEN.join(', ')}`);
    if (k === 'open' && ['loot', 'profession'].includes(v) && w.name === undefined && w.index === undefined && v === 'profession') errors.push(`${where}: open profession needs "name" (e.g. "Alchemy")`);
  } else if (k === 'combat') { if (typeof v !== 'boolean') errors.push(`${where}.combat: true or false`); }
  else if (k === 'money') { if (!isNum(v) || v < 0) errors.push(`${where}.money: copper amount (10000 = 1 gold)`); }
  else if (k === 'give' || k === 'take' || k === 'buy') { if (!isObj(v) || !isNum(v.item)) errors.push(`${where}.${k}: {"item": itemID, "count": n}`); }
  else if (k === 'sell') { if (!isObj(v) || !isNum(v.item) || !isNum(v.price)) errors.push(`${where}.sell: {"item": itemID, "count": n, "price": copper each}`); }
  else if (k === 'aura') { if (!isObj(v) || (v.add === undefined && v.remove === undefined)) errors.push(`${where}.aura: {"add": spellID, "remaining": seconds} or {"remove": spellID}`); }
  else if (k === 'cast') { if (!isNum(v) && typeof v !== 'string') errors.push(`${where}.cast: a spell ID or name`); }
  else if (k === 'hit') { if (!isObj(v) || typeof v.from !== 'string' || typeof v.to !== 'string') errors.push(`${where}.hit: {"from": "party1", "to": "enemy:2", "amount": 300} (units: player, party1-4, enemy:<id>)`); }
  else if (k === 'set') { if (!isObj(v)) errors.push(`${where}.set: {"player.level": 30, ...} (dotted world paths)`); }
}

export function validateUseCase(uc: unknown): string[] {
  const errors: string[] = [];
  if (!isObj(uc)) return ['The file must be a JSON object with title, addons, steps'];
  for (const k of Object.keys(uc)) if (!['title', 'summary', 'addons', 'setup', 'steps', 'allowErrors', '$schema'].includes(k)) errors.push(`unknown top-level field "${k}"`);
  if (typeof uc.title !== 'string' || !uc.title.trim()) errors.push('title: required, a short name for the use case');
  if (uc.summary !== undefined && typeof uc.summary !== 'string') errors.push('summary: a sentence');
  if (!Array.isArray(uc.addons) || !uc.addons.length || !uc.addons.every((a: unknown) => typeof a === 'string')) errors.push('addons: required, the addon folder names to load, e.g. ["VendorPrinter"]');
  if (uc.setup !== undefined) {
    const s = uc.setup;
    if (!isObj(s)) errors.push('setup: an object');
    else {
      for (const k of Object.keys(s)) if (!['world', 'savedVariables', 'run', 'wait'].includes(k)) errors.push(`setup: unknown field "${k}"`);
      if (s.world !== undefined && typeof s.world !== 'string' && !isObj(s.world)) errors.push('setup.world: "default", a fixture path, or {"base": ..., "set": {...}}');
      if (isObj(s.world) && s.world.set !== undefined && !isObj(s.world.set)) errors.push('setup.world.set: {"player.money": 50000, ...}');
      if (s.savedVariables !== undefined) {
        if (!isObj(s.savedVariables)) errors.push('setup.savedVariables: {"AddonName": {"account": "fixtures/x.account.lua", "character": "..."}}');
        else for (const [addon, v] of Object.entries(s.savedVariables)) {
          if (!isObj(v)) errors.push(`setup.savedVariables.${addon}: {"account": ..., "character": ...}`);
          else for (const k of Object.keys(v)) {
            if (k !== 'account' && k !== 'character') errors.push(`setup.savedVariables.${addon}: unknown field "${k}"`);
            else if (typeof v[k] !== 'string') errors.push(`setup.savedVariables.${addon}.${k}: a fixture path ending in .lua, or Lua text`);
          }
        }
      }
      if (s.run !== undefined && typeof s.run !== 'string') errors.push('setup.run: Lua code');
      if (s.wait !== undefined && (!isNum(s.wait) || s.wait < 0)) errors.push('setup.wait: seconds');
    }
  }
  if (!Array.isArray(uc.steps) || !uc.steps.length) { errors.push('steps: required, a non-empty list'); return errors; }
  uc.steps.forEach((step: unknown, i: number) => {
    const w = `steps[${i}]`;
    if (!isObj(step)) { errors.push(`${w}: must be an object`); return; }
    for (const k of Object.keys(step)) if (!STEP_KEYS.has(k)) errors.push(`${w}: unknown field "${k}"`);
    const actions = ACTIONS.filter((a) => step[a] !== undefined);
    if (actions.length > 1) errors.push(`${w}: one action per step (found ${actions.join(' and ')}); split it into steps`);
    if (!actions.length && step.say === undefined) errors.push(`${w}: does nothing; add an action (${ACTIONS.join(', ')}) or a say`);
    if (step.say !== undefined && (typeof step.say !== 'string' || !step.say.trim())) errors.push(`${w}.say: caption text`);
    if (step.at !== undefined) validateTarget(step.at, `${w}.at`, errors);
    if (step.at !== undefined && actions.length) errors.push(`${w}.at: only for a caption-only step (an action's caption points at its own target)`);
    if (step.hold !== undefined && (!isNum(step.hold) || step.hold < 0)) errors.push(`${w}.hold: seconds`);
    for (const t of ['click', 'hover', 'drag', 'scroll'] as const) if (step[t] !== undefined) validateTarget(step[t], `${w}.${t}`, errors);
    if (step.slash !== undefined && (typeof step.slash !== 'string' || !step.slash.startsWith('/'))) errors.push(`${w}.slash: a command starting with /, e.g. "/vp"`);
    if (step.drag !== undefined) {
      if (step.to === undefined) errors.push(`${w}: drag needs "to": a target, or {"dx": 40, "dy": -20}`);
      else if (isObj(step.to) && ('dx' in step.to || 'dy' in step.to)) {
        if (!isNum(step.to.dx ?? 0) || !isNum(step.to.dy ?? 0)) errors.push(`${w}.to: dx and dy are numbers (UI units; dy positive = down)`);
      } else validateTarget(step.to, `${w}.to`, errors);
    } else if (step.to !== undefined) errors.push(`${w}.to: only with drag`);
    if (step.type !== undefined && typeof step.type !== 'string') errors.push(`${w}.type: the text to type`);
    if (step.key !== undefined && (typeof step.key !== 'string' || !KEYS.test(step.key))) errors.push(`${w}.key: a key name like ENTER, ESCAPE, TAB, UP, F1 or a single letter`);
    if (step.delta !== undefined && (!Number.isInteger(step.delta) || step.delta === 0)) errors.push(`${w}.delta: wheel clicks, positive = up, negative = down`);
    if (step.delta !== undefined && step.scroll === undefined) errors.push(`${w}.delta: only with scroll`);
    if (step.world !== undefined) validateWorld(step.world, `${w}.world`, errors);
    if (step.event !== undefined && (typeof step.event !== 'string' || !/^[A-Z0-9_]+$/.test(step.event))) errors.push(`${w}.event: an event name like PLAYER_REGEN_DISABLED`);
    if (step.args !== undefined && (typeof step.args !== 'string' || step.event === undefined)) errors.push(`${w}.args: Lua literals as text, e.g. "\\"player\\", 42"; only with event`);
    if (step.wait !== undefined) {
      if (isNum(step.wait)) { if (step.wait <= 0) errors.push(`${w}.wait: seconds above 0`); }
      else if (isObj(step.wait)) {
        validateAssertion(step.wait.for, `${w}.wait.for`, errors);
        if (step.wait.timeout !== undefined && (!isNum(step.wait.timeout) || step.wait.timeout <= 0)) errors.push(`${w}.wait.timeout: seconds`);
        for (const k of Object.keys(step.wait)) if (k !== 'for' && k !== 'timeout') errors.push(`${w}.wait: unknown field "${k}"`);
      } else errors.push(`${w}.wait: seconds, or {"for": <check>, "timeout": 30}`);
    }
    if (step.run !== undefined && typeof step.run !== 'string') errors.push(`${w}.run: Lua code`);
    if (step.expect !== undefined) validateAssertion(step.expect, `${w}.expect`, errors);
    if (step.button !== undefined && !BUTTONS.includes(step.button)) errors.push(`${w}.button: ${BUTTONS.join(', ')}`);
    if ((step.button !== undefined || step.double !== undefined) && step.click === undefined) errors.push(`${w}: button/double only with click`);
    for (const m of ['shift', 'ctrl', 'alt', 'double']) if (step[m] !== undefined && typeof step[m] !== 'boolean') errors.push(`${w}.${m}: true or false`);
    if ((step.shift || step.ctrl || step.alt) && !['click', 'drag', 'key', 'scroll'].includes(actionOf(step as Step))) errors.push(`${w}: shift/ctrl/alt only with click, drag, key or scroll`);
  });
  return errors;
}

// ---------------------------------------------------------------------------
// Descriptions (step lists, logs, reports)
// ---------------------------------------------------------------------------
export function describeTarget(t: Target | undefined): string {
  if (!t) return '?';
  if ('text' in t) return `"${t.text}"${t.within ? ` in ${t.within}` : ''}${t.nth ? ` (#${t.nth})` : ''}`;
  if ('frame' in t) return t.frame;
  if ('path' in t) return t.path;
  return `point ${t.point[0]},${t.point[1]}`;
}

export function describeAssertion(a: Assertion): string {
  const parts: string[] = [];
  if (a.shown) parts.push(`${describeTarget(a.shown)} is shown`);
  if (a.hidden) parts.push(`${describeTarget(a.hidden)} is not shown`);
  if (a.tooltip) parts.push(`tooltip has ${[a.tooltip].flat().map((s) => `"${s}"`).join(', ')}`);
  if (a.noTooltip) parts.push('no tooltip');
  if (a.chat) parts.push(`chat says "${a.chat}"`);
  if (a.lua) parts.push(a.equals !== undefined ? `${a.lua} == ${JSON.stringify(a.equals)}` : `${a.lua} is true`);
  if (a.noErrors) parts.push('no Lua errors');
  return parts.join(' and ');
}

function mods(s: Step) { return `${s.ctrl ? 'Ctrl+' : ''}${s.alt ? 'Alt+' : ''}${s.shift ? 'Shift+' : ''}`; }

export function describeWorld(w: WorldAction): string {
  if ('open' in w) return `open ${w.open}${w.name ? ` "${w.name}"` : w.index ? ` #${w.index}` : ''}`;
  if ('close' in w) return `close ${w.close}`;
  if ('combat' in w) return w.combat ? 'enter combat' : 'leave combat';
  if ('money' in w) return `set money to ${w.money}c`;
  if ('give' in w) return `give item ${w.give.item} x${w.give.count ?? 1}`;
  if ('take' in w) return `take item ${w.take.item} x${w.take.count ?? 1}`;
  if ('buy' in w) return `buy item ${w.buy.item} x${w.buy.count ?? 1} on the AH`;
  if ('sell' in w) return `sell item ${w.sell.item} x${w.sell.count ?? 1} at ${w.sell.price}c`;
  if ('aura' in w) return w.aura.add !== undefined ? `add buff ${w.aura.add}${w.aura.remaining ? ` (${w.aura.remaining} s left)` : ''}` : `remove buff ${w.aura.remove}`;
  if ('cast' in w) return `cast ${w.cast}`;
  if ('hit' in w) return `${w.hit.from} hits ${w.hit.to}${w.hit.amount ? ` for ${w.hit.amount}` : ''}`;
  return `set ${Object.keys(w.set).join(', ')}`;
}

export function describeStep(s: Step): string {
  switch (actionOf(s)) {
    case 'slash': return `type ${s.slash}`;
    case 'click': return `${mods(s)}${s.button === 'RightButton' ? 'right-' : ''}${s.double ? 'double-' : ''}click ${describeTarget(s.click)}`;
    case 'hover': return `hover ${describeTarget(s.hover)}`;
    case 'drag': return `${mods(s)}drag ${describeTarget(s.drag)} to ${s.to && 'dx' in s.to ? `${s.to.dx ?? 0},${s.to.dy ?? 0}` : describeTarget(s.to as Target)}`;
    case 'type': return `type "${s.type}"`;
    case 'key': return `press ${mods(s)}${s.key}`;
    case 'scroll': return `scroll ${describeTarget(s.scroll)} ${(s.delta ?? -1) > 0 ? 'up' : 'down'} ${Math.abs(s.delta ?? -1)}`;
    case 'world': return describeWorld(s.world!);
    case 'event': return `fire ${s.event}${s.args ? `(${s.args})` : ''}`;
    case 'wait': return typeof s.wait === 'number' ? `wait ${s.wait} s` : `wait until ${describeAssertion(s.wait!.for)}`;
    case 'run': return `run Lua: ${s.run!.length > 50 ? s.run!.slice(0, 47) + '...' : s.run}`;
    case 'expect': return `check ${describeAssertion(s.expect!)}`;
    default: return `caption${s.at ? ` at ${describeTarget(s.at)}` : ''}`;
  }
}

// ---------------------------------------------------------------------------
// JSON Schema (docs/usecase.schema.json is generated from this; npm test checks it is current)
// ---------------------------------------------------------------------------
export function useCaseSchema() {
  const target = {
    description: 'What to point at, found the way a viewer would. Prefer text.',
    oneOf: [
      { type: 'object', required: ['text'], additionalProperties: false, properties: {
        text: { type: 'string', description: 'Visible text (colour codes ignored; case and punctuation ignored for exact matches; falls back to "contains")' },
        within: { type: 'string', description: 'Only inside this frame (global name or dotted path)' },
        nth: { type: 'integer', minimum: 1, description: 'Pick the nth match, top to bottom, when several match' } } },
      { type: 'object', required: ['frame'], additionalProperties: false, properties: { frame: { type: 'string', description: 'Global frame name' } } },
      { type: 'object', required: ['path'], additionalProperties: false, properties: { path: { type: 'string', description: 'Global name then parentKeys, e.g. "MyFrame.Tabs.2"' } } },
      { type: 'object', required: ['point'], additionalProperties: false, properties: { point: { type: 'array', items: { type: 'number' }, minItems: 2, maxItems: 2, description: '[x, y] UI units from the top-left (screen is about 1365x768)' } } },
    ],
  };
  const assertion = {
    type: 'object', additionalProperties: false, minProperties: 1,
    properties: {
      shown: { $ref: '#/$defs/target' }, hidden: { $ref: '#/$defs/target' },
      tooltip: { oneOf: [{ type: 'string' }, { type: 'array', items: { type: 'string' } }], description: 'A visible tooltip contains each string' },
      noTooltip: { const: true }, chat: { type: 'string', description: 'Some chat line since the start contains this' },
      lua: { type: 'string', description: 'Lua expression; true unless equals is given' }, equals: { description: 'JSON value lua must equal' },
      noErrors: { const: true },
    },
  };
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: 'addon-sandbox/usecase.schema.json',
    title: 'Addon Sandbox use case',
    type: 'object', required: ['title', 'addons', 'steps'], additionalProperties: false,
    properties: {
      $schema: { type: 'string' },
      title: { type: 'string' }, summary: { type: 'string' },
      addons: { type: 'array', items: { type: 'string' }, minItems: 1 },
      allowErrors: { type: 'boolean', description: 'Lua errors do not fail the use case' },
      setup: { type: 'object', additionalProperties: false, properties: {
        world: { description: '"default", a fixture path (relative to the use case folder), or {"base": path|"default", "set": {"dotted.path": value}}', oneOf: [{ type: 'string' }, { type: 'object' }] },
        savedVariables: { type: 'object', additionalProperties: { type: 'object', additionalProperties: false, properties: { account: { type: 'string' }, character: { type: 'string' } } },
          description: 'Per addon: fixture .lua paths or inline Lua. Addons not listed start with no SavedVariables.' },
        run: { type: 'string', description: 'Lua run after login' },
        wait: { type: 'number', description: 'Seconds after login before step 1 (default 3; the video title card shows meanwhile)' } } },
      steps: { type: 'array', minItems: 1, items: { $ref: '#/$defs/step' } },
    },
    $defs: {
      target,
      assertion,
      step: {
        type: 'object', additionalProperties: false,
        properties: {
          say: { type: 'string', description: 'Caption shown during this step, or alone as a caption step' },
          at: { $ref: '#/$defs/target', description: 'Caption-only steps: what the caption points at' },
          hold: { type: 'number', description: 'Seconds a caption or hover stays (default: reading time)' },
          slash: { type: 'string', pattern: '^/' }, click: { $ref: '#/$defs/target' }, hover: { $ref: '#/$defs/target' },
          drag: { $ref: '#/$defs/target' },
          to: { oneOf: [{ $ref: '#/$defs/target' }, { type: 'object', additionalProperties: false, properties: { dx: { type: 'number' }, dy: { type: 'number' } } }] },
          type: { type: 'string' }, key: { type: 'string' }, scroll: { $ref: '#/$defs/target' }, delta: { type: 'integer' },
          world: { type: 'object', description: 'One of: open, close, combat, money, give, take, buy, sell, aura, cast, hit, set' },
          event: { type: 'string' }, args: { type: 'string' },
          wait: { oneOf: [{ type: 'number' }, { type: 'object', required: ['for'], additionalProperties: false, properties: { for: { $ref: '#/$defs/assertion' }, timeout: { type: 'number' } } }] },
          run: { type: 'string' }, expect: { $ref: '#/$defs/assertion' },
          button: { enum: BUTTONS }, shift: { type: 'boolean' }, ctrl: { type: 'boolean' }, alt: { type: 'boolean' }, double: { type: 'boolean' },
          note: { type: 'string' },
        },
      },
    },
  };
}

// Use case ids: "<Addon>/<file name without .usecase.json>"
export function useCaseId(addon: string, file: string) { return `${addon}/${file.replace(/\.usecase\.json$/i, '')}`; }

// A use case with its fixtures loaded (the server and the headless runner build this).
export interface ResolvedUseCase {
  id: string;
  addon: string;
  name: string;
  useCase: UseCase;
  world: unknown;
  savedVariables: Record<string, { account: string | null; character: string | null }>;
  errors: string[];
}
