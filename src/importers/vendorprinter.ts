// Builds world data from what VendorPrinter recorded in game: your professions and recipes,
// the merchants you visited and their prices, and AH listings shaped like your last scan.
import type { World } from '../core/world.ts';

type Eval = (expr: string) => { value?: any; error?: string };

export function importVendorPrinter(world: World, evalLua: Eval): { world: World; summary: string } | { error: string } {
  const db = evalLua('VendorPrinterDB').value;
  const char = evalLua('VendorPrinterCharDB').value;
  if (!db || !char) return { error: 'VendorPrinter data not loaded (enable VendorPrinter and reload).' };
  const next: World = structuredClone(world);
  let recipes = 0;

  for (const [profName, prof] of Object.entries<any>(char.professions ?? {})) {
    const target = next.professions[profName] ?? { skillLevel: 1, maxSkillLevel: 300, recipes: {} };
    for (const [id, r] of Object.entries<any>(prof.recipes ?? {})) {
      target.recipes[id] = {
        name: r.name, learned: !!r.learned, output: r.output, qmin: r.qmin, qmax: r.qmax, source: r.source,
        reagents: (r.reagents ?? []).map((slot: any) => ({ id: slot.ids?.[0], qty: slot.qty })).filter((x: any) => x.id),
      };
      // Crafted items are usually named like their recipe.
      if (r.output && !next.items[r.output]) next.items[r.output] = { name: r.name, quality: 1, stack: 20, classID: 0 };
      recipes++;
    }
    next.professions[profName] = target;
  }

  const byVendor = new Map<string, { zone: string; items: World['merchants'][number]['items'] }>();
  for (const [id, unit] of Object.entries<number>(db.vendor ?? {})) {
    const src = db.vendorSource?.[id] ?? { npc: 'Vendor', zone: '' };
    const key = src.npc;
    if (!byVendor.has(key)) byVendor.set(key, { zone: src.zone ?? '', items: [] });
    byVendor.get(key)!.items.push({ id: Number(id), price: Math.max(1, Math.round(unit)), stack: 1, available: db.vendorLimited?.[id] ? 5 : -1 });
  }
  const merchants = [...byVendor].map(([name, v]) => ({ name, zone: v.zone, items: v.items.sort((a, b) => a.id - b.id) }));
  next.merchants = [...merchants, ...next.merchants.filter((m) => !byVendor.has(m.name))];

  let listings = 0;
  for (const [id, min] of Object.entries<number>(db.ahMin ?? {})) {
    const avg = db.ah?.[id] ?? min;
    const listed = Math.max(1, db.ahListed?.[id] ?? 20);
    const rows: [number, number][] = [];
    if (Math.round(avg) <= Math.round(min)) rows.push([Math.round(min), listed]);
    else {
      const first = Math.max(1, Math.round(listed * 0.1));
      const second = Math.max(1, Math.round(listed * 0.3));
      rows.push([Math.round(min), first], [Math.round(avg), second]);
      if (listed > first + second) rows.push([Math.round(avg * 1.15), listed - first - second]);
    }
    next.auctions[id] = rows;
    listings += rows.length;
  }
  return {
    world: next,
    summary: `${recipes} recipes, ${merchants.length} merchants, ${Object.keys(db.ahMin ?? {}).length} AH items (${listings} listings)`,
  };
}
