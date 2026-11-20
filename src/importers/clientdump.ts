// Merges SandboxDump's in-game export into the world: real item data and the client build.
import type { World } from '../core/world.ts';

export function importClientDump(world: World, db: any): { world: World; summary: string } | { error: string } {
  if (!db || typeof db !== 'object') return { error: 'SandboxDump data is empty.' };
  const next: World = structuredClone(world);
  let items = 0;
  for (const [id, it] of Object.entries<any>(db.items ?? {})) {
    if (!it?.name) continue;
    next.items[id] = {
      name: it.name, quality: it.quality, sellPrice: it.sellPrice, icon: it.icon, stack: it.stack,
      classID: it.classID, reagent: it.reagent ?? undefined,
    };
    items++;
  }
  const b = db.build;
  if (b) {
    next.client.version = b.version ?? next.client.version;
    next.client.build = String(b.build ?? next.client.build);
    next.client.interface = Number(b.interface) || next.client.interface;
  }
  const fns = Array.isArray(db.functions) ? db.functions.length : 0;
  return {
    world: next,
    summary: `${items} items${b ? `, client ${b.version} (${b.build}), interface ${b.interface}` : ''}${fns ? `, ${fns} API functions recorded` : ''}`,
  };
}
