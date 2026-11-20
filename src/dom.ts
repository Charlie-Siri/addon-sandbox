// Tiny DOM helpers.
type Attrs = Record<string, string | number | boolean | ((e: any) => void) | undefined>;

export function h<K extends keyof HTMLElementTagNameMap>(tag: K, attrs: Attrs = {}, ...children: (Node | string | null | undefined | false)[]) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === false) continue;
    if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v as EventListener);
    else if (k === 'class') el.className = String(v);
    else if (k === 'html') el.innerHTML = String(v);
    else if (v === true) el.setAttribute(k, '');
    else el.setAttribute(k, String(v));
  }
  for (const c of children) if (c !== null && c !== undefined && c !== false) el.append(c);
  return el;
}

export function $(id: string) { return document.getElementById(id)!; }

export function storageGet(key: string, fallback: string): string {
  try { return localStorage.getItem(key) ?? fallback; } catch { return fallback; }
}
export function storageSet(key: string, value: string) {
  try { localStorage.setItem(key, value); } catch { /* private mode or blocked storage */ }
}

export function formatMoney(copper: number) {
  const g = Math.floor(copper / 10000), s = Math.floor(copper / 100) % 100, c = copper % 100;
  return `${g ? `${g.toLocaleString()}g ` : ''}${g || s ? `${s}s ` : ''}${c}c`;
}
