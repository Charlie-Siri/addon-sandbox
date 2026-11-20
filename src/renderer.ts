// Draws the runtime's render list as absolutely positioned DOM elements, keyed by region id.
// Only elements whose output changed are touched.
import { fontFamily, wowToHtml } from './text.ts';

type RGBA = [number, number, number, number];
interface Item {
  k: 't' | 'f' | 'b' | 'e'; id: number; x: number; y: number; w: number; h: number; z: number; a: number;
  clip?: [number, number, number, number];
  tex?: string | null; atl?: string | null; c?: RGBA | null; vc?: RGBA | null; tc?: number[] | null; bl?: string; ds?: boolean; rot?: number; gr?: any[] | null;
  t?: string; fo?: string; sz?: number; fl?: string; col?: RGBA; jh?: string; jv?: string; wr?: boolean; sh?: boolean; ml?: number; iw?: boolean;
  st?: string; stt?: string; chk?: boolean; bg?: RGBA | null; bd?: RGBA | null; es?: number; bgf?: string | null; edf?: string | null;
  cur?: number; ins?: number[]; hl?: boolean;
}
export interface RenderList { w: number; h: number; items: Item[] }

const rgba = (c: RGBA | null | undefined, mul?: RGBA | null, alpha = 1) => {
  const m = mul ?? [1, 1, 1, 1];
  const v = c ?? [1, 1, 1, 1];
  return `rgba(${Math.round(v[0] * m[0] * 255)},${Math.round(v[1] * m[1] * 255)},${Math.round(v[2] * m[2] * 255)},${(v[3] * m[3] * alpha).toFixed(3)})`;
};

// Known Blizzard texture paths drawn with CSS (no Blizzard art is bundled).
function textureCss(it: Item): { css: string; cls: string } {
  const vc = it.vc;
  if (it.c) return { css: `background:${rgba(it.c, vc)};`, cls: 'tex' };
  if (it.gr) {
    const [o, r1, g1, b1, a1, r2, g2, b2, a2] = it.gr;
    const dir = o === 'VERTICAL' ? 'to top' : 'to right';
    return { css: `background:linear-gradient(${dir},${rgba([r1, g1, b1, a1])},${rgba([r2, g2, b2, a2])});`, cls: 'tex' };
  }
  const raw = (it.tex ?? it.atl ?? '').toString();
  const p = raw.toLowerCase().replace(/\//g, '\\');
  const tint = rgba([1, 1, 1, 1], vc);
  if (/white8x8|chatframebackground|ui-tooltip-background|\\buttons\\white|whitesquare|solid/.test(p)) return { css: `background:${tint};`, cls: 'tex' };
  if (p.includes('ui-statusbar') || p.includes('statusbar')) {
    const c = vc ?? [0.85, 0.85, 0.85, 1];
    return { css: `background:linear-gradient(to bottom,${rgba([1.25, 1.25, 1.25, 1], c)},${rgba(c)} 45%,${rgba([0.6, 0.6, 0.6, 1], c)});`, cls: 'tex' };
  }
  if (p.includes('ui-actionbutton-border') || p.includes('glow')) {
    const c = vc ?? [1, 1, 1, 1];
    return { css: `background:radial-gradient(closest-side,transparent 52%,${rgba(c, null, 0.95)} 62%,transparent 76%);`, cls: 'tex' };
  }
  if (p.includes('questtitlehighlight') || p.includes('buttonhilight') || p.includes('highlight')) {
    return { css: `background:${p.includes('quest') ? 'rgba(90,140,255,0.28)' : 'rgba(255,255,255,0.18)'};`, cls: 'tex' };
  }
  if (p.includes('sortarrow')) {
    // The file's arrow points down; a flipped tex coord (top > bottom) points it up.
    const up = !!it.tc && it.tc[2] > it.tc[3];
    return { css: `background:#ffd100;clip-path:polygon(${up ? '50% 0,100% 100%,0 100%' : '0 0,100% 0,50% 100%'});`, cls: 'tex' };
  }
  if (p.includes('ui-scrollbar-knob')) return { css: '', cls: 'tex knob' };
  if (p.includes('sliderbar-button')) return { css: '', cls: 'tex slider-thumb' };
  if (p.includes('goldicon')) return { css: '', cls: 'tex coin coin-gold' };
  if (p.includes('silvericon')) return { css: '', cls: 'tex coin coin-silver' };
  if (p.includes('coppericon')) return { css: '', cls: 'tex coin coin-copper' };
  // Icons: numeric file IDs or Interface\Icons paths get a tinted placeholder tile with a stable hue.
  if (/^\d+$/.test(raw) || p.includes('\\icons\\')) {
    let hash = 0;
    for (let i = 0; i < raw.length; i++) hash = (hash * 31 + raw.charCodeAt(i)) >>> 0;
    const hue = hash % 360;
    return { css: `--hue:${hue};`, cls: 'tex icon' };
  }
  return { css: `background:${rgba([1, 1, 1, 0.07], vc)};`, cls: 'tex unknown' };
}

function clipCss(it: Item): string {
  if (!it.clip) return '';
  const [cx, cy, cw, ch] = it.clip;
  const top = Math.max(0, cy - it.y), left = Math.max(0, cx - it.x);
  const right = Math.max(0, it.x + it.w - (cx + cw)), bottom = Math.max(0, it.y + it.h - (cy + ch));
  if (!top && !left && !right && !bottom) return '';
  return `clip-path:inset(${top}px ${right}px ${bottom}px ${left}px);`;
}

function outlineShadow(flags: string | undefined, shadow: boolean | undefined) {
  const parts: string[] = [];
  if (flags && /OUTLINE/.test(flags)) {
    const w = /THICK/.test(flags) ? 1.5 : 1;
    parts.push(`${w}px 0 0 #000`, `-${w}px 0 0 #000`, `0 ${w}px 0 #000`, `0 -${w}px 0 #000`);
  }
  if (shadow) parts.push('1px 1px 0 rgba(0,0,0,.9)');
  return parts.length ? `text-shadow:${parts.join(',')};` : '';
}

const JUSTIFY_H: Record<string, string> = { LEFT: 'flex-start', CENTER: 'center', RIGHT: 'flex-end' };
const JUSTIFY_V: Record<string, string> = { TOP: 'flex-start', MIDDLE: 'center', BOTTOM: 'flex-end' };

export class Renderer {
  private els = new Map<string, { el: HTMLElement; sig: string; inner: string }>();
  readonly root: HTMLElement;
  onHyperlink?: (link: string) => void;

  constructor(root: HTMLElement) {
    this.root = root;
  }

  clear() {
    for (const { el } of this.els.values()) el.remove();
    this.els.clear();
  }

  apply(list: RenderList) {
    this.root.style.width = `${list.w}px`;
    this.root.style.height = `${list.h}px`;
    const seen = new Set<string>();
    for (const it of list.items) {
      const key = it.k + it.id;
      seen.add(key);
      let entry = this.els.get(key);
      if (!entry) {
        const el = document.createElement('div');
        el.dataset.id = String(it.id);
        this.root.appendChild(el);
        entry = { el, sig: '', inner: '' };
        this.els.set(key, entry);
      }
      const { css, cls, inner } = this.describe(it);
      const sig = cls + '|' + css;
      if (sig !== entry.sig) {
        entry.el.className = cls;
        entry.el.style.cssText = css;
        entry.sig = sig;
      }
      if (inner !== entry.inner) {
        entry.el.innerHTML = inner;
        entry.inner = inner;
        if (it.k === 'e' && it.cur !== undefined && it.cur >= 0) {
          const box = entry.el.firstElementChild as HTMLElement | null;
          if (box) box.scrollLeft = box.scrollWidth;
        }
      }
    }
    for (const [key, { el }] of this.els) {
      if (!seen.has(key)) { el.remove(); this.els.delete(key); }
    }
  }

  private describe(it: Item): { css: string; cls: string; inner: string } {
    const base = `left:${it.x}px;top:${it.y}px;width:${it.w}px;height:${it.h}px;z-index:${it.z};${clipCss(it)}`;
    if (it.k === 't') {
      const t = textureCss(it);
      let extra = '';
      if (it.bl === 'ADD') extra += 'mix-blend-mode:screen;';
      if (it.ds) extra += 'filter:grayscale(1);';
      if (it.rot) extra += `transform:rotate(${-it.rot}rad);`;
      return { css: base + t.css + extra + `opacity:${it.a};`, cls: t.cls, inner: '' };
    }
    if (it.k === 'f') {
      const col = it.col ?? [1, 1, 1, 1];
      const wrap = it.wr !== false;
      // 2px of slack: the DOM's text width can exceed the canvas measurement by a fraction of a pixel.
      const box = `left:${it.x - 1}px;top:${it.y}px;width:${it.w + 2}px;height:${it.h}px;z-index:${it.z};${clipCss(it)}`;
      const css = box + `opacity:${it.a};color:${rgba(col)};font-family:${fontFamily(it.fo ?? '')};font-size:${it.sz}px;`
        + `justify-content:${JUSTIFY_H[it.jh ?? 'CENTER'] ?? 'center'};align-items:${JUSTIFY_V[it.jv ?? 'MIDDLE'] ?? 'center'};`
        + `text-align:${(it.jh ?? 'CENTER').toLowerCase()};` + outlineShadow(it.fl, it.sh)
        + (it.ml && it.ml > 0 ? `--lines:${it.ml};` : '');
      // Auto-sized text never wraps or truncates; fixed-width text truncates with an ellipsis when wrapping is off.
      const cls = 'fs' + (it.iw ? ' free' : wrap ? ' wrap' : ' nowrap') + (it.ml && it.ml > 0 ? ' clamp' : '');
      return { css, cls, inner: `<span>${wowToHtml(it.t ?? '', it.sz)}</span>` };
    }
    if (it.k === 'e') {
      const col = it.col ?? [1, 1, 1, 1];
      const [l, r, t, b] = it.ins ?? [0, 0, 0, 0];
      const css = base + `opacity:${it.a};color:${rgba(col)};font-family:${fontFamily(it.fo ?? '')};font-size:${it.sz}px;`
        + `padding:${t}px ${r}px ${b}px ${l}px;text-align:${(it.jh ?? 'LEFT').toLowerCase()};`;
      const text = it.t ?? '';
      let inner: string;
      const escHtml = (s: string) => s.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]!));
      if (it.cur !== undefined && it.cur >= 0) {
        const chars = Array.from(text);
        const before = escHtml(chars.slice(0, it.cur).join(''));
        const after = escHtml(chars.slice(it.cur).join(''));
        inner = `<div class="eb-text${it.hl ? ' hl' : ''}">${before}<i class="caret"></i>${after}</div>`;
      } else {
        inner = `<div class="eb-text">${escHtml(text)}</div>`;
      }
      return { css, cls: 'eb' + (it.ml ? ' multi' : ''), inner };
    }
    // Boxes: backdrops and stand-in template styles.
    if (it.st === 'backdrop') {
      const es = it.es ?? 0;
      const edf = (it.edf ?? '').toLowerCase();
      const bgf = (it.bgf ?? '').toLowerCase();
      let css = base + `opacity:${it.a};`;
      if (bgf) {
        const dark = bgf.includes('dialogbox-background-dark') ? [0, 0, 0, 1] : bgf.includes('dialogbox-background') ? [0.08, 0.08, 0.1, 1] : [1, 1, 1, 1];
        css += `background:${rgba(dark as RGBA, it.bg)};`;
      }
      if (edf) {
        const solid = edf.includes('white8x8') || edf.includes('chatframebackground');
        const w = solid ? Math.max(es, 1) : Math.min(Math.max(es * 0.2, 1), 6);
        const radius = solid ? 0 : Math.min(es * 0.35, 8);
        const bdColor = edf.includes('gold-border') ? rgba([0.9, 0.72, 0.25, 1], it.bd) : rgba(edf.includes('dialogbox-border') ? [0.75, 0.75, 0.75, 1] : [1, 1, 1, 1], it.bd);
        css += `border:${w}px solid ${bdColor};border-radius:${radius}px;`;
        if (bgf && !solid) css += 'background-clip:padding-box;';
      }
      return { css, cls: 'box backdrop', inner: '' };
    }
    const cls = `box sb-${it.st} s-${it.stt ?? 'n'}${it.chk ? ' checked' : ''}`;
    return { css: base + `opacity:${it.a};`, cls, inner: '' };
  }
}
