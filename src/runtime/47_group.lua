-- Group combat: party members, enemies (with nameplates and threat), the combat log, health events, raid markers,
-- pings, and secure handler snippets. Enough for addons that watch a group fight.
--
-- World data (all optional):
--   party   = { { name, class, level, health, healthMax, inCombat, target = enemyId, leader } }   -> party1..party4
--   enemies = { { id, name, level, health, healthMax, inCombat, nameplate = true, threat = { "player", "party1" },
--                 dead, marker } }                                                               -> nameplateN
--   client.addonPings = true   lets addons call C_Ping.SendMacroPing (the live client blocks it, as far as we know)
-- Host helpers for use cases: SANDBOX.Hit(from, to, amount), SANDBOX.Ping(unit, kind)
local S = SANDBOX
local host = S.host
local W = S.W

local function Party() return S.world.party or {} end
local function Enemies() return S.world.enemies or {} end

---------------------------------------------------------------------------
-- Unit resolution
---------------------------------------------------------------------------
local plateOf = {}       -- enemy record -> "nameplateN"
local plateUnits = {}    -- "nameplateN" -> enemy record

-- Tokens stay with their unit while its plate exists (as in game); new plates take the lowest free number.
local function RebuildPlates()
    local keep = {}
    for _, e in ipairs(Enemies()) do
        if e.nameplate and not e.dead and plateOf[e] then keep[e] = plateOf[e] end
    end
    plateOf, plateUnits = {}, {}
    for e, token in pairs(keep) do plateOf[e] = token; plateUnits[token] = e end
    for _, e in ipairs(Enemies()) do
        if e.nameplate and not e.dead and not plateOf[e] then
            local n = 1
            while plateUnits["nameplate" .. n] do n = n + 1 end
            plateOf[e] = "nameplate" .. n
            plateUnits["nameplate" .. n] = e
        end
    end
end

local function EnemyById(id)
    id = tostring(id)
    for _, e in ipairs(Enemies()) do if tostring(e.id) == id then return e end end
end

-- Returns the record for a group or enemy unit token, or nil (other tokens go to the base functions).
local GroupUnit
GroupUnit = function(unit)
    if type(unit) ~= "string" then return nil end
    local u = unit:lower()
    local n = u:match("^party(%d)$")
    if n then return Party()[tonumber(n)] end
    local p, rest = u:match("^(party%d)(target)$")
    if p then
        local m = GroupUnit(p)
        return m and m.target and EnemyById(m.target) or nil
    end
    if u:match("^nameplate%d+$") then return plateUnits[u] end
    local plate = u:match("^(nameplate%d+)target$")
    if plate then
        local e = plateUnits[plate]
        local t = e and e.target
        if t == "player" then return S.Player() end
        return t and GroupUnit(t) or nil
    end
    local id = u:match("^enemy:(.+)$")
    if id then return EnemyById(id) end
    if u == "target" and S.world.target and S.world.target.enemy then return EnemyById(S.world.target.enemy) end
    if u == "playertarget" or u == "targettarget" then return nil end
    return nil
end
S.GroupUnit = GroupUnit

local function IsEnemy(r)
    if not r then return false end
    for _, e in ipairs(Enemies()) do if e == r then return true end end
    return false
end
local function IsMember(r)
    for _, m in ipairs(Party()) do if m == r then return true end end
    return false
end

local function GUIDOf(r)
    if r == S.Player() then return UnitGUID("player") end
    if IsEnemy(r) then return r.guid or ("Creature-0-0-0-0-%d-%010d"):format(r.npcID or 1000, tonumber(r.id) or 0) end
    for i, m in ipairs(Party()) do if m == r then return m.guid or ("Player-91-0000000%d"):format(i) end end
end

-- Wrap a base unit function: group/enemy units first, then the original.
local function Wrap(name, fn)
    local base = _G[name]
    _G[name] = function(unit, ...)
        local r = GroupUnit(unit)
        if r then return fn(r, unit, ...) end
        if base then return base(unit, ...) end
    end
end

Wrap("UnitExists", function(r) return not r.gone end)
Wrap("UnitName", function(r) return r.name or "Unknown", nil end)
Wrap("UnitGUID", function(r) return GUIDOf(r) end)
Wrap("UnitLevel", function(r) return r.level or 60 end)
Wrap("UnitHealth", function(r) return r.health or r.healthMax or 1000 end)
Wrap("UnitHealthMax", function(r) return r.healthMax or 1000 end)
Wrap("UnitIsDead", function(r) return r.dead or (r.health ~= nil and r.health <= 0) or false end)
Wrap("UnitIsDeadOrGhost", function(r) return r.dead or (r.health ~= nil and r.health <= 0) or false end)
Wrap("UnitAffectingCombat", function(r) return r.inCombat or false end)
Wrap("UnitIsPlayer", function(r) return not IsEnemy(r) end)
Wrap("UnitIsConnected", function(r) return true end)
Wrap("UnitClass", function(r)
    if IsEnemy(r) then return "Warrior", "WARRIOR", 1 end
    local file = (r.class or "WARRIOR"):upper()
    return LOCALIZED_CLASS_NAMES_MALE[file] or file, file, 1
end)
-- Two-unit questions: an enemy on either side makes them hostile.
local function Pair(name, hostile, friendly)
    local base = _G[name]
    _G[name] = function(a, b)
        local ra, rb = GroupUnit(a), GroupUnit(b)
        if ra or rb then
            if IsEnemy(ra) ~= IsEnemy(rb) then return hostile end
            return friendly
        end
        if base then return base(a, b) end
    end
end
Pair("UnitCanAttack", true, false)
Pair("UnitIsEnemy", true, false)
Pair("UnitIsFriend", false, true)
Pair("UnitReaction", 2, 5)
Wrap("UnitInParty", function(r) return IsMember(r) end)
Wrap("UnitIsGroupLeader", function(r) return r.leader or false end)
Wrap("UnitIsGroupAssistant", function(r) return r.assist or false end)
Wrap("UnitClassification", function(r) return r.classification or "normal" end)
Wrap("UnitCreatureType", function(r) return IsEnemy(r) and (r.creatureType or "Humanoid") or nil end)

local baseIsUnit = UnitIsUnit
function UnitIsUnit(a, b)
    local ra, rb = GroupUnit(a), GroupUnit(b)
    if ra or rb then
        if not ra and a and a:lower() == "player" then ra = S.Player() end
        if not rb and b and b:lower() == "player" then rb = S.Player() end
        return ra ~= nil and ra == rb
    end
    return baseIsUnit(a, b)
end

local baseCombat = UnitAffectingCombat
function UnitAffectingCombat(unit)
    local r = GroupUnit(unit)
    if r then return r.inCombat or false end
    return baseCombat(unit)
end

function IsInGroup() return #Party() > 0 end
function IsInRaid() return false end
function GetNumGroupMembers() local n = #Party() return n > 0 and n + 1 or 0 end
function GetNumSubgroupMembers() return #Party() end
local baseLeader = UnitIsGroupLeader
function UnitIsGroupLeader(unit)
    local r = GroupUnit(unit)
    if r then return r.leader or false end
    if unit == "player" then return #Party() == 0 or S.Player().leader or false end
    return baseLeader and baseLeader(unit) or false
end
function UnitIsGroupAssistant(unit)
    local r = GroupUnit(unit)
    if r then return r.assist or false end
    return unit == "player" and (S.Player().assist or false) or false
end
function UnitInRange(unit)
    local r = GroupUnit(unit)
    if r and IsMember(r) then return not r.far, true end
    return false, false
end

---------------------------------------------------------------------------
-- Threat
---------------------------------------------------------------------------
local function OnThreatList(member, enemy)
    for _, who in ipairs(enemy.threat or {}) do
        if type(who) == "string" and UnitIsUnit(who, member) then return true end
    end
    return false
end
function UnitThreatSituation(unit, mob)
    if not mob then
        -- overall: 3 when the unit is tanking something (party member's aggro = true, or first on a threat list)
        local r = unit == "player" and S.Player() or GroupUnit(unit)
        if not r then return nil end
        if r.aggro then return 3 end
        for _, e in ipairs(Enemies()) do
            if not e.dead and e.threat and e.threat[1] and UnitIsUnit(e.threat[1], unit) then return 3 end
        end
        return r.inCombat and 0 or nil
    end
    local e = GroupUnit(mob)
    if not IsEnemy(e) then return nil end
    if not OnThreatList(unit, e) then return nil end
    return (e.threat[1] and UnitIsUnit(e.threat[1], unit)) and 3 or 0
end
function UnitDetailedThreatSituation(unit, mob)
    local s = UnitThreatSituation(unit, mob)
    if s == nil then return nil end
    return s == 3, s, s == 3 and 100 or 50, s == 3 and 100 or 50, s == 3 and 1000 or 500
end

---------------------------------------------------------------------------
-- Nameplates
---------------------------------------------------------------------------
local plateFrames = {}   -- token -> frame
local function PlateFrame(token)
    local f = plateFrames[token]
    if not f then
        f = CreateFrame("Frame", nil, WorldFrame)
        f:Hide()
        f.UnitFrame = { unit = token }
        f.namePlateUnitToken = token
        plateFrames[token] = f
    end
    return f
end
C_NamePlate = C_NamePlate or {}
function C_NamePlate.GetNamePlates()
    local out = {}
    for token in pairs(plateUnits) do out[#out + 1] = PlateFrame(token) end
    table.sort(out, function(a, b) return a.namePlateUnitToken < b.namePlateUnitToken end)
    return out
end
function C_NamePlate.GetNamePlateForUnit(unit)
    local r = GroupUnit(unit)
    local token = r and plateOf[r]
    return token and PlateFrame(token) or nil
end

---------------------------------------------------------------------------
-- Raid markers
---------------------------------------------------------------------------
function GetRaidTargetIndex(unit)
    local r = GroupUnit(unit)
    return r and r.marker or nil
end
function SetRaidTarget(unit, index)
    local r = GroupUnit(unit)
    if not r then return end
    if #Party() > 0 and not (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) then
        host.chat("You don't have permission to mark targets.", 1, 0.1, 0.1)
        return
    end
    r.marker = (index and index > 0) and index or nil
    S.FireEvent("RAID_TARGET_UPDATE")
end

---------------------------------------------------------------------------
-- Combat log
---------------------------------------------------------------------------
COMBATLOG_OBJECT_AFFILIATION_MINE = 0x00000001
COMBATLOG_OBJECT_AFFILIATION_PARTY = 0x00000002
COMBATLOG_OBJECT_AFFILIATION_RAID = 0x00000004
COMBATLOG_OBJECT_AFFILIATION_OUTSIDER = 0x00000008
COMBATLOG_OBJECT_REACTION_FRIENDLY = 0x00000010
COMBATLOG_OBJECT_REACTION_HOSTILE = 0x00000040
COMBATLOG_OBJECT_CONTROL_PLAYER = 0x00000100
COMBATLOG_OBJECT_CONTROL_NPC = 0x00000200
COMBATLOG_OBJECT_TYPE_PLAYER = 0x00000400
COMBATLOG_OBJECT_TYPE_NPC = 0x00000800
COMBATLOG_OBJECT_TYPE_PET = 0x00001000

local currentEvent = nil
function CombatLogGetCurrentEventInfo()
    if not currentEvent then return nil end
    return unpack(currentEvent, 1, currentEvent.n)
end

local function Flags(r)
    if r == S.Player() then return 0x511 end   -- mine, friendly, player-controlled, player
    if IsMember(r) then return 0x512 end       -- party, friendly, player-controlled, player
    return 0xA48                               -- outsider, hostile, npc-controlled, npc
end

local function TokenFor(r)
    if r == S.Player() then return "player" end
    for i, m in ipairs(Party()) do if m == r then return "party" .. i end end
    return plateOf[r]
end

local function Resolve(who)
    if who == "player" then return S.Player() end
    return GroupUnit(who)
end

-- A hit from one unit to another: health, combat state, threat, then the combat log and unit events.
function S.Hit(from, to, amount, spellName)
    local src, dst = Resolve(from), Resolve(to)
    if not src or not dst then S.ReportError(("SANDBOX.Hit: unknown unit %s or %s"):format(tostring(from), tostring(to)), "") return end
    amount = tonumber(amount) or 100
    dst.healthMax = dst.healthMax or 1000
    dst.health = math.max(0, (dst.health or dst.healthMax) - amount)
    for _, r in ipairs({ src, dst }) do
        if not r.inCombat then
            r.inCombat = true
            local token = TokenFor(r)
            if r == S.Player() then S.SetCombat(true) elseif token then S.FireEvent("UNIT_FLAGS", token) end
        end
    end
    if IsEnemy(dst) and not IsEnemy(src) then
        dst.threat = dst.threat or {}
        local token = TokenFor(src)
        local seen = false
        for _, t in ipairs(dst.threat) do if t == token then seen = true end end
        if token and not seen then table.insert(dst.threat, token) end
    end
    local sub = spellName and "SPELL_DAMAGE" or "SWING_DAMAGE"
    local ev = { GetTime(), sub, false, GUIDOf(src), src.name, Flags(src), 0, GUIDOf(dst), dst.name, Flags(dst), 0 }
    if spellName then
        ev[#ev + 1] = 0; ev[#ev + 1] = spellName; ev[#ev + 1] = 1
    end
    ev[#ev + 1] = amount; ev[#ev + 1] = -1; ev[#ev + 1] = 1
    ev.n = #ev
    currentEvent = ev
    S.FireEvent("COMBAT_LOG_EVENT_UNFILTERED")
    currentEvent = nil
    local dtoken = TokenFor(dst)
    if dtoken then S.FireEvent("UNIT_HEALTH", dtoken) end
    if dst == S.Player() then S.FireEvent("UNIT_COMBAT", "player", "WOUND", "", amount, 1) end
    if dst.health <= 0 then
        dst.dead = IsEnemy(dst) or nil
        if IsEnemy(dst) then
            dst.inCombat = false
            local token = plateOf[dst]
            RebuildPlates()
            if token then S.FireEvent("NAME_PLATE_UNIT_REMOVED", token) end
        end
    end
end

---------------------------------------------------------------------------
-- Pings
---------------------------------------------------------------------------
-- The calling addon, from the stack (for ADDON_ACTION_FORBIDDEN).
local function CallingAddon()
    local stack = debugstack(3) or ""
    return stack:match("Interface/AddOns/([^/]+)/") or "?"
end

function S.Ping(unit, kind)
    kind = (kind or "attack"):lower()
    local name = unit and UnitExists(unit) and UnitName(unit) or nil
    local label = ({ attack = "Attack", warning = "Warning", onmyway = "On My Way", assist = "Assist" })[kind] or kind
    host.chat(("|cffff5050[%s ping]|r %s%s"):format(label, UnitName("player"), name and (" on " .. name) or ""), 1, 0.5, 0.4)
    S.FireEvent("PING_SENT", kind, name)
    S.lastPing = { unit = unit, kind = kind, name = name, at = GetTime() }
end

C_Ping = C_Ping or {}
function C_Ping.SendMacroPing(kind, target)
    if not S.world.client.addonPings then
        local addon = CallingAddon()
        S.FireEvent("ADDON_ACTION_FORBIDDEN", addon, "C_Ping.SendMacroPing()")
        host.warn(("%s was blocked from C_Ping.SendMacroPing() (a hardware event is needed; set client.addonPings to allow it)"):format(addon))
        return
    end
    S.Ping(target, type(kind) == "string" and kind or "attack")
end
function C_Ping.TogglePingListener() end
Enum.PingSubjectType = Enum.PingSubjectType or { Attack = 0, Warning = 1, Assist = 2, OnMyWay = 3, AlertThreat = 4, AlertNotThreat = 5 }

-- /ping [@unit] kind, from macros and the chat box (needs a hardware event in game: a click or key).
local function PingCommand(rest)
    local unit = "target"
    local cond = rest:match("%[(.-)%]")
    if cond then
        local at = cond:match("@([%w:]+)")
        if at then unit = at end
        if cond:find("exists") and not UnitExists(unit) then return end
        rest = rest:gsub("%b[]", "")
    end
    local kind = rest:match("^%s*(%S+)") or "attack"
    if not UnitExists(unit) then unit = nil end
    S.Ping(unit, kind)
end
local baseMacro = S.RunMacroText
function S.RunMacroText(text)
    local rest = {}
    for line in tostring(text or ""):gmatch("[^\n]+") do
        local cmd, args = line:match("^%s*(/%S+)%s*(.-)%s*$")
        if cmd and cmd:lower() == "/ping" then PingCommand(args)
        elseif cmd and (cmd:lower() == "/target" or cmd:lower() == "/tar") then
            local unit = args:gsub("%b[]", ""):match("^%s*(%S+)")
            local r = unit and GroupUnit(unit)
            if r and IsEnemy(r) then S.world.target = { name = r.name, level = r.level, enemy = r.id } ; S.FireEvent("PLAYER_TARGET_CHANGED") end
        else rest[#rest + 1] = line end
    end
    if #rest > 0 and baseMacro then baseMacro(table.concat(rest, "\n")) end
end
SlashCmdList.SANDBOXPING = function(msg) PingCommand(msg or "") end
SLASH_SANDBOXPING1 = "/ping"

---------------------------------------------------------------------------
-- Secure handlers: frame refs and wrapped scripts (snippets run as plain Lua with self, button, down)
---------------------------------------------------------------------------
function SecureHandlerSetFrameRef(frame, label, ref)
    local s = W[frame]
    if not s then return end
    s.frameRefs = s.frameRefs or {}
    s.frameRefs[label] = ref
end
local frameMeta = getmetatable(UIParent).__index
function frameMeta.GetFrameRef(self, label)
    local s = W[self]
    return s and s.frameRefs and s.frameRefs[label] or nil
end
function frameMeta.SetFrameRef(self, label, ref) SecureHandlerSetFrameRef(self, label, ref) end

local function Compile(body, args)
    local fn, err = loadstring("local " .. args .. " = ...\n" .. (body or ""), "secure snippet")
    if not fn then S.ReportError("Secure snippet: " .. tostring(err), "") return nil end
    return fn
end
function SecureHandlerWrapScript(frame, script, header, preBody, postBody)
    local s = W[frame]
    if not s then return end
    s.wraps = s.wraps or {}
    s.wraps[script] = s.wraps[script] or {}
    table.insert(s.wraps[script], { pre = Compile(preBody, "self, button, down"), post = Compile(postBody, "self, message, button, down") })
end
function SecureHandlerUnwrapScript(frame, script)
    local s = W[frame]
    if s and s.wraps then s.wraps[script] = nil end
end
function SecureHandlerExecute(frame, body)
    local fn = Compile(body, "self")
    if fn then S.Call(fn, frame) end
end

-- Hook into clicks: wrapped OnClick pre-bodies run before the click's action.
local baseDoClick = S.DoClick
function S.DoClick(self, button, down)
    local s = W[self]
    local wraps = s and s.wraps and s.wraps.OnClick
    if wraps then
        for _, w in ipairs(wraps) do if w.pre then S.Call(w.pre, self, button or "LeftButton", down or false) end end
    end
    baseDoClick(self, button, down)
    if wraps then
        for _, w in ipairs(wraps) do if w.post then S.Call(w.post, self, nil, button or "LeftButton", down or false) end end
    end
end

---------------------------------------------------------------------------
-- World sync
---------------------------------------------------------------------------
local origSetWorld, origSetValue = S.SetWorld, S.SetWorldValue
function S.SetWorld(literal)
    origSetWorld(literal)
    plateOf, plateUnits = {}, {}
    RebuildPlates()
    if S.loggedIn then S.FireEvent("GROUP_ROSTER_UPDATE") end
end
function S.SetWorldValue(path, literal)
    origSetValue(path, literal)
    local root = tostring(path):match("^[^%.]+")
    if root == "enemies" then
        local before = {}
        for token in pairs(plateUnits) do before[token] = true end
        RebuildPlates()
        for token in pairs(plateUnits) do if not before[token] then S.FireEvent("NAME_PLATE_UNIT_ADDED", token) end end
        for token in pairs(before) do if not plateUnits[token] then S.FireEvent("NAME_PLATE_UNIT_REMOVED", token) end end
    elseif root == "party" then
        S.FireEvent("GROUP_ROSTER_UPDATE")
        for i = 1, #Party() do S.FireEvent("UNIT_FLAGS", "party" .. i) end
    end
end
RebuildPlates()

---------------------------------------------------------------------------
-- Group members: buffs (counting down), power type, assigned role, talents through inspect, visibility
--   party[i].auras = { { spellId, remaining, count } }   party[i].role = "TANK"   party[i].talents = { 5, 0, 31 }
---------------------------------------------------------------------------
local memberAuras = {}   -- member record -> { { spellId, name, icon, duration, expires, count, instance } }
local nextInstance = 100000

local function MakeMemberAura(a)
    local r, id = S.SpellRec(a.spellId or a.name)
    nextInstance = nextInstance + 1
    local duration = tonumber(a.duration) or (r and tonumber(r.aura)) or 0
    local remaining = tonumber(a.remaining) or duration
    return { spellId = tonumber(a.spellId) or id or 0, name = a.name or (r and r.name) or ("Spell " .. tostring(a.spellId)),
        icon = a.icon or (r and r.icon) or 136243, duration = duration, expires = remaining > 0 and (S.now + remaining) or 0,
        count = tonumber(a.count) or 0, instance = nextInstance }
end

local function RebuildMemberAuras()
    memberAuras = {}
    for _, m in ipairs(Party()) do
        local list = {}
        for _, a in ipairs(m.auras or {}) do list[#list + 1] = MakeMemberAura(a) end
        memberAuras[m] = list
    end
end

local function TokenOfMember(m)
    for i, x in ipairs(Party()) do if x == m then return "party" .. i end end
end

-- A spell cast on a group member: their copy of the buff (re)starts. Returns true when `unit` is a member.
function S.ApplyAuraToUnit(unit, spell)
    local m = GroupUnit(unit)
    if not m or not IsMember(m) then return false end
    local r, id = S.SpellRec(spell)
    local list = memberAuras[m] or {}
    memberAuras[m] = list
    for i = #list, 1, -1 do if list[i].spellId == id or (r and list[i].name == r.name) then table.remove(list, i) end end
    list[#list + 1] = MakeMemberAura({ spellId = id })
    S.FireEvent("UNIT_AURA", TokenOfMember(m), { isFullUpdate = true })
    return true
end

S.tickHooks[#S.tickHooks + 1] = function()
    for m, list in pairs(memberAuras) do
        local changed = false
        for i = #list, 1, -1 do
            if list[i].expires > 0 and list[i].expires <= S.now then table.remove(list, i); changed = true end
        end
        if changed then local t = TokenOfMember(m) if t then S.FireEvent("UNIT_AURA", t, { isFullUpdate = true }) end end
    end
end

local function MemberAura(unit, index, filter)
    local m = GroupUnit(unit)
    if not m or not IsMember(m) then return nil, false end
    if filter and tostring(filter):upper():find("HARMFUL") then return nil, true end
    return (memberAuras[m] or {})[tonumber(index) or 0], true
end

local baseByIndex, baseUnitAura = C_UnitAuras.GetAuraDataByIndex, UnitAura
function C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
    local a, member = MemberAura(unit, index, filter)
    if not member then return baseByIndex(unit, index, filter) end
    if not a then return nil end
    return { name = a.name, icon = a.icon, applications = a.count, duration = a.duration, expirationTime = a.expires,
        sourceUnit = "party1", spellId = a.spellId, isHelpful = true, isHarmful = false, auraInstanceID = a.instance,
        canApplyAura = false, isFromPlayerOrPlayerPet = false, points = {}, timeMod = 1 }
end
C_UnitAuras.GetBuffDataByIndex = C_UnitAuras.GetAuraDataByIndex
function UnitAura(unit, index, filter)
    local a, member = MemberAura(unit, index, filter)
    if not member then return baseUnitAura(unit, index, filter) end
    if not a then return nil end
    return a.name, a.icon, a.count, nil, a.duration, a.expires, nil, false, false, a.spellId
end
UnitBuff = UnitAura

local POWER = { WARRIOR = { 1, "RAGE" }, ROGUE = { 3, "ENERGY" } }
local basePower = UnitPowerType
function UnitPowerType(unit)
    local m = GroupUnit(unit)
    if not m then return basePower(unit) end
    if IsEnemy(m) then return 1, "RAGE" end
    local p = POWER[(m.class or ""):upper()]
    if p then return p[1], p[2] end
    return 0, "MANA"
end

function UnitGroupRolesAssigned(unit)
    local m = unit == "player" and S.Player() or GroupUnit(unit)
    return (m and m.role) or "NONE"
end

local baseVisible = UnitIsVisible
function UnitIsVisible(unit)
    local m = GroupUnit(unit)
    if m then return not m.far end
    if baseVisible then return baseVisible(unit) end
    return unit == "player"
end
function CheckInteractDistance(unit)
    local m = GroupUnit(unit)
    if m then return not m.far end
    return unit == "player"
end
function CanInspect(unit) local m = GroupUnit(unit) return m ~= nil and IsMember(m) end

local inspected = nil
function NotifyInspect(unit)
    local m = GroupUnit(unit)
    if not m or not IsMember(m) then return end
    local guid = UnitGUID(unit)
    C_Timer.After(0.3, function() inspected = m; S.FireEvent("INSPECT_READY", guid) end)
end
function ClearInspectPlayer() inspected = nil end
function GetNumTalentTabs() return 3 end
local TREES = {
    WARRIOR = { "Arms", "Fury", "Protection" }, PALADIN = { "Holy", "Protection", "Retribution" },
    DRUID = { "Balance", "Feral Combat", "Restoration" }, PRIEST = { "Discipline", "Holy", "Shadow" },
    MAGE = { "Arcane", "Fire", "Frost" }, WARLOCK = { "Affliction", "Demonology", "Destruction" },
    ROGUE = { "Assassination", "Combat", "Subtlety" }, HUNTER = { "Beast Mastery", "Marksmanship", "Survival" },
    SHAMAN = { "Elemental", "Enhancement", "Restoration" },
}
-- Classic shape: name, icon, pointsSpent, fileName.
function GetTalentTabInfo(tab, isInspect)
    local who = isInspect and inspected or S.Player()
    if not who then return nil end
    local class = (who.class or "WARRIOR"):upper()
    local names = TREES[class] or TREES.WARRIOR
    local points = (who.talents or {})[tonumber(tab) or 0] or 0
    return names[tab] or ("Tree " .. tostring(tab)), 132222, points, (names[tab] or ""):gsub("%s", "")
end

local origSetWorld2, origSetValue2 = S.SetWorld, S.SetWorldValue
function S.SetWorld(literal) origSetWorld2(literal); RebuildMemberAuras() end
function S.SetWorldValue(path, literal)
    origSetValue2(path, literal)
    if tostring(path):match("^party") then
        RebuildMemberAuras()
        for i = 1, #Party() do S.FireEvent("UNIT_AURA", "party" .. i, { isFullUpdate = true }) end
    end
end
RebuildMemberAuras()

-- Party members' gear (inspect): party[i].equipment = { [17] = itemID }
local baseInvItem = GetInventoryItemID
function GetInventoryItemID(unit, slot)
    local m = GroupUnit(unit)
    if m and IsMember(m) then
        local eq = m.equipment or {}
        return tonumber(eq[slot] or eq[tostring(slot)])
    end
    return baseInvItem(unit, slot)
end
