// Which addons load, in what order: the chosen ones plus their required dependencies,
// alphabetical like the client, with every dependency before its dependents.
export interface AddonDeps { name: string; deps: string[]; optDeps: string[]; loadOnDemand?: boolean }

export function resolveLoadOrder(selected: string[], installed: AddonDeps[]) {
  const byName = new Map(installed.map((a) => [a.name.toLowerCase(), a]));
  const wanted = new Set<string>();
  const missing: string[] = [];
  const want = (name: string, by?: string) => {
    const a = byName.get(name.toLowerCase());
    if (!a) { missing.push(by ? `${name} (required by ${by})` : name); return; }
    if (wanted.has(a.name)) return;
    wanted.add(a.name);
    for (const d of a.deps) want(d, a.name);
  };
  for (const s of selected) want(s);

  const order: string[] = [];
  const done = new Set<string>();
  const visiting = new Set<string>();
  const visit = (name: string) => {
    if (done.has(name) || visiting.has(name)) return;
    visiting.add(name);
    const a = byName.get(name.toLowerCase())!;
    // Optional deps that are loading anyway go first too.
    for (const d of [...a.deps, ...a.optDeps].sort()) {
      const dep = byName.get(d.toLowerCase());
      if (dep && wanted.has(dep.name)) visit(dep.name);
    }
    visiting.delete(name);
    done.add(name);
    order.push(name);
  };
  for (const name of [...wanted].sort((x, y) => x.toLowerCase().localeCompare(y.toLowerCase()))) visit(name);
  return { order, missing };
}
