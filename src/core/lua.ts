// JS values -> Lua source literals (how structured data crosses into the VM).

// Lua string literal; control characters as 3-digit escapes so a following digit can't extend them.
export function luaString(s: string): string {
  return '"' + s.replace(/[\\"\x00-\x1f\x7f]/g, (c) => {
    if (c === '\\') return '\\\\';
    if (c === '"') return '\\"';
    if (c === '\n') return '\\n';
    if (c === '\r') return '\\r';
    if (c === '\t') return '\\t';
    return '\\' + c.charCodeAt(0).toString().padStart(3, '0');
  }) + '"';
}

// JSON-like value -> Lua literal. Object keys that look like integers become numeric keys ({"2589": x} -> {[2589]=x}).
export function toLua(value: unknown): string {
  if (value === null || value === undefined) return 'nil';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') return Number.isFinite(value) ? String(value) : '0';
  if (typeof value === 'string') return luaString(value);
  if (Array.isArray(value)) return '{' + value.map(toLua).join(',') + '}';
  if (typeof value === 'object') {
    const parts: string[] = [];
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (v === undefined) continue;
      const key = /^-?\d+$/.test(k) && Math.abs(Number(k)) < 2 ** 53 ? `[${k}]` : `[${luaString(k)}]`;
      parts.push(`${key}=${toLua(v)}`);
    }
    return '{' + parts.join(',') + '}';
  }
  return 'nil';
}
