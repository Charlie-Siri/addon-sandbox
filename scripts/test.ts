// npm test: parser and load-order checks, runtime self-tests (tests/runtime.test.lua), XML loading, integration runs
// of VendorPrinter when it's installed, the use case runner, spells and auras, and every use case in profile/usecases.
// Writes nothing.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { Sandbox, type AddonBundle } from '../src/core/sandbox.ts';
import { parseToc } from '../src/core/toc.ts';
import { xmlToLua, parseXml } from '../src/core/xml.ts';
import { toLua } from '../src/core/lua.ts';
import { resolveLoadOrder } from '../src/core/loadorder.ts';
import { defaultWorld } from '../src/core/world.ts';
import { runtimeSources, nodeMetrics, loadHeadless, loadUseCaseHeadless, resolveUseCaseRef, allUseCaseRefs } from './headless.ts';
import { Runner, loadUseCase, failureReport } from '../src/core/runner.ts';
import { validateUseCase, useCaseSchema, type UseCase } from '../src/core/usecase.ts';
import { importVendorPrinter } from '../src/importers/vendorprinter.ts';

let failed = 0;
async function test(name: string, fn: () => void | Promise<void>) {
  try { await fn(); console.log(`  ok    ${name}`); }
  catch (e) { failed++; console.log(`  FAIL  ${name}\n        ${(e as Error).message.split('\n').join('\n        ')}`); }
}

function bundle(name: string, files: Record<string, string>): AddonBundle {
  const toc = parseToc(files[`${name}.toc`]);
  return { name, toc, files: Object.fromEntries(Object.entries(files).map(([p, text]) => [p.toLowerCase(), { path: p, text }])) };
}

async function session(bundles: AddonBundle[]) {
  const log = { chat: [] as string[], errors: [] as string[], warnings: [] as string[] };
  const sb = await Sandbox.create({
    runtime: runtimeSources(), metrics: nodeMetrics,
    callbacks: {
      chat: (t) => log.chat.push(t), error: (m, s) => log.errors.push(`${m}\n${s.split('\n').slice(0, 4).join('\n')}`),
      warn: (m) => log.warnings.push(m), missing: () => {}, event: () => {}, sound: () => {}, reload: () => {},
      fstack: () => {}, etrace: () => {}, openChat: () => {}, insertChat: () => false,
    },
  });
  sb.setScreen(1365, 768, 1920, 1080);
  sb.setWorld(defaultWorld({ name: 'Tester-Forever', realm: '0' }));
  sb.loadAddons(bundles, {}, [], false);
  return { sb, log };
}

console.log('Parsers');
await test('TOC metadata, files and conditions', () => {
  const t = parseToc('## Interface: 16001\n## Title: |cff00ff00Demo|r\n## SavedVariables: A, B\n## Dependencies: Lib\n# comment\nCore.lua\nsub\\File.lua\n[AllowLoadGameType mainline]Retail.lua\nLocales\\[Family].lua\n');
  assert.equal(t.interface, '16001');
  assert.equal(t.title, 'Demo');
  assert.deepEqual(t.savedVariables, ['A', 'B']);
  assert.deepEqual(t.deps, ['Lib']);
  assert.deepEqual(t.files, ['Core.lua', 'sub/File.lua', 'Retail.lua', 'Locales/Mainline.lua']);
});
await test('XML elements, entities, CDATA and line numbers', () => {
  const ui = parseXml('<Ui>\n<!-- c -->\n<Frame name="A&amp;B">\n<Scripts><OnLoad><![CDATA[x = 1 < 2]]></OnLoad></Scripts>\n</Frame>\n</Ui>');
  const frame = ui.children[0];
  assert.equal(frame.attr.name, 'A&B');
  assert.equal(frame.line, 3);
  assert.equal(frame.children[0].children[0].text, 'x = 1 < 2');
  assert.match(xmlToLua('<Ui><Frame></Ui>'), /error=/);
});
await test('JSON to Lua literals', () => {
  assert.equal(toLua({ 2589: 'a', name: 'q"\n', list: [1, true] }), '{[2589]="a",["name"]="q\\"\\n",["list"]={1,true}}');
});
await test('load order: dependencies first, alphabetical otherwise', () => {
  const { order, missing } = resolveLoadOrder(['Zeta', 'Alpha'], [
    { name: 'Alpha', deps: ['Lib'], optDeps: [] }, { name: 'Lib', deps: [], optDeps: [] },
    { name: 'Zeta', deps: ['Gone'], optDeps: ['Alpha'] },
  ]);
  assert.deepEqual(order, ['Lib', 'Alpha', 'Zeta']);
  assert.deepEqual(missing, ['Gone (required by Zeta)']);
});

console.log('Runtime');
await test('runtime self-tests (tests/runtime.test.lua)', async () => {
  const src = fs.readFileSync(new URL('../tests/runtime.test.lua', import.meta.url), 'utf8');
  const { sb, log } = await session([bundle('RuntimeTests', { 'RuntimeTests.toc': '## Interface: 16001\nruntime.test.lua\n', 'runtime.test.lua': src })]);
  sb.close();
  assert.deepEqual(log.errors, []);
  const done = log.chat.find((l) => l.startsWith('SANDBOX_TESTS_PASSED'));
  assert.ok(done, 'self-tests did not finish');
  console.log(`        ${done.replace('SANDBOX_TESTS_PASSED', 'passed:')}`);
});
await test('XML frames: templates, inherits, parentKey, anchors, OnLoad order', async () => {
  const xml = `<Ui>
  <Script file="Pre.lua"/>
  <Frame name="DemoRowTemplate" virtual="true">
    <Size x="100" y="20"/>
    <Layers><Layer level="OVERLAY"><FontString parentKey="Label" inherits="GameFontNormal" text="row"><Anchors><Anchor point="LEFT"/></Anchors></FontString></Layer></Layers>
  </Frame>
  <Frame name="DemoFrame" parent="UIParent" mixin="DemoMixin">
    <Size x="300" y="200"/>
    <Anchors><Anchor point="CENTER"/></Anchors>
    <Frames>
      <Frame parentKey="First" inherits="DemoRowTemplate"><Anchors><Anchor point="TOPLEFT" relativeKey="$parent.Second" relativePoint="BOTTOMLEFT"/></Anchors></Frame>
      <Frame parentKey="Second" inherits="DemoRowTemplate"><Anchors><Anchor point="TOPLEFT"/></Anchors>
        <Scripts><OnLoad>table.insert(LoadOrder, "child")</OnLoad></Scripts></Frame>
      <Button name="$parentButton" parentKey="Go" inherits="UIPanelButtonTemplate" text="OKAY"><Size x="80" y="22"/><Anchors><Anchor point="BOTTOM"/></Anchors></Button>
    </Frames>
    <Scripts><OnLoad method="OnLoad"/></Scripts>
  </Frame>
</Ui>`;
  const pre = 'LoadOrder = {}\nDemoMixin = {}\nfunction DemoMixin:OnLoad() table.insert(LoadOrder, "parent") end\n';
  const { sb, log } = await session([bundle('XmlDemo', { 'XmlDemo.toc': '## Interface: 16001\nUI.xml\n', 'UI.xml': xml, 'Pre.lua': pre })]);
  const r = sb.eval('{ order = table.concat(LoadOrder, ","), label = DemoFrame.First.Label:GetText(), button = DemoFrameButton == DemoFrame.Go, text = DemoFrame.Go:GetText(), firstTop = DemoFrame.First:GetTop(), secondBottom = DemoFrame.Second:GetBottom() }').value;
  sb.close();
  assert.deepEqual(log.errors, []);
  assert.equal(r.order, 'child,parent');
  assert.equal(r.label, 'row');
  assert.equal(r.button, true);
  assert.equal(r.text, 'Okay');
  assert.equal(Math.round(r.firstTop), Math.round(r.secondBottom), 'deferred relativeKey anchor to a later sibling');
});

console.log('Addons');
const vpInstalled = fs.existsSync(`${process.env.SANDBOX_WOW_DIR ?? `${process.env.HOME}/Faugus/battlenet/drive_c/Program Files (x86)/World of Warcraft/_forever_`}/Interface/AddOns/VendorPrinter`);
if (!vpInstalled) console.log('  skip  VendorPrinter not installed');
else {
  await test('VendorPrinter: loads, opens its window, flags merchant flips', async () => {
    const { sandbox, log } = await loadHeadless({ addons: ['VendorPrinter'], world: defaultWorld({ name: 'Tester-Forever', realm: '0' }) });
    sandbox.advance(0.5);
    sandbox.chat('/vp');
    sandbox.advance(0.5);
    const shown = sandbox.eval('VendorPrinterFrame and VendorPrinterFrame:IsShown()').value;
    sandbox.openMerchant(1);
    sandbox.advance(0.5);
    const merchant = sandbox.eval('MerchantFrame:IsShown() and GetMerchantNumItems()').value;
    sandbox.close();
    assert.deepEqual(log.errors.map((e) => e.message), []);
    assert.equal(shown, true, '/vp opened VendorPrinterFrame');
    assert.ok(merchant > 0, 'merchant window open with items');
  });

  await test('VendorPrinter: limited-stock vendor prices stay out of reagent costs', async () => {
    const { sandbox: sb, log } = await loadHeadless({ addons: ['VendorPrinter'], world: defaultWorld({ name: 'Tester-Forever', realm: '0' }) });
    sb.advance(0.5);
    sb.run('local d = VendorPrinterDB wipe(d.vendor) wipe(d.vendorUnlimited) wipe(d.vendorLimited)');
    sb.openMerchant(1);   // Shan'ti: 2678 unlimited at 10c, 2320 limited (5 in stock) at 10c
    sb.advance(0.5);
    const d = sb.eval('{ v = VendorPrinterDB.version, u2678 = VendorPrinterDB.vendorUnlimited[2678], u2320 = VendorPrinterDB.vendorUnlimited[2320] or false, v2320 = VendorPrinterDB.vendor[2320], l2320 = VendorPrinterDB.vendorLimited[2320] }').value;
    sb.close();
    assert.deepEqual(log.errors.map((e) => e.message), []);
    assert.deepEqual(d, { v: 2, u2678: 10, u2320: false, v2320: 10, l2320: true });
  });
}

if (vpInstalled) {
  await test('VendorPrinter earnings: vendor buy, craft, AH sale by mail, vendor sale', async () => {
    const { sandbox: sb, log } = await loadHeadless({ addons: ['VendorPrinter'], world: defaultWorld({ name: 'Tester-Forever', realm: '0' }) });
    const step = (s = 1) => sb.advance(s, 0.05);
    const imported = importVendorPrinter(sb.worldJSON(), (e) => sb.eval(e));
    assert.ok(!('error' in imported), 'world import');
    if ('error' in imported) return;
    sb.setWorld(imported.world);
    sb.setWorldValue('player.money', 100000000);
    step(1);
    sb.run('VendorPrinterCharDB.ledger.lots = {}; wipe(VendorPrinterCharDB.ledger.activities)');   // start clean, keep the table the ledger holds
    // A learned recipe whose reagents one merchant sells.
    const pick = sb.eval(`(function()
      local w = SANDBOX.world
      for mi, m in ipairs(w.merchants) do
        local sold = {} for _, e in ipairs(m.items) do sold[e.id] = true end
        for name, prof in pairs(w.professions) do for id, r in pairs(prof.recipes) do
          if r.learned and #r.reagents > 0 and (r.qmin or 1) == (r.qmax or 1) then
            local ok = true for _, g in ipairs(r.reagents) do if not sold[g.id] then ok = false end end
            if ok then return { merchant = mi, recipe = id, output = r.output, reagents = r.reagents, prof = name, qty = r.qmin or 1 } end
          end end end
      end end)()`).value;
    assert.ok(pick, 'a craftable recipe from vendor reagents');
    sb.chat('/vp report');   // opens the window; it must survive the updates below
    const before = sb.eval('#VendorPrinterCharDB.ledger.tx').value ?? 0;
    sb.openMerchant(pick.merchant); step(1);
    for (const g of pick.reagents) sb.run(`for i = 1, GetMerchantNumItems() do if GetMerchantItemID(i) == ${g.id} then BuyMerchantItem(i, ${g.qty * 4}) end end`);
    step(2); sb.closeMerchant();
    sb.openProfession(pick.prof); step(1);
    sb.run(`C_TradeSkillUI.CraftRecipe(${pick.recipe}, 4)`); step(4); sb.closeProfession();
    sb.openAH(); step(1);
    sb.sellOnAH(pick.output, pick.qty * 2, 5000, 0.5); step(2); sb.closeAH();
    sb.openMail(); step(1); sb.run('TakeInboxMoney(1)'); step(2); sb.closeMail();
    sb.openMerchant(pick.merchant); step(1);
    sb.run(`for bag = 0, 5 do for slot = 1, C_Container.GetContainerNumSlots(bag) do if C_Container.GetContainerItemID(bag, slot) == ${pick.output} then C_Container.UseContainerItem(bag, slot) return end end end`);
    step(2); sb.closeMerchant();
    const L = sb.eval('VendorPrinterCharDB.ledger').value;
    sb.close();
    assert.deepEqual(log.errors.map((e) => e.message), []);
    const tx = L.tx.slice(before);
    const kinds = tx.map((t: any) => t.k).join(',');
    assert.equal(tx.filter((t: any) => t.k === 'buy').length, pick.reagents.length, `vendor buys recorded (${kinds})`);
    assert.equal(tx.filter((t: any) => t.k === 'craft').length, 4, `4 crafts recorded (${kinds})`);
    const sales = tx.filter((t: any) => t.k === 'sell' && !t.u);
    assert.equal(sales.length, 2, `AH and vendor sales recorded (${kinds})`);
    const ah = L.activities.craftAH;
    assert.ok(ah && ah.units === pick.qty * 2, 'AH sale counted under craftAH');
    assert.equal(Math.round(ah.revenue), Math.round(pick.qty * 2 * 5000 * 0.95), 'AH revenue = sale minus 5% cut');
    for (const a of Object.values<any>(L.activities)) assert.ok(Math.abs(a.revenue - a.cost - a.profit) < 0.01, 'profit = revenue - cost');
    const bought = tx.filter((t: any) => t.k === 'buy').reduce((n: number, t: any) => n + t.m, 0);
    const costs = Object.values<any>(L.activities).reduce((n: number, a: any) => n + a.cost, 0);
    assert.ok(Math.abs(bought - costs) < 0.01, `every reagent copper ends up as cost of a sale (${bought} vs ${costs})`);
  });
}

if (vpInstalled) {
  await test('VendorPrinter where to buy: QuestieDB vendors, faction filter, unpriced first', async () => {
    const { sandbox: sb, log } = await loadHeadless({ addons: ['VendorPrinter'], world: defaultWorld({ name: 'Tester-Forever', realm: '0' }) });
    sb.advance(0.5);
    sb.chat('/vp vendors');
    sb.advance(0.3);
    const withoutDb = JSON.parse(sb.render()).items.some((i: any) => (i.t ?? '').includes('Needs QuestieDB'));
    sb.chat('/vp vendors');
    // Stand-in for QuestieDB's read API (the real one needs C_EncodingUtil, which the sandbox lacks).
    const ids = sb.eval(`(function()
      local db, unpriced, ahOnly = VendorPrinterDB
      for _, p in pairs(VendorPrinterCharDB.professions) do for _, r in pairs(p.recipes) do for _, s in ipairs(r.reagents) do
        local id = s.ids[1]
        if not db.vendor[id] then if db.ah[id] then ahOnly = ahOnly or id else unpriced = unpriced or id end end
      end end end
      local npcs = {
        [9001] = { name = "Alliance Vendor", friendlyToFaction = "A", zoneID = 1637, spawns = { [1637] = { { 40, 50 } } } },
        [9002] = { name = "Testy Vendor", subName = "Trade Supplies", friendlyToFaction = "AH", zoneID = 1637, spawns = { [1637] = { { 55.2, 60.7 } } } },
        [9003] = { name = "Other Vendor", friendlyToFaction = "H", zoneID = 14, spawns = { [14] = { { 10, 20 } } } },
      }
      ItemDB = { Get = function(id, key) if key ~= "vendors" then return nil end
        if id == unpriced then return { 9001, 9002 } elseif id == ahOnly then return { 9003 } end end }
      NpcDB = { Get = function(id, key) return npcs[id] and npcs[id][key] end }
      return { unpriced = unpriced, ahOnly = ahOnly }
    end)()`).value;
    assert.ok(ids?.unpriced && ids?.ahOnly, 'user data has an unpriced and an AH-only reagent');
    sb.chat('/vp vendors');
    sb.advance(0.3);
    const texts = JSON.parse(sb.render()).items.map((i: any) => i.t ?? '').join('\n');
    sb.run('local sc = select(1, VendorPrinterSourcesFrame:GetChildren()) for _, c in ipairs({ VendorPrinterSourcesFrame:GetChildren() }) do if c.GetScrollChild then sc = c:GetScrollChild() end end local first = select(1, sc:GetChildren()) first:Click()');
    sb.close();
    assert.deepEqual(log.errors.map((e) => e.message), []);
    assert.ok(withoutDb, 'explains that QuestieDB is needed');
    assert.ok(texts.includes('Testy Vendor') && texts.includes('Other Vendor'), 'friendly vendors listed');
    assert.ok(!texts.includes('Alliance Vendor'), 'other-faction vendors filtered out');
    assert.ok(texts.indexOf('Testy Vendor') < texts.indexOf('Other Vendor'), 'unpriced reagent listed first');
    assert.ok(log.chat.some((l) => l.includes('from Testy Vendor in zone 1637 (55, 61)')), 'click prints where to buy');
  });
}

if (vpInstalled) {
  await test('VendorPrinter column sort (asc, desc, off) and flips at unvisited vendors', async () => {
    const { sandbox: sb, log } = await loadHeadless({ addons: ['VendorPrinter'], world: defaultWorld({ name: 'Tester-Forever', realm: '0' }) });
    sb.advance(0.5);
    sb.run('VendorPrinterDB.settings.tab = "vendor"; VendorPrinterDB.settings.sorts = {}');
    sb.chat('/vp');
    sb.advance(0.5);
    // Visible rows' data in screen order, and a header button by its label.
    const helpers = `local function Rows() local out = {} for _, c in ipairs({ VendorPrinterFrame:GetChildren() }) do if c.GetScrollChild then
        for _, r in ipairs({ c:GetScrollChild():GetChildren() }) do if r:IsShown() and r.data then out[#out + 1] = r.data end end end end return out end
      local function Header(label) for _, c in ipairs({ VendorPrinterFrame:GetChildren() }) do if c.SetLabel then
        for _, rg in ipairs({ c:GetRegions() }) do if rg.GetText and rg:GetText() == label then return c end end end end end`;
    const profits = (clicks: number) => sb.eval(`(function() ${helpers}
        for i = 1, ${clicks} do Header("Profit"):Click() end
        local out = {} for i, d in ipairs(Rows()) do if i > 8 then break end out[i] = d.profit or false end return out end)()`).value as (number | false)[];
    const firstName = () => sb.eval(`(function() ${helpers} return Rows()[1].recipe.name end)()`).value;
    const offOrder = firstName();
    const asc = profits(1);
    const desc = profits(1);
    const off = profits(1);
    const nums = (a: (number | false)[]) => a.filter((x): x is number => x !== false);
    assert.deepEqual(nums(asc), [...nums(asc)].sort((x, y) => x - y), 'ascending after one click');
    assert.deepEqual(nums(desc), [...nums(desc)].sort((x, y) => y - x), 'descending after two clicks');
    assert.equal(firstName(), offOrder, 'third click restores the default order');
    assert.ok(off.length > 0);
    assert.deepEqual(sb.eval('VendorPrinterDB.settings.sorts.vendor').value ?? {}, {}, 'sort state saved per tab, cleared when off');

    // Flips: an AH item no visited vendor sells, profitable at 4x its sell price, sold by a QuestieDB vendor.
    const pick = sb.eval(`(function() local db = VendorPrinterDB
        for id, min in pairs(db.ahMin) do if not db.vendor[id] then local sell = select(11, GetItemInfo(id))
          if sell and sell > 0 and min * 0.95 > sell * 4 + 1 then return { id = id, sell = sell } end end end end)()`).value;
    sb.advance(0.3);
    const pick2 = pick ?? sb.eval(`(function() local db = VendorPrinterDB
        for id, min in pairs(db.ahMin) do if not db.vendor[id] then local sell = select(11, GetItemInfo(id))
          if sell and sell > 0 and min * 0.95 > sell * 4 + 1 then return { id = id, sell = sell } end end end end)()`).value;
    assert.ok(pick2, 'found an AH item that would flip from a vendor');
    sb.run(`ItemDB = { Get = function(id, key) if key == "vendors" and id == ${pick2.id} then return { 9100 } end end }
      NpcDB = { Get = function(id, key) return ({ name = "Faraway Vendor", friendlyToFaction = "H", zoneID = 14, spawns = { [14] = { { 33, 44 } } } })[key] end }`);
    sb.run('VendorPrinterDB.settings.tab = "flips"; VendorPrinterFrame:Hide(); VendorPrinterFrame:Show()');
    sb.advance(3);
    sb.run('VendorPrinterFrame:Hide(); VendorPrinterFrame:Show()');
    sb.advance(0.5);
    const flip = sb.eval(`(function() ${helpers} for _, d in ipairs(Rows()) do if d.itemID == ${pick2.id} then return d end end end)()`).value;
    sb.run('VendorPrinterDB.settings.flipsUnvisited = false; VendorPrinterFrame:Hide(); VendorPrinterFrame:Show()');
    sb.advance(0.5);
    const hidden = sb.eval(`(function() ${helpers} for _, d in ipairs(Rows()) do if d.itemID == ${pick2.id} then return true end end return false end)()`).value;
    sb.close();
    assert.deepEqual(log.errors.map((e) => e.message), []);
    assert.ok(flip, 'unvisited-vendor flip listed');
    assert.equal(flip.estimated, true);
    assert.equal(flip.buy, pick2.sell * 4, 'estimated at 4x the sell price');
    assert.equal(flip.source.npc, 'Faraway Vendor');
    assert.equal(hidden, false, 'Unvisited vendors off hides it');
  });
}

if (vpInstalled) {
  await test('VendorPrinter bulk buy: Alt+click, 199 units in stacks of 20, stops at vendor stock', async () => {
    const { sandbox: sb, log } = await loadHeadless({ addons: ['VendorPrinter'], world: defaultWorld({ name: 'Tester-Forever', realm: '0' }) });
    sb.setWorldValue('items.2678.stack', 20);           // Mild Spices: 20 per purchase
    sb.setWorldValue('client.itemsCached', true);
    sb.advance(0.5);
    sb.openMerchant(1);                                  // Shan'ti: Mild Spices 10c (slot 1), limited item (slot 4, 5 left)
    sb.advance(0.5);
    const altClick = (slot: number) => sb.run(`local b = MerchantItem${slot}ItemButton local x, y = b:GetCenter()
      SANDBOX.MouseMove(x, SANDBOX.screenH - y) SANDBOX.MouseDown("LeftButton", false, false, true) SANDBOX.MouseUp("LeftButton", false, false, true)`);
    const before = sb.eval('{ count = GetItemCount(2678), money = GetMoney() }').value;
    altClick(1);
    const shown = sb.eval('VendorPrinterBulkBuy and VendorPrinterBulkBuy:IsShown()').value;
    sb.run('local d = VendorPrinterBulkBuy for _, c in ipairs({ d:GetChildren() }) do if c.SetNumeric then c:SetText("199") end end');
    sb.run('local d = VendorPrinterBulkBuy for _, c in ipairs({ d:GetChildren() }) do if c.GetText and c:GetText() == "Buy" then c:Click() end end');
    sb.advance(5);
    const after = sb.eval('{ count = GetItemCount(2678), money = GetMoney() }').value;
    // Limited stock: ask for 20, the vendor has 5.
    altClick(4);
    sb.run('local d = VendorPrinterBulkBuy for _, c in ipairs({ d:GetChildren() }) do if c.SetNumeric then c:SetText("20") end end');
    sb.run('local d = VendorPrinterBulkBuy for _, c in ipairs({ d:GetChildren() }) do if c.GetText and c:GetText() == "Buy" then c:Click() end end');
    sb.advance(5);
    const limited = sb.eval('GetItemCount(2320)').value;
    sb.close();
    assert.deepEqual(log.errors.map((e) => e.message), []);
    assert.equal(shown, true, 'Alt+click opens the amount box');
    assert.equal(after.count - before.count, 199, '199 units arrived');
    assert.equal(before.money - after.money, 1990, 'paid 199 x 10c');
    assert.ok(log.chat.some((l) => l.includes('Bought 199x') && l.includes('in 10 purchases')), 'summary: 10 purchases');
    assert.equal(limited, 5, 'limited stock: bought what the vendor had');
    assert.ok(log.chat.some((l) => l.includes('Bought 5x') && l.includes('vendor sold out')), 'says why it stopped');
  });
}

console.log('Use cases');
// A tiny addon the use case tests drive: a window with a button, a tooltip, an edit box, a slash command and a timer.
const DEMO_LUA = `
local f = CreateFrame("Frame", "DemoWindow", UIParent, "BasicFrameTemplateWithInset")
f:SetSize(300, 200) f:SetPoint("CENTER") f:Hide()
f:SetMovable(true) f:EnableMouse(true) f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving) f:SetScript("OnDragStop", f.StopMovingOrSizing)
local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal") title:SetPoint("TOP", 0, -6) title:SetText("Demo Window")
local b = CreateFrame("Button", "DemoWindowGo", f, "UIPanelButtonTemplate")
b:SetSize(100, 24) b:SetPoint("CENTER") b:SetText("Press me")
b:SetScript("OnClick", function() DemoPresses = (DemoPresses or 0) + 1 print("Pressed " .. DemoPresses) end)
b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT") GameTooltip:AddLine("Presses the button") GameTooltip:Show() end)
b:SetScript("OnLeave", function() GameTooltip:Hide() end)
local e = CreateFrame("EditBox", "DemoWindowInput", f, "InputBoxTemplate")
e:SetSize(80, 20) e:SetPoint("BOTTOM", 0, 20) e:SetAutoFocus(false)
local later = f:CreateFontString(nil, "OVERLAY", "GameFontNormal") later:SetPoint("BOTTOM", 0, 50)
SLASH_DEMOUC1 = "/demo"
SlashCmdList.DEMOUC = function() f:Show() C_Timer.After(10, function() later:SetText("Ten seconds later") end) end
`;
const demoBundle = () => bundle('DemoUC', { 'DemoUC.toc': '## Interface: 16001\nDemo.lua\n', 'Demo.lua': DEMO_LUA });

async function runUseCase(uc: UseCase) {
  const r = await session([]);
  r.sb.close();
  let runner: Runner | null = null;
  const sb = await Sandbox.create({
    runtime: runtimeSources(), metrics: nodeMetrics,
    callbacks: { chat: (t) => runner?.onChat(t), error: (m, st) => runner?.onError(m, st), warn: () => {}, missing: () => {}, event: () => {},
      sound: () => {}, reload: () => {}, fstack: () => {}, etrace: () => {}, openChat: () => {}, insertChat: () => false },
  });
  sb.setScreen(1365, 768, 1920, 1080);
  runner = new Runner({ id: 'Demo/test', useCase: uc, sandbox: sb });
  loadUseCase(sb, { id: 'Demo/test', addon: 'DemoUC', name: 'test', useCase: uc, world: defaultWorld(null), savedVariables: {}, errors: [] }, [demoBundle()], []);
  runner.fastForward();
  return runner;
}

await test('schema file is current (npm run schema)', () => {
  const onDisk = fs.readFileSync(new URL('../docs/usecase.schema.json', import.meta.url), 'utf8');
  assert.equal(onDisk, JSON.stringify(useCaseSchema(), null, 2) + '\n', 'docs/usecase.schema.json is stale: run npm run schema');
});
await test('validation names the problem', () => {
  assert.deepEqual(validateUseCase({ title: 'x', addons: ['A'], steps: [{ say: 'hi' }] }), []);
  const errs = validateUseCase({ title: '', addons: [], steps: [{ click: { text: 'a' }, hover: { text: 'b' } }, { click: { txt: 'a' } }, { wait: { for: { nope: 1 } } }, { key: 'enter' }] });
  const joined = errs.join('\n');
  for (const want of ['title: required', 'addons: required', 'one action per step', 'exactly one of text, frame, path or point', 'unknown check "nope"', 'steps[3].key']) {
    assert.ok(joined.includes(want), `missing "${want}" in:\n${joined}`);
  }
});
await test('runner: slash, click, hover + tooltip, type, drag, waits, checks', async () => {
  const r = await runUseCase({ title: 'Demo', addons: ['DemoUC'], setup: { wait: 1 }, steps: [
    { slash: '/demo', say: 'Open the demo.' },
    { expect: { shown: { text: 'Demo Window' } } },
    { hover: { text: 'Press me' } },
    { expect: { tooltip: 'Presses the button' } },
    { click: { text: 'Press me' } },
    { click: { text: 'Press me' }, double: true },
    { expect: { lua: 'DemoPresses', equals: 3 } },
    { expect: { chat: 'Pressed 3' } },
    { click: { frame: 'DemoWindowInput' } },
    { type: 'abc' },
    { expect: { lua: 'DemoWindowInput:GetText()', equals: 'abc' } },
    { run: 'DemoLeft0, DemoTop0 = DemoWindow:GetLeft(), DemoWindow:GetTop()' },
    { drag: { text: 'Demo Window' }, to: { dx: 100, dy: 50 } },
    { expect: { lua: 'DemoWindow:GetLeft() - DemoLeft0 > 95 and DemoTop0 - DemoWindow:GetTop() > 45' } },
    { wait: { for: { shown: { text: 'Ten seconds later' } }, timeout: 20 } },
    { wait: 60 },
    { expect: { noErrors: true, hidden: { text: 'Not on screen' } } },
  ] });
  assert.equal(r.failure, null, r.failure ? `step ${r.failure.step + 1}: ${r.failure.message}` : '');
  assert.ok(r.done);
  assert.ok(r.sandboxTime > r.displayTime + 50, 'the 60 s wait plays compressed');
  r.sandbox.close();
});
await test('runner: a missing target fails with suggestions', async () => {
  const r = await runUseCase({ title: 'Demo', addons: ['DemoUC'], setup: { wait: 0.5 }, steps: [
    { slash: '/demo' }, { click: { text: 'Pres me' } },
  ] });
  assert.equal(r.failure?.step, 1);
  assert.match(r.failure!.message, /No visible text matches "Pres me"/);
  assert.ok(r.failure!.candidates?.includes('Press me'), `suggestions: ${r.failure!.candidates}`);
  assert.match(failureReport(r), /Visible text on screen/);
  r.sandbox.close();
});
await test('runner: unknown slash command and Lua errors fail the step', async () => {
  const a = await runUseCase({ title: 'x', addons: ['DemoUC'], setup: { wait: 0.2 }, steps: [{ slash: '/nope' }] });
  assert.match(a.failure!.message, /\/nope is not a slash command/);
  a.sandbox.close();
  const b = await runUseCase({ title: 'x', addons: ['DemoUC'], setup: { wait: 0.2 }, steps: [{ run: 'error("boom")' }] });
  assert.match(b.failure!.message, /Lua error: .*boom/);
  b.sandbox.close();
});
await test('spells and auras: cast, expiry, secure buttons, weapon enchants', async () => {
  const { sb, log } = await session([]);
  sb.run(`
    local b = CreateFrame("Button", "CastBtn", UIParent, "SecureActionButtonTemplate")
    b:SetSize(40, 40) b:SetPoint("CENTER") b:RegisterForClicks("AnyUp")
    b:SetAttribute("type1", "spell") b:SetAttribute("spell1", 9910)
    AuraEvents = 0
    local f = CreateFrame("Frame") f:RegisterUnitEvent("UNIT_AURA", "player") f:SetScript("OnEvent", function() AuraEvents = AuraEvents + 1 end)
  `);
  sb.advance(0.1);
  const before = sb.eval('{ known = IsSpellKnown(9885), unknown = IsSpellKnown(21849), name = C_Spell.GetSpellName(9885), aura = C_UnitAuras.GetPlayerAuraBySpellID(9910) ~= nil }').value;
  sb.mouseMove(683, 384); sb.mouseDown('LeftButton'); sb.mouseUp('LeftButton');
  const cast = sb.eval('{ name = (UnitAura("player", 1)), left = C_UnitAuras.GetAuraDataByIndex("player", 1).expirationTime - GetTime(), events = AuraEvents }').value;
  sb.advance(601, 1);
  const expired = sb.eval('{ aura = C_UnitAuras.GetPlayerAuraBySpellID(9910) ~= nil, events = AuraEvents }').value;
  sb.setWorldValue('equipment', { 16: 2589 });
  sb.setWorldValue('items.2589.use', { enchant: { duration: 1800, charges: 0, id: 7 } });
  sb.run('SANDBOX.RunMacroText("/use item:2589\\n/use 16")');
  const ench = sb.eval('{ GetWeaponEnchantInfo() }').value;
  sb.close();
  assert.deepEqual(log.errors, []);
  assert.deepEqual(before, { known: true, unknown: false, name: 'Mark of the Wild', aura: false });
  assert.equal(cast.name, 'Thorns');
  assert.ok(cast.left > 599 && cast.left <= 600, `remaining ${cast.left}`);
  assert.ok(cast.events >= 1, 'UNIT_AURA fired');
  assert.equal(expired.aura, false, 'Thorns ran out after 10 min');
  assert.ok(expired.events > cast.events, 'UNIT_AURA fired on expiry');
  assert.equal(ench[0], true, 'main hand enchanted');
  assert.ok(ench[1] > 1790000, `enchant ms ${ench[1]}`);
});
const ucRefs = allUseCaseRefs();
for (const ref of ucRefs) {
  await test(`use case ${ref}`, async () => {
    const resolved = resolveUseCaseRef(ref);
    const { runner, errors } = await loadUseCaseHeadless(resolved);
    assert.deepEqual(errors, []);
    runner.fastForward();
    const f = runner.failure;
    runner.sandbox.close();
    assert.equal(f, null, f ? `step ${f.step + 1}: ${f.message}` : '');
  });
}
if (!ucRefs.length) console.log('  skip  no use cases in profile/usecases');

console.log(failed ? `\n${failed} test(s) failed` : '\nAll tests passed');
process.exitCode = failed ? 1 : 0;
