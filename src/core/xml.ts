// Small XML parser for addon UI files: elements, attributes, text, CDATA, comments, entities, line numbers.
// Output is a Lua table literal: { tag=, line=, attr={}, children={}, text= } (see runtime/50_xml.lua).
import { luaString } from './lua.ts';

interface XmlNode { tag: string; line: number; attr: Record<string, string>; children: XmlNode[]; text: string }

const ENTITIES: Record<string, string> = { lt: '<', gt: '>', amp: '&', quot: '"', apos: "'" };
function decode(s: string) {
  return s.replace(/&(#x[0-9a-f]+|#\d+|\w+);/gi, (whole, e: string) => {
    if (e[0] === '#') return String.fromCodePoint(e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10));
    return ENTITIES[e] ?? whole;
  });
}

export class XmlError extends Error {
  line: number;
  constructor(message: string, line: number) { super(message); this.line = line; }
}

export function parseXml(src: string): XmlNode {
  const root: XmlNode = { tag: '#document', line: 1, attr: {}, children: [], text: '' };
  const stack: XmlNode[] = [root];
  let i = 0;
  let line = 1;
  const advance = (to: number) => {
    for (let k = i; k < to; k++) if (src.charCodeAt(k) === 10) line++;
    i = to;
  };
  while (i < src.length) {
    const lt = src.indexOf('<', i);
    if (lt === -1) { stack[stack.length - 1].text += decode(src.slice(i)); break; }
    if (lt > i) stack[stack.length - 1].text += decode(src.slice(i, lt));
    advance(lt);
    if (src.startsWith('<!--', i)) {
      const end = src.indexOf('-->', i);
      if (end === -1) throw new XmlError('unterminated comment', line);
      advance(end + 3);
    } else if (src.startsWith('<![CDATA[', i)) {
      const end = src.indexOf(']]>', i);
      if (end === -1) throw new XmlError('unterminated CDATA', line);
      stack[stack.length - 1].text += src.slice(i + 9, end);
      advance(end + 3);
    } else if (src.startsWith('<?', i) || src.startsWith('<!', i)) {
      const end = src.indexOf('>', i);
      advance(end === -1 ? src.length : end + 1);
    } else if (src.startsWith('</', i)) {
      const end = src.indexOf('>', i);
      if (end === -1) throw new XmlError('unterminated closing tag', line);
      const tag = src.slice(i + 2, end).trim();
      const open = stack.pop();
      if (!open || open.tag !== tag) {
        throw new XmlError(`closing </${tag}> doesn't match <${open?.tag ?? '?'}>`, line);
      }
      advance(end + 1);
    } else {
      const startLine = line;
      const m = /^<([\w:.\-]+)/.exec(src.slice(i, i + 200));
      if (!m) throw new XmlError('malformed tag', line);
      let j = i + m[0].length;
      const attr: Record<string, string> = {};
      const attrRe = /\s*([\w:.\-]+)\s*=\s*("([^"]*)"|'([^']*)')|\s*(\/?)>|\s+/y;
      let selfClosing = false;
      let closed = false;
      while (j < src.length) {
        attrRe.lastIndex = j;
        const a = attrRe.exec(src);
        if (!a) throw new XmlError(`malformed attributes in <${m[1]}>`, line);
        j = attrRe.lastIndex;
        if (a[1]) attr[a[1]] = decode(a[3] ?? a[4] ?? '');
        else if (a[0].trim().endsWith('>')) { selfClosing = a[5] === '/'; closed = true; break; }
      }
      if (!closed) throw new XmlError(`unterminated <${m[1]}>`, line);
      const node: XmlNode = { tag: m[1], line: startLine, attr, children: [], text: '' };
      stack[stack.length - 1].children.push(node);
      advance(j);
      if (!selfClosing) stack.push(node);
    }
  }
  if (stack.length > 1) throw new XmlError(`<${stack[stack.length - 1].tag}> is never closed`, stack[stack.length - 1].line);
  const ui = root.children.find((c) => c.tag === 'Ui');
  if (!ui) throw new XmlError('no <Ui> root element', 1);
  return ui;
}

function nodeToLua(n: XmlNode): string {
  const attrs = Object.entries(n.attr).map(([k, v]) => `[${luaString(k)}]=${luaString(v)}`).join(',');
  const kids = n.children.map(nodeToLua).join(',');
  const text = n.text.trim() ? `,text=${luaString(n.text)}` : '';
  return `{tag=${luaString(n.tag)},line=${n.line},attr={${attrs}},children={${kids}}${text}}`;
}

// Never throws: parse errors come back as { error=, line= } for the runtime to report.
export function xmlToLua(src: string): string {
  try {
    return nodeToLua(parseXml(src));
  } catch (e) {
    const line = e instanceof XmlError ? e.line : 0;
    return `{error=${luaString(String((e as Error).message))},line=${line}}`;
  }
}
