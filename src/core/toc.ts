// TOC parser: "## Key: Value" metadata plus the ordered file list.
export interface TocInfo {
  meta: Record<string, string>;   // every "## Key: Value" line, keys as written
  title: string;
  interface: string;
  version: string;
  notes: string;
  deps: string[];                 // RequiredDeps / Dependencies / Dep*
  optDeps: string[];
  savedVariables: string[];
  savedVariablesPerCharacter: string[];
  loadOnDemand: boolean;
  files: string[];                // forward slashes, as written (case preserved)
}

const list = (v: string | undefined) => (v ?? '').split(',').map((s) => s.trim()).filter(Boolean);

// [Family] / [Game] variables in file paths. shortcut: fixed to the retail values; confirm Forever's in Phase 0.
const TOC_VARIABLES: Record<string, string> = { family: 'Mainline', game: 'Standard', textlocale: 'enUS' };

export function parseToc(text: string): TocInfo {
  const meta: Record<string, string> = {};
  const files: string[] = [];
  for (const raw of text.replace(/^﻿/, '').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith('##')) {
      const m = line.match(/^##\s*([^:]+?)\s*:\s*(.*)$/);
      if (m) meta[m[1]] = m[2].trim();
      continue;
    }
    if (line.startsWith('#')) continue;
    // Strip load conditions like "[AllowLoadGameType mainline]" before the path; substitute path variables.
    const file = line
      .replace(/^\[[^\]]*\]\s*/, '')
      .replace(/\[(\w+)\]/g, (whole, name: string) => TOC_VARIABLES[name.toLowerCase()] ?? whole)
      .replace(/\\/g, '/');
    if (file) files.push(file);
  }
  const get = (key: string) => {
    const lower = key.toLowerCase();
    for (const k of Object.keys(meta)) if (k.toLowerCase() === lower) return meta[k];
    return undefined;
  };
  const deps = [...list(get('RequiredDeps')), ...list(get('Dependencies')), ...list(get('Dependancies'))];
  for (const k of Object.keys(meta)) if (/^Dep\w*$/i.test(k) && !/^Dependencies$/i.test(k)) deps.push(...list(meta[k]));
  return {
    meta,
    title: (get('Title') ?? '').replace(/\|c\w{8}|\|r/g, ''),
    interface: get('Interface') ?? '',
    version: get('Version') ?? '',
    notes: get('Notes') ?? '',
    deps: [...new Set(deps)],
    optDeps: list(get('OptionalDeps')),
    savedVariables: list(get('SavedVariables')),
    savedVariablesPerCharacter: list(get('SavedVariablesPerCharacter')),
    loadOnDemand: get('LoadOnDemand') === '1',
    files,
  };
}
