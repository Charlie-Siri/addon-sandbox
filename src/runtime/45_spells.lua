-- Spells and auras: known spells, the player's buffs with real expiry, casting (CastSpellByName/ID and secure
-- action buttons), usable items that apply buffs or weapon enchants, and weapon enchants themselves.
--
-- World data (all optional):
--   spells   = { [id] = { name, icon, aura = seconds (0 = no expiry), known = false (exists but not learned) } }
--   auras    = { { spellId, name, icon, duration, remaining, count } }   remaining counts down while the sandbox runs
--   equipment = { [16] = itemID, [17] = itemID }
--   weaponEnchants = { [16] = { remaining, charges, id }, [17] = {...} }
--   items[id].use = { aura = spellId, consume = true } or { enchant = { duration, charges, id }, consume = true }
local S = SANDBOX
local host = S.host
local W = S.W

---------------------------------------------------------------------------
-- Tick hooks: run every frame after timers (S.Frame and S.Advance call them)
---------------------------------------------------------------------------
S.tickHooks = S.tickHooks or {}

---------------------------------------------------------------------------
-- Spell book
---------------------------------------------------------------------------
local function Spells() return S.world.spells or {} end

local function SpellRec(spell)
    if spell == nil then return nil end
    local id = tonumber(spell)
    local spells = Spells()
    if id then
        local r = spells[id] or spells[tostring(id)]
        if r then return r, id end
        return nil, id
    end
    local name = tostring(spell):lower()
    -- "Mark of the Wild(Rank 3)" -> name only
    name = name:gsub("%(.-%)", ""):gsub("^%s+", ""):gsub("%s+$", "")
    local best, bestId
    for k, r in pairs(spells) do
        if r.name and r.name:lower() == name then
            local kid = tonumber(k)
            -- several ranks share a name: prefer a known one with the highest id
            if not best or (r.known ~= false and (best.known == false or (kid or 0) > (bestId or 0))) then
                best, bestId = r, kid
            end
        end
    end
    return best, bestId
end
S.SpellRec = SpellRec

local function Known(spell)
    local r = SpellRec(spell)
    return r ~= nil and r.known ~= false
end

C_Spell = C_Spell or {}
local fallbackInfo = C_Spell.GetSpellInfo
function C_Spell.GetSpellInfo(spell)
    if spell == nil then return nil end
    local r, id = SpellRec(spell)
    if r then
        return { name = r.name or ("Spell " .. tostring(id)), spellID = id or 0, iconID = r.icon or 136243, castTime = 0,
            minRange = 0, maxRange = 0, originalIconID = r.icon or 136243 }
    end
    if tonumber(spell) and fallbackInfo then return fallbackInfo(spell) end
    return nil
end
function C_Spell.GetSpellName(spell)
    local info = C_Spell.GetSpellInfo(spell)
    return info and info.name
end
function C_Spell.GetSpellTexture(spell)
    local info = C_Spell.GetSpellInfo(spell)
    return info and info.iconID
end
function C_Spell.DoesSpellExist(spell) return C_Spell.GetSpellInfo(spell) ~= nil end
function GetSpellInfo(spell)
    local info = C_Spell.GetSpellInfo(spell)
    if info then return info.name, nil, info.iconID, 0, 0, 0, info.spellID end
end
function GetSpellTexture(spell) return C_Spell.GetSpellTexture(spell) end
function IsSpellKnown(id) return Known(id) end
function IsPlayerSpell(id) return Known(id) end
function IsSpellKnownOrOverridesKnown(id) return Known(id) end
C_SpellBook = C_SpellBook or {}
function C_SpellBook.IsSpellKnown(id) return Known(id) end
function C_SpellBook.IsSpellInSpellBook(id) return Known(id) end

---------------------------------------------------------------------------
-- Auras (player only; other units have none)
---------------------------------------------------------------------------
local auras = {}          -- { spellId, name, icon, duration, expires (S.now based, 0 = none), count, instance }
local nextInstance = 0
S.auraList = function() return auras end

local function IsPlayer(unit)
    return unit == nil or unit == "player" or (UnitIsUnit and UnitIsUnit(unit, "player"))
end

local function AuraUpdated()
    S.FireEvent("UNIT_AURA", "player", { isFullUpdate = true })
end

local function MakeAura(a)
    local r, id = SpellRec(a.spellId or a.name)
    nextInstance = nextInstance + 1
    local duration = tonumber(a.duration) or (r and tonumber(r.aura)) or 0
    local remaining = tonumber(a.remaining) or duration
    return {
        spellId = tonumber(a.spellId) or id or 0,
        name = a.name or (r and r.name) or ("Spell " .. tostring(a.spellId)),
        icon = a.icon or (r and r.icon) or 136243,
        duration = duration,
        expires = remaining > 0 and (S.now + remaining) or 0,
        count = tonumber(a.count) or 0,
        instance = nextInstance,
    }
end

local function RebuildAuras()
    auras = {}
    for _, a in ipairs(S.world.auras or {}) do auras[#auras + 1] = MakeAura(a) end
end

-- Keep world.auras in sync (remaining time) so the dev panel and saved world see the live state.
local function SyncWorld()
    local list = {}
    for _, a in ipairs(auras) do
        list[#list + 1] = { spellId = a.spellId, name = a.name, icon = a.icon, duration = a.duration,
            remaining = a.expires > 0 and math.max(0, math.floor((a.expires - S.now) * 10 + 0.5) / 10) or 0,
            count = a.count > 0 and a.count or nil }
    end
    S.world.auras = list
end

function S.ApplyAura(spell, remaining, quiet)
    local r, id = SpellRec(spell)
    local name = r and r.name or tostring(spell)
    for i = #auras, 1, -1 do
        if auras[i].spellId == id or auras[i].name == name then table.remove(auras, i) end
    end
    local a = MakeAura({ spellId = id, name = name, remaining = remaining })
    if remaining and (not r or not r.aura) then a.duration = remaining end
    auras[#auras + 1] = a
    SyncWorld()
    if not quiet then AuraUpdated() end
    return a
end

function S.RemoveAura(spell, quiet)
    local r, id = SpellRec(spell)
    local name = r and r.name or tostring(spell)
    local removed = false
    for i = #auras, 1, -1 do
        if auras[i].spellId == id or auras[i].name == name then table.remove(auras, i); removed = true end
    end
    if removed then SyncWorld(); if not quiet then AuraUpdated() end end
    return removed
end

-- Expire auras whose time ran out.
S.tickHooks[#S.tickHooks + 1] = function()
    local changed = false
    for i = #auras, 1, -1 do
        local a = auras[i]
        if a.expires > 0 and a.expires <= S.now then
            table.remove(auras, i)
            changed = true
        end
    end
    if changed then SyncWorld(); AuraUpdated() end
end

local function AuraData(a)
    return {
        name = a.name, icon = a.icon, applications = a.count, dispelName = nil, duration = a.duration,
        expirationTime = a.expires, sourceUnit = "player", isStealable = false, nameplateShowPersonal = false,
        spellId = a.spellId, canApplyAura = true, isBossAura = false, isFromPlayerOrPlayerPet = true,
        nameplateShowAll = false, timeMod = 1, points = {}, isHelpful = true, isHarmful = false, isRaid = false,
        isNameplateOnly = false, auraInstanceID = a.instance, charges = 1, maxCharges = 1,
    }
end

local function Helpful(filter)
    return filter == nil or filter == "" or not tostring(filter):upper():find("HARMFUL")
end

C_UnitAuras = C_UnitAuras or {}
function C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
    if not IsPlayer(unit) or not Helpful(filter) then return nil end
    local a = auras[tonumber(index) or 0]
    return a and AuraData(a) or nil
end
function C_UnitAuras.GetBuffDataByIndex(unit, index, filter) return C_UnitAuras.GetAuraDataByIndex(unit, index, filter) end
function C_UnitAuras.GetDebuffDataByIndex() return nil end
function C_UnitAuras.GetPlayerAuraBySpellID(id)
    id = tonumber(id)
    for _, a in ipairs(auras) do if a.spellId == id then return AuraData(a) end end
    return nil
end
function C_UnitAuras.GetAuraDataBySpellName(unit, name, filter)
    if not IsPlayer(unit) or not Helpful(filter) then return nil end
    for _, a in ipairs(auras) do if a.name == name then return AuraData(a) end end
    return nil
end
function C_UnitAuras.GetAuraDataByAuraInstanceID(unit, instance)
    if not IsPlayer(unit) then return nil end
    for _, a in ipairs(auras) do if a.instance == instance then return AuraData(a) end end
    return nil
end
function C_UnitAuras.GetAuraSlots(unit, filter)
    local out = { nil }
    if IsPlayer(unit) and Helpful(filter) then for i = 1, #auras do out[#out + 1] = i end end
    return unpack(out)
end
function C_UnitAuras.IsAuraFilteredOutByInstanceID() return false end
function C_UnitAuras.WantsAlteredForm() return false end

local function Classic(a)
    if not a then return nil end
    return a.name, a.icon, a.count, nil, a.duration, a.expires, "player", false, false, a.spellId, true, false, true, false, 1
end
function UnitAura(unit, index, filter)
    if not IsPlayer(unit) or not Helpful(filter) then return nil end
    return Classic(auras[tonumber(index) or 0])
end
function UnitBuff(unit, index, filter) return UnitAura(unit, index, filter) end
function UnitDebuff() return nil end

AuraUtil = AuraUtil or {}
function AuraUtil.FindAuraByName(name, unit, filter)
    if not IsPlayer(unit) or not Helpful(filter) then return nil end
    for _, a in ipairs(auras) do if a.name == name then return Classic(a) end end
end
function AuraUtil.ForEachAura(unit, filter, maxCount, func, usePackedAura)
    if not IsPlayer(unit) or not Helpful(filter) then return end
    for i, a in ipairs(auras) do
        if maxCount and i > maxCount then break end
        local stop
        if usePackedAura then stop = func(AuraData(a)) else stop = func(Classic(a)) end
        if stop then return end
    end
end

---------------------------------------------------------------------------
-- Equipment and weapon enchants
---------------------------------------------------------------------------
local enchants = {}   -- [slot] = { expires, charges, id }

local function RebuildEnchants()
    enchants = {}
    for slot, e in pairs(S.world.weaponEnchants or {}) do
        local n = tonumber(slot)
        if n and (tonumber(e.remaining) or 0) > 0 then
            enchants[n] = { expires = S.now + tonumber(e.remaining), charges = tonumber(e.charges) or 0, id = tonumber(e.id) or 0 }
        end
    end
end

local function SyncEnchants()
    local out = {}
    for slot, e in pairs(enchants) do
        out[tostring(slot)] = { remaining = math.max(0, math.floor((e.expires - S.now) * 10 + 0.5) / 10), charges = e.charges, id = e.id }
    end
    S.world.weaponEnchants = out
end

S.tickHooks[#S.tickHooks + 1] = function()
    for slot, e in pairs(enchants) do
        if e.expires <= S.now then
            enchants[slot] = nil
            SyncEnchants()
            S.FireEvent("UNIT_INVENTORY_CHANGED", "player")
        end
    end
end

local function Equipped(slot)
    local eq = S.world.equipment or {}
    return tonumber(eq[slot] or eq[tostring(slot)])
end

function GetInventoryItemID(unit, slot)
    if not IsPlayer(unit) then return nil end
    return Equipped(tonumber(slot))
end
function GetInventoryItemLink(unit, slot)
    local id = GetInventoryItemID(unit, slot)
    if id then local _, link = GetItemInfo(id) return link end
end
function GetInventoryItemTexture(unit, slot)
    local id = GetInventoryItemID(unit, slot)
    if id then return C_Item.GetItemIconByID(id) or 134400 end
end

function GetWeaponEnchantInfo()
    local function One(slot)
        local e = enchants[slot]
        if not e then return false, 0, 0, 0 end
        return true, math.max(0, math.floor((e.expires - S.now) * 1000)), e.charges, e.id
    end
    local a1, a2, a3, a4 = One(16)
    local b1, b2, b3, b4 = One(17)
    return a1, a2, a3, a4, b1, b2, b3, b4
end

function S.ApplyEnchant(slot, duration, charges, id)
    slot = tonumber(slot) or 16
    enchants[slot] = { expires = S.now + (tonumber(duration) or 1800), charges = tonumber(charges) or 0, id = tonumber(id) or 0 }
    SyncEnchants()
    S.FireEvent("UNIT_INVENTORY_CHANGED", "player")
end

---------------------------------------------------------------------------
-- World sync: rebuild live state when the host replaces or edits the world
---------------------------------------------------------------------------
local origSetWorld, origWorldJSON, origSetValue = S.SetWorld, S.WorldJSON, S.SetWorldValue
function S.SetWorld(literal)
    origSetWorld(literal)
    RebuildAuras()
    RebuildEnchants()
    if S.loggedIn then AuraUpdated() end
end
function S.WorldJSON()
    SyncWorld()
    SyncEnchants()
    return origWorldJSON()
end
function S.SetWorldValue(path, literal)
    origSetValue(path, literal)
    local root = tostring(path):match("^[^%.]+")
    if root == "auras" then RebuildAuras(); AuraUpdated()
    elseif root == "weaponEnchants" then RebuildEnchants(); S.FireEvent("UNIT_INVENTORY_CHANGED", "player")
    elseif root == "spells" then S.FireEvent("SPELLS_CHANGED"); S.FireEvent("LEARNED_SPELL_IN_TAB") end
end

---------------------------------------------------------------------------
-- Casting and using items
---------------------------------------------------------------------------
local function CastGUID(id) return ("Cast-3-0-0-0-%d-%08X"):format(id or 0, math.random(0, 0x7fffffff)) end

-- unit: who the spell lands on (nil/"player" = you). Buffs on group members go through S.ApplyAuraToUnit (47_group).
function S.CastSpell(spell, unit)
    local r, id = SpellRec(spell)
    if not r or r.known == false then
        host.chat("You don't know that spell.", 1, 0.1, 0.1)
        S.FireEvent("UI_ERROR_MESSAGE", 0, "You don't know that spell.")
        return false
    end
    local guid = CastGUID(id)
    S.FireEvent("UNIT_SPELLCAST_SENT", "player", "", guid, id)
    S.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", guid, id)
    if r.aura ~= nil then
        if unit and unit ~= "player" and S.ApplyAuraToUnit and S.ApplyAuraToUnit(unit, id) then return true end
        S.ApplyAura(id)
    end
    return true
end
function CastSpellByName(name) S.CastSpell(name) end
function CastSpellByID(id) S.CastSpell(id) end
C_Spell.CastSpell = function(spell) S.CastSpell(spell) end

local pendingEnchant = nil   -- an item waiting for a weapon slot (/use 16 after /use <poison>)

-- Uses an item from the bags: applies its buff or readies its weapon enchant. Returns true if something happened.
function S.UseItem(item)
    local id = tonumber(item) or tonumber(tostring(item or ""):match("item:(%d+)"))
    if not id and item then
        for k, r in pairs(S.world.items or {}) do
            if r.name and r.name:lower() == tostring(item):lower() then id = tonumber(k) break end
        end
    end
    if not id then S.Missing("UseItem(" .. tostring(item) .. ")") return false end
    if GetItemCount(id) < 1 then
        host.chat("You don't have that item.", 1, 0.1, 0.1)
        return false
    end
    local rec = (S.world.items or {})[id] or (S.world.items or {})[tostring(id)] or {}
    local use = rec.use
    if not use then host.chat(("Nothing happens (%s has no use in the sandbox world)."):format(rec.name or id), 1, 0.5, 0.2) return false end
    if use.enchant then
        pendingEnchant = { id = id, enchant = use.enchant, consume = use.consume }
        return true
    end
    if use.aura then S.ApplyAura(use.aura) end
    if use.consume ~= false then S.RemoveItem(id, 1) end
    S.FireEvent("BAG_UPDATE_COOLDOWN")
    return true
end

local function UseSlot(slot)
    slot = tonumber(slot)
    if pendingEnchant and (slot == 16 or slot == 17) then
        local p = pendingEnchant
        pendingEnchant = nil
        if not Equipped(slot) then host.chat("No weapon equipped in that slot.", 1, 0.1, 0.1) return end
        S.ApplyEnchant(slot, p.enchant.duration, p.enchant.charges, p.enchant.id)
        if p.consume ~= false then S.RemoveItem(p.id, 1) end
        return
    end
    S.Missing("UseInventoryItem(" .. tostring(slot) .. ")")
end
UseInventoryItem = function(slot) UseSlot(slot) end
UseItemByName = function(name) S.UseItem(name) end

-- Runs macro text the way the sandbox understands it: /cast, /use item:ID, /use <name>, /use <slot>.
function S.RunMacroText(text)
    for line in tostring(text or ""):gmatch("[^\n]+") do
        local cmd, rest = line:match("^%s*(/%S+)%s*(.-)%s*$")
        if cmd then
            cmd = cmd:lower()
            rest = rest:gsub("%b[]", ""):gsub("^%s+", "")
            if cmd == "/cast" or cmd == "/spell" then
                S.CastSpell(rest)
            elseif cmd == "/use" then
                if rest:match("^%d+$") then UseSlot(tonumber(rest)) else S.UseItem(rest) end
            elseif cmd == "/cancelaura" then
                S.RemoveAura(rest)
            else
                S.ChatCommand(line)
            end
        end
    end
end

-- Secure action buttons: SecureButton_GetModifiedAttribute's lookup order, then the action.
local BUTTON_SUFFIX = { LeftButton = "1", RightButton = "2", MiddleButton = "3", Button4 = "4", Button5 = "5" }
local function ModPrefix()
    local p = ""
    if S.mods.alt then p = p .. "alt-" end
    if S.mods.ctrl then p = p .. "ctrl-" end
    if S.mods.shift then p = p .. "shift-" end
    return p
end
function SecureButton_GetModifiedAttribute(self, name, button)
    local s = W[self]
    local attrs = s and s.attributes or {}
    local b = BUTTON_SUFFIX[button or "LeftButton"] or ""
    local m = ModPrefix()
    for _, key in ipairs({ m .. name .. b, m .. name .. "*", "*" .. name .. b, name .. b, "*" .. name .. "*", name .. "*", name }) do
        local v = attrs[key]
        if v ~= nil then return v end
    end
    return nil
end
SecureButton_GetAttribute = SecureButton_GetModifiedAttribute

function S.SecureAction(self, button)
    local get = function(name) return SecureButton_GetModifiedAttribute(self, name, button) end
    local kind = get("type")
    if kind == nil or kind == "" then return end
    if kind == "spell" then
        local spell = get("spell")
        if spell then S.CastSpell(spell, get("unit")) end
    elseif kind == "item" then
        local item = get("item")
        if item then
            local bag, slot = tostring(item):match("^(%d+)%s+(%d+)$")
            if bag then
                local id = C_Container.GetContainerItemID(tonumber(bag), tonumber(slot))
                if id then S.UseItem(id) end
            elseif tostring(item):match("^%d+$") and tonumber(item) <= 19 then
                UseSlot(tonumber(item))
            else
                S.UseItem(item)
            end
        end
    elseif kind == "macro" then
        local text = get("macrotext")
        if text then S.RunMacroText(text) else S.Missing("secure macro by index") end
    elseif kind == "cancelaura" then
        local spell = get("spell") or get("spell-name")
        if spell then S.RemoveAura(spell) end
    elseif kind == "click" then
        local target = get("clickbutton")
        if type(target) == "table" and target.Click then target:Click(button) end
    else
        S.Missing("secure action type '" .. tostring(kind) .. "'")
    end
end

for _, name in ipairs({ "SecureActionButtonTemplate", "InsecureActionButtonTemplate" }) do
    S.RegisterTemplate(name, function(f)
        local s = W[f]
        s.secureAction = true
        s.mouse = true
    end)
end
