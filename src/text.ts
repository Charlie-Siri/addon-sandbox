// WoW text: escape sequences (|c colors, |T textures, |H links, |n) to HTML, and canvas text metrics.
import type { TextMetrics } from './core/sandbox.ts';

const FAMILIES: [RegExp, string][] = [
  [/ARIALN/i, '"Arial Narrow", "Liberation Sans Narrow", "Roboto Condensed", "Nimbus Sans Narrow", Arial, sans-serif'],
  [/MORPHEUS/i, '"Morpheus", "Cinzel", Georgia, serif'],
  [/SKURRI/i, '"Skurri", Impact, sans-serif'],
];
const DEFAULT_FAMILY = '"Friz Quadrata TT", "Friz Quadrata", "Albertus", "URW Classico", Optima, Candara, "Noto Sans", sans-serif';
export function fontFamily(file: string): string {
  for (const [re, fam] of FAMILIES) if (re.test(file)) return fam;
  return DEFAULT_FAMILY;
}

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));

// Inline textures: coins and a generic icon box.
function inlineTexture(spec: string, size: number): string {
  const [path, h] = spec.split(':');
  const px = Number(h) > 0 ? Number(h) : size;
  const p = path.toLowerCase().replace(/\//g, '\\');
  const coin = p.includes('goldicon') ? 'gold' : p.includes('silvericon') ? 'silver' : p.includes('coppericon') ? 'copper' : null;
  if (coin) return `<i class="coin coin-${coin}" style="width:${px * 0.85}px;height:${px * 0.85}px"></i>`;
  return `<i class="inline-tex" style="width:${px}px;height:${px}px" title="${esc(path)}"></i>`;
}

// Converts a WoW-escaped string to HTML. `size` sizes inline textures.
export function wowToHtml(text: string, size = 12): string {
  let out = '';
  let open = 0;
  let i = 0;
  while (i < text.length) {
    const bar = text.indexOf('|', i);
    if (bar === -1) { out += esc(text.slice(i)); break; }
    out += esc(text.slice(i, bar));
    const code = text[bar + 1];
    if (code === 'c' && /^[0-9a-fA-F]{8}$/.test(text.slice(bar + 2, bar + 10))) {
      const hex = text.slice(bar + 4, bar + 10);
      out += `<span style="color:#${hex}">`;
      open++;
      i = bar + 10;
    } else if (code === 'c' && text[bar + 2] === 'n') {
      // |cnCOLOR_NAME:text|r — named colors, shown in the default text color.
      const colon = text.indexOf(':', bar);
      out += '<span>';
      open++;
      i = colon === -1 ? bar + 2 : colon + 1;
    } else if (code === 'r') {
      if (open > 0) { out += '</span>'; open--; }
      i = bar + 2;
    } else if (code === 'n') {
      out += '<br>';
      i = bar + 2;
    } else if (code === '|') {
      out += '|';
      i = bar + 2;
    } else if (code === 'T') {
      const end = text.indexOf('|t', bar);
      if (end === -1) { i = bar + 2; continue; }
      out += inlineTexture(text.slice(bar + 2, end), size);
      i = end + 2;
    } else if (code === 'A') {
      const end = text.indexOf('|a', bar);
      if (end === -1) { i = bar + 2; continue; }
      out += `<i class="inline-tex" style="width:${size}px;height:${size}px"></i>`;
      i = end + 2;
    } else if (code === 'H') {
      const mid = text.indexOf('|h', bar + 2);
      if (mid === -1) { i = bar + 2; continue; }
      const link = text.slice(bar + 2, mid);
      const end = text.indexOf('|h', mid + 2);
      const label = end === -1 ? '' : text.slice(mid + 2, end);
      out += `<span class="wow-link" data-link="${esc(link)}">${wowToHtml(label, size)}</span>`;
      i = end === -1 ? mid + 2 : end + 2;
    } else if (code === 'K') {
      const end = text.indexOf('|k', bar);
      i = end === -1 ? bar + 2 : end + 2;
    } else if (code === '4') {
      // |4singular:plural; — pick the plural form.
      const semi = text.indexOf(';', bar);
      const forms = text.slice(bar + 2, semi === -1 ? undefined : semi).split(':');
      out += esc(forms[1] ?? forms[0] ?? '');
      i = semi === -1 ? text.length : semi + 1;
    } else {
      out += '|';
      i = bar + 1;
    }
  }
  while (open-- > 0) out += '</span>';
  return out.replace(/\n/g, '<br>');
}

// Plain text for measuring: escapes removed, inline textures replaced by a same-width placeholder.
export function wowToPlain(text: string): string {
  return text
    .replace(/\|c[0-9a-fA-F]{8}/g, '').replace(/\|cn[^:]*:/g, '').replace(/\|r/g, '')
    .replace(/\|H[^|]*\|h/g, '').replace(/\|h/g, '')
    .replace(/\|T[^|]*\|t/g, '').replace(/\|A[^|]*\|a/g, '')
    .replace(/\|K[^|]*\|k/g, '').replace(/\|n/g, '\n').replace(/\|\|/g, '|');
}

export function createMetrics(): TextMetrics {
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d')!;
  const fontCache = new Map<string, string>();
  const setFont = (file: string, size: number) => {
    const key = file + size;
    let font = fontCache.get(key);
    if (!font) { font = `${size}px ${fontFamily(file)}`; fontCache.set(key, font); }
    if (ctx.font !== font) ctx.font = font;
  };
  const width = (file: string, size: number, plain: string) => {
    setFont(file, size);
    return ctx.measureText(plain).width;
  };
  // Inline textures render as boxes of about 0.85em plus margins (see .coin / .inline-tex).
  const textureWidth = (text: string, size: number) => (text.match(/\|[TA][^|]*\|[ta]/g)?.length ?? 0) * (size * 0.85 + 2);
  const full = (file: string, size: number, text: string) => width(file, size, wowToPlain(text)) + textureWidth(text, size);
  return {
    measure: full,
    lines(file, size, text, maxWidth) {
      let lines = 0;
      for (const para of text.replace(/\|n/g, '\n').split('\n')) {
        const words = para.split(/(\s+)/);
        let line = '';
        let count = 1;
        for (const w of words) {
          const next = line + w;
          if (line && full(file, size, next.trimEnd()) > maxWidth + 0.5) { count++; line = w.trimStart(); }
          else line = next;
        }
        lines += count;
      }
      return lines;
    },
  };
}
