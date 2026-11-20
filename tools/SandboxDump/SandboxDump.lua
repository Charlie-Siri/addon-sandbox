-- Sandbox Dump: records facts about the real client for the Addon Sandbox.
-- /sbdump        build info, API names, enums, widget methods, then item data (takes a few minutes)
-- /sbdump items  item data only
-- Results land in SandboxDumpDB, written to WTF/Account/<account>/SavedVariables/SandboxDump.lua on /reload.
local addonName = ...
local PREFIX = "|cff33ff99Sandbox Dump|r: "
local function Print(msg, ...) print(PREFIX .. (select("#", ...) > 0 and msg:format(...) or msg)) end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" and ... == addonName then
        SandboxDumpDB = SandboxDumpDB or {}
        -- Counts loads: if this goes up across /reload, SavedVariables are read back correctly.
        SandboxDumpDB.sessions = (SandboxDumpDB.sessions or 0) + 1
        if SandboxDumpDB.sessions > 1 then
            Print("SavedVariables read back OK (session %d). /sbdump to export client data.", SandboxDumpDB.sessions)
        end
    end
end)

local function SortedKeys(t)
    local out = {}
    for k in pairs(t) do if type(k) == "string" then out[#out + 1] = k end end
    table.sort(out)
    return out
end

local function DumpBuild(db)
    local version, build, date, interface, localized, buildType = GetBuildInfo()
    db.build = { version = version, build = build, date = date, interface = interface, localized = localized,
        buildType = buildType, locale = GetLocale(), project = WOW_PROJECT_ID, time = time() }
    Print("Client %s build %s, interface %s.", tostring(version), tostring(build), tostring(interface))
end

local function DumpApi(db)
    local functions, namespaces, tables = {}, {}, {}
    for _, name in ipairs(SortedKeys(_G)) do
        local ok, value = pcall(function() return _G[name] end)
        if ok then
            local tv = type(value)
            if tv == "function" then
                functions[#functions + 1] = name
            elseif tv == "table" and (name:match("^C_") or name == "Enum" or name == "Settings" or name == "MenuUtil") then
                local members = {}
                for _, key in ipairs(SortedKeys(value)) do
                    if type(value[key]) == "function" then members[#members + 1] = key end
                end
                namespaces[name] = members
            elseif tv == "table" and not (value.GetObjectType) and name:match("^%u[%w_]*$") and name:match("Mixin$") then
                tables[#tables + 1] = name
            end
        end
    end
    db.functions, db.namespaces, db.mixins = functions, namespaces, tables
    local n = 0
    for _ in pairs(namespaces) do n = n + 1 end
    Print("%d global functions, %d C_ namespaces, %d mixins.", #functions, n, #tables)
end

local function DumpEnums(db)
    local enums = {}
    for _, name in ipairs(SortedKeys(Enum or {})) do
        local e = {}
        for k, v in pairs(Enum[name]) do
            if type(k) == "string" and type(v) == "number" then e[k] = v end
        end
        enums[name] = e
    end
    db.enums = enums
end

local WIDGETS = { "Frame", "Button", "CheckButton", "EditBox", "ScrollFrame", "Slider", "StatusBar", "Cooldown",
    "GameTooltip", "MessageFrame", "ScrollingMessageFrame", "Model", "PlayerModel", "ColorSelect", "SimpleHTML" }

local function Methods(obj)
    local out = {}
    local mt = getmetatable(obj)
    local index = mt and mt.__index
    if type(index) == "table" then
        for _, key in ipairs(SortedKeys(index)) do out[#out + 1] = key end
    end
    return out
end

local function DumpWidgets(db)
    local widgets = {}
    local parent = CreateFrame("Frame")
    for _, t in ipairs(WIDGETS) do
        local ok, obj = pcall(CreateFrame, t, nil, parent)
        if ok and obj then widgets[t] = Methods(obj) else widgets[t] = false end
    end
    widgets.Texture = Methods(parent:CreateTexture())
    widgets.FontString = Methods(parent:CreateFontString())
    widgets.AnimationGroup = Methods(parent:CreateAnimationGroup())
    widgets.Font = Methods(CreateFont("SandboxDumpFont"))
    db.widgets = widgets
end

-- Item IDs worth knowing: everything VendorPrinter recorded, plus your bags.
local function CollectItemIDs()
    local ids = {}
    local function add(id) id = tonumber(id) if id and id > 0 then ids[id] = true end end
    local vp = _G.VendorPrinterDB
    if type(vp) == "table" then
        for _, key in ipairs({ "vendor", "ah", "ahMin" }) do
            for id in pairs(vp[key] or {}) do add(id) end
        end
    end
    local char = _G.VendorPrinterCharDB
    if type(char) == "table" then
        for _, prof in pairs(char.professions or {}) do
            for _, recipe in pairs(prof.recipes or {}) do
                add(recipe.output)
                for _, slot in ipairs(recipe.reagents or {}) do
                    for _, id in ipairs(slot.ids or {}) do add(id) end
                end
            end
        end
    end
    if C_Container then
        for bag = 0, 5 do
            for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do add(C_Container.GetContainerItemID(bag, slot)) end
        end
    end
    local list = {}
    for id in pairs(ids) do list[#list + 1] = id end
    table.sort(list)
    return list
end

local function ReadItem(id)
    local name, _, quality, itemLevel, minLevel, typeName, subTypeName, stack, equipLoc, icon, sellPrice, classID,
        subclassID, bindType, expansion, setID, isReagent = C_Item.GetItemInfo(id)
    if not name then return nil end
    return { name = name, quality = quality, itemLevel = itemLevel, minLevel = minLevel, type = typeName,
        subType = subTypeName, stack = stack, equipLoc = equipLoc ~= "" and equipLoc or nil, icon = icon,
        sellPrice = sellPrice, classID = classID, subclassID = subclassID, bind = bindType, reagent = isReagent or nil }
end

-- Requests item data in batches and waits for the client to answer.
local BATCH, TIMEOUT = 40, 8
local function DumpItems(db, done)
    local ids = CollectItemIDs()
    db.items = db.items or {}
    local index, missing = 1, 0
    Print("Reading %d items (about %d seconds)...", #ids, math.ceil(#ids / BATCH * 0.6))
    local lastPercent = -1
    local function step()
        local batch = {}
        for i = index, math.min(index + BATCH - 1, #ids) do
            batch[#batch + 1] = ids[i]
            C_Item.RequestLoadItemDataByID(ids[i])
        end
        local started = GetTime()
        local function poll()
            local pending = 0
            for _, id in ipairs(batch) do
                if not db.items[id] then
                    local item = ReadItem(id)
                    if item then db.items[id] = item else pending = pending + 1 end
                end
            end
            if pending > 0 and GetTime() - started < TIMEOUT then C_Timer.After(0.2, poll) return end
            missing = missing + pending
            index = index + #batch
            local percent = math.floor((index - 1) / math.max(#ids, 1) * 10) * 10
            if percent > lastPercent then lastPercent = percent; Print("Items %d%%", percent) end
            if index <= #ids then C_Timer.After(0.05, step)
            else
                Print("Items done: %d read, %d without data.", #ids - missing, missing)
                if done then done() end
            end
        end
        poll()
    end
    if #ids == 0 then Print("No item IDs found (is VendorPrinter enabled?).") if done then done() end return end
    step()
end

SLASH_SANDBOXDUMP1 = "/sbdump"
SlashCmdList.SANDBOXDUMP = function(msg)
    msg = strtrim(msg or ""):lower()
    local db = SandboxDumpDB
    local function finish() Print("Done. /reload to write the file, then use \"Import client dump\" in the sandbox.") end
    if msg == "items" then DumpItems(db, finish) return end
    DumpBuild(db)
    DumpApi(db)
    DumpEnums(db)
    DumpWidgets(db)
    DumpItems(db, finish)
end
