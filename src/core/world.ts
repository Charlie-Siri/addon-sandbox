// The fake game world the API mocks read: player, items, bags, merchants, AH listings, loot, professions.
// The dev panel edits it; it persists as profile/world.json.
export interface WorldItem { name: string; quality?: number; sellPrice?: number; icon?: number; stack?: number; classID?: number; reagent?: boolean }
export interface World {
  client: { version: string; build: string; interface: number; locale: string; itemsCached?: boolean; itemLoadDelay?: number; autoLoot?: boolean; ahNoThrottle?: boolean };
  player: { name: string; realm: string; class: string; race: string; faction: string; level: number; money: number; zone: string; subZone: string; inCombat: boolean; guid?: string };
  target?: { name: string; level: number } | null;
  items: Record<string, WorldItem>;
  bags: Record<string, { size: number; slots: Record<string, { id: number; count: number }> }>;
  merchants: { name: string; zone?: string; items: { id: number; price: number; stack?: number; available?: number }[] }[];
  auctions: Record<string, [number, number][]>;   // itemID -> [unitPrice, quantity][]
  loot: { name: string; money?: number; items: { id: number; count?: number }[] }[];
  mail?: { sender: string; subject: string; money?: number; items?: { id: number; count?: number }[];
    invoice?: { type: string; item: string; buyer?: string; bid: number; buyout?: number; deposit?: number; consignment?: number; count?: number } }[];
  professions: Record<string, { skillLevel: number; maxSkillLevel: number; skillLineID?: number; recipes: Record<string, {
    name: string; learned: boolean; output: number; qmin?: number; qmax?: number; reagents: { id: number; qty: number }[]; source?: string;
  }> }>;
  // Spells the player knows (known: false = exists for names only). aura = seconds the buff lasts when cast (0 = no expiry).
  spells?: Record<string, { name: string; icon?: number; aura?: number; known?: boolean }>;
  // Buffs on the player; remaining counts down while the sandbox runs.
  auras?: { spellId: number; name?: string; icon?: number; duration?: number; remaining: number; count?: number }[];
  equipment?: Record<string, number>;   // inventory slot (16 main hand, 17 off hand) -> itemID
  weaponEnchants?: Record<string, { remaining: number; charges?: number; id?: number }>;
}

// A level 60 druid's buff spells (all ranks known, the way the client reports them).
function druidSpells(): NonNullable<World['spells']> {
  const out: NonNullable<World['spells']> = {};
  for (const id of [1126, 5232, 6756, 5234, 8907, 9884, 9885]) out[id] = { name: 'Mark of the Wild', icon: 136078, aura: 1800 };
  for (const id of [467, 782, 1075, 8914, 9756, 9910]) out[id] = { name: 'Thorns', icon: 136104, aura: 600 };
  for (const id of [21849, 21850]) out[id] = { name: 'Gift of the Wild', icon: 136038, aura: 3600, known: false };
  return out;
}

// Client facts from .build.info on this machine (1.60.1.70888); interface 16001 is the community-reported value.
export function defaultWorld(character?: { name: string; realm: string } | null): World {
  const [name, realm] = character ? splitName(character.name) : ['Sandbox', 'Forever'];
  return {
    client: { version: '1.60.1', build: '70888', interface: 16001, locale: 'enUS', itemLoadDelay: 0.05 },
    player: { name, realm, class: 'DRUID', race: 'Tauren', faction: 'Horde', level: 60, money: 1234567, zone: 'Orgrimmar',
      subZone: 'The Drag', inCombat: false },
    target: null,
    items: {
      2589: { name: 'Linen Cloth', quality: 1, sellPrice: 13, icon: 132889, stack: 200, classID: 7 },
      2592: { name: 'Wool Cloth', quality: 1, sellPrice: 33, icon: 132911, stack: 200, classID: 7 },
      2678: { name: 'Mild Spices', quality: 1, sellPrice: 0, icon: 133938, stack: 200, classID: 7 },
      2672: { name: 'Stringy Wolf Meat', quality: 1, sellPrice: 4, icon: 133970, stack: 200, classID: 7 },
      2680: { name: 'Spiced Wolf Meat', quality: 1, sellPrice: 10, icon: 133974, stack: 200, classID: 0 },
      2770: { name: 'Copper Ore', quality: 1, sellPrice: 5, icon: 134566, stack: 200, classID: 7 },
      2840: { name: 'Copper Bar', quality: 1, sellPrice: 10, icon: 133217, stack: 200, classID: 7 },
      4306: { name: 'Silk Cloth', quality: 1, sellPrice: 150, icon: 132905, stack: 200, classID: 7 },
      6948: { name: 'Hearthstone', quality: 1, sellPrice: 0, icon: 134414, stack: 1, classID: 15 },
    },
    bags: {
      0: { size: 16, slots: { 1: { id: 6948, count: 1 }, 2: { id: 2589, count: 37 }, 3: { id: 2672, count: 8 } } },
      1: { size: 12, slots: {} },
    },
    merchants: [
      { name: 'Shan\'ti', zone: 'Orgrimmar', items: [
        { id: 2678, price: 10, stack: 1 },
        { id: 159, price: 25, stack: 1 },
        { id: 30817, price: 25, stack: 1 },
        { id: 2320, price: 10, stack: 1, available: 5 },
      ] },
    ],
    auctions: {
      2589: [[22, 40], [25, 200], [30, 120]],
      2592: [[60, 80], [64, 200]],
      2770: [[45, 20], [50, 100]],
      2840: [[70, 60]],
      4306: [[180, 40], [200, 200]],
    },
    mail: [],
    loot: [
      { name: 'Wolf', money: 1234, items: [{ id: 2672, count: 2 }, { id: 2589, count: 3 }] },
      { name: 'Treasure chest', money: 54321, items: [{ id: 4306, count: 12 }, { id: 2770, count: 6 }] },
    ],
    spells: druidSpells(),
    auras: [],
    professions: {
      Cooking: { skillLevel: 75, maxSkillLevel: 150, skillLineID: 185, recipes: {
        2538: { name: 'Charred Wolf Meat', learned: true, output: 2679, reagents: [{ id: 2672, qty: 1 }] },
        2539: { name: 'Spiced Wolf Meat', learned: true, output: 2680, reagents: [{ id: 2672, qty: 1 }, { id: 2678, qty: 1 }] },
      } },
    },
  };
}

// WTF character folders are "Name-Realm"; realm may itself contain dashes.
function splitName(folder: string): [string, string] {
  const i = folder.indexOf('-');
  return i === -1 ? [folder, 'Forever'] : [folder.slice(0, i), folder.slice(i + 1)];
}
