-- XML: builds frames, regions, fonts and templates from parsed addon XML.
-- The host parses the XML and hands over a Lua table: { tag, attr = {}, children = {}, text, line }.
local S = SANDBOX
local host = S.host
local W = S.W

-- A few GlobalStrings that Blizzard-style XML refers to by name (text="OKAY").
for k, v in pairs({ OKAY = "Okay", CANCEL = "Cancel", CLOSE = "Close", ACCEPT = "Accept", DECLINE = "Decline",
    YES = "Yes", NO = "No", DONE = "Done", DEFAULTS = "Defaults", NAME = "Name", FILTER = "Filter", RESET = "Reset",
    SAVE = "Save", DELETE = "Delete", REMOVE = "Remove", NONE = "None", ENABLE = "Enable", DISABLE = "Disable",
    ADD = "Add", BACK = "Back", NEXT = "Next", PREV = "Prev", OPTIONS = "Options", APPLY = "Apply", EDIT = "Edit",
    UNKNOWN = "Unknown", LOADING = "Loading...", ALL = "All", OTHER = "Other", GENERAL = "General", HELP_LABEL = "Help",
    CONTINUE = "Continue", PREVIOUS = "Previous", COMBAT = "Combat", LOCK = "Lock", UNLOCK = "Unlock" }) do
    if _G[k] == nil then _G[k] = v end
end

local warnedTags = {}
local function UnknownTag(ctx, node)
    local key = node.tag
    if not warnedTags[key] then
        warnedTags[key] = true
        S.Missing("XML:<" .. key .. ">")
    end
end

local function Bool(v) return v == "true" or v == "1" end
local function Num(v) return tonumber(v) end

local function Dir(path) return path:match("^(.*)/[^/]*$") or "" end
local function Join(dir, file)
    file = file:gsub("\\", "/")
    if dir == "" then return file end
    return dir .. "/" .. file
end

local function Text(v)
    if not v then return nil end
    local g = _G[v]
    if type(g) == "string" then return g end
    return v
end

local function SubstParent(name, parent)
    if not name then return nil end
    if name:find("$", 1, true) then
        local pname = parent and W[parent] and W[parent].name or ""
        name = name:gsub("%$[pP]arent", pname)
    end
    return name
end

local function Children(node, tag)
    local out = {}
    for _, c in ipairs(node.children or {}) do if not tag or c.tag == tag then out[#out + 1] = c end end
    return out
end
local function FirstChild(node, tag)
    for _, c in ipairs(node.children or {}) do if c.tag == tag then return c end end
end

-- <Size x= y=> or <Size><AbsDimension x= y=/></Size>
local function Dimension(node)
    local abs = FirstChild(node, "AbsDimension")
    local a = abs and abs.attr or node.attr
    return Num(a.x), Num(a.y)
end

local function ApplySize(region, node)
    local x, y = Dimension(node)
    local s = W[region]
    if x then s.width = x end
    if y then s.height = y end
    S.Changed()
end

-- relativeKey="$parent.Foo" walks from the region; relativeTo="$parentFoo" is a global name.
local function ResolveRelative(region, a)
    if a.relativeKey then
        local cur = region
        for part in a.relativeKey:gmatch("[^%.]+") do
            if part == "$parent" or part == "$Parent" then cur = W[cur] and W[cur].parent
            else cur = cur and cur[part] end
            if not cur then return nil, true end
        end
        return cur
    end
    if a.relativeTo then
        local parent = W[region].parent
        if a.relativeTo == "$parent" or a.relativeTo == "$Parent" then return parent end
        local name = SubstParent(a.relativeTo, parent)
        local target = _G[name]
        if not target then return nil, true end
        return target
    end
    return nil
end

local function ApplyAnchors(ctx, region, node)
    for _, anchor in ipairs(Children(node, "Anchor")) do
        local a = anchor.attr
        local rel, missing = ResolveRelative(region, a)
        local x, y = Num(a.x) or 0, Num(a.y) or 0
        local offset = FirstChild(anchor, "Offset")
        if offset then
            local ox, oy = Dimension(offset)
            x, y = ox or x, oy or y
        end
        local function apply(target)
            local ok, err = pcall(region.SetPoint, region, a.point or "CENTER", target, a.relativePoint or a.point or "CENTER", x, y)
            if not ok then S.ReportError(("%s:%d: %s"):format(ctx.path, anchor.line or 0, tostring(err)), "") end
        end
        if missing then
            -- Target not created yet (a later sibling): retry once the whole top-level frame exists.
            table.insert(ctx.deferred, function()
                local target = ResolveRelative(region, a)
                if target then apply(target)
                else S.Warn(("%s:%d: anchor target %s not found"):format(ctx.path, anchor.line or 0, a.relativeKey or a.relativeTo)) end
            end)
        else
            apply(rel)
        end
    end
end

local function ApplyColor(node)
    local a = node.attr
    if a.color then
        local c = _G[a.color]
        if type(c) == "table" and c.GetRGBA then return c:GetRGBA() end
    end
    return Num(a.r) or 1, Num(a.g) or 1, Num(a.b) or 1, Num(a.a) or 1
end

local function ApplyKeyValues(obj, node)
    for _, kv in ipairs(Children(node, "KeyValue")) do
        local a = kv.attr
        local key = a.keyType == "number" and tonumber(a.key) or a.key
        local value = a.value
        local t = a.type or "string"
        if t == "number" then value = tonumber(value)
        elseif t == "boolean" then value = value == "true"
        elseif t == "nil" then value = nil
        elseif t == "global" then value = _G[value] end
        if key ~= nil then obj[key] = value end
    end
end

local function ParentKey(obj, parent, a)
    if not parent then return end
    if a.parentKey then
        parent[a.parentKey] = obj
        W[obj].parentKey = a.parentKey
    end
    if a.parentArray then
        parent[a.parentArray] = parent[a.parentArray] or {}
        table.insert(parent[a.parentArray], obj)
    end
end

---------------------------------------------------------------------------
-- Scripts
---------------------------------------------------------------------------
local SCRIPT_ARGS = { OnEvent = "self, event, ...", OnUpdate = "self, elapsed", OnClick = "self, button, down",
    PreClick = "self, button, down", PostClick = "self, button, down", OnDoubleClick = "self, button",
    OnEnter = "self, motion", OnLeave = "self, motion", OnMouseDown = "self, button", OnMouseUp = "self, button, upInside",
    OnMouseWheel = "self, delta", OnValueChanged = "self, value, userInput", OnTextChanged = "self, userInput",
    OnChar = "self, text", OnKeyDown = "self, key", OnKeyUp = "self, key", OnDragStart = "self, button",
    OnDragStop = "self", OnReceiveDrag = "self", OnSizeChanged = "self, width, height", OnVerticalScroll = "self, offset",
    OnHorizontalScroll = "self, offset", OnScrollRangeChanged = "self, xrange, yrange",
    OnAttributeChanged = "self, name, value", OnHyperlinkClick = "self, link, text, button",
    OnHyperlinkEnter = "self, link, text", OnMinMaxChanged = "self, min, max", OnFinished = "self, requested",
    OnTooltipSetItem = "self", OnShow = "self", OnHide = "self", OnLoad = "self" }

local function CompileScript(ctx, node, scriptName)
    local a = node.attr
    if a["function"] then
        local fname = a["function"]
        return function(...)
            local fn = _G[fname]
            if fn then return fn(...) end
            error(("%s: script function %s not found"):format(scriptName, fname), 2)
        end
    end
    if a.method then
        local method = a.method
        return function(self, ...)
            local fn = self[method]
            if fn then return fn(self, ...) end
        end
    end
    local body = node.text
    if not body or body:match("^%s*$") then return nil end
    local args = SCRIPT_ARGS[scriptName] or "self, ..."
    local src = ("return function(%s)%s%s\nend"):format(args, string.rep("\n", math.max((node.line or 1) - 1, 0)), body)
    local fn, err = loadstring(src, "@Interface/AddOns/" .. ctx.addon .. "/" .. ctx.path)
    if not fn then S.ReportError(err, "") return nil end
    return fn()
end

local function ApplyScripts(ctx, obj, node)
    local s = W[obj]
    for _, scriptNode in ipairs(node.children or {}) do
        local name = scriptNode.tag
        local fn = CompileScript(ctx, scriptNode, name)
        if fn then
            local inherit = scriptNode.attr.inherit
            local existing = s.scripts and s.scripts[name]
            if existing and inherit == "prepend" then
                local old = existing
                fn = (function(new) return function(...) new(...) return old(...) end end)(fn)
            elseif existing and inherit == "append" then
                local old = existing
                fn = (function(new) return function(...) old(...) return new(...) end end)(fn)
            end
            if s.isFrame then obj:SetScript(name, fn)
            elseif s.scripts then s.scripts[name] = fn end
        end
    end
end

---------------------------------------------------------------------------
-- Fonts
---------------------------------------------------------------------------
local function ApplyFontNode(font, node)
    local fs = W[font]
    local a = node.attr
    if a.inherits then font:SetFontObject(a.inherits) end
    if a.font then fs.file = a.font end
    if a.height then fs.size = Num(a.height) end
    if a.outline then fs.flags = a.outline == "NORMAL" and "OUTLINE" or (a.outline == "THICK" and "THICKOUTLINE" or "") end
    if a.monochrome == "true" then fs.flags = (fs.flags or "") .. ",MONOCHROME" end
    if a.justifyH then fs.justifyH = a.justifyH end
    if a.justifyV then fs.justifyV = a.justifyV end
    if a.spacing then fs.spacing = Num(a.spacing) end
    for _, c in ipairs(node.children or {}) do
        if c.tag == "FontHeight" then
            local v = FirstChild(c, "AbsValue")
            fs.size = Num((v or c).attr.val) or fs.size
        elseif c.tag == "Color" then
            local r, g, b, al = ApplyColor(c)
            fs.color = { r, g, b, al }
        elseif c.tag == "Shadow" then
            local col = FirstChild(c, "Color")
            fs.shadow = col and { ApplyColor(col) } or { 0, 0, 0, 1 }
        end
    end
end

local function LoadFont(ctx, node)
    local name = node.attr.name
    local font = CreateFont(name)
    ApplyFontNode(font, node)
    return font
end

local function LoadFontFamily(ctx, node)
    local roman
    for _, member in ipairs(Children(node, "Member")) do
        if member.attr.alphabet == "roman" or not roman then roman = FirstChild(member, "Font") end
    end
    local font = CreateFont(node.attr.name)
    if roman then ApplyFontNode(font, roman) end
end

---------------------------------------------------------------------------
-- Regions
---------------------------------------------------------------------------
local ApplyRegionNode

local function CreateRegion(ctx, node, parent, layer, sublevel)
    local a = node.attr
    local name = SubstParent(a.name, parent)
    local obj
    if node.tag == "FontString" then
        obj = parent:CreateFontString(name, layer, nil)
    elseif node.tag == "MaskTexture" then
        obj = parent:CreateMaskTexture(name, layer, nil, sublevel)
    elseif node.tag == "Line" then
        obj = parent:CreateLine(name, layer, nil, sublevel)
    else
        obj = parent:CreateTexture(name, layer, nil, sublevel)
    end
    ParentKey(obj, parent, a)
    ApplyRegionNode(ctx, obj, node)
    return obj
end

ApplyRegionNode = function(ctx, obj, node)
    local a = node.attr
    local s = W[obj]
    if a.inherits then
        for t in a.inherits:gmatch("[^,%s]+") do
            if s.isFontString and S.fontObjects[t] then s.fontObject = S.fontObjects[t]
            else S.ApplyTemplates(obj, t) end
        end
    end
    if a.mixin then for m in a.mixin:gmatch("[^,%s]+") do if _G[m] then Mixin(obj, _G[m]) end end end
    if a.hidden then s.shown = not Bool(a.hidden) end
    if a.alpha then s.alpha = Num(a.alpha) or 1 end
    if a.setAllPoints == "true" then obj:SetAllPoints() end
    if s.isFontString then
        if a.font then s.file = a.font end
        if a.text then obj:SetText(Text(a.text)) end
        if a.justifyH then obj:SetJustifyH(a.justifyH) end
        if a.justifyV then obj:SetJustifyV(a.justifyV) end
        if a.maxLines then obj:SetMaxLines(Num(a.maxLines)) end
        if a.wordwrap then obj:SetWordWrap(Bool(a.wordwrap)) end
        if a.spacing then obj:SetSpacing(Num(a.spacing)) end
    else
        if a.file then obj:SetTexture(a.file) end
        if a.atlas then obj:SetAtlas(a.atlas, Bool(a.useAtlasSize)) end
        if a.alphaMode then obj:SetBlendMode(a.alphaMode) end
        if a.desaturated then obj:SetDesaturated(Bool(a.desaturated)) end
    end
    for _, c in ipairs(node.children or {}) do
        local tag = c.tag
        if tag == "Size" then ApplySize(obj, c)
        elseif tag == "Anchors" then ApplyAnchors(ctx, obj, c)
        elseif tag == "Color" then
            if s.isFontString then obj:SetTextColor(ApplyColor(c)) else obj:SetColorTexture(ApplyColor(c)) end
        elseif tag == "TexCoords" then
            local ta = c.attr
            obj:SetTexCoord(Num(ta.left) or 0, Num(ta.right) or 1, Num(ta.top) or 0, Num(ta.bottom) or 1)
        elseif tag == "Gradient" then
            local minC, maxC = FirstChild(c, "MinColor"), FirstChild(c, "MaxColor")
            if minC and maxC then obj:SetGradient(c.attr.orientation or "HORIZONTAL", CreateColor(ApplyColor(minC)), CreateColor(ApplyColor(maxC))) end
        elseif tag == "KeyValues" then ApplyKeyValues(obj, c)
        elseif tag == "Shadow" then
            local col = FirstChild(c, "Color")
            s.shadow = col and { ApplyColor(col) } or { 0, 0, 0, 1 }
        elseif tag == "FontHeight" then
            local v = FirstChild(c, "AbsValue")
            s.size = Num((v or c).attr.val)
        elseif tag == "Animations" or tag == "Scripts" then
            -- region animations and scripts aren't emulated
        else
            UnknownTag(ctx, c)
        end
    end
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
local CreateFrameFromNode

-- Templates apply later than they were defined, so each application gets its own deferred-anchor list.
function S.ApplyXMLTemplate(ctx, obj, node, apply)
    local c = setmetatable({ deferred = {} }, { __index = ctx })
    apply(c, obj, node)
    for _, fn in ipairs(c.deferred) do fn() end
end

local BUTTON_TEXTURES = { NormalTexture = "SetNormalTexture", PushedTexture = "SetPushedTexture",
    DisabledTexture = "SetDisabledTexture", HighlightTexture = "SetHighlightTexture", CheckedTexture = "SetCheckedTexture",
    DisabledCheckedTexture = "SetDisabledCheckedTexture", ThumbTexture = "SetThumbTexture", BarTexture = "SetStatusBarTexture" }
local BUTTON_FONTS = { NormalFont = "SetNormalFontObject", HighlightFont = "SetHighlightFontObject", DisabledFont = "SetDisabledFontObject" }

local function ApplyFrameNode(ctx, obj, node)
    local a = node.attr
    local s = W[obj]
    if a.inherits then S.ApplyTemplates(obj, a.inherits) end
    for _, key in ipairs({ "mixin", "secureMixin" }) do
        if a[key] then
            for m in a[key]:gmatch("[^,%s]+") do
                if _G[m] then Mixin(obj, _G[m]) else S.Warn(("%s: mixin %s not found"):format(ctx.path, m)) end
            end
        end
    end
    if a.hidden then s.shown = not Bool(a.hidden); S.Changed() end
    if a.enableMouse then obj:EnableMouse(Bool(a.enableMouse)) end
    if a.enableMouseWheel then obj:EnableMouseWheel(Bool(a.enableMouseWheel)) end
    if a.enableKeyboard then obj:EnableKeyboard(Bool(a.enableKeyboard)) end
    if a.movable then obj:SetMovable(Bool(a.movable)) end
    if a.resizable then obj:SetResizable(Bool(a.resizable)) end
    if a.clampedToScreen then obj:SetClampedToScreen(Bool(a.clampedToScreen)) end
    if a.toplevel then obj:SetToplevel(Bool(a.toplevel)) end
    if a.frameStrata then obj:SetFrameStrata(a.frameStrata) end
    if a.frameLevel then obj:SetFrameLevel(Num(a.frameLevel)) end
    if a.useParentLevel == "true" then s.level = nil end
    if a.id then obj:SetID(Num(a.id)) end
    if a.alpha then obj:SetAlpha(Num(a.alpha)) end
    if a.scale then obj:SetScale(Num(a.scale)) end
    if a.clipChildren then obj:SetClipsChildren(Bool(a.clipChildren)) end
    if a.setAllPoints == "true" then obj:SetAllPoints() end
    if a.registerForClicks and obj.RegisterForClicks then obj:RegisterForClicks(strsplit(",", a.registerForClicks)) end
    if a.registerForDrag then obj:RegisterForDrag(strsplit(",", a.registerForDrag)) end
    if s.isEditBox then
        if a.autoFocus then obj:SetAutoFocus(Bool(a.autoFocus)) end
        if a.numeric then obj:SetNumeric(Bool(a.numeric)) end
        if a.letters then obj:SetMaxLetters(Num(a.letters)) end
        if a.multiLine then obj:SetMultiLine(Bool(a.multiLine)) end
        if a.password then obj:SetPassword(Bool(a.password)) end
    end
    if s.isButton and a.text then obj:SetText(Text(a.text)) end
    if s.isCheckButton and a.checked then obj:SetChecked(Bool(a.checked)) end
    if s.isButton and a.motionScriptsWhileDisabled then obj:SetMotionScriptsWhileDisabled(Bool(a.motionScriptsWhileDisabled)) end
    if s.isSlider or s.isStatusBar then
        if a.minValue or a.maxValue then obj:SetMinMaxValues(Num(a.minValue) or 0, Num(a.maxValue) or 0) end
        if a.defaultValue then obj:SetValue(Num(a.defaultValue)) end
        if a.orientation then obj:SetOrientation(a.orientation) end
        if s.isSlider and a.valueStep then obj:SetValueStep(Num(a.valueStep)) end
        if s.isSlider and a.obeyStepOnDrag then obj:SetObeyStepOnDrag(Bool(a.obeyStepOnDrag)) end
        if s.isStatusBar and a.reverseFill then obj:SetReverseFill(Bool(a.reverseFill)) end
    end

    local anchorsNode
    for _, c in ipairs(node.children or {}) do
        local tag = c.tag
        if tag == "Size" then ApplySize(obj, c)
        elseif tag == "Anchors" then anchorsNode = c
        elseif tag == "Layers" then
            for _, layer in ipairs(Children(c, "Layer")) do
                local level = layer.attr.level or "ARTWORK"
                local sub = Num(layer.attr.textureSubLevel) or 0
                for _, r in ipairs(layer.children or {}) do
                    if r.tag == "Texture" or r.tag == "FontString" or r.tag == "MaskTexture" or r.tag == "Line" then
                        CreateRegion(ctx, r, obj, level, sub)
                    else
                        UnknownTag(ctx, r)
                    end
                end
            end
        elseif tag == "Frames" then
            for _, child in ipairs(c.children or {}) do CreateFrameFromNode(ctx, child, obj) end
        elseif tag == "Scripts" then ApplyScripts(ctx, obj, c)
        elseif tag == "KeyValues" then ApplyKeyValues(obj, c)
        elseif BUTTON_TEXTURES[tag] then
            local layer = tag == "HighlightTexture" and "HIGHLIGHT" or (tag == "CheckedTexture" or tag == "DisabledCheckedTexture" or tag == "ThumbTexture") and "OVERLAY" or "ARTWORK"
            local tex = CreateRegion(ctx, c, obj, layer, 0)
            local setter = obj[BUTTON_TEXTURES[tag]]
            if setter then setter(obj, tex) end
        elseif BUTTON_FONTS[tag] then
            local setter = obj[BUTTON_FONTS[tag]]
            if setter and c.attr.style then setter(obj, c.attr.style) end
        elseif tag == "ButtonText" then
            local fs = CreateRegion(ctx, c, obj, "OVERLAY", 0)
            if obj.SetFontString then obj:SetFontString(fs) end
            if #W[fs].points == 0 then fs:SetPoint("CENTER") end
        elseif tag == "FontString" and s.isEditBox then
            if c.attr.inherits then obj:SetFontObject(c.attr.inherits) end
        elseif tag == "ScrollChild" then
            for _, child in ipairs(c.children or {}) do
                local sc = CreateFrameFromNode(ctx, child, obj)
                if sc and obj.SetScrollChild then obj:SetScrollChild(sc) end
            end
        elseif tag == "HitRectInsets" then
            local ins = FirstChild(c, "AbsInset")
            local ia = (ins or c).attr
            obj:SetHitRectInsets(Num(ia.left) or 0, Num(ia.right) or 0, Num(ia.top) or 0, Num(ia.bottom) or 0)
        elseif tag == "TextInsets" then
            local ins = FirstChild(c, "AbsInset")
            local ia = (ins or c).attr
            if obj.SetTextInsets then obj:SetTextInsets(Num(ia.left) or 0, Num(ia.right) or 0, Num(ia.top) or 0, Num(ia.bottom) or 0) end
        elseif tag == "Attributes" then
            for _, attrNode in ipairs(Children(c, "Attribute")) do
                local at = attrNode.attr
                local value = at.value
                if at.type == "number" then value = tonumber(value) elseif at.type == "boolean" then value = value == "true" end
                obj:SetAttribute(at.name, value)
            end
        elseif tag == "Animations" then
            for _, ag in ipairs(Children(c, "AnimationGroup")) do
                local group = obj:CreateAnimationGroup(SubstParent(ag.attr.name, obj))
                if ag.attr.parentKey then obj[ag.attr.parentKey] = group end
                if ag.attr.looping then group:SetLooping(ag.attr.looping) end
            end
        elseif tag == "Backdrop" then
            -- Legacy <Backdrop>: only meaningful with BackdropTemplate.
            if obj.SetBackdrop then obj:SetBackdrop({ bgFile = c.attr.bgFile, edgeFile = c.attr.edgeFile, edgeSize = 16 }) end
        elseif tag == "ResizeBounds" or tag == "PushedTextOffset" or tag == "HighlightColor" or tag == "DisabledColor"
            or tag == "NormalColor" or tag == "FontHeight" or tag == "Color" or tag == "Shadow" then
            -- cosmetic, ignored
        else
            UnknownTag(ctx, c)
        end
    end
    if anchorsNode then ApplyAnchors(ctx, obj, anchorsNode) end
end

CreateFrameFromNode = function(ctx, node, parent)
    local tag = node.tag
    if not S.FRAME_TYPES[tag:lower()] then
        UnknownTag(ctx, node)
        return nil
    end
    local a = node.attr
    if a.virtual == "true" then
        -- A virtual frame nested in another frame is still a global template.
        S.RegisterTemplate(a.name, function(obj) S.ApplyXMLTemplate(ctx, obj, node, ApplyFrameNode) end)
        return nil
    end
    local p = parent
    if a.parent then p = _G[a.parent] or p end
    local name = SubstParent(a.name, p)
    local ok, obj = pcall(S.CreateFrameRaw, tag, name, p)
    if not ok then S.ReportError(("%s:%d: %s"):format(ctx.path, node.line or 0, tostring(obj)), "") return nil end
    ParentKey(obj, p, a)
    ApplyFrameNode(ctx, obj, node)
    S.RunScript(obj, "OnLoad")
    return obj
end

---------------------------------------------------------------------------
-- Files
---------------------------------------------------------------------------
local function LoadUiNode(ctx, node)
    local tag = node.tag
    local a = node.attr
    if tag == "Script" then
        if a.file then
            S.RunFile(ctx.addon, Join(ctx.dir, a.file), ctx.ns)
        elseif node.text and not node.text:match("^%s*$") then
            local src = string.rep("\n", math.max((node.line or 1) - 1, 0)) .. node.text
            local fn, err = loadstring(src, "@Interface/AddOns/" .. ctx.addon .. "/" .. ctx.path)
            if fn then S.Call(fn) else S.ReportError(err, "") end
        end
    elseif tag == "Include" then
        if a.file then S.RunFile(ctx.addon, Join(ctx.dir, a.file), ctx.ns) end
    elseif tag == "Font" then
        LoadFont(ctx, node)
    elseif tag == "FontFamily" then
        LoadFontFamily(ctx, node)
    elseif tag == "Texture" or tag == "FontString" then
        if a.virtual == "true" and a.name then
            S.RegisterTemplate(a.name, function(obj) S.ApplyXMLTemplate(ctx, obj, node, ApplyRegionNode) end)
        end
    elseif tag == "AnimationGroup" then
        -- virtual animation groups: not emulated
    else
        ctx.deferred = {}
        CreateFrameFromNode(ctx, node, nil)
        for _, fn in ipairs(ctx.deferred) do fn() end
    end
end

function S.LoadXMLFile(addon, path, ns)
    local literal = host.xml(addon, path)
    if not literal then
        S.Warn(("%s: couldn't open %s"):format(addon, path))
        return
    end
    local fn, err = loadstring("return " .. literal, "@" .. path)
    if not fn then S.ReportError(("%s: %s"):format(path, err), "") return end
    local tree = fn()
    if tree.error then
        S.ReportError(("Interface/AddOns/%s/%s:%d: XML error: %s"):format(addon, path, tree.line or 0, tree.error), "")
        return
    end
    local ctx = { addon = addon, path = path, dir = Dir(path), ns = ns, deferred = {} }
    for _, node in ipairs(tree.children or {}) do LoadUiNode(ctx, node) end
end
