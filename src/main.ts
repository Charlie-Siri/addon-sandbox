// Addon Sandbox app: session lifecycle (load, save, live reload), frame loop, input, panels.
import './style.css';
import wasmUri from 'wasmoon-lua5.1/dist/liblua5.1.wasm?url';
import { Sandbox, type AddonBundle, type SavedVariablesText, type InstalledAddon } from './core/sandbox.ts';
import { resolveLoadOrder } from './core/loadorder.ts';
import { defaultWorld, type World } from './core/world.ts';
import type { TocInfo } from './core/toc.ts';
import { Renderer, type RenderList } from './renderer.ts';
import { createMetrics, wowToHtml } from './text.ts';
import { importVendorPrinter } from './importers/vendorprinter.ts';
import { importClientDump } from './importers/clientdump.ts';
import { h, $, storageGet, storageSet, formatMoney } from './dom.ts';
import { loadUseCase } from './core/runner.ts';
import type { ResolvedUseCase } from './core/usecase.ts';
import {
  initUseCases, playerActive, playerTick, getRecorder, renderTab as renderUseCases, fixtureButtons, recorderApi, restartPlayer,
  type SessionHooks,
} from './usecases.ts';

const runtimeFiles = import.meta.glob('./runtime/*.lua', { query: '?raw', import: 'default', eager: true }) as Record<string, string>;
const runtime = Object.keys(runtimeFiles).sort().map((p) => ({ name: p.split('/').pop()!, code: runtimeFiles[p] }));

interface Character { account: string; realm: string; name: string }
interface Summary extends Omit<TocInfo, 'files'> { name: string; tocFile: string; fileCount: number }
interface ServerState { paths: { addonsDir: string; wtfDir: string; profileDir: string }; settings: { addons: string[]; character: Character | null }; characters: Character[]; addonsDirFound: boolean }
interface SvResponse extends SavedVariablesText { from: { account: string | null; character: string | null } }

const api = {
  async get<T>(url: string): Promise<T> {
    const r = await fetch(url);
    if (!r.ok) throw new Error(`${url}: ${(await r.json().catch(() => ({}))).error ?? r.status}`);
    return r.json();
  },
  async post(url: string, body: unknown) {
    const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    if (!r.ok) throw new Error(`${url}: ${(await r.json().catch(() => ({}))).error ?? r.status}`);
    return r.json();
  },
};

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
const metrics = createMetrics();
const renderer = new Renderer($('ui'));
let sandbox: Sandbox | null = null;
let server: ServerState;
let installed: Summary[] = [];
let svSources: Record<string, SvResponse['from']> = {};
let loading = false;
let paused = false;
let lastStatus = '';
const errors = new Map<string, { message: string; stack: string; count: number; last: number; open: boolean }>();
const missing = new Map<string, number>();
const warnings: string[] = [];
const eventLog: string[] = [];
let eventLogDirty = false;
let inspecting = false;
// 'usecase': the running sandbox belongs to a use case (its state is never saved to the profile).
let mode: 'normal' | 'usecase' = 'normal';
let ucHooks: SessionHooks | null = null;
const videoId = new URLSearchParams(location.search).get('record');   // the video exporter's page

// ---------------------------------------------------------------------------
// Session lifecycle
// ---------------------------------------------------------------------------
async function saveSession(sb: Sandbox) {
  if (mode !== 'normal' || videoId) return 0;
  const sv = sb.logout();
  const world = sb.worldJSON();
  await Promise.all([
    ...Object.entries(sv).map(([name, data]) => api.post(`/api/sv/${encodeURIComponent(name)}`, data)),
    api.post('/api/world', world),
  ]);
  return Object.keys(sv).length;
}

async function reload(reason = 'Reload', resumed = false) {
  if (loading) return;
  if (playerActive()) { restartPlayer(); return; }
  loading = true;
  setStatus(`${reason}…`);
  const started = performance.now();
  const wasRunning = sandbox !== null || resumed;
  try {
    const marks: string[] = [];
    let t = performance.now();
    const mark = (label: string) => { const now = performance.now(); marks.push(`${label} ${Math.round(now - t)}`); t = now; };
    if (sandbox) {
      const saved = await saveSession(sandbox);
      mark('save');
      sandbox.close();
      sandbox = null;
      if (saved) systemLine(`Saved SavedVariables for ${saved} addon${saved === 1 ? '' : 's'} to the sandbox profile.`);
    }
    renderer.clear();
    clearOverlay();
    [server, installed] = await Promise.all([api.get<ServerState>('/api/state'), api.get<Summary[]>('/api/addons')]);
    if (!server.addonsDirFound) systemLine(`AddOns folder not found: ${server.paths.addonsDir}. Set SANDBOX_WOW_DIR.`, true);
    const { order, missing: missingDeps } = resolveLoadOrder(server.settings.addons, installed);
    for (const m of missingDeps) systemLine(`Missing addon: ${m}`, true);
    const bundles = await Promise.all(order.map((name) => api.get<AddonBundle>(`/api/addon/${encodeURIComponent(name)}`)));
    const svList = server.settings.character
      ? await Promise.all(order.map((name) => api.get<SvResponse>(`/api/sv/${encodeURIComponent(name)}`)))
      : [];
    const sv: Record<string, SavedVariablesText> = {};
    svSources = {};
    order.forEach((name, i) => {
      if (!svList[i]) return;
      sv[name] = { account: svList[i].account, character: svList[i].character };
      svSources[name] = svList[i].from;
    });
    const savedWorld = await api.get<World | null>('/api/world');
    mark('fetch');

    const sb = await Sandbox.create({ runtime, metrics, callbacks, wasmUri });
    sandbox = sb;
    resizeStage();
    mark('vm');
    sb.setWorld(savedWorld ?? defaultWorld(server.settings.character));
    const loadStart = performance.now();
    sb.loadAddons(bundles, sv, installed.map(toInstalled), wasRunning);
    const ms = performance.now() - loadStart;
    mark('load');
    // First run: build the world from VendorPrinter's recorded game data, before any sandbox scan replaces it.
    if (!savedWorld && order.includes('VendorPrinter')) {
      const result = importVendorPrinter(sb.worldJSON(), (expr) => sb.eval(expr));
      if (!('error' in result)) {
        sb.setWorld(result.world);
        await api.post('/api/world', result.world);
        systemLine(`New world built from VendorPrinter's game data: ${result.summary}.`);
      }
    }
    lastStatus = `${order.length ? order.join(', ') : 'No addons'} · loaded in ${Math.round(ms)} ms`;
    console.debug('[sandbox] reload phases (ms):', marks.join(', '));
    setStatus(lastStatus);
    renderAll();
    $('stage').focus();
    // ?run=/vp&run=/vp%20debug runs chat commands after the first load.
    if (!wasRunning) for (const cmd of new URLSearchParams(location.search).getAll('run')) sb.chat(cmd);
  } catch (e) {
    setStatus('Load failed');
    systemLine(`Load failed: ${(e as Error).message}`, true);
    console.error(e);
  } finally {
    loading = false;
    const total = Math.round(performance.now() - started);
    if (total > 2000) systemLine(`Reload took ${total} ms`);
  }
}

function toInstalled(a: Summary): InstalledAddon {
  return { name: a.name, title: a.title, notes: a.notes, interface: a.interface, loadOnDemand: a.loadOnDemand, deps: a.deps, optDeps: a.optDeps, meta: a.meta };
}

// Save on tab close (best effort, sync logout + beacons).
window.addEventListener('pagehide', () => {
  if (!sandbox || mode !== 'normal' || videoId) return;
  try {
    const sv = sandbox.logout();
    for (const [name, data] of Object.entries(sv)) {
      navigator.sendBeacon(`/api/sv/${encodeURIComponent(name)}`, new Blob([JSON.stringify(data)], { type: 'application/json' }));
    }
    navigator.sendBeacon('/api/world', new Blob([JSON.stringify(sandbox.worldJSON())], { type: 'application/json' }));
  } catch { /* page is going away */ }
});

// Live reload when an addon file changes on disk.
if (import.meta.hot) {
  import.meta.hot.on('sandbox:changed', (data: { addon: string; file: string }) => {
    if (videoId) return;
    if (sandbox?.loadOrder.includes(data.addon)) {
      systemLine(`${data.file} changed: reloading`);
      reload('Live reload');
    }
  });
}

// ---------------------------------------------------------------------------
// Runtime callbacks
// ---------------------------------------------------------------------------
const callbacks = {
  chat: (text: string, r: number, g: number, b: number) => { ucHooks?.chat(text); chatLine(text, [r, g, b]); },
  error: (message: string, stack: string) => { ucHooks?.error(message, stack); addError(message, stack); },
  warn: (message: string) => { warnings.push(message); systemLine(message, true); renderApis(); },
  missing: (name: string) => { missing.set(name, (missing.get(name) ?? 0) + 1); renderApis(); },
  event: (name: string, args: string) => {
    eventLog.push(`${(performance.now() / 1000).toFixed(2).padStart(8)}  ${name}${args ? `  ${args}` : ''}`);
    if (eventLog.length > 600) eventLog.splice(0, eventLog.length - 500);
    eventLogDirty = true;
  },
  sound: (id: string) => { eventLog.push(`${(performance.now() / 1000).toFixed(2).padStart(8)}  ♪ PlaySound ${id}`); eventLogDirty = true; },
  reload: () => { setTimeout(() => reload('/reload'), 0); },
  fstack: () => setInspect(!inspecting),
  etrace: () => selectTab('events'),
  openChat: (text: string) => { const input = $('chat-input') as HTMLInputElement; input.value = text; input.focus(); },
  insertChat: (link: string) => {
    const input = $('chat-input') as HTMLInputElement;
    if (document.activeElement !== input) return false;
    input.value += link;
    return true;
  },
};

// ---------------------------------------------------------------------------
// Frame loop
// ---------------------------------------------------------------------------
let last = performance.now();
let lastPanelUpdate = 0;
function tick(now: number) {
  const dt = Math.min((now - last) / 1000, 0.25);
  last = now;
  if (videoId) return;   // the video exporter drives frames itself
  if (playerActive()) {
    if (sandbox && !loading) {
      try { playerTick(dt); } catch (e) { addError(`Use case player error: ${(e as Error).message}`, (e as Error).stack ?? ''); }
      if (now - lastPanelUpdate > 400) {
        lastPanelUpdate = now;
        updateGameState();
        if (eventLogDirty) renderEventLog();
      }
    }
  } else if (sandbox && !paused && !loading) {
    try {
      const json = sandbox.frame(dt);
      if (json) renderer.apply(JSON.parse(json) as RenderList);
    } catch (e) {
      addError(`Sandbox frame error: ${(e as Error).message}`, '');
    }
    if (now - lastPanelUpdate > 400) {
      lastPanelUpdate = now;
      updateGameState();
      if (eventLogDirty) renderEventLog();
    }
  }
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);

// ---------------------------------------------------------------------------
// Stage: scaling and input
// ---------------------------------------------------------------------------
const UI_HEIGHT = 768;
let scale = 1;
let uiWidth = 1365;
function resizeStage() {
  const stage = $('stage');
  const rect = stage.getBoundingClientRect();
  if (!rect.height) return;
  scale = rect.height / UI_HEIGHT;
  const width = rect.width / scale;
  uiWidth = width;
  for (const id of ['ui', 'overlay', 'uc-layer']) $(id).style.transform = `scale(${scale})`;
  sandbox?.setScreen(width, UI_HEIGHT, Math.round(rect.width * devicePixelRatio), Math.round(rect.height * devicePixelRatio));
}
new ResizeObserver(resizeStage).observe($('stage'));

function uiPoint(e: MouseEvent) {
  const rect = $('stage').getBoundingClientRect();
  return { x: (e.clientX - rect.left) / scale, y: (e.clientY - rect.top) / scale };
}
const BUTTONS = ['LeftButton', 'MiddleButton', 'RightButton', 'Button4', 'Button5'];
const stage = $('stage');
stage.addEventListener('pointermove', (e) => {
  if (!sandbox) return;
  const p = uiPoint(e);
  sandbox.mouseMove(p.x, p.y);
  if (inspecting) renderInspector();
});
stage.addEventListener('pointerdown', (e) => {
  if (!sandbox) return;
  stage.focus();
  stage.setPointerCapture(e.pointerId);
  const p = uiPoint(e);
  sandbox.mouseMove(p.x, p.y);
  getRecorder()?.pointerDown(p.x, p.y, BUTTONS[e.button] ?? 'LeftButton', { shift: e.shiftKey, ctrl: e.ctrlKey, alt: e.altKey });
  sandbox.mouseDown(BUTTONS[e.button] ?? 'LeftButton', e.shiftKey, e.ctrlKey, e.altKey);
  e.preventDefault();
});
stage.addEventListener('pointerup', (e) => {
  if (!sandbox) return;
  const p = uiPoint(e);
  sandbox.mouseMove(p.x, p.y);
  sandbox.mouseUp(BUTTONS[e.button] ?? 'LeftButton', e.shiftKey, e.ctrlKey, e.altKey);
  getRecorder()?.pointerUp(p.x, p.y);
});
stage.addEventListener('pointerleave', () => sandbox?.mouseLeave());
stage.addEventListener('contextmenu', (e) => e.preventDefault());
stage.addEventListener('wheel', (e) => {
  const delta = e.deltaY < 0 ? 1 : -1;
  if (sandbox?.mouseWheel(delta)) {
    e.preventDefault();
    const p = uiPoint(e);
    getRecorder()?.wheel(p.x, p.y, delta);
  }
}, { passive: false });

const KEY_NAMES: Record<string, string> = {
  Escape: 'ESCAPE', Enter: 'ENTER', Backspace: 'BACKSPACE', Delete: 'DELETE', ArrowLeft: 'LEFT', ArrowRight: 'RIGHT',
  ArrowUp: 'UP', ArrowDown: 'DOWN', Home: 'HOME', End: 'END', Tab: 'TAB', ' ': 'SPACE', PageUp: 'PAGEUP', PageDown: 'PAGEDOWN',
};
function keyName(e: KeyboardEvent) {
  if (KEY_NAMES[e.key]) return KEY_NAMES[e.key];
  if (/^F\d+$/.test(e.key)) return e.key;
  if (e.key.length === 1) return e.key.toUpperCase();
  return e.key.toUpperCase();
}
stage.addEventListener('keydown', (e) => {
  if (!sandbox) return;
  if (['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) return;
  if (e.ctrlKey && e.key.toLowerCase() === 'v') return;   // handled by the paste event
  const key = keyName(e);
  let handled = sandbox.keyDown(key, e.shiftKey, e.ctrlKey, e.altKey);
  let typed = false;
  if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) { typed = sandbox.char(e.key); handled = typed || handled; }
  getRecorder()?.key(key, { shift: e.shiftKey, ctrl: e.ctrlKey, alt: e.altKey }, typed ? e.key : null, handled);
  if (!handled && (key === 'ENTER' || e.key === '/')) {
    const input = $('chat-input') as HTMLInputElement;
    input.value = e.key === '/' ? '/' : '';
    input.focus();
    handled = true;
  }
  if (handled || key === 'TAB' || key === 'SPACE') e.preventDefault();
});
stage.addEventListener('keyup', (e) => {
  if (sandbox && !['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) sandbox.keyUp(keyName(e), e.shiftKey, e.ctrlKey, e.altKey);
});
stage.addEventListener('paste', (e) => {
  const text = e.clipboardData?.getData('text') ?? '';
  if (text && sandbox?.char(text.replace(/\r?\n/g, ' '))) e.preventDefault();
});

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------
function setStatus(text: string) { $('status').textContent = text; }
$('btn-reload').addEventListener('click', () => reload());
$('btn-pause').addEventListener('click', () => {
  paused = !paused;
  $('btn-pause').textContent = paused ? 'Resume' : 'Pause';
  $('btn-pause').classList.toggle('active', paused);
  setStatus(paused ? 'Paused (time and OnUpdate stopped)' : lastStatus);
});
window.addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'r' && !e.shiftKey) { e.preventDefault(); reload(); }
});

// ---------------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------------
const chatHistory: string[] = [];
let historyIndex = 0;
function chatLine(text: string, rgb: [number, number, number], cls = '') {
  const log = $('chat-log');
  const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 24;
  const color = `rgb(${Math.round(rgb[0] * 255)},${Math.round(rgb[1] * 255)},${Math.round(rgb[2] * 255)})`;
  log.append(h('div', { class: `line ${cls}`, style: `color:${color}`, html: wowToHtml(text, 13) }));
  while (log.childElementCount > 800) log.firstElementChild!.remove();
  if (atBottom) log.scrollTop = log.scrollHeight;
}
function systemLine(text: string, warn = false) { chatLine(text, warn ? [1, 0.6, 0.3] : [0.55, 0.6, 0.7], 'system'); }

const chatInput = $('chat-input') as HTMLInputElement;
chatInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    const text = chatInput.value.trim();
    chatInput.value = '';
    if (!text) { stage.focus(); return; }
    chatHistory.push(text);
    historyIndex = chatHistory.length;
    if (!sandbox) { systemLine('Sandbox is not running.', true); return; }
    if (text.startsWith('/') && !/^\/(reload|reloadui|fstack|etrace|eventtrace)\b/i.test(text)) getRecorder()?.slash(text);
    sandbox.chat(text);
    if (!text.startsWith('/')) stage.focus();
  } else if (e.key === 'ArrowUp') {
    historyIndex = Math.max(0, historyIndex - 1);
    chatInput.value = chatHistory[historyIndex] ?? '';
    e.preventDefault();
  } else if (e.key === 'ArrowDown') {
    historyIndex = Math.min(chatHistory.length, historyIndex + 1);
    chatInput.value = chatHistory[historyIndex] ?? '';
    e.preventDefault();
  } else if (e.key === 'Escape') {
    chatInput.value = '';
    stage.focus();
  }
});

// ---------------------------------------------------------------------------
// Errors (BugSack-style: deduplicated with counts)
// ---------------------------------------------------------------------------
function addError(message: string, stack: string) {
  const e = errors.get(message);
  if (e) { e.count++; e.last = Date.now(); }
  else errors.set(message, { message, stack, count: 1, last: Date.now(), open: errors.size === 0 });
  renderErrors();
}
function cleanStack(stack: string) {
  return stack.split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('[C]: in function \'xpcall\'') && !l.includes('sandbox/00_base.lua'))
    .join('\n');
}
function renderErrors() {
  const list = $('err-list');
  list.replaceChildren();
  const sorted = [...errors.values()].sort((a, b) => b.last - a.last);
  for (const e of sorted) {
    const row = h('div', { class: `err${e.open ? ' open' : ''}` },
      h('div', { class: 'err-head', onclick: () => { e.open = !e.open; renderErrors(); } },
        h('span', { class: 'err-count' }, `${e.count}×`), h('span', { class: 'err-msg' }, e.message)),
      e.open && e.stack ? h('pre', { class: 'err-stack' }, cleanStack(e.stack)) : null);
    list.append(row);
  }
  if (!sorted.length) list.append(h('div', { class: 'empty' }, 'No errors.'));
  const total = sorted.reduce((n, e) => n + e.count, 0);
  $('err-count').textContent = String(total);
  $('err-count').classList.toggle('hot', total > 0);
}
$('err-clear').addEventListener('click', () => { errors.clear(); renderErrors(); });

// ---------------------------------------------------------------------------
// Side panel tabs
// ---------------------------------------------------------------------------
function selectTab(name: string) {
  storageSet('sandbox.tab', name);
  for (const b of document.querySelectorAll<HTMLElement>('#tabs button')) b.classList.toggle('active', b.dataset.tab === name);
  for (const body of document.querySelectorAll<HTMLElement>('.tab-body')) body.hidden = body.id !== `tab-${name}`;
  if (name === 'events') renderEventLog();
  if (name === 'usecases') renderUseCases();
}
for (const b of document.querySelectorAll<HTMLElement>('#tabs button')) b.addEventListener('click', () => selectTab(b.dataset.tab!));

function renderAll() {
  renderWorld();
  renderEvents();
  renderFrames();
  renderAddons();
  renderApis();
  renderErrors();
}

function section(title: string, ...children: (Node | null | false)[]) {
  return h('section', { class: 'card' }, h('h3', {}, title), ...children);
}
function button(label: string, onclick: () => void, cls = '') { return h('button', { class: cls, onclick }, label); }

// World ------------------------------------------------------------------
let gameState: any = {};
function updateGameState() {
  if (!sandbox) return;
  const next = sandbox.gameState();
  if (JSON.stringify(next) !== JSON.stringify(gameState)) {
    gameState = next;
    if (!$('tab-world').hidden) renderWorld();
  }
}

function renderWorld() {
  const body = $('tab-world');
  body.replaceChildren();
  if (!sandbox) return;
  const world = sandbox.worldJSON() as World;
  const p = world.player;
  const st = gameState;

  const moneyInput = h('input', { type: 'number', min: 0, step: 'any', value: (p.money / 10000).toFixed(2), class: 'num' }) as HTMLInputElement;
  const toggle = (label: string, checked: boolean, onchange: (on: boolean) => void) => {
    const box = h('input', { type: 'checkbox', checked, onchange: (e: Event) => onchange((e.target as HTMLInputElement).checked) });
    return h('label', { class: 'toggle' }, box, label);
  };
  body.append(section('Player',
    h('div', { class: 'kv' }, `${p.name}-${p.realm} · level ${p.level} ${p.race} ${p.class.toLowerCase()} · ${p.zone}`),
    h('div', { class: 'row' }, h('span', { class: 'muted' }, `Money: ${formatMoney(st.money ?? p.money)}`), moneyInput,
      button('Set gold', () => sandbox!.setWorldValue('player.money', Math.round(Number(moneyInput.value) * 10000)))),
    h('div', { class: 'toggles' },
      toggle('In combat', !!st.combat, (on) => sandbox!.setCombat(on)),
      toggle('Item data cached instantly', !!world.client.itemsCached, (on) => sandbox!.setWorldValue('client.itemsCached', on)),
      toggle('Auto loot', !!world.client.autoLoot, (on) => sandbox!.setWorldValue('client.autoLoot', on)),
      toggle('No AH scan cooldown', !!world.client.ahNoThrottle, (on) => sandbox!.setWorldValue('client.ahNoThrottle', on)))));

  const merchants = h('div', { class: 'chips' });
  world.merchants.forEach((m, i) => merchants.append(button(`${m.name} (${m.items.length})`, () => sandbox!.openMerchant(i + 1), st.merchant === m.name ? 'chip active' : 'chip')));
  if (st.merchant) merchants.append(button('Close merchant', () => sandbox!.closeMerchant(), 'chip danger'));
  const loot = h('div', { class: 'chips' });
  world.loot.forEach((l, i) => loot.append(button(l.name, () => sandbox!.openLoot(i + 1), 'chip')));
  if (st.loot) loot.append(button('Close loot', () => sandbox!.closeLoot(), 'chip danger'));
  const profs = h('div', { class: 'chips' });
  for (const name of Object.keys(world.professions)) {
    const count = Object.keys(world.professions[name].recipes).length;
    profs.append(button(`${name} (${count})`, () => sandbox!.openProfession(name), st.profession === name ? 'chip active' : 'chip'));
  }
  if (st.profession) profs.append(button('Close', () => sandbox!.closeProfession(), 'chip danger'));
  const mail = h('div', { class: 'chips' },
    st.mail ? button('Close mailbox', () => sandbox!.closeMail(), 'chip danger') : button(`Open mailbox (${st.mailCount ?? 0})`, () => sandbox!.openMail(), 'chip'));

  // AH trading the way the AH window does it (purchase API calls; sales come back as invoice mail).
  const bag = sandbox.bagItems();
  const buyId = h('input', { type: 'number', min: 1, placeholder: 'item ID', class: 'num' }) as HTMLInputElement;
  const buyQty = h('input', { type: 'number', min: 1, value: 20, class: 'num' }) as HTMLInputElement;
  const sellItem = h('select', { class: 'grow' }) as HTMLSelectElement;
  for (const it of bag) sellItem.append(h('option', { value: it.id }, `${it.name} (${it.count})`));
  const sellQty = h('input', { type: 'number', min: 1, value: 1, class: 'num' }) as HTMLInputElement;
  const sellPrice = h('input', { type: 'number', min: 0, step: 'any', placeholder: 'each, copper', class: 'num' }) as HTMLInputElement;
  const fillPrice = () => {
    const min = world.auctions[sellItem.value]?.map((l) => l[0]).sort((a, b) => a - b)[0];
    sellPrice.value = min ? String(min) : '';
  };
  sellItem.addEventListener('change', fillPrice);
  fillPrice();
  const trade = section('Auction House trading',
    h('div', { class: 'label' }, 'Buy (AH must be open)'),
    h('div', { class: 'row' }, buyId, h('span', { class: 'muted' }, '×'), buyQty,
      button('Buy', () => sandbox!.buyFromAH(Number(buyId.value), Number(buyQty.value)))),
    h('div', { class: 'label' }, 'Sell: posts bag items; the sale invoice arrives by mail in 1 s'),
    h('div', { class: 'row' }, sellItem),
    h('div', { class: 'row' }, sellQty, h('span', { class: 'muted' }, 'at'), sellPrice,
      button('Post and sell', () => { sandbox!.sellOnAH(Number(sellItem.value), Number(sellQty.value), Number(sellPrice.value)); setTimeout(renderWorld, 200); })));
  const ahItems = Object.keys(world.auctions).length;
  body.append(section('Open a window',
    h('div', { class: 'label' }, 'Merchants'), merchants,
    h('div', { class: 'label' }, `Auction House · ${ahItems} items listed`),
    h('div', { class: 'chips' },
      st.ah ? button('Close AH', () => sandbox!.closeAH(), 'chip danger') : button('Open AH', () => sandbox!.openAH(), 'chip'),
      button(st.ahThrottle ? `Reset scan cooldown (${Math.ceil(st.ahThrottle / 60)} min)` : 'Scan cooldown ready', () => sandbox!.resetAHThrottle(), 'chip')),
    h('div', { class: 'label' }, 'Loot'), loot,
    h('div', { class: 'label' }, 'Professions'), profs,
    h('div', { class: 'label' }, 'Mail'), mail,
    h('div', { class: 'label' }, 'Bags (right-click sells at a merchant)'),
    h('div', { class: 'chips' }, button('Toggle bags', () => sandbox!.run('ToggleAllBags()'), 'chip'))), trade);

  const status = h('div', { class: 'muted small' });
  const textarea = h('textarea', { class: 'json', spellcheck: false }) as HTMLTextAreaElement;
  const details = h('details', { ontoggle: () => { if ((details as HTMLDetailsElement).open) textarea.value = JSON.stringify(sandbox!.worldJSON(), null, 1); } },
    h('summary', {}, 'Edit world JSON'), textarea,
    h('div', { class: 'row' },
      button('Apply', () => {
        try { sandbox!.setWorld(JSON.parse(textarea.value)); status.textContent = 'Applied. Saved on the next reload.'; renderWorld(); }
        catch (e) { status.textContent = `Invalid JSON: ${(e as Error).message}`; }
      })));
  body.append(section('World data',
    h('div', { class: 'row wrap' },
      sandbox.loadOrder.includes('VendorPrinter') ? button('Import from VendorPrinter data', () => {
        const result = importVendorPrinter(sandbox!.worldJSON(), (expr) => sandbox!.eval(expr));
        if ('error' in result) { status.textContent = result.error; return; }
        sandbox!.setWorld(result.world);
        status.textContent = `Imported ${result.summary}. Saved on the next reload.`;
        renderWorld();
      }) : null,
      button('Import client dump', async () => {
        const dump = await api.get<{ text: string; modified: number } | null>('/api/dump');
        if (!dump) { status.textContent = 'No SandboxDump export found. Install tools/SandboxDump, run /sbdump in game, then /reload.'; return; }
        const parsed = sandbox!.parseSavedVariables(dump.text);
        const result = importClientDump(sandbox!.worldJSON(), parsed.value?.SandboxDumpDB);
        if ('error' in result) { status.textContent = parsed.error ?? result.error; return; }
        sandbox!.setWorld(result.world);
        status.textContent = `Imported ${result.summary} (exported ${new Date(dump.modified).toLocaleString()}). Saved on the next reload.`;
        renderWorld();
      }),
      button('Save now', async () => { await api.post('/api/world', sandbox!.worldJSON()); status.textContent = 'World saved to profile/world.json.'; }),
      button('Reset to default', () => {
        if (!confirm('Replace the world (player, bags, merchants, AH, loot, professions) with the default one?')) return;
        sandbox!.setWorld(defaultWorld(server.settings.character));
        status.textContent = 'Reset. Saved on the next reload.';
        renderWorld();
      }, 'danger')),
    status, details),
    section('Use case fixtures',
      h('div', { class: 'muted small' }, 'Saves this world, or the loaded addons\' SavedVariables, for use cases to start from (profile/usecases/<Addon>/fixtures/).'),
      fixtureButtons(status)));
}

// Events ---------------------------------------------------------------------
const COMMON_EVENTS = ['ADDON_LOADED', 'PLAYER_LOGIN', 'PLAYER_ENTERING_WORLD', 'PLAYER_MONEY', 'BAG_UPDATE', 'BAG_UPDATE_DELAYED',
  'PLAYER_REGEN_DISABLED', 'PLAYER_REGEN_ENABLED', 'GET_ITEM_INFO_RECEIVED', 'MERCHANT_SHOW', 'MERCHANT_CLOSED', 'LOOT_OPENED',
  'TRADE_SKILL_SHOW', 'TRADE_SKILL_LIST_UPDATE', 'AUCTION_HOUSE_SHOW', 'CHAT_MSG_SYSTEM', 'UNIT_INVENTORY_CHANGED', 'ZONE_CHANGED_NEW_AREA'];
function renderEvents() {
  const body = $('tab-events');
  body.replaceChildren();
  if (!sandbox) return;
  const registered = sandbox.registeredEvents();
  const list = h('datalist', { id: 'event-names' });
  for (const e of new Set([...registered, ...COMMON_EVENTS])) list.append(h('option', { value: e }));
  const name = h('input', { list: 'event-names', placeholder: 'EVENT_NAME', class: 'grow mono' }) as HTMLInputElement;
  const args = h('input', { placeholder: 'arguments as Lua: "player", 42, true', class: 'grow mono' }) as HTMLInputElement;
  const fire = () => { if (name.value.trim()) sandbox!.fireEvent(name.value.trim().toUpperCase(), args.value.trim()); };
  args.addEventListener('keydown', (e) => { if (e.key === 'Enter') fire(); });
  const chips = h('div', { class: 'chips' });
  for (const e of registered) chips.append(button(e, () => { name.value = e; args.focus(); }, 'chip mono'));
  if (!registered.length) chips.append(h('span', { class: 'muted small' }, 'No addon events registered.'));
  const filter = h('input', { placeholder: 'Filter log', class: 'grow', id: 'event-filter', oninput: () => renderEventLog() });
  body.append(
    section('Fire an event', list, h('div', { class: 'row' }, name), h('div', { class: 'row' }, args, button('Fire', fire, 'primary'))),
    section(`Registered by loaded code (${registered.length})`, chips),
    section('Event log', h('div', { class: 'row' }, filter, button('Clear', () => { eventLog.length = 0; renderEventLog(); })),
      h('pre', { class: 'event-log', id: 'event-log' })));
  renderEventLog();
}
function renderEventLog() {
  eventLogDirty = false;
  const el = document.getElementById('event-log');
  if (!el || $('tab-events').hidden) return;
  const f = ((document.getElementById('event-filter') as HTMLInputElement | null)?.value ?? '').toUpperCase();
  const lines = f ? eventLog.filter((l) => l.toUpperCase().includes(f)) : eventLog;
  const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 24;
  el.textContent = lines.slice(-400).join('\n');
  if (atBottom) el.scrollTop = el.scrollHeight;
}

// Frames -----------------------------------------------------------------------
function setInspect(on: boolean) {
  inspecting = on;
  if (on) selectTab('frames');
  renderFrames();
  if (!on) clearOverlay();
}
function clearOverlay() { $('overlay').replaceChildren(); }
function renderFrames() {
  const body = $('tab-frames');
  body.replaceChildren();
  const outline = h('input', { type: 'checkbox', checked: $('ui').classList.contains('outlines'), onchange: (e: Event) => $('ui').classList.toggle('outlines', (e.target as HTMLInputElement).checked) });
  body.append(section('Inspector',
    h('div', { class: 'row wrap' },
      button(inspecting ? 'Stop inspecting' : 'Inspect frames under the cursor (/fstack)', () => setInspect(!inspecting), inspecting ? 'primary' : ''),
      h('label', { class: 'toggle' }, outline, 'Outline every region')),
    h('div', { id: 'fstack', class: 'fstack' }, inspecting ? h('div', { class: 'muted small' }, 'Move the mouse over the game view.') : null)));
}
function renderInspector() {
  if (!sandbox) return;
  const stack = sandbox.frameStack().filter((f) => f.name !== 'UIParent' && f.name !== 'WorldFrame');
  const list = document.getElementById('fstack');
  if (list) {
    list.replaceChildren(...stack.slice(0, 30).map((f, i) => h('div', { class: `fs-row${f.mouse ? ' mouse' : ''}${i === 0 ? ' top' : ''}` },
      h('span', { class: 'mono' }, f.name), h('span', { class: 'muted' }, ` ${f.type} · ${f.strata} ${f.level}`))));
  }
  const overlay = $('overlay');
  overlay.replaceChildren(...stack.slice(0, 6).map((f, i) => h('div', {
    class: `ov-box${i === 0 ? ' top' : ''}`, style: `left:${f.rect[0]}px;top:${f.rect[1]}px;width:${f.rect[2]}px;height:${f.rect[3]}px`,
  }, i === 0 ? h('span', {}, f.name) : null)));
}

// Addons -------------------------------------------------------------------------
function renderAddons() {
  const body = $('tab-addons');
  body.replaceChildren();
  if (!server) return;
  const selected = new Set(server.settings.addons);
  const charSelect = h('select', { class: 'grow' }) as HTMLSelectElement;
  for (const c of server.characters) {
    const value = `${c.account}|${c.realm}|${c.name}`;
    const cur = server.settings.character;
    charSelect.append(h('option', { value, selected: !!cur && cur.account === c.account && cur.realm === c.realm && cur.name === c.name }, `${c.name} (${c.account})`));
  }
  charSelect.addEventListener('change', async () => {
    const [account, realm, name] = charSelect.value.split('|');
    await api.post('/api/settings', { character: { account, realm, name } });
    reload('Switching character');
  });
  const list = h('div', { class: 'addon-list' });
  for (const a of installed) {
    const box = h('input', { type: 'checkbox', checked: selected.has(a.name), onchange: (e: Event) => {
      if ((e.target as HTMLInputElement).checked) selected.add(a.name); else selected.delete(a.name);
    } });
    const loaded = sandbox?.loadOrder.includes(a.name);
    list.append(h('label', { class: `addon${loaded ? ' loaded' : ''}` }, box,
      h('span', { class: 'addon-name' }, a.title || a.name),
      h('span', { class: 'muted small' }, ` ${a.version ? `v${a.version} · ` : ''}${a.interface || '?'}${a.deps.length ? ` · needs ${a.deps.join(', ')}` : ''}`)));
  }
  const svRows = h('div', {});
  for (const name of sandbox?.loadOrder ?? []) {
    const from = svSources[name];
    if (!from || (!from.account && !from.character)) continue;
    const label = (src: string | null) => src === 'sandbox' ? 'sandbox copy' : src === 'wtf' ? 'seeded from WTF' : 'none';
    svRows.append(h('div', { class: 'row' }, h('span', { class: 'grow' }, `${name}: account ${label(from.account)}, character ${label(from.character)}`),
      button('Re-seed from WTF', async () => {
        if (!confirm(`Discard the sandbox's copy of ${name}'s SavedVariables and start again from your real WTF files? Your WTF folder is not changed.`)) return;
        sandbox?.close();
        sandbox = null;
        await api.post(`/api/sv/${encodeURIComponent(name)}/reset`, {});
        reload('Re-seeding');
      }, 'small')));
  }
  body.append(
    section('Character', h('div', { class: 'row' }, charSelect),
      h('div', { class: 'muted small' }, 'Picks which WTF SavedVariables seed the sandbox. The sandbox never writes to your WTF folder.')),
    section(`Addons (${installed.length} installed)`, list,
      h('div', { class: 'row' }, button('Apply and reload', async () => {
        await api.post('/api/settings', { addons: [...selected] });
        reload('Loading addons');
      }, 'primary'), h('span', { class: 'muted small' }, 'Required dependencies load automatically.'))),
    section('SavedVariables', svRows.childElementCount ? svRows : h('div', { class: 'muted small' }, 'No SavedVariables loaded.'),
      h('div', { class: 'muted small mono' }, server.paths.profileDir)));
}

// APIs -------------------------------------------------------------------------
function renderApis() {
  const body = $('tab-apis');
  body.replaceChildren();
  const rows = [...missing.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  body.append(
    section(`Used but not emulated (${rows.length})`,
      rows.length ? h('div', { class: 'chips' }, ...rows.map(([name]) => h('span', { class: 'chip mono static' }, name)))
        : h('div', { class: 'muted small' }, 'Nothing yet. Calls to real WoW APIs the sandbox only stubs show up here.')),
    section(`Warnings (${warnings.length})`, warnings.length
      ? h('pre', { class: 'event-log' }, warnings.slice(-200).join('\n'))
      : h('div', { class: 'muted small' }, 'No warnings.')));
}

// ---------------------------------------------------------------------------
// Use case sessions
// ---------------------------------------------------------------------------
async function fetchBundles(addons: string[]) {
  if (!installed.length) installed = await api.get<Summary[]>('/api/addons');
  const { order, missing: missingDeps } = resolveLoadOrder(addons, installed);
  if (missingDeps.length) throw new Error(`Not installed: ${missingDeps.join(', ')}`);
  return Promise.all(order.map((name) => api.get<AddonBundle>(`/api/addon/${encodeURIComponent(name)}`)));
}

async function startUseCase(resolved: ResolvedUseCase, attach: (sb: Sandbox) => SessionHooks): Promise<Sandbox> {
  while (loading) await new Promise((r) => setTimeout(r, 30));
  loading = true;
  try {
    setStatus(`Use case: ${resolved.useCase.title} · loading…`);
    if (sandbox) {
      const saved = await saveSession(sandbox);
      if (saved) systemLine(`Saved your session (${saved} addon${saved === 1 ? '' : 's'}); it comes back when you exit the use case.`);
      sandbox.close();
      sandbox = null;
    }
    ucHooks = null;
    renderer.clear();
    clearOverlay();
    const bundles = await fetchBundles(resolved.useCase.addons);
    const sb = await Sandbox.create({ runtime, metrics, callbacks, wasmUri });
    sandbox = sb;
    mode = 'usecase';
    ucHooks = attach(sb);
    resizeStage();
    loadUseCase(sb, resolved, bundles, installed.map(toInstalled));
    renderer.apply(JSON.parse(sb.render()) as RenderList);
    renderAll();
    return sb;
  } finally { loading = false; }
}

async function createDetached(resolved: ResolvedUseCase, attach: (sb: Sandbox) => SessionHooks): Promise<Sandbox> {
  const bundles = await fetchBundles(resolved.useCase.addons);
  let hooks: SessionHooks | null = null;
  const quiet = {
    chat: (t: string) => hooks?.chat(t), error: (m: string, s: string) => hooks?.error(m, s), warn: () => {}, missing: () => {},
    event: () => {}, sound: () => {}, reload: () => {}, fstack: () => {}, etrace: () => {}, openChat: () => {}, insertChat: () => false,
  };
  const sb = await Sandbox.create({ runtime, metrics, callbacks: quiet, wasmUri });
  sb.setScreen(1365, UI_HEIGHT, 1920, 1080);
  hooks = attach(sb);
  loadUseCase(sb, resolved, bundles, installed.map(toInstalled));
  return sb;
}

async function endUseCase() {
  if (sandbox) { sandbox.close(); sandbox = null; }
  mode = 'normal';
  ucHooks = null;
  renderer.clear();
  await reload('Back to your session', true);
}

initUseCases({
  api,
  sandbox: () => sandbox,
  startUseCase,
  createDetached,
  endUseCase,
  applyRender: (json) => renderer.apply(JSON.parse(json) as RenderList),
  forceRender: () => { if (sandbox) renderer.apply(JSON.parse(sandbox.render()) as RenderList); },
  screen: () => ({ w: uiWidth, h: UI_HEIGHT }),
  systemLine,
  setStatus,
  selectTab,
  loadedAddons: () => sandbox?.loadOrder.slice() ?? [],
});

if (videoId) {
  // Video export: the stage fills the window; scripts/video.ts calls window.__uc.prepare() and frame().
  document.body.classList.add('recording');
  resizeStage();
  (window as any).__uc = recorderApi(videoId);
} else {
  selectTab(storageGet('sandbox.tab', 'world'));
  reload('Loading');
}
