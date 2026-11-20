-- API: timers, the frame loop, addon loading and the login sequence, SavedVariables, units, client info,
-- addon metadata, CVars, enums. Game systems (items, bags, merchant, AH, loot, professions) are in 40_game.lua.
local S = SANDBOX
local host = S.host
local W = S.W

S.world = { player = {}, client = {}, items = {}, bags = {}, merchants = {}, auctions = {}, loot = {}, professions = {} }
S.addons, S.addonOrder, S.installed = {}, {}, {}
S.loggedIn = false

-- Every fired event goes to the dev panel's event log.
function S.eventLog(event, ...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, math.min(n, 6) do
        local v = select(i, ...)
        parts[i] = type(v) == "string" and ("%q"):format(v) or tostring(v)
    end
    host.event(event, table.concat(parts, ", "))
end

-- Host entry point for firing an event from the dev panel; args arrive as a Lua literal list.
function S.FireEventFromHost(event, argsLiteral)
    local args = {}
    if argsLiteral and argsLiteral ~= "" then
        local fn, err = loadstring("return " .. argsLiteral, "event args")
        if not fn then S.ReportError("Bad event arguments: " .. err, "") return end
        args = { fn() }
    end
    S.FireEvent(event, unpack(args, 1, table.maxn(args)))
end

function S.RegisteredEventsJSON()
    local out = {}
    for event, count in pairs(S.registeredEvents) do out[#out + 1] = event end
    table.sort(out)
    return S.JSON(out)
end

---------------------------------------------------------------------------
-- Timers
---------------------------------------------------------------------------
local timers = {}

local TimerHandle = {}
TimerHandle.__index = TimerHandle
function TimerHandle:Cancel() self._cancelled = true end
function TimerHandle:IsCancelled() return self._cancelled or false end
function TimerHandle:Invoke(...) if self._cb then self._cb(...) end end
function TimerHandle:GetRemainingIterations() return self._iterations end

local function Schedule(delay, cb, handle, interval, iterations)
    if type(cb) ~= "function" then error("C_Timer: callback must be a function", 3) end
    local t = { at = S.now + math.max(tonumber(delay) or 0, 0), cb = cb, handle = handle, interval = interval,
        iterations = iterations }
    timers[#timers + 1] = t
    return t
end

C_Timer = {}
function C_Timer.After(delay, cb) Schedule(delay, cb) end
function C_Timer.NewTimer(delay, cb)
    local h = setmetatable({ _cb = cb }, TimerHandle)
    Schedule(delay, cb, h)
    return h
end
function C_Timer.NewTicker(interval, cb, iterations)
    local h = setmetatable({ _cb = cb, _iterations = iterations }, TimerHandle)
    Schedule(interval, cb, h, interval, iterations)
    return h
end

local function RunTimers()
    local due = {}
    local keep = {}
    for _, t in ipairs(timers) do
        if t.handle and t.handle._cancelled then
            -- dropped
        elseif t.at <= S.now then
            due[#due + 1] = t
        else
            keep[#keep + 1] = t
        end
    end
    timers = keep
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, t in ipairs(due) do
        if not (t.handle and t.handle._cancelled) then
            if t.handle then S.Call(t.cb, t.handle) else S.Call(t.cb) end
            if t.interval and not (t.handle and t.handle._cancelled) then
                if t.iterations then t.iterations = t.iterations - 1; t.handle._iterations = t.iterations end
                if not t.iterations or t.iterations > 0 then
                    t.at = S.now + t.interval
                    timers[#timers + 1] = t
                end
            end
        end
    end
end
S.PendingTimers = function() return #timers end

---------------------------------------------------------------------------
-- Frame loop: the host calls this once per animation frame. Returns render JSON, or "" when nothing changed.
---------------------------------------------------------------------------
-- Per-frame game systems (aura and enchant expiry) registered by later runtime files.
S.tickHooks = S.tickHooks or {}
function S.RunTickHooks()
    for i = 1, #S.tickHooks do S.Call(S.tickHooks[i]) end
end

function S.Frame(elapsed)
    elapsed = math.min(math.max(tonumber(elapsed) or 0, 0), 1)
    S.now = S.now + elapsed
    if elapsed > 0 then S.fps = math.floor(1 / elapsed + 0.5) end
    RunTimers()
    S.RunTickHooks()
    S.RunOnUpdate(elapsed)
    if S.RefreshHover then S.RefreshHover() end
    if S.dirty then S.renderPending = false return S.BuildRender() end
    if S.renderPending then S.renderPending = false return S.lastRender or "" end
    return ""
end

-- Headless helper: advance time in steps (timers and OnUpdate run), no render.
function S.Advance(seconds, step)
    step = step or 0.05
    local t = 0
    while t < seconds do
        local dt = math.min(step, seconds - t)
        S.now = S.now + dt
        RunTimers()
        S.RunTickHooks()
        S.RunOnUpdate(dt)
        if S.RefreshHover then S.RefreshHover() end
        t = t + dt
    end
end

---------------------------------------------------------------------------
-- World state (owned by Lua at runtime; the dev panel reads and edits it)
---------------------------------------------------------------------------
function S.SetWorld(literal)
    local fn, err = loadstring("return " .. literal, "world")
    if not fn then error("Bad world data: " .. err) end
    local world = fn() or {}
    for _, key in ipairs({ "player", "client", "items", "bags", "merchants", "auctions", "loot", "professions", "mail" }) do
        world[key] = world[key] or {}
    end
    S.world = world
end
function S.WorldJSON() return S.JSON(S.world) end

-- Dev panel edits: set a value at a dotted path ("player.money") from a Lua literal.
function S.SetWorldValue(path, literal)
    local fn, err = loadstring("return " .. literal, "world value")
    if not fn then error("Bad value: " .. err) end
    local value = fn()
    local t, last = S.world, nil
    local keys = {}
    for part in path:gmatch("[^%.]+") do keys[#keys + 1] = tonumber(part) or part end
    for i = 1, #keys - 1 do
        t[keys[i]] = t[keys[i]] or {}
        t = t[keys[i]]
    end
    last = keys[#keys]
    local old = t[last]
    t[last] = value
    if path == "player.money" and old ~= value then S.FireEvent("PLAYER_MONEY") end
    if path == "player.inCombat" and old ~= value then S.FireEvent(value and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED") end
end

---------------------------------------------------------------------------
-- Addon loading
---------------------------------------------------------------------------
function S.SetInstalled(literal)
    local fn = loadstring("return " .. literal, "addon list")
    S.installed = fn and fn() or {}
end

local function NormalizePath(path)
    path = path:gsub("\\", "/")
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then parts[#parts] = nil elseif part ~= "." then parts[#parts + 1] = part end
    end
    return table.concat(parts, "/")
end
S.NormalizePath = NormalizePath

function S.RunLuaFile(addon, path, ns)
    local src = host.file(addon, path)
    if not src then
        S.Warn(("%s: couldn't open %s (listed in the TOC or XML)"):format(addon, path))
        return
    end
    local fn, err = loadstring(src, "@Interface/AddOns/" .. addon .. "/" .. path)
    if not fn then
        S.ReportError(err, "")
        return
    end
    S.Call(fn, addon, ns)
end

local function RunFile(addon, path, ns)
    path = NormalizePath(path)
    local ext = path:match("%.(%w+)$")
    ext = ext and ext:lower()
    if ext == "lua" then S.RunLuaFile(addon, path, ns)
    elseif ext == "xml" then S.LoadXMLFile(addon, path, ns)
    else S.Warn(("%s: ignoring %s (not .lua or .xml)"):format(addon, path)) end
end
S.RunFile = RunFile

-- info: { name, title, notes, version, interface, files = {...}, savedVariables, savedVariablesPerCharacter, meta }
function S.LoadAddon(literal)
    local info = loadstring("return " .. literal, "addon info")()
    local name = info.name
    local ns = {}
    local addon = { info = info, ns = ns, loaded = false, index = #S.addonOrder + 1 }
    S.addons[name] = addon
    S.addonOrder[#S.addonOrder + 1] = name
    local started = host.now()
    for _, file in ipairs(info.files or {}) do RunFile(name, file, ns) end
    addon.loadMs = host.now() - started
end

-- SavedVariables files run in a scratch environment, then only the TOC-declared names are copied to _G.
function S.LoadSavedVariables(addonName, accountText, characterText)
    local addon = S.addons[addonName]
    if not addon then return end
    local info = addon.info
    for _, pair in ipairs({ { accountText, info.savedVariables }, { characterText, info.savedVariablesPerCharacter } }) do
        local text, names = pair[1], pair[2] or {}
        if text and text ~= "" then
            local env = {}
            local fn, err = loadstring(text, "@WTF/" .. addonName .. ".lua")
            if fn then
                setfenv(fn, env)
                local ok, runErr = pcall(fn)
                if not ok then S.ReportError(("%s SavedVariables: %s"):format(addonName, tostring(runErr)), "") end
            else
                S.ReportError(("%s SavedVariables: %s"):format(addonName, err), "")
            end
            for _, var in ipairs(names) do _G[var] = env[var] end
        end
    end
    addon.loaded = true
    S.FireEvent("ADDON_LOADED", addonName, false)
end

function S.Login(isReload)
    S.loggedIn = true
    S.FireEvent("VARIABLES_LOADED")
    S.FireEvent("SPELLS_CHANGED")
    S.FireEvent("PLAYER_LOGIN")
    S.FireEvent("PLAYER_ENTERING_WORLD", not isReload, isReload and true or false)
    C_Timer.After(0.5, function()
        S.FireEvent("ZONE_CHANGED_NEW_AREA")
        S.FireEvent("BAG_UPDATE_DELAYED")
        S.FireEvent("PLAYER_MONEY")
    end)
end

function S.Logout()
    S.FireEvent("PLAYER_LEAVING_WORLD")
    S.FireEvent("PLAYER_LOGOUT")
end

-- SavedVariables writer, in the client's format (no indentation, sorted keys for stable diffs).
local function SerializeNumber(v)
    if v ~= v then return "0/0" end
    if v == math.huge then return "math.huge" end
    if v == -math.huge then return "-math.huge" end
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return ("%d"):format(v) end
    local s = ("%.16g"):format(v)
    if tonumber(s) ~= v then s = ("%.17g"):format(v) end
    return s
end

local function SerializeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        return ("\\%03d"):format(c:byte())
    end) .. '"'
end

local function KeyOrder(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
end

local function Serialize(v, out, seen)
    local tv = type(v)
    if tv == "number" then out[#out + 1] = SerializeNumber(v)
    elseif tv == "string" then out[#out + 1] = SerializeString(v)
    elseif tv == "boolean" then out[#out + 1] = tostring(v)
    elseif tv == "table" and not W[v] and not seen[v] then
        seen[v] = true
        out[#out + 1] = "{\n"
        local n = #v
        for i = 1, n do
            local item = v[i]
            local ti = type(item)
            if ti == "number" or ti == "string" or ti == "boolean" or (ti == "table" and not W[item]) then
                Serialize(item, out, seen)
                out[#out + 1] = ",\n"
            else
                out[#out + 1] = "nil,\n"
            end
        end
        local keys = {}
        for k, item in pairs(v) do
            local tk = type(k)
            local isArray = tk == "number" and k >= 1 and k <= n and k == math.floor(k)
            local ti = type(item)
            if not isArray and (tk == "string" or tk == "number" or tk == "boolean")
                and (ti == "number" or ti == "string" or ti == "boolean" or (ti == "table" and not W[item])) then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys, KeyOrder)
        for _, k in ipairs(keys) do
            out[#out + 1] = "["
            Serialize(k, out, seen)
            out[#out + 1] = "] = "
            Serialize(v[k], out, seen)
            out[#out + 1] = ",\n"
        end
        out[#out + 1] = "}"
        seen[v] = nil
    else
        out[#out + 1] = "nil"
    end
end

local function SerializeVariables(names)
    if not names or #names == 0 then return nil end
    local out = { "\n" }
    for _, name in ipairs(names) do
        out[#out + 1] = name .. " = "
        Serialize(_G[name], out, {})
        out[#out + 1] = "\n"
    end
    return table.concat(out)
end
S.SerializeVariables = SerializeVariables

-- { [addon] = { account = text|nil, character = text|nil } } as JSON for the host to write.
function S.SerializeSavedVariables()
    local result = {}
    for _, name in ipairs(S.addonOrder) do
        local addon = S.addons[name]
        if addon.loaded then
            local info = addon.info
            local account = SerializeVariables(info.savedVariables)
            local character = SerializeVariables(info.savedVariablesPerCharacter)
            if account or character then result[name] = { account = account, character = character } end
        end
    end
    return S.JSON(result)
end

---------------------------------------------------------------------------
-- Addon metadata (C_AddOns)
---------------------------------------------------------------------------
local function FindInstalled(nameOrIndex)
    if type(nameOrIndex) == "number" then return S.installed[nameOrIndex] end
    local lower = tostring(nameOrIndex):lower()
    for _, a in ipairs(S.installed) do if a.name:lower() == lower then return a end end
end

C_AddOns = {}
function C_AddOns.IsAddOnLoaded(name)
    local a = S.addons[name]
    if not a and type(name) == "number" then local inst = S.installed[name]; a = inst and S.addons[inst.name] end
    return a and a.loaded or false, a and a.loaded or false
end
function C_AddOns.GetAddOnMetadata(name, field)
    local a = FindInstalled(name)
    if not a then error(("GetAddOnMetadata: unknown addon '%s'"):format(tostring(name)), 2) end
    local lower = tostring(field):lower()
    for k, v in pairs(a.meta or {}) do if k:lower() == lower then return v end end
end
function C_AddOns.GetNumAddOns() return #S.installed end
function C_AddOns.GetAddOnInfo(nameOrIndex)
    local a = FindInstalled(nameOrIndex)
    if not a then return nil end
    local loaded = S.addons[a.name] ~= nil
    return a.name, a.title ~= "" and a.title or a.name, a.notes, true, loaded and nil or "DISABLED", "INSECURE", false
end
function C_AddOns.IsAddOnLoadOnDemand(name) local a = FindInstalled(name) return a and a.loadOnDemand or false end
function C_AddOns.IsAddOnLoadable(name) return FindInstalled(name) ~= nil, nil end
function C_AddOns.DoesAddOnExist(name) return FindInstalled(name) ~= nil end
function C_AddOns.GetAddOnEnableState(name) return S.addons[type(name) == "table" and name.name or name] and 2 or 0 end
function C_AddOns.EnableAddOn() end
function C_AddOns.DisableAddOn() end
function C_AddOns.EnableAllAddOns() end
function C_AddOns.DisableAllAddOns() end
function C_AddOns.SaveAddOns() end
function C_AddOns.ResetAddOns() end
function C_AddOns.GetAddOnDependencies(name)
    local a = FindInstalled(name)
    if a and a.deps then return unpack(a.deps) end
end
function C_AddOns.GetAddOnOptionalDependencies(name)
    local a = FindInstalled(name)
    if a and a.optDeps then return unpack(a.optDeps) end
end
-- shortcut: load-on-demand addons aren't preloaded, so LoadAddOn only succeeds for addons already loaded.
function C_AddOns.LoadAddOn(name)
    if S.addons[name] then return true, nil end
    S.Missing("C_AddOns.LoadAddOn(" .. tostring(name) .. ")")
    return false, "DISABLED"
end
function C_AddOns.GetAddOnName(index) local a = S.installed[index] return a and a.name end
function C_AddOns.GetAddOnTitle(name) local a = FindInstalled(name) return a and a.title end
function C_AddOns.GetAddOnNotes(name) local a = FindInstalled(name) return a and a.notes end
function C_AddOns.GetAddOnSecurity() return "INSECURE" end
function C_AddOns.GetAddOnInterfaceVersion(name)
    local a = FindInstalled(name)
    return a and tonumber(a.interface) or 0
end
function C_AddOns.IsAddonVersionCheckEnabled() return true end
function C_AddOns.SetAddonVersionCheck() end
function GetAddOnMemoryUsage() return 0 end
function UpdateAddOnMemoryUsage() end
function GetAddOnCPUUsage() return 0 end
function UpdateAddOnCPUUsage() end
function GetScriptCPUUsage() return 0 end
function ReloadUI() host.reload() end
function Logout() S.Warn("Logout() called: ignored in the sandbox") end
function Quit() S.Warn("Quit() called: ignored in the sandbox") end

---------------------------------------------------------------------------
-- Client and environment
---------------------------------------------------------------------------
local function Client() return S.world.client or {} end
function GetBuildInfo()
    local c = Client()
    local interface = tonumber(c.interface) or 16001
    return c.version or "1.60.1", tostring(c.build or "70888"), c.date or "Nov 11 2026", interface, c.version or "1.60.1", "Release"
end
function GetLocale() return Client().locale or "enUS" end
function GetCurrentRegion() return 1 end
function GetCurrentRegionName() return "US" end
function IsTrialAccount() return false end
function IsVeteranTrialAccount() return false end
function IsRestrictedAccount() return false end
function IsLoggedIn() return S.loggedIn end
function IsPublicBuild() return true end
function IsTestBuild() return false end
function IsBetaBuild() return false end
function IsOnTournamentRealm() return false end
function GetNetStats() return 0, 0, 30, 30 end
function GetGameTime()
    local t = date("*t")
    return t.hour, t.min
end
function GetLocalGameTime() return GetGameTime() end
C_DateAndTime = {}
function C_DateAndTime.GetCurrentCalendarTime()
    local t = date("*t")
    return { year = t.year, month = t.month, monthDay = t.day, weekday = t.wday, hour = t.hour, minute = t.min }
end
function C_DateAndTime.GetServerTimeLocal() return time() end
function C_DateAndTime.GetSecondsUntilDailyReset() return 3600 * 8 end
function C_DateAndTime.GetSecondsUntilWeeklyReset() return 86400 * 3 end
function GetQuestResetTime() return 3600 * 8 end

local cvars = { autoLootDefault = "1", scriptErrors = "1", uiScale = "1", useUiScale = "0", taintLog = "0",
    Sound_EnableSFX = "1", Sound_EnableAllSound = "1", portal = "US", textLocale = "enUS", agentUID = "wow_forever" }
C_CVar = {}
function C_CVar.GetCVar(name) return cvars[name] end
function C_CVar.SetCVar(name, value) cvars[name] = value ~= nil and tostring(value) or nil; S.FireEvent("CVAR_UPDATE", name, value) return true end
function C_CVar.GetCVarBool(name) local v = cvars[name] return v == "1" or v == "true" end
function C_CVar.GetCVarDefault(name) return cvars[name] end
function C_CVar.RegisterCVar(name, default) if cvars[name] == nil then cvars[name] = default and tostring(default) end end
function C_CVar.GetCVarInfo(name) return cvars[name], cvars[name], false, false, false end
GetCVar, SetCVar, GetCVarBool, GetCVarDefault, RegisterCVar = C_CVar.GetCVar, C_CVar.SetCVar, C_CVar.GetCVarBool, C_CVar.GetCVarDefault, C_CVar.RegisterCVar

---------------------------------------------------------------------------
-- Player and units
---------------------------------------------------------------------------
local CLASS_IDS = { WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5, DEATHKNIGHT = 6, SHAMAN = 7,
    MAGE = 8, WARLOCK = 9, MONK = 10, DRUID = 11, DEMONHUNTER = 12, EVOKER = 13 }
local CLASS_NAMES = { WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
    DEATHKNIGHT = "Death Knight", SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", MONK = "Monk", DRUID = "Druid",
    DEMONHUNTER = "Demon Hunter", EVOKER = "Evoker" }
LOCALIZED_CLASS_NAMES_MALE, LOCALIZED_CLASS_NAMES_FEMALE = CLASS_NAMES, CLASS_NAMES
CLASS_SORT_ORDER = { "WARRIOR", "DEATHKNIGHT", "PALADIN", "MONK", "PRIEST", "SHAMAN", "DRUID", "ROGUE", "MAGE",
    "WARLOCK", "HUNTER", "DEMONHUNTER", "EVOKER" }
MAX_PLAYER_LEVEL = 60

local function Player() return S.world.player or {} end
S.Player = Player

-- Returns the unit's record (player, target, npc) or nil.
local function Unit(unit)
    if type(unit) ~= "string" then return nil end
    unit = unit:lower()
    if unit == "player" then return Player() end
    if unit == "npc" then
        local m = S.openMerchant
        if m then return { name = m.name, level = 60, npc = true } end
        return S.openNPC
    end
    if unit == "target" then return S.world.target end
    if unit == "mouseover" then return nil end
    return nil
end
S.Unit = Unit

function UnitExists(unit) return Unit(unit) ~= nil end
function UnitName(unit)
    local u = Unit(unit)
    if not u then return nil end
    return u.name or "Unknown", nil
end
UnitNameUnmodified = UnitName
function UnitFullName(unit)
    local u = Unit(unit)
    if not u then return nil end
    return u.name, u == Player() and GetNormalizedRealmName() or u.realm
end
function GetUnitName(unit, showServer) return UnitName(unit) end
function UnitGUID(unit)
    local u = Unit(unit)
    if not u then return nil end
    if u == Player() then return u.guid or "Player-91-0A1B2C3D" end
    return u.guid or ("Creature-0-0-0-0-%d-0000000000"):format(u.npcID or 1)
end
function UnitLevel(unit) local u = Unit(unit) return u and (u.level or 60) or 0 end
UnitEffectiveLevel = UnitLevel
function UnitClass(unit)
    local u = Unit(unit)
    if not u then return nil end
    local file = (u.class or "WARRIOR"):upper()
    return CLASS_NAMES[file] or file, file, CLASS_IDS[file] or 1
end
UnitClassBase = function(unit) local _, file, id = UnitClass(unit) return file, id end
function UnitRace(unit)
    local u = Unit(unit)
    if not u then return nil end
    local race = u.race or "Human"
    return race, (race:gsub("%s", "")), u.raceID or 1
end
function UnitFactionGroup(unit)
    local u = Unit(unit)
    if not u then return nil end
    local f = u.faction or "Alliance"
    return f, f
end
function UnitSex(unit) return Unit(unit) and 2 or nil end
function UnitHealth(unit) local u = Unit(unit) return u and (u.health or 1000) or 0 end
function UnitHealthMax(unit) local u = Unit(unit) return u and (u.healthMax or 1000) or 0 end
function UnitPower(unit) local u = Unit(unit) return u and (u.power or 100) or 0 end
function UnitPowerMax(unit) local u = Unit(unit) return u and (u.powerMax or 100) or 0 end
function UnitPowerType() return 0, "MANA" end
function UnitIsPlayer(unit) local u = Unit(unit) return u ~= nil and not u.npc end
function UnitIsUnit(a, b)
    local ua, ub = Unit(a), Unit(b)
    return ua ~= nil and ua == ub
end
function UnitIsDead(unit) return false end
function UnitIsGhost(unit) return false end
function UnitIsDeadOrGhost(unit) return false end
function UnitIsAFK() return false end
function UnitIsDND() return false end
function UnitIsConnected(unit) return Unit(unit) ~= nil end
function UnitAffectingCombat(unit) local u = Unit(unit) return u == Player() and Player().inCombat or false end
function UnitInParty() return false end
function UnitInRaid() return nil end
function UnitIsGroupLeader() return false end
function UnitCanAttack() return false end
function UnitCanCooperate() return true end
function UnitIsFriend() return true end
function UnitIsEnemy() return false end
function UnitReaction() return 5 end
function UnitIsTapDenied() return false end
function UnitClassification() return "normal" end
function UnitCreatureType() return nil end
function UnitXP() return Player().xp or 0 end
function UnitXPMax() return Player().xpMax or 1000 end
function GetXPExhaustion() return nil end
function IsResting() return Player().resting or false end
function IsMounted() return false end
function IsFlying() return false end
function IsSwimming() return false end
function IsFalling() return false end
function IsStealthed() return false end
function UnitOnTaxi() return false end
function UnitInVehicle() return false end
function UnitHasVehicleUI() return false end
function UnitBuff() return nil end
function UnitDebuff() return nil end
function UnitAura() return nil end
C_UnitAuras = { GetAuraDataByIndex = function() return nil end, GetPlayerAuraBySpellID = function() return nil end,
    GetBuffDataByIndex = function() return nil end, GetDebuffDataByIndex = function() return nil end }
function GetMaxPlayerLevel() return MAX_PLAYER_LEVEL end
function GetRealmName() return Player().realm or "Forever" end
function GetNormalizedRealmName() return (GetRealmName():gsub("[%s%-]", "")) end
function GetRealmID() return 91 end
function Ambiguate(name, context) return (name and name:gsub("%-" .. GetNormalizedRealmName() .. "$", "")) end
function GetPlayerInfoByGUID(guid)
    if guid ~= UnitGUID("player") then return nil end
    local className, classFile = UnitClass("player")
    local race, raceFile = UnitRace("player")
    return className, classFile, race, raceFile, 2, UnitName("player"), GetRealmName()
end
function InCombatLockdown() return Player().inCombat or false end
function IsInGroup() return false end
function IsInRaid() return false end
function GetNumGroupMembers() return 0 end
function GetNumSubgroupMembers() return 0 end
function IsInGuild() return Player().guild ~= nil end
function GetGuildInfo(unit) if Unit(unit) == Player() and Player().guild then return Player().guild, "Member", 4 end end
function IsInInstance() return false, "none" end
function GetInstanceInfo() return GetZoneText(), "none", 0, "", 5, 0, false, 0, 0 end
function GetZoneText() return Player().zone or "Orgrimmar" end
GetRealZoneText = GetZoneText
function GetSubZoneText() return Player().subZone or "" end
function GetMinimapZoneText() return Player().subZone ~= "" and Player().subZone or GetZoneText() end
function GetZonePVPInfo() return "sanctuary" end
C_Map = {}
function C_Map.GetBestMapForUnit(unit) return Unit(unit) == Player() and (Player().mapID or 85) or nil end
function C_Map.GetMapInfo(mapID) return { mapID = mapID, name = GetZoneText(), mapType = 3, parentMapID = 0 } end
function C_Map.GetPlayerMapPosition() return nil end
function C_Map.GetMapChildrenInfo() return {} end
function GetSpecialization() return nil end
function GetSpecializationInfo() return nil end
function GetNumSpecializations() return 0 end
function C_SpecializationInfo_GetSpecialization() return nil end

-- Spells: enough for addons that look up names and icons.
C_Spell = {}
function C_Spell.GetSpellInfo(id)
    if not id then return nil end
    return { name = "Spell " .. tostring(id), spellID = tonumber(id) or 0, iconID = 136243, castTime = 0, minRange = 0, maxRange = 0, originalIconID = 136243 }
end
function C_Spell.GetSpellName(id) return id and ("Spell " .. tostring(id)) end
function C_Spell.GetSpellTexture(id) return 136243 end
function C_Spell.DoesSpellExist(id) return true end
function C_Spell.GetSpellCooldown() return { startTime = 0, duration = 0, isEnabled = true, modRate = 1 } end
function C_Spell.IsSpellUsable() return true, false end
function C_Spell.GetSpellLink(id) return ("|cff71d5ff|Hspell:%d:0|h[Spell %d]|h|r"):format(id, id) end
function IsSpellKnown() return false end
function IsPlayerSpell() return false end
function GetSpellInfo(id)
    local info = C_Spell.GetSpellInfo(id)
    if info then return info.name, nil, info.iconID, 0, 0, 0, info.spellID end
end

C_ChatInfo = {}
function C_ChatInfo.RegisterAddonMessagePrefix() return true end
function C_ChatInfo.IsAddonMessagePrefixRegistered() return true end
function C_ChatInfo.SendAddonMessage() return true end
function C_ChatInfo.SendAddonMessageLogged() return true end
function C_ChatInfo.GetRegisteredAddonMessagePrefixes() return {} end
RegisterAddonMessagePrefix = C_ChatInfo.RegisterAddonMessagePrefix
SendAddonMessage = C_ChatInfo.SendAddonMessage

---------------------------------------------------------------------------
-- Sounds
---------------------------------------------------------------------------
local soundIds = { LOOT_WINDOW_COIN_SOUND = 120, IG_MAINMENU_OPTION_CHECKBOX_ON = 856, IG_MAINMENU_OPTION_CHECKBOX_OFF = 857,
    IG_MAINMENU_OPEN = 850, IG_MAINMENU_CLOSE = 851, U_CHAT_SCROLL_BUTTON = 1115, IG_CHARACTER_INFO_OPEN = 839,
    IG_CHARACTER_INFO_CLOSE = 840, IG_QUEST_LIST_OPEN = 875, RAID_WARNING = 8959, READY_CHECK = 8960,
    AUCTION_WINDOW_OPEN = 5274, AUCTION_WINDOW_CLOSE = 5275, MONEY_FRAME_OPEN = 891, MONEY_FRAME_CLOSE = 892,
    TELL_MESSAGE = 3081, ALARM_CLOCK_WARNING_3 = 12889, IG_SPELLBOOK_OPEN = 829, UI_BNET_TOAST = 18019 }
local nextSound = 900000
SOUNDKIT = setmetatable({}, { __index = function(t, k)
    local id = soundIds[k]
    if not id then nextSound = nextSound + 1; id = nextSound end
    rawset(t, k, id)
    return id
end })
for k, v in pairs(soundIds) do SOUNDKIT[k] = v end
function PlaySound(id, channel) host.sound(tostring(id)) return true, 1 end
function PlaySoundFile(file, channel) host.sound(tostring(file)) return true, 1 end
function PlayMusic() end
function StopMusic() end
function StopSound() end

---------------------------------------------------------------------------
-- Enums
---------------------------------------------------------------------------
Enum = Enum or {}
Enum.ItemQuality = { Poor = 0, Common = 1, Standard = 1, Uncommon = 2, Good = 2, Rare = 3, Superior = 3, Epic = 4,
    Legendary = 5, Artifact = 6, Heirloom = 7, WoWToken = 8 }
Enum.TooltipDataType = { Item = 0, Spell = 1, Unit = 2, Corpse = 3, Object = 4, Currency = 5, BattlePet = 6,
    UnitAura = 7, AzeriteEssence = 8, CompanionPet = 9, Mount = 10, PetAction = 11, Achievement = 12,
    EnhancedConduit = 13, EquipmentSet = 14, InstanceLock = 15, PvPBrawl = 16, RecipeRankInfo = 17, Totem = 18,
    Toy = 19, CorruptionCleanser = 20, MinimapMouseover = 21, Flyout = 22, Quest = 23, QuestPartyProgress = 24,
    Macro = 25, Debug = 26 }
Enum.CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2, Automatic = 3 }
Enum.LootSlotType = { None = 0, Item = 1, Money = 2, Currency = 3 }
Enum.AuctionHouseSortOrder = { Price = 0, Name = 1, Level = 2, Bid = 3, Buyout = 4, TimeRemaining = 5 }
Enum.AuctionHouseTimeLeftBand = { Short = 0, Medium = 1, Long = 2, VeryLong = 3 }
Enum.ItemClass = { Consumable = 0, Container = 1, Weapon = 2, Gem = 3, Armor = 4, Reagent = 5, Projectile = 6,
    Tradegoods = 7, ItemEnhancement = 8, Recipe = 9, CurrencyTokenObsolete = 10, Quiver = 11, Questitem = 12,
    Key = 13, PermanentObsolete = 14, Miscellaneous = 15, Glyph = 16, Battlepet = 17, WoWToken = 18, Profession = 19 }
Enum.BagIndex = { Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5, Bank = -1 }
Enum.ItemBind = { None = 0, OnAcquire = 1, OnEquip = 2, OnUse = 3, Quest = 4 }
Enum.PowerType = { Mana = 0, Rage = 1, Focus = 2, Energy = 3, ComboPoints = 4, Runes = 5, RunicPower = 6 }
Enum.TradeskillRecipeType = { Item = 1, Salvage = 2, Enchant = 3, Recraft = 4, Gathering = 5 }
Enum.Profession = { FirstAid = 0, Blacksmithing = 1, Leatherworking = 2, Alchemy = 3, Herbalism = 4, Cooking = 5,
    Mining = 6, Tailoring = 7, Engineering = 8, Enchanting = 9, Fishing = 10, Skinning = 11, Jewelcrafting = 12,
    Inscription = 13, Archaeology = 14 }
Enum.ChatChannelType = { None = 0, Custom = 1, PrivateParty = 2, PublicParty = 3, Communities = 4 }
LE_ITEM_QUALITY_POOR, LE_ITEM_QUALITY_COMMON, LE_ITEM_QUALITY_UNCOMMON, LE_ITEM_QUALITY_RARE = 0, 1, 2, 3
LE_ITEM_QUALITY_EPIC, LE_ITEM_QUALITY_LEGENDARY = 4, 5
LOOT_SLOT_NONE, LOOT_SLOT_ITEM, LOOT_SLOT_MONEY, LOOT_SLOT_CURRENCY = 0, 1, 2, 3
WOW_PROJECT_MAINLINE, WOW_PROJECT_CLASSIC = 1, 2
WOW_PROJECT_ID = WOW_PROJECT_MAINLINE
LE_EXPANSION_LEVEL_CURRENT = 0
function GetExpansionLevel() return 0 end
function GetServerExpansionLevel() return 0 end
function GetClassicExpansionLevel() return 0 end

-- Host helper: evaluate an expression and return it as JSON (inspector, importers).
function S.EvalJSON(expr)
    local fn, err = loadstring("return " .. expr, "eval")
    if not fn then return S.JSON({ error = err }) end
    local ok, value = pcall(fn)
    if not ok then return S.JSON({ error = tostring(value) }) end
    return S.JSON({ value = value })
end

-- Host helper: run a SavedVariables file in a scratch environment and return its variables as JSON.
function S.ParseSavedVariablesJSON(text)
    local fn, err = loadstring(text, "savedvariables")
    if not fn then return S.JSON({ error = err }) end
    local env = {}
    setfenv(fn, env)
    local ok, runErr = pcall(fn)
    if not ok then return S.JSON({ error = tostring(runErr) }) end
    return S.JSON({ value = env })
end
