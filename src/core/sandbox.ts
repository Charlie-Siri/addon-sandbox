// One sandbox session: a Lua 5.1 VM running the WoW runtime plus the loaded addons.
// Environment-agnostic: the browser app and the headless runner both drive it.
import { Lua } from 'wasmoon-lua5.1';
import { toLua } from './lua.ts';
import { xmlToLua } from './xml.ts';
import type { TocInfo } from './toc.ts';

export interface AddonBundle {
  name: string;
  toc: TocInfo;
  files: Record<string, { path: string; text: string }>;   // lower-case path -> file
}

export interface SavedVariablesText { account: string | null; character: string | null }

export interface InstalledAddon {
  name: string; title: string; notes: string; interface: string; loadOnDemand: boolean;
  deps: string[]; optDeps: string[]; meta: Record<string, string>;
}

export interface HostCallbacks {
  chat(text: string, r: number, g: number, b: number): void;
  error(message: string, stack: string): void;
  warn(message: string): void;
  missing(name: string): void;
  event(name: string, args: string): void;
  sound(id: string): void;
  reload(): void;
  fstack(): void;
  etrace(): void;
  openChat(text: string): void;
  insertChat(link: string): boolean;
}

export interface TextMetrics {
  measure(fontFile: string, size: number, text: string): number;
  lines(fontFile: string, size: number, text: string, width: number): number;
}

export interface SandboxOptions {
  runtime: { name: string; code: string }[];   // runtime/*.lua, in load order
  metrics: TextMetrics;
  callbacks: HostCallbacks;
  wasmUri?: string;
}

type LuaFn = (...args: unknown[]) => any;

export interface VisibleText {
  text: string; kind: 'text' | 'edit'; owner: string; ownerId: number; rect: [number, number, number, number];
  clickName?: string; clickId?: number; covered?: string;
}
export interface TargetMatch {
  kind: 'text' | 'edit' | 'frame' | 'point'; name?: string; text?: string; exact: boolean; strict?: boolean; ownerId?: number;
  rect: [number, number, number, number]; point: [number, number];
  clickName?: string; clickId?: number; clickRect?: [number, number, number, number]; covered?: string;
}
export interface PointInfo {
  point: [number, number]; hitName?: string; hitId?: number; global?: string; path?: string; texts?: string[];
  rect?: [number, number, number, number];
}

export class Sandbox {
  private addons = new Map<string, AddonBundle>();
  private api!: Record<string, LuaFn>;
  loadOrder: string[] = [];

  private lua: Lua;
  private constructor(lua: Lua) { this.lua = lua; }

  static async create(opts: SandboxOptions): Promise<Sandbox> {
    const lua = await Lua.create(opts.wasmUri ? { customWasmUri: opts.wasmUri } : {});
    const sb = new Sandbox(lua);
    const cb = opts.callbacks;
    const u32 = (n: number) => n >>> 0;
    lua.ctx.SANDBOX_HOST = {
      measure: (font: string, size: number, text: string) => opts.metrics.measure(font, size, text),
      lines: (font: string, size: number, text: string, width: number) => opts.metrics.lines(font, size, text, width),
      now: () => performance.now(),
      chat: (text: string, r: number, g: number, b: number) => cb.chat(text, r, g, b),
      error: (msg: string, stack: string) => cb.error(msg, stack),
      warn: (msg: string) => cb.warn(msg),
      missing: (name: string) => cb.missing(name),
      event: (name: string, args: string) => cb.event(name, args),
      sound: (id: string) => cb.sound(id),
      reload: () => cb.reload(),
      fstack: () => cb.fstack(),
      etrace: () => cb.etrace(),
      openChat: (text: string) => cb.openChat(text),
      insertChat: (link: string) => cb.insertChat(link),
      file: (addon: string, path: string) => sb.file(addon, path),
      xml: (addon: string, path: string) => {
        const text = sb.file(addon, path);
        return text == null ? null : xmlToLua(text);
      },
      band: (a: number, b: number) => u32(a & b), bor: (a: number, b: number) => u32(a | b),
      bxor: (a: number, b: number) => u32(a ^ b), bnot: (a: number) => u32(~a),
      lshift: (a: number, n: number) => u32(a << n), rshift: (a: number, n: number) => a >>> n,
      arshift: (a: number, n: number) => u32(a >> n),
    };
    // Runtime files are passed as globals and compiled with a proper chunk name for readable stacks.
    for (const file of opts.runtime) {
      lua.ctx.SANDBOX_RUNTIME_SRC = file.code;
      lua.doStringSync(`local f = assert(loadstring(SANDBOX_RUNTIME_SRC, "@sandbox/${file.name}")); SANDBOX_RUNTIME_SRC = nil; f()`);
    }
    const S = lua.ctx.SANDBOX as Record<string, LuaFn>;
    const api: Record<string, LuaFn> = {};
    for (const name of ['Frame', 'BuildRender', 'MouseMove', 'MouseDown', 'MouseUp', 'MouseWheel', 'MouseLeave',
      'KeyDown', 'KeyUp', 'Char', 'ChatCommand', 'SetScreen', 'SetWorld', 'WorldJSON', 'SetWorldValue', 'SetInstalled',
      'LoadAddon', 'LoadSavedVariables', 'Login', 'Logout', 'SerializeSavedVariables', 'FireEventFromHost',
      'RegisteredEventsJSON', 'FrameStack', 'OpenMerchant', 'OpenAH', 'OpenLoot',
      'OpenProfession', 'SetCombat', 'ResetAHThrottle', 'GameStateJSON', 'Advance', 'RunCode', 'EvalJSON', 'ParseSavedVariablesJSON',
      'UCTextsJSON', 'UCFindJSON', 'UCDescribePointJSON', 'UCTooltipJSON', 'UCNamedFramesJSON', 'UCSlashJSON', 'UCShapeJSON']) {
      api[name] = S[name];
    }
    sb.api = api;
    return sb;
  }

  // Addon file lookup, case-insensitive like the client.
  private file(addon: string, path: string): string | null {
    const bundle = this.addons.get(addon);
    if (!bundle) return null;
    const key = path.replace(/\\/g, '/').replace(/^\/+/, '').toLowerCase();
    return bundle.files[key]?.text ?? null;
  }

  setScreen(w: number, h: number, pixelW: number, pixelH: number) { this.api.SetScreen(w, h, pixelW, pixelH); }
  setWorld(world: unknown) { this.api.SetWorld(toLua(world ?? {})); }
  worldJSON(): any { return JSON.parse(this.api.WorldJSON()); }
  setWorldValue(path: string, value: unknown) { this.api.SetWorldValue(path, toLua(value)); }

  // Runs each addon's files, then its SavedVariables and ADDON_LOADED, then the login events.
  loadAddons(bundles: AddonBundle[], savedVariables: Record<string, SavedVariablesText>, installed: InstalledAddon[], isReload: boolean) {
    // Loaded addons expose their full TOC metadata (the installed list carries a trimmed copy).
    const full = new Map(bundles.map((b) => [b.name, b.toc.meta]));
    this.api.SetInstalled(toLua(installed.map((a) => (full.has(a.name) ? { ...a, meta: full.get(a.name)! } : a))));
    for (const b of bundles) {
      this.addons.set(b.name, b);
      const t = b.toc;
      this.api.LoadAddon(toLua({
        name: b.name, title: t.title, notes: t.notes, version: t.version, interface: t.interface, files: t.files,
        savedVariables: t.savedVariables, savedVariablesPerCharacter: t.savedVariablesPerCharacter, meta: t.meta,
      }));
      const sv = savedVariables[b.name];
      this.api.LoadSavedVariables(b.name, sv?.account ?? null, sv?.character ?? null);
      this.loadOrder.push(b.name);
    }
    this.api.Login(isReload);
  }

  // Fires the logout events and returns every loaded addon's SavedVariables, serialized like the client.
  logout(): Record<string, SavedVariablesText> {
    this.api.Logout();
    return JSON.parse(this.api.SerializeSavedVariables());
  }

  frame(dt: number): string { return this.api.Frame(dt) as string; }
  render(): string { return this.api.BuildRender() as string; }
  advance(seconds: number, step = 0.05) { this.api.Advance(seconds, step); }

  mouseMove(x: number, y: number) { this.api.MouseMove(x, y); }
  mouseDown(button: string, shift = false, ctrl = false, alt = false) { this.api.MouseDown(button, shift, ctrl, alt); }
  mouseUp(button: string, shift = false, ctrl = false, alt = false) { this.api.MouseUp(button, shift, ctrl, alt); }
  mouseWheel(delta: number): boolean { return !!this.api.MouseWheel(delta); }
  mouseLeave() { this.api.MouseLeave(); }
  keyDown(key: string, shift: boolean, ctrl: boolean, alt: boolean): boolean { return !!this.api.KeyDown(key, shift, ctrl, alt); }
  keyUp(key: string, shift: boolean, ctrl: boolean, alt: boolean) { this.api.KeyUp(key, shift, ctrl, alt); }
  char(text: string): boolean { return !!this.api.Char(text); }

  chat(text: string) { this.api.ChatCommand(text); }
  run(code: string) { this.api.RunCode(code, '/run'); }
  fireEvent(event: string, argsLiteral: string) { this.api.FireEventFromHost(event, argsLiteral); }
  registeredEvents(): string[] { return JSON.parse(this.api.RegisteredEventsJSON()); }
  frameStack(): any[] { return JSON.parse(this.api.FrameStack()); }
  gameState(): any { return JSON.parse(this.api.GameStateJSON()); }
  eval(expr: string): { value?: any; error?: string } { return JSON.parse(this.api.EvalJSON(expr)); }
  parseSavedVariables(text: string): { value?: any; error?: string } { return JSON.parse(this.api.ParseSavedVariablesJSON(text)); }

  openMerchant(index: number) { this.api.OpenMerchant(index); }
  closeMerchant() { this.run('CloseMerchant()'); }
  openAH() { this.api.OpenAH(); }
  closeAH() { this.run('C_AuctionHouse.CloseAuctionHouse()'); }
  openLoot(index: number) { this.api.OpenLoot(index); }
  closeLoot() { this.run('CloseLoot()'); }
  openProfession(name: string) { this.api.OpenProfession(name); }
  closeProfession() { this.run('C_TradeSkillUI.CloseTradeSkill()'); }
  setCombat(on: boolean) { this.api.SetCombat(on); }
  openMail() { this.run('SANDBOX.OpenMail()'); }
  closeMail() { this.run('CloseMail()'); }
  buyFromAH(itemID: number, quantity: number) { this.run(`SANDBOX.BuyFromAH(${Math.floor(itemID)}, ${Math.floor(quantity)})`); }
  sellOnAH(itemID: number, quantity: number, unitPrice: number, delay = 1) {
    this.run(`SANDBOX.SellOnAH(${Math.floor(itemID)}, ${Math.floor(quantity)}, ${Math.floor(unitPrice)}, ${Number(delay)})`);
  }
  bagItems(): { id: number; name: string; count: number }[] {
    return this.eval(`(function() local t, seen = {}, {} for bag = 0, 5 do for slot = 1, C_Container.GetContainerNumSlots(bag) do
      local id = C_Container.GetContainerItemID(bag, slot) if id and not seen[id] then seen[id] = true
      t[#t + 1] = { id = id, name = SANDBOX.Item(id).name, count = GetItemCount(id) } end end end return t end)()`).value ?? [];
  }
  resetAHThrottle() { this.api.ResetAHThrottle(); }

  addonToc(name: string): TocInfo | undefined { return this.addons.get(name)?.toc; }

  // SavedVariables as they stand, serialized like the client, without firing logout events.
  serializeSavedVariables(): Record<string, SavedVariablesText> { return JSON.parse(this.api.SerializeSavedVariables()); }

  // Use case helpers (src/runtime/60_usecase.lua). Rects are UI units from the top-left: [x, y, w, h].
  texts(within?: string): VisibleText[] {
    const r = JSON.parse(this.api.UCTextsJSON(within ?? null));
    if (r && !Array.isArray(r) && r.error) throw new Error(r.error);
    return Array.isArray(r) ? r : [];
  }
  find(target: Record<string, unknown>): { matches: TargetMatch[]; error?: string } {
    const r = JSON.parse(this.api.UCFindJSON(toLua(target)));
    return { matches: Array.isArray(r.matches) ? r.matches : [], error: r.error };
  }
  describePoint(x: number, y: number): PointInfo { return JSON.parse(this.api.UCDescribePointJSON(x, y)); }
  tooltips(): { name: string; lines: string[] }[] {
    const r = JSON.parse(this.api.UCTooltipJSON());
    return Array.isArray(r) ? r.map((t: any) => ({ name: t.name, lines: Array.isArray(t.lines) ? t.lines : [] })) : [];
  }
  namedFrames(): { name: string; type: string; rect: number[]; mouse: boolean }[] {
    const r = JSON.parse(this.api.UCNamedFramesJSON());
    return Array.isArray(r) ? r : [];
  }
  slashCommands(): { key: string; aliases: string[] }[] {
    const r = JSON.parse(this.api.UCSlashJSON());
    return Array.isArray(r) ? r.map((c: any) => ({ key: c.key, aliases: Array.isArray(c.aliases) ? c.aliases : [] })) : [];
  }
  shape(expr: string, depth = 2): { value?: any; error?: string } { return JSON.parse(this.api.UCShapeJSON(expr, depth)); }

  close() { this.lua.global.close(); }
}
