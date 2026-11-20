// Draws a use case's presentation layer over the game view: the fake cursor, click ripples, the caption bubble with a
// spotlight, the chat box while a command is typed, the "later" badge and the title card. Everything animates from
// the runner's display time (never CSS transitions or the wall clock), so a video frame is the same on every export.
import type { ViewState } from './core/runner.ts';
import { wowToHtml } from './text.ts';

type Rect = [number, number, number, number];

const CURSOR_SVG = `<svg viewBox="0 0 24 24" width="24" height="24" xmlns="http://www.w3.org/2000/svg">
<path d="M4 2 L4 19 L8.5 15 L11.5 22 L14.5 20.7 L11.6 14 L17.5 14 Z" fill="#fff" stroke="#111" stroke-width="1.6" stroke-linejoin="round"/></svg>`;

function el(cls: string, parent: HTMLElement, html = '') {
  const d = document.createElement('div');
  d.className = cls;
  if (html) d.innerHTML = html;
  parent.append(d);
  return d;
}

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));

export class UseCaseView {
  private root: HTMLElement;
  private cursor: HTMLElement;
  private ripple: HTMLElement;
  private spot: HTMLElement;
  private caption: HTMLElement;
  private chat: HTMLElement;
  private badge: HTMLElement;
  private title: HTMLElement;
  private toast: HTMLElement;
  private chatLog: HTMLElement;
  private chatKey = '';
  private captionKey = '';
  private captionStart = 0;
  private captionSize = { w: 0, h: 0 };
  private titleKey = '';
  private titleStart = 0;
  private titleEnd = -1;
  private lastTitle: ViewState['title'] = null;
  private badgeStart = 0;
  private badgeKey = '';
  showChecks = true;

  constructor(root: HTMLElement) {
    this.root = root;
    this.spot = el('uc-spot', root);
    this.chatLog = el('uc-chatlog', root);
    this.caption = el('uc-caption', root);
    this.chat = el('uc-chat', root);
    this.badge = el('uc-badge', root);
    this.toast = el('uc-toast', root);
    this.ripple = el('uc-ripple', root);
    this.cursor = el('uc-cursor', root, CURSOR_SVG);
    this.title = el('uc-title', root);
    this.clear();
  }

  clear() {
    for (const e of [this.cursor, this.ripple, this.spot, this.caption, this.chat, this.badge, this.title, this.toast, this.chatLog]) e.style.display = 'none';
    this.captionKey = this.titleKey = this.badgeKey = this.chatKey = '';
    this.titleEnd = -1;
    this.lastTitle = null;
  }

  // The use case's chat output in a game-style chat frame (videos have no side panel). Lines fade after 45 s.
  private renderChatLog(lines: { text: string; t: number }[], t: number) {
    const recent = lines.slice(-9).filter((l) => t - l.t < 45);
    const key = recent.map((l) => l.t.toFixed(2)).join(',') + '|' + Math.floor(t);
    if (key === this.chatKey) return;
    this.chatKey = key;
    if (!recent.length) { this.chatLog.style.display = 'none'; return; }
    this.chatLog.style.display = '';
    this.chatLog.innerHTML = recent.map((l) => {
      const age = t - l.t;
      const op = age > 40 ? Math.max(0, (45 - age) / 5) : 1;
      return `<div class="uc-chatline" style="opacity:${op.toFixed(2)}">${wowToHtml(l.text, 14)}</div>`;
    }).join('');
  }

  render(v: ViewState, t: number, screen: { w: number; h: number }, chatLines?: { text: string; t: number }[]) {
    // the layer spans the UI screen so bottom-anchored parts (chat) land on screen
    this.root.style.width = `${screen.w}px`;
    this.root.style.height = `${screen.h}px`;
    if (chatLines) this.renderChatLog(chatLines, t);
    // cursor
    if (v.cursor) {
      this.cursor.style.display = '';
      this.cursor.style.transform = `translate(${v.cursor.x - 3}px, ${v.cursor.y - 2}px) scale(${v.pressed ? 0.86 : 1})`;
    } else this.cursor.style.display = 'none';

    // click ripple (0.5 s)
    const rp = v.ripple;
    const age = rp ? t - rp.t : 99;
    if (rp && age >= 0 && age < 0.5) {
      const k = age / 0.5;
      const r = 6 + 22 * k;
      Object.assign(this.ripple.style, {
        display: '', left: `${rp.x - r}px`, top: `${rp.y - r}px`, width: `${r * 2}px`, height: `${r * 2}px`, opacity: String(0.9 * (1 - k)),
      });
    } else this.ripple.style.display = 'none';

    // caption + spotlight
    const cap = v.caption;
    if (cap) {
      const key = cap.text + '|' + (cap.rect ?? []).map(Math.round).join(',');
      if (key !== this.captionKey) {
        this.captionKey = key;
        this.captionStart = t;
        this.caption.innerHTML = esc(cap.text);
        this.caption.style.display = '';
        this.caption.style.left = '0px';
        this.caption.style.top = '0px';
        this.captionSize = { w: this.caption.offsetWidth, h: this.caption.offsetHeight };
        this.placeCaption(cap.rect, screen);
      }
      const k = Math.min(1, (t - this.captionStart) / 0.25);
      this.caption.style.opacity = String(k);
      this.caption.style.transform = `translateY(${(1 - k) * 6}px)`;
    } else {
      this.captionKey = '';
      this.caption.style.display = 'none';
    }
    const sp = v.spotlight;
    if (sp && cap) {
      const pad = 6;
      const k = Math.min(1, (t - this.captionStart) / 0.25);
      Object.assign(this.spot.style, {
        display: '', left: `${sp[0] - pad}px`, top: `${sp[1] - pad}px`, width: `${sp[2] + pad * 2}px`, height: `${sp[3] + pad * 2}px`,
        opacity: String(k),
      });
    } else this.spot.style.display = 'none';

    // chat box while a slash command is typed
    if (v.chat !== null) {
      const caret = Math.floor(t * 2) % 2 === 0 ? '<i class="uc-caret"></i>' : '<i class="uc-caret off"></i>';
      this.chat.innerHTML = `<span class="uc-chat-label">Say:</span> ${esc(v.chat)}${caret}`;
      this.chat.style.display = '';
    } else this.chat.style.display = 'none';

    // "45 s later" badge
    if (v.badge) {
      if (v.badge !== this.badgeKey) { this.badgeKey = v.badge; this.badgeStart = t; }
      this.badge.innerHTML = `<span class="uc-ff">&#9193;</span> ${esc(v.badge)}`;
      this.badge.style.display = '';
      this.badge.style.opacity = String(Math.min(1, (t - this.badgeStart) / 0.2));
    } else { this.badgeKey = ''; this.badge.style.display = 'none'; }

    // title card: fades in, fades out after the runner clears it
    this.title.style.width = `${screen.w}px`;
    this.title.style.height = `${screen.h}px`;
    if (v.title) {
      const key = v.title.title;
      if (key !== this.titleKey) {
        this.titleKey = key;
        this.titleStart = t;
        this.titleEnd = -1;
        this.lastTitle = v.title;
        this.title.innerHTML = `<div class="uc-title-card"><div class="uc-title-addons">${v.title.addons.map((a) => `<span>${esc(a)}</span>`).join('')}</div>`
          + `<div class="uc-title-main">${esc(v.title.title)}</div>${v.title.summary ? `<div class="uc-title-sub">${esc(v.title.summary)}</div>` : ''}</div>`;
      }
      this.title.style.display = '';
      this.title.style.opacity = String(Math.min(1, (t - this.titleStart) / 0.35));
    } else if (this.lastTitle) {
      if (this.titleEnd < 0) this.titleEnd = t;
      const k = 1 - (t - this.titleEnd) / 0.4;
      if (k > 0) { this.title.style.display = ''; this.title.style.opacity = String(k); }
      else { this.title.style.display = 'none'; this.lastTitle = null; this.titleKey = ''; }
    } else this.title.style.display = 'none';

    // expect results (player only)
    const c = v.check;
    if (this.showChecks && c && t - c.t < 1.6) {
      this.toast.className = `uc-toast ${c.ok ? 'ok' : 'bad'}`;
      this.toast.textContent = `${c.ok ? '✓' : '✗'} ${c.text}`;
      this.toast.style.display = '';
      this.toast.style.opacity = String(Math.min(1, (1.6 - (t - c.t)) / 0.3));
    } else this.toast.style.display = 'none';
  }

  // Below the target when there is room, else above; centred on it, kept on screen. No target: lower third.
  private placeCaption(rect: Rect | null, screen: { w: number; h: number }) {
    const { w, h } = this.captionSize;
    const margin = 14;
    let x: number, y: number;
    this.caption.classList.remove('above', 'below', 'free');
    if (rect) {
      const cx = rect[0] + rect[2] / 2;
      x = Math.min(Math.max(cx - w / 2, margin), screen.w - w - margin);
      // above first: game tooltips usually open below or beside the cursor
      const below = rect[1] + rect[3] + 16;
      const above = rect[1] - 16 - h;
      if (above > margin) { y = above; this.caption.classList.add('above'); }
      else if (below + h < screen.h - margin) { y = below; this.caption.classList.add('below'); }
      else { y = Math.min(Math.max(rect[1], margin), screen.h - h - margin); this.caption.classList.add('free'); }
      this.caption.style.setProperty('--arrow-x', `${Math.min(Math.max(cx - x, 18), w - 18)}px`);
    } else {
      x = (screen.w - w) / 2;
      y = screen.h - h - 92;
      this.caption.classList.add('free');
    }
    this.caption.style.left = `${Math.round(x)}px`;
    this.caption.style.top = `${Math.round(y)}px`;
  }
}
