-- Widgets: object model, anchor layout, render list, hit testing, mouse and keyboard input.
-- Coordinates are WoW's: origin bottom-left, y up, in UIParent units (screen height 768 at scale 1).
local S = SANDBOX
local host = S.host

local W = setmetatable({}, { __mode = "k" })   -- [widget object] = internal state
S.W = W
local frames = {}                              -- every frame, creation order
S.allFrames = frames
local nextId = 0
local layoutGen = 1
S.dirty = true
S.screenW, S.screenH = 1365, 768

local function Changed() layoutGen = layoutGen + 1; S.dirty = true end   -- geometry, visibility or text changed
local function Repaint() S.dirty = true end                              -- visuals only
S.Changed, S.Repaint = Changed, Repaint

local STRATA = { WORLD = 0, BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6,
    FULLSCREEN_DIALOG = 7, TOOLTIP = 8, BLIZZARD = 9 }
local STRATA_NAMES = {}
for k, v in pairs(STRATA) do STRATA_NAMES[v] = k end
local LAYERS = { BACKGROUND = 1, BORDER = 2, ARTWORK = 3, OVERLAY = 4, HIGHLIGHT = 5 }
local POINTS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

---------------------------------------------------------------------------
-- Classes
---------------------------------------------------------------------------
local Classes = {}
S.Classes = Classes

local function Class(name, parent)
    local methods = {}
    local class = { name = name, parent = parent and Classes[parent], methods = methods }
    class.meta = { __index = methods }
    if parent then setmetatable(methods, { __index = Classes[parent].methods }) end
    Classes[name] = class
    return methods
end
S.Class = Class

local function State(self, method)
    local s = W[self]
    if not s then error(("Usage: %s called on an invalid object"):format(method or "method"), 3) end
    return s
end
S.State = State

local function NewObject(className, objType, name)
    nextId = nextId + 1
    local obj = { [0] = newproxy() }
    local s = { id = nextId, obj = obj, class = Classes[className], type = objType or className, name = name,
        shown = true, alpha = 1, points = {}, layoutDirtyCb = nil }
    W[obj] = s
    setmetatable(obj, Classes[className].meta)
    return obj, s
end
S.NewObject = NewObject

-- Methods every real widget has but the sandbox doesn't emulate: no-ops that report themselves once.
local function StubMethods(class, names, ret)
    for _, name in ipairs(names) do
        if not class[name] then
            class[name] = function() S.Missing("Widget:" .. name) return ret end
        end
    end
end
S.StubMethods = StubMethods

---------------------------------------------------------------------------
-- Object / ScriptObject
---------------------------------------------------------------------------
local Object = Class("Object")

function Object:GetName() return State(self).name end
function Object:GetObjectType() return State(self).type end
function Object:IsObjectType(t)
    local s = State(self)
    if s.type == t then return true end
    local c = s.class
    while c do
        if c.name == t then return true end
        c = c.parent
    end
    return false
end
function Object:GetParent() return State(self).parent end
function Object:GetDebugName()
    local s = State(self)
    if s.name then return s.name end
    local p = s.parent and W[s.parent]
    if p then
        for k, v in pairs(s.parent) do if v == self then return (p.name or "?") .. "." .. tostring(k) end end
    end
    return ("<%s %d>"):format(s.type, s.id)
end
function Object:IsForbidden() return false end
function Object:SetForbidden() end
function Object:CanChangeProtectedState() return true end
function Object:IsProtected() return false, false end
function Object:GetParentKey() return State(self).parentKey end
function Object:SetParentKey(key)
    local s = State(self)
    s.parentKey = key
    if s.parent then s.parent[key] = self end
end

---------------------------------------------------------------------------
-- Scripts and events
---------------------------------------------------------------------------
local MOUSE_SCRIPTS = { OnEnter = "motion", OnLeave = "motion", OnMouseDown = "click", OnMouseUp = "click",
    OnClick = "click", OnMouseWheel = "wheel" }

function S.RunScript(obj, name, ...)
    local s = W[obj]
    if not s or not s.scripts then return end
    local fn = s.scripts[name]
    if fn then S.Call(fn, obj, ...) end
    local hooks = s.hooks and s.hooks[name]
    if hooks then
        for i = 1, #hooks do S.Call(hooks[i], obj, ...) end
    end
end

function S.HasScript(obj, name)
    local s = W[obj]
    return s and s.scripts and (s.scripts[name] or (s.hooks and s.hooks[name])) and true or false
end

local eventFrames = {}   -- [event] = list of frames, registration order
S.eventFrames = eventFrames
S.registeredEvents = {}  -- [event] = count (shown in the dev panel)

function S.FireEvent(event, ...)
    S.eventLog(event, ...)
    local list = eventFrames[event]
    if not list then return end
    local copy = { unpack(list) }
    for i = 1, #copy do
        local f = copy[i]
        local s = W[f]
        if s and s.events and s.events[event] then
            local filter = s.unitFilter and s.unitFilter[event]
            if not filter or filter[(...)] then
                S.RunScript(f, "OnEvent", event, ...)
            end
        end
    end
end
-- Replaced by the API layer with something that forwards to the dev panel.
function S.eventLog() end

local function RegisterEvent(s, event)
    if s.events[event] then return end
    s.events[event] = true
    local list = eventFrames[event]
    if not list then list = {}; eventFrames[event] = list end
    list[#list + 1] = s.obj
    S.registeredEvents[event] = (S.registeredEvents[event] or 0) + 1
end

local function UnregisterEvent(s, event)
    if not s.events[event] then return end
    s.events[event] = nil
    if s.unitFilter then s.unitFilter[event] = nil end
    local list = eventFrames[event]
    for i = #list, 1, -1 do if list[i] == s.obj then table.remove(list, i) end end
    S.registeredEvents[event] = (S.registeredEvents[event] or 1) - 1
    if S.registeredEvents[event] <= 0 then S.registeredEvents[event] = nil end
end

---------------------------------------------------------------------------
-- Region (shared by frames, textures and font strings)
---------------------------------------------------------------------------
local Region = Class("Region", "Object")
Class("ScriptRegion", "Region")

local function IsVisible(s)
    while s do
        if not s.shown then return false end
        s = s.parent and W[s.parent]
    end
    return true
end
S.IsVisible = IsVisible

local function EffectiveScale(s)
    local scale = 1
    while s do
        if s.scale then scale = scale * s.scale end
        if s.ignoreParentScale then break end
        s = s.parent and W[s.parent]
    end
    return scale
end
S.EffectiveScale = EffectiveScale

-- Fires OnShow/OnHide down the tree for frames whose visibility changed.
local function PropagateVisibility(s, visible)
    if s.isFrame then
        if visible then
            S.RunScript(s.obj, "OnShow")
            if s.autoFocus and s.isEditBox then S.SetFocus(s.obj) end
        else
            if S.focus == s.obj then S.ClearFocus() end
            if S.moving and S.moving.s == s then S.moving = nil end
            S.RunScript(s.obj, "OnHide")
        end
        for _, child in ipairs(s.children) do
            local cs = W[child]
            if cs.shown then PropagateVisibility(cs, visible) end
        end
    end
end

local function SetShown(self, shown)
    local s = State(self)
    shown = shown and true or false
    if s.shown == shown then return end
    local before = IsVisible(s)
    s.shown = shown
    Changed()
    local after = IsVisible(s)
    if before ~= after then PropagateVisibility(s, after) end
end

function Region:Show() SetShown(self, true) end
function Region:Hide() SetShown(self, false) end
function Region:SetShown(shown) SetShown(self, shown) end
function Region:IsShown() return State(self).shown end
function Region:IsVisible() return IsVisible(State(self)) end

local function ResolveRelative(rel, method)
    if type(rel) == "string" then
        local found = _G[rel]
        if not found then error(("%s: Couldn't find region named '%s'"):format(method, rel), 3) end
        rel = found
    end
    if rel ~= nil and not W[rel] then error(method .. ": invalid relative region", 3) end
    return rel
end

-- True if `target` is (directly or through anchors) positioned relative to `s`.
local function DependsOn(target, s, seen)
    if target == s then return true end
    seen = seen or {}
    if seen[target] then return false end
    seen[target] = true
    for _, p in ipairs(target.points) do
        local rel = p.rel and W[p.rel] or (target.parent and W[target.parent])
        if rel and DependsOn(rel, s, seen) then return true end
    end
    return false
end

function Region:SetPoint(point, a, b, c, d)
    local s = State(self, "SetPoint")
    point = type(point) == "string" and point:upper() or point
    if not POINTS[point] then error(("SetPoint: invalid anchor point '%s'"):format(tostring(point)), 2) end
    local rel, relPoint, x, y
    if type(a) == "number" then
        x, y = a, b
    else
        rel = ResolveRelative(a, "SetPoint")
        if type(b) == "number" then relPoint, x, y = point, b, c
        else relPoint, x, y = b, c, d end
    end
    relPoint = type(relPoint) == "string" and relPoint:upper() or point
    if not POINTS[relPoint] then error(("SetPoint: invalid relative point '%s'"):format(tostring(relPoint)), 2) end
    if rel == self then error("SetPoint: Cannot anchor to itself", 2) end
    if rel and DependsOn(W[rel], s) then error("SetPoint: Cannot anchor to a region dependent on it", 2) end
    local entry = { point = point, rel = rel, relPoint = relPoint, x = tonumber(x) or 0, y = tonumber(y) or 0 }
    for i, p in ipairs(s.points) do
        if p.point == point then s.points[i] = entry; Changed() return end
    end
    s.points[#s.points + 1] = entry
    Changed()
end

function Region:SetAllPoints(rel, doResize)
    local s = State(self, "SetAllPoints")
    rel = ResolveRelative(rel, "SetAllPoints")
    if rel == self then error("SetAllPoints: Cannot anchor to itself", 2) end
    s.points = {
        { point = "TOPLEFT", rel = rel, relPoint = "TOPLEFT", x = 0, y = 0 },
        { point = "BOTTOMRIGHT", rel = rel, relPoint = "BOTTOMRIGHT", x = 0, y = 0 },
    }
    Changed()
end

function Region:ClearAllPoints()
    local s = State(self)
    if #s.points > 0 then s.points = {}; Changed() end
end

function Region:ClearPoint(point)
    local s = State(self)
    for i, p in ipairs(s.points) do
        if p.point == point then table.remove(s.points, i); Changed() return end
    end
end

function Region:ClearPointsOffset()
    local s = State(self)
    for _, p in ipairs(s.points) do p.x, p.y = 0, 0 end
    Changed()
end

function Region:AdjustPointsOffset(dx, dy)
    local s = State(self)
    for _, p in ipairs(s.points) do p.x, p.y = p.x + (dx or 0), p.y + (dy or 0) end
    Changed()
end

function Region:GetNumPoints() return #State(self).points end
function Region:GetPoint(i)
    local s = State(self)
    if type(i) == "string" then
        for _, p in ipairs(s.points) do if p.point == i then return p.point, p.rel, p.relPoint, p.x, p.y end end
        return
    end
    local p = s.points[i or 1]
    if p then return p.point, p.rel or s.parent, p.relPoint, p.x, p.y end
end
Region.GetPointByName = Region.GetPoint

function Region:SetSize(w, h)
    local s = State(self)
    s.width, s.height = tonumber(w), tonumber(h or w)
    Changed()
    if s.isFrame then S.RunScript(self, "OnSizeChanged", s.width, s.height) end
end
function Region:SetWidth(w)
    local s = State(self)
    s.width = tonumber(w)
    Changed()
    if s.isFrame then S.RunScript(self, "OnSizeChanged", s.width, s.height or 0) end
end
function Region:SetHeight(h)
    local s = State(self)
    s.height = tonumber(h)
    Changed()
    if s.isFrame then S.RunScript(self, "OnSizeChanged", s.width or 0, s.height) end
end

function Region:SetAlpha(a)
    local s = State(self)
    a = math.min(math.max(tonumber(a) or 1, 0), 1)
    if s.alpha ~= a then s.alpha = a; Repaint() end
end
function Region:GetAlpha() return State(self).alpha end
function Region:GetEffectiveAlpha()
    local s, a = State(self), 1
    while s do a = a * s.alpha; s = s.parent and W[s.parent] end
    return a
end
function Region:IsAnchoringRestricted() return false end
function Region:IsDragging() return S.dragging == self end
function Region:SetParentArray(key, value, unique) end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------
local resolving = {}
local Resolve

local function PointCoord(r, point)
    local l, b, w, h = r.l, r.b, r.w, r.h
    if point == "TOPLEFT" then return l, b + h
    elseif point == "TOP" then return l + w / 2, b + h
    elseif point == "TOPRIGHT" then return l + w, b + h
    elseif point == "LEFT" then return l, b + h / 2
    elseif point == "CENTER" then return l + w / 2, b + h / 2
    elseif point == "RIGHT" then return l + w, b + h / 2
    elseif point == "BOTTOMLEFT" then return l, b
    elseif point == "BOTTOM" then return l + w / 2, b
    else return l + w, b end
end

local H_LEFT = { TOPLEFT = true, LEFT = true, BOTTOMLEFT = true }
local H_RIGHT = { TOPRIGHT = true, RIGHT = true, BOTTOMRIGHT = true }
local V_TOP = { TOPLEFT = true, TOP = true, TOPRIGHT = true }
local V_BOTTOM = { BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

-- One axis: from the anchored edges and an optional size, derive start and length.
local function SolveAxis(lo, hi, mid, size)
    if lo and hi then return lo, hi - lo end
    if lo and size then return lo, size end
    if hi and size then return hi - size, size end
    if mid and size then return mid - size / 2, size end
    if lo and mid then return lo, (mid - lo) * 2 end
    if hi and mid then return 2 * mid - hi, (hi - mid) * 2 end
    local p = lo or hi or mid
    if p then return p, 0 end
    return nil
end

-- Text measurement through the host, cached.
local measureCache, linesCache = {}, {}
local measureCount = 0
function S.MeasureText(family, size, text)
    local key = family .. "\1" .. size .. "\1" .. text
    local w = measureCache[key]
    if not w then
        w = host.measure(family, size, text)
        measureCount = measureCount + 1
        if measureCount > 20000 then measureCache, measureCount = {}, 0 end
        measureCache[key] = w
    end
    return w
end
function S.CountLines(family, size, text, width)
    local key = family .. "\1" .. size .. "\1" .. math.floor(width) .. "\1" .. text
    local n = linesCache[key]
    if not n then
        n = host.lines(family, size, text, width)
        linesCache[key] = n
    end
    return n
end

local function Compute(s)
    if s.isScreen then
        s.l, s.b, s.w, s.h = 0, 0, S.screenW, S.screenH
        return true
    end
    local es = EffectiveScale(s)
    -- Scroll child: placed at the scroll frame's top-left, shifted by the scroll offsets.
    if s.scrollFrame then
        local sf = Resolve(s.scrollFrame)
        if not sf then return false end
        local sfs = W[s.scrollFrame]
        local w, h = (s.width or 0) * es, (s.height or 0) * es
        local top = sf.b + sf.h + (sfs.vscroll or 0) * es
        s.l, s.b, s.w, s.h = sf.l - (sfs.hscroll or 0) * es, top - h, w, h
        return true
    end
    -- Status bar fill: a slice of the bar.
    if s.fillOf then
        local bar = Resolve(s.fillOf)
        if not bar then return false end
        local bs = W[s.fillOf]
        local range = (bs.max or 1) - (bs.min or 0)
        local f = range > 0 and math.min(math.max(((bs.value or 0) - (bs.min or 0)) / range, 0), 1) or 0
        if bs.orientation == "VERTICAL" then
            local h = bar.h * f
            s.l, s.w, s.h = bar.l, bar.w, h
            s.b = bs.reverseFill and (bar.b + bar.h - h) or bar.b
        else
            local w = bar.w * f
            s.b, s.w, s.h = bar.b, w, bar.h
            s.l = bs.reverseFill and (bar.l + bar.w - w) or bar.l
        end
        return true
    end
    -- Slider thumb: positioned along the slider by value.
    if s.thumbOf then
        local sl = Resolve(s.thumbOf)
        if not sl then return false end
        local ss = W[s.thumbOf]
        local range = (ss.max or 1) - (ss.min or 0)
        local f = range > 0 and math.min(math.max(((ss.value or 0) - (ss.min or 0)) / range, 0), 1) or 0
        local w, h = (s.width or 16) * es, (s.height or 16) * es
        if ss.orientation == "HORIZONTAL" then
            s.l = sl.l + (sl.w - w) * f
            s.b = sl.b + (sl.h - h) / 2
        else
            s.l = sl.l + (sl.w - w) / 2
            s.b = sl.b + sl.h - h - (sl.h - h) * f
        end
        s.w, s.h = w, h
        return true
    end

    local points = s.points
    if #points == 0 then return false end
    local left, right, cx, top, bottom, cy
    for i = 1, #points do
        local p = points[i]
        local rel = p.rel or s.parent
        local rx, ry
        if rel then
            local r = Resolve(rel)
            if not r then return false end
            rx, ry = PointCoord(r, p.relPoint)
        else
            rx, ry = PointCoord({ l = 0, b = 0, w = S.screenW, h = S.screenH }, p.relPoint)
        end
        local ax, ay = rx + p.x * es, ry + p.y * es
        local pt = p.point
        if H_LEFT[pt] then left = ax elseif H_RIGHT[pt] then right = ax else cx = ax end
        if V_TOP[pt] then top = ay elseif V_BOTTOM[pt] then bottom = ay else cy = ay end
    end

    local width = s.width and s.width * es
    s.intrinsicW = false
    if not width and s.isFontString and not (left and right) then
        width = S.FontStringWidth(s) * es
        s.intrinsicW = true
    end
    local l, w = SolveAxis(left, right, cx, width)
    if not l then return false end

    local height = s.height and s.height * es
    if not height and s.isFontString and not (top and bottom) then height = S.FontStringHeight(s, w / es) * es end
    local b, h = SolveAxis(bottom, top, cy, height)
    if not b then return false end
    s.l, s.b, s.w, s.h = l, b, w, h
    return true
end

Resolve = function(obj)
    local s = W[obj]
    if not s then return nil end
    if s.rgen == layoutGen then return s.valid and s or nil end
    if resolving[s] then return nil end
    resolving[s] = true
    local ok = Compute(s)
    resolving[s] = nil
    if ok and s.clamped then
        local ins = s.clampInsets or { 0, 0, 0, 0 }
        s.l = math.min(math.max(s.l, -ins[1]), math.max(S.screenW - s.w + ins[2], -ins[1]))
        s.b = math.min(math.max(s.b, -ins[4]), math.max(S.screenH - s.h + ins[3], -ins[4]))
    end
    s.rgen, s.valid = layoutGen, ok
    return ok and s or nil
end
S.Resolve = Resolve

-- Rect getters return values in the region's own scale, like WoW.
local function Rect(self)
    local s = State(self)
    local r = Resolve(self)
    if not r then return nil end
    local es = EffectiveScale(s)
    return r.l / es, r.b / es, r.w / es, r.h / es
end

function Region:GetLeft() local l = Rect(self) return l end
function Region:GetBottom() local _, b = Rect(self) return b end
function Region:GetRight() local l, _, w = Rect(self) return l and l + w end
function Region:GetTop() local _, b, _, h = Rect(self) return b and b + h end
function Region:GetCenter()
    local l, b, w, h = Rect(self)
    if l then return l + w / 2, b + h / 2 end
end
function Region:GetRect() return Rect(self) end
function Region:GetScaledRect()
    local r = Resolve(self)
    if r then return r.l, r.b, r.w, r.h end
end
function Region:IsRectValid() return Resolve(self) ~= nil end
function Region:GetWidth()
    local s = State(self)
    local _, _, w = Rect(self)
    if w then return w end
    if s.isFontString and not s.width then return S.FontStringWidth(s) end
    return s.width or 0
end
function Region:GetHeight()
    local s = State(self)
    local _, _, _, h = Rect(self)
    if h then return h end
    if s.isFontString and not s.height then return S.FontStringHeight(s) end
    return s.height or 0
end
function Region:GetSize() return self:GetWidth(), self:GetHeight() end
function Region:IsMouseOver(top, bottom, left, right)
    local r = Resolve(self)
    if not r then return false end
    local x, y = S.cursorX or -1, S.cursorY or -1
    return x >= r.l - (left or 0) and x <= r.l + r.w + (right or 0)
        and y >= r.b - (bottom or 0) and y <= r.b + r.h + (top or 0)
end
function Region:IsMouseMotionFocus() return S.hover == self end

---------------------------------------------------------------------------
-- Layered regions: textures and font strings
---------------------------------------------------------------------------
local LayeredRegion = Class("LayeredRegion", "Region")

function LayeredRegion:SetDrawLayer(layer, sublevel)
    local s = State(self)
    if layer and LAYERS[layer] then s.layer = layer end
    if sublevel then s.sublevel = math.min(math.max(sublevel, -8), 7) end
    Repaint()
end
function LayeredRegion:GetDrawLayer() local s = State(self) return s.layer, s.sublevel end
function LayeredRegion:SetVertexColor(r, g, b, a)
    local s = State(self)
    s.vc = { tonumber(r) or 1, tonumber(g) or 1, tonumber(b) or 1, tonumber(a) or 1 }
    Repaint()
end
function LayeredRegion:GetVertexColor()
    local vc = State(self).vc
    if vc then return vc[1], vc[2], vc[3], vc[4] end
    return 1, 1, 1, 1
end
function LayeredRegion:SetParent(parent)
    local s = State(self)
    parent = ResolveRelative(parent, "SetParent")
    if not parent or not W[parent].isFrame then error("SetParent: a region's parent must be a frame", 2) end
    local old = W[s.parent]
    if old then for i, r in ipairs(old.regions) do if r == self then table.remove(old.regions, i) break end end end
    s.parent = parent
    table.insert(W[parent].regions, self)
    Changed()
end

local function NewRegion(className, parent, name, layer, sublevel)
    local ps = W[parent]
    if name and ps.name then name = name:gsub("%$[pP]arent", ps.name) end
    local obj, s = NewObject(className, className, name)
    s.parent = parent
    s.layer = LAYERS[layer] and layer or "ARTWORK"
    s.sublevel = tonumber(sublevel) or 0
    table.insert(ps.regions, obj)
    if name then _G[name] = obj end
    Changed()
    return obj, s
end
S.NewRegion = NewRegion

-- Texture ---------------------------------------------------------------
local Texture = Class("Texture", "LayeredRegion")

function Texture:SetTexture(file, wrapH, wrapV, filter)
    local s = State(self)
    if type(file) == "number" then file = tostring(file) end
    if file ~= nil and type(file) ~= "string" then error("Usage: Texture:SetTexture(file)", 2) end
    s.file, s.color, s.atlas, s.gradient = file, nil, nil, nil
    if file and file:match("^%s*$") then s.file = nil end
    Repaint()
    return true
end
function Texture:GetTexture() local s = State(self) return s.file or (s.color and "FileData ID 0") end
function Texture:GetTextureFileID() return tonumber(State(self).file) end
function Texture:GetTextureFilePath() return State(self).file end
function Texture:SetColorTexture(r, g, b, a)
    local s = State(self)
    s.color = { tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0, tonumber(a) or 1 }
    s.file, s.atlas, s.gradient = nil, nil, nil
    Repaint()
end
function Texture:SetAtlas(atlas, useAtlasSize, filterMode)
    local s = State(self)
    s.atlas, s.file, s.color = atlas, nil, nil
    if useAtlasSize then
        local info = S.atlasInfo and S.atlasInfo[atlas]
        if info then s.width, s.height = info.width, info.height; Changed() end
    end
    Repaint()
end
function Texture:GetAtlas() return State(self).atlas end
function Texture:SetTexCoord(...)
    local s = State(self)
    local n = select("#", ...)
    if n == 4 then
        local l, r, t, b = ...
        s.tc = { l, r, t, b }
    elseif n == 8 then
        local ulx, uly, llx, lly, urx, ury, lrx, lry = ...
        s.tc = { math.min(ulx, llx), math.max(urx, lrx), math.min(uly, ury), math.max(lly, lry) }
    end
    Repaint()
end
function Texture:GetTexCoord()
    local tc = State(self).tc or { 0, 1, 0, 1 }
    return tc[1], tc[3], tc[1], tc[4], tc[2], tc[3], tc[2], tc[4]
end
function Texture:SetDesaturated(on) State(self).desat = on and true or nil; Repaint() end
function Texture:IsDesaturated() return State(self).desat or false end
function Texture:SetDesaturation(v) State(self).desat = (tonumber(v) or 0) > 0.5 or nil; Repaint() end
function Texture:SetBlendMode(mode) State(self).blend = mode; Repaint() end
function Texture:GetBlendMode() return State(self).blend or "BLEND" end
function Texture:SetRotation(rad) State(self).rotation = tonumber(rad) or 0; Repaint() end
function Texture:GetRotation() return State(self).rotation or 0 end
function Texture:SetGradient(orientation, minColor, maxColor, ...)
    local s = State(self)
    if type(minColor) == "table" and type(maxColor) == "table" then
        local r1, g1, b1, a1 = minColor:GetRGBA()
        local r2, g2, b2, a2 = maxColor:GetRGBA()
        s.gradient = { orientation, r1, g1, b1, a1 or 1, r2, g2, b2, a2 or 1 }
    end
    Repaint()
end
function Texture:SetHorizTile() end
function Texture:SetVertTile() end
function Texture:GetHorizTile() return false end
function Texture:GetVertTile() return false end
function Texture:SetSnapToPixelGrid() end
function Texture:SetTexelSnappingBias() end
function Texture:IsObjectLoaded() return true end
function Texture:SetMask() end
function Texture:AddMaskTexture() end
function Texture:RemoveMaskTexture() end
function Texture:SetNonBlocking() end
function Texture:SetBlockingLoadsRequested() end
function Texture:ResetTexCoord() State(self).tc = nil; Repaint() end
function Texture:SetStartPoint() end
function Texture:SetEndPoint() end
function Texture:SetThickness() end
Class("MaskTexture", "Texture")
Class("Line", "Texture")

-- Font objects ------------------------------------------------------------
local Font = Class("Font", "Object")
local fontObjects = {}
S.fontObjects = fontObjects

local function NewFont(name)
    local obj, s = NewObject("Font", "Font", name)
    s.file, s.size, s.flags = "Fonts\\FRIZQT__.TTF", 12, ""
    s.color = { 1, 1, 1, 1 }
    s.justifyH, s.justifyV = "CENTER", "MIDDLE"
    if name then fontObjects[name] = obj; _G[name] = obj end
    return obj, s
end
S.NewFont = NewFont

local function FontProps(s)
    -- A font object may inherit from another (SetFontObject on a Font).
    if s.inherits then
        local p = W[s.inherits]
        if p then
            local f, sz, fl, col, jh, jv, sh = FontProps(p)
            return s.file or f, s.size or sz, s.flags or fl, s.color or col, s.justifyH or jh, s.justifyV or jv,
                s.shadow or sh
        end
    end
    return s.file, s.size, s.flags, s.color, s.justifyH, s.justifyV, s.shadow
end
S.FontProps = FontProps

function Font:SetFont(file, size, flags)
    local s = State(self)
    s.file, s.size, s.flags = file, tonumber(size) or s.size, flags or ""
    Changed()
    return true
end
function Font:GetFont() local f, sz, fl = FontProps(State(self)) return f, sz, fl end
function Font:SetTextColor(r, g, b, a) State(self).color = { r or 1, g or 1, b or 1, a or 1 }; Repaint() end
function Font:GetTextColor() local c = select(4, FontProps(State(self))) return c[1], c[2], c[3], c[4] end
function Font:SetJustifyH(j) State(self).justifyH = j; Repaint() end
function Font:SetJustifyV(j) State(self).justifyV = j; Repaint() end
function Font:GetJustifyH() return select(5, FontProps(State(self))) end
function Font:GetJustifyV() return select(6, FontProps(State(self))) end
function Font:SetShadowColor(r, g, b, a) State(self).shadow = { r, g, b, a or 1 }; Repaint() end
function Font:GetShadowColor()
    local sh = select(7, FontProps(State(self)))
    if sh then return sh[1], sh[2], sh[3], sh[4] end
    return 0, 0, 0, 0
end
function Font:SetShadowOffset(x, y) State(self).shadowOffset = { x, y } end
function Font:GetShadowOffset() local o = State(self).shadowOffset or { 0, 0 } return o[1], o[2] end
function Font:SetSpacing(v) State(self).spacing = v end
function Font:GetSpacing() return State(self).spacing or 0 end
function Font:SetFontObject(font)
    local s = State(self)
    if type(font) == "string" then font = fontObjects[font] end
    s.inherits = font
    Changed()
end
function Font:GetFontObject() return State(self).inherits end
function Font:CopyFontObject(src)
    if type(src) == "string" then src = fontObjects[src] end
    local s, from = State(self), W[src]
    if not from then return end
    local f, sz, fl, col, jh, jv, sh = FontProps(from)
    s.file, s.size, s.flags, s.justifyH, s.justifyV = f, sz, fl, jh, jv
    s.color = { col[1], col[2], col[3], col[4] }
    s.shadow = sh
    Changed()
end
function Font:SetIndentedWordWrap() end
function Font:GetIndentedWordWrap() return false end
function Font:SetAlpha(a) State(self).alpha = a end
function Font:GetAlpha() return State(self).alpha or 1 end

function CreateFont(name)
    if name and fontObjects[name] then return fontObjects[name] end
    return (NewFont(name))
end
function GetFonts()
    local out = {}
    for name in pairs(fontObjects) do out[#out + 1] = name end
    return out
end

-- FontString --------------------------------------------------------------
local FontString = Class("FontString", "LayeredRegion")

local function FontOf(s)
    local fo = s.fontObject and W[s.fontObject]
    local file, size, flags, color, jh, jv, shadow
    if fo then file, size, flags, color, jh, jv, shadow = FontProps(fo) end
    return s.file or file or "Fonts\\FRIZQT__.TTF", s.size or size or 12, s.flags or flags or "",
        s.color or color or { 1, 1, 1, 1 }, s.justifyH or jh or "CENTER", s.justifyV or jv or "MIDDLE",
        s.shadow or shadow
end
S.FontOf = FontOf

function S.FontStringWidth(s)
    local text = s.text
    if not text or text == "" then return 0 end
    local file, size = FontOf(s)
    local widest = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        widest = math.max(widest, S.MeasureText(file, size, line))
    end
    return widest
end

function S.FontStringHeight(s, width)
    local text = s.text
    if not text or text == "" then return 0 end
    local file, size = FontOf(s)
    local lines
    if width and width > 0 and s.wordWrap ~= false then
        lines = S.CountLines(file, size, text, width)
    else
        local _, n = text:gsub("\n", "")
        lines = n + 1
    end
    if s.maxLines and s.maxLines > 0 then lines = math.min(lines, s.maxLines) end
    return lines * size + (lines - 1) * (s.spacing or 0)
end

function FontString:SetText(text)
    local s = State(self)
    if text ~= nil then text = tostring(text) end
    if s.text == text then return end
    s.text = text
    Changed()
end
function FontString:GetText() return State(self).text end
function FontString:SetFormattedText(fmt, ...) self:SetText(fmt:format(...)) end
function FontString:SetFont(file, size, flags)
    local s = State(self)
    s.file, s.size, s.flags = file, tonumber(size), flags or ""
    Changed()
    return true
end
function FontString:GetFont() local f, sz, fl = FontOf(State(self)) return f, sz, fl end
function FontString:SetFontObject(font)
    local s = State(self)
    if type(font) == "string" then
        local found = fontObjects[font]
        if not found then S.Warn(("SetFontObject: unknown font object '%s'"):format(font)) end
        font = found
    end
    s.fontObject = font
    s.file, s.size, s.flags = nil, nil, nil
    Changed()
end
function FontString:GetFontObject() return State(self).fontObject end
function FontString:SetTextColor(r, g, b, a)
    State(self).color = { tonumber(r) or 1, tonumber(g) or 1, tonumber(b) or 1, tonumber(a) or 1 }
    Repaint()
end
function FontString:GetTextColor() local c = select(4, FontOf(State(self))) return c[1], c[2], c[3], c[4] end
function FontString:SetJustifyH(j) State(self).justifyH = j and j:upper(); Repaint() end
function FontString:GetJustifyH() return select(5, FontOf(State(self))) end
function FontString:SetJustifyV(j) State(self).justifyV = j and j:upper(); Repaint() end
function FontString:GetJustifyV() return select(6, FontOf(State(self))) end
function FontString:SetWordWrap(on) State(self).wordWrap = on and true or false; Changed() end
function FontString:CanWordWrap() return State(self).wordWrap ~= false end
function FontString:SetNonSpaceWrap(on) State(self).nonSpaceWrap = on end
function FontString:CanNonSpaceWrap() return State(self).nonSpaceWrap or false end
function FontString:SetMaxLines(n) State(self).maxLines = n; Changed() end
function FontString:GetMaxLines() return State(self).maxLines or 0 end
function FontString:GetStringWidth() return S.FontStringWidth(State(self)) end
FontString.GetUnboundedStringWidth = FontString.GetStringWidth
function FontString:GetStringHeight()
    local s = State(self)
    local r = Resolve(self)
    return S.FontStringHeight(s, r and r.w / EffectiveScale(s) or s.width)
end
function FontString:GetNumLines()
    local s = State(self)
    local _, size = FontOf(s)
    return math.max(1, math.floor(self:GetStringHeight() / size + 0.5))
end
function FontString:IsTruncated()
    local s = State(self)
    local r = Resolve(self)
    if not r or not s.text then return false end
    return S.FontStringWidth(s) * EffectiveScale(s) > r.w + 0.5 and s.wordWrap == false
end
function FontString:SetShadowColor(r, g, b, a) State(self).shadow = { r, g, b, a or 1 }; Repaint() end
function FontString:GetShadowColor()
    local sh = select(7, FontOf(State(self)))
    if sh then return sh[1], sh[2], sh[3], sh[4] end
    return 0, 0, 0, 0
end
function FontString:SetShadowOffset(x, y) State(self).shadowOffset = { x, y }; Repaint() end
function FontString:GetShadowOffset() local o = State(self).shadowOffset or { 0, 0 } return o[1], o[2] end
function FontString:SetSpacing(v) State(self).spacing = v; Changed() end
function FontString:GetSpacing() return State(self).spacing or 0 end
function FontString:SetTextHeight(h) State(self).size = h; Changed() end
function FontString:SetIndentedWordWrap() end
function FontString:SetAlphaGradient() end
function FontString:SetTextScale(v) end
function FontString:GetTextScale() return 1 end
function FontString:SetFixedColor() end
function FontString:CalculateScreenAreaFromCharacterSpan() end
function FontString:FindCharacterIndexAtCoordinate() return 1 end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local Frame = Class("Frame", "Region")

local function EffectiveStrata(s)
    while s do
        if s.strata then return s.strata end
        s = s.parent and W[s.parent]
    end
    return "MEDIUM"
end
local function EffectiveLevel(s)
    local add = 0
    while s do
        if s.level then return s.level + add end
        add = add + 1
        s = s.parent and W[s.parent]
    end
    return add - 1
end
S.EffectiveStrata, S.EffectiveLevel = EffectiveStrata, EffectiveLevel

function Frame:SetParent(parent)
    local s = State(self)
    parent = ResolveRelative(parent, "SetParent")
    if parent == self then error("SetParent: can't parent a frame to itself", 2) end
    local before = IsVisible(s)
    local old = s.parent and W[s.parent]
    if old then
        for i, c in ipairs(old.children) do if c == self then table.remove(old.children, i) break end end
    end
    s.parent = parent
    if parent then table.insert(W[parent].children, self) end
    Changed()
    local after = IsVisible(s)
    if before ~= after then PropagateVisibility(s, after) end
end

function Frame:GetChildren() return unpack(State(self).children) end
function Frame:GetNumChildren() return #State(self).children end
function Frame:GetRegions() return unpack(State(self).regions) end
function Frame:GetNumRegions() return #State(self).regions end

function Frame:CreateTexture(name, layer, template, sublevel)
    local obj = NewRegion("Texture", self, name, layer, sublevel)
    if template then S.ApplyTemplates(obj, template) end
    return obj
end
function Frame:CreateMaskTexture(name, layer, template, sublevel)
    return (NewRegion("MaskTexture", self, name, layer, sublevel))
end
function Frame:CreateLine(name, layer, template, sublevel)
    return (NewRegion("Line", self, name, layer, sublevel))
end
function Frame:CreateFontString(name, layer, template)
    local obj, s = NewRegion("FontString", self, name, layer or "ARTWORK", 0)
    s.isFontString = true
    if template then
        local font = type(template) == "string" and fontObjects[template] or (type(template) == "table" and template)
        if font then s.fontObject = font else S.ApplyTemplates(obj, template) end
    end
    return obj
end

function Frame:SetScript(name, fn)
    local s = State(self, "SetScript")
    if fn ~= nil and type(fn) ~= "function" then error("Usage: Frame:SetScript(\"type\", function)", 2) end
    s.scripts[name] = fn
    local kind = MOUSE_SCRIPTS[name]
    if fn and kind then
        if kind == "wheel" then s.wheel = true
        elseif s.mouseExplicit == nil then s.mouse = true end
    end
    if name == "OnUpdate" then S.onUpdateDirty = true end
end
function Frame:GetScript(name) return State(self).scripts[name] end
function Frame:HasScript(name) return true end
function Frame:HookScript(name, fn)
    local s = State(self)
    if not s.scripts[name] then return self:SetScript(name, fn) end
    s.hooks = s.hooks or {}
    s.hooks[name] = s.hooks[name] or {}
    table.insert(s.hooks[name], fn)
end

function Frame:RegisterEvent(event)
    if type(event) ~= "string" then error("Usage: Frame:RegisterEvent(\"event\")", 2) end
    RegisterEvent(State(self), event)
    return true
end
function Frame:RegisterUnitEvent(event, unit1, unit2)
    local s = State(self)
    RegisterEvent(s, event)
    s.unitFilter = s.unitFilter or {}
    s.unitFilter[event] = { [unit1 or "player"] = true }
    if unit2 then s.unitFilter[event][unit2] = true end
    return true
end
function Frame:UnregisterEvent(event) UnregisterEvent(State(self), event) end
function Frame:UnregisterAllEvents()
    local s = State(self)
    for event in pairs(s.events) do UnregisterEvent(s, event) end
end
function Frame:IsEventRegistered(event) return State(self).events[event] or false end
function Frame:RegisterAllEvents() State(self).allEvents = true end

function Frame:SetFrameStrata(strata)
    local s = State(self)
    if strata == "PARENT" then s.strata = nil
    elseif STRATA[strata] then s.strata = strata end
    Repaint()
end
function Frame:GetFrameStrata() return EffectiveStrata(State(self)) end
function Frame:SetFixedFrameStrata() end
function Frame:SetFixedFrameLevel() end
function Frame:SetFrameLevel(level) State(self).level = math.max(0, tonumber(level) or 0); Repaint() end
function Frame:GetFrameLevel() return EffectiveLevel(State(self)) end
function Frame:SetToplevel(on) State(self).toplevel = on and true or false end
function Frame:IsToplevel() return State(self).toplevel or false end
function Frame:Raise()
    local s = State(self)
    local strata, top = EffectiveStrata(s), 0
    for _, f in ipairs(frames) do
        local fs = W[f]
        if f ~= self and fs.shown and EffectiveStrata(fs) == strata then top = math.max(top, EffectiveLevel(fs)) end
    end
    if EffectiveLevel(s) <= top then s.level = top + 1; Repaint() end
end
function Frame:Lower()
    local s = State(self)
    if s.level and s.level > 0 then s.level = 0; Repaint() end
end

function Frame:EnableMouse(on) local s = State(self) s.mouse = on and true or false; s.mouseExplicit = s.mouse end
function Frame:IsMouseEnabled() return State(self).mouse or false end
Frame.SetMouseClickEnabled = Frame.EnableMouse
Frame.SetMouseMotionEnabled = Frame.EnableMouse
Frame.IsMouseClickEnabled = Frame.IsMouseEnabled
Frame.IsMouseMotionEnabled = Frame.IsMouseEnabled
function Frame:EnableMouseWheel(on) State(self).wheel = on and true or false end
function Frame:IsMouseWheelEnabled() return State(self).wheel or false end
function Frame:EnableKeyboard(on) State(self).keyboard = on and true or false end
function Frame:IsKeyboardEnabled() return State(self).keyboard or false end
function Frame:SetPropagateKeyboardInput(on) State(self).propagateKeys = on and true or false end
function Frame:GetPropagateKeyboardInput() return State(self).propagateKeys or false end
function Frame:EnableGamePadButton() end
function Frame:EnableGamePadStick() end
function Frame:SetMovable(on) State(self).movable = on and true or false end
function Frame:IsMovable() return State(self).movable or false end
function Frame:SetResizable(on) State(self).resizable = on and true or false end
function Frame:IsResizable() return State(self).resizable or false end
function Frame:SetClampedToScreen(on) State(self).clamped = on and true or false end
function Frame:IsClampedToScreen() return State(self).clamped or false end
function Frame:SetClampRectInsets(l, r, t, b) State(self).clampInsets = { l or 0, r or 0, t or 0, b or 0 } end
function Frame:GetClampRectInsets() local c = State(self).clampInsets or { 0, 0, 0, 0 } return c[1], c[2], c[3], c[4] end
function Frame:SetUserPlaced(on) State(self).userPlaced = on end
function Frame:IsUserPlaced() return State(self).userPlaced or false end
function Frame:SetDontSavePosition() end
function Frame:SetResizeBounds(minW, minH, maxW, maxH) State(self).resizeBounds = { minW, minH, maxW, maxH } end
function Frame:GetResizeBounds() local b = State(self).resizeBounds or {} return b[1] or 0, b[2] or 0, b[3] or 0, b[4] or 0 end
function Frame:SetMinResize(w, h) local s = State(self) s.resizeBounds = s.resizeBounds or {}; s.resizeBounds[1], s.resizeBounds[2] = w, h end
function Frame:SetMaxResize(w, h) local s = State(self) s.resizeBounds = s.resizeBounds or {}; s.resizeBounds[3], s.resizeBounds[4] = w, h end
function Frame:RegisterForDrag(...)
    local s = State(self)
    s.drag = {}
    for i = 1, select("#", ...) do
        local b = select(i, ...)
        if b then s.drag[(b:gsub("Up$", ""):gsub("Down$", ""))] = true end
    end
end
function Frame:SetHitRectInsets(l, r, t, b) State(self).hitInsets = { l or 0, r or 0, t or 0, b or 0 } end
function Frame:GetHitRectInsets() local h = State(self).hitInsets or { 0, 0, 0, 0 } return h[1], h[2], h[3], h[4] end
function Frame:SetScale(scale)
    local s = State(self)
    scale = tonumber(scale)
    if not scale or scale <= 0 then error("Frame:SetScale(): Scale must be > 0", 2) end
    s.scale = scale
    Changed()
end
function Frame:GetScale() return State(self).scale or 1 end
function Frame:GetEffectiveScale() return EffectiveScale(State(self)) end
function Frame:SetIgnoreParentScale(on) State(self).ignoreParentScale = on; Changed() end
function Frame:IsIgnoringParentScale() return State(self).ignoreParentScale or false end
function Frame:SetIgnoreParentAlpha(on) State(self).ignoreParentAlpha = on; Repaint() end
function Frame:IsIgnoringParentAlpha() return State(self).ignoreParentAlpha or false end
function Frame:SetID(id) State(self).frameID = tonumber(id) or 0 end
function Frame:GetID() return State(self).frameID or 0 end
function Frame:SetClipsChildren(on) State(self).clips = on and true or false; Repaint() end
function Frame:DoesClipChildren() return State(self).clips or false end
function Frame:SetAttribute(name, value)
    local s = State(self)
    s.attributes = s.attributes or {}
    s.attributes[name] = value
    S.RunScript(self, "OnAttributeChanged", name, value)
end
function Frame:GetAttribute(name) local a = State(self).attributes return a and a[name] end
function Frame:SetAttributeNoHandler(name, value)
    local s = State(self)
    s.attributes = s.attributes or {}
    s.attributes[name] = value
end
function Frame:EnableDrawLayer() end
function Frame:DisableDrawLayer() end
function Frame:SetHyperlinksEnabled(on) State(self).hyperlinks = on end
function Frame:GetHyperlinksEnabled() return State(self).hyperlinks or false end
function Frame:SetFlattensRenderLayers() end
function Frame:SetFrameBuffer() end
function Frame:SetDrawLayerEnabled() end
function Frame:IsDrawLayerEnabled() return true end
function Frame:GetBoundsRect() return self:GetRect() end
function Frame:SetIsFrameBuffer() end
function Frame:SetUsingParentLevel(on) if on then State(self).level = nil end end
function Frame:SetHighlightLocked(on) State(self).highlightLocked = on; Repaint() end

-- Dragging (StartMoving/StartSizing) ---------------------------------------
function Frame:StartMoving()
    local s = State(self)
    if not s.movable then error("Frame:StartMoving(): frame isn't movable", 2) end
    local r = Resolve(self)
    if not r then return end
    S.moving = { s = s, dx = (S.cursorX or 0) - r.l, dy = (S.cursorY or 0) - (r.b + r.h) }
    S.dragging = self
end
function Frame:StartSizing(point)
    local s = State(self)
    if not s.resizable then error("Frame:StartSizing(): frame isn't resizable", 2) end
    local r = Resolve(self)
    if not r then return end
    -- Pin the top-left corner, then grow toward the cursor.
    local es = EffectiveScale(s)
    s.points = { { point = "TOPLEFT", rel = UIParent, relPoint = "BOTTOMLEFT", x = r.l / es, y = (r.b + r.h) / es } }
    S.sizing = { s = s, point = point or "BOTTOMRIGHT" }
    Changed()
end
function Frame:StopMovingOrSizing()
    if S.moving and S.moving.s.obj == self then S.moving = nil end
    if S.sizing and S.sizing.s.obj == self then S.sizing = nil end
    if S.dragging == self then S.dragging = nil end
end

---------------------------------------------------------------------------
-- Frame creation
---------------------------------------------------------------------------
local FRAME_TYPES = {}
S.FRAME_TYPES = FRAME_TYPES
function S.RegisterFrameType(objType, className, init)
    FRAME_TYPES[objType:lower()] = { type = objType, class = className, init = init }
end

S.templates = {}
-- Lua templates are functions(obj); XML virtual frames register a function too (see 50_xml.lua).
function S.RegisterTemplate(name, fn, info)
    S.templates[name] = { apply = fn, info = info or {} }
end

function S.ApplyTemplates(obj, list)
    for name in tostring(list):gmatch("[^,%s]+") do
        local t = S.templates[name]
        if t then
            t.apply(obj)
        else
            S.Missing("Template:" .. name)
        end
    end
end

function S.CreateFrameRaw(frameType, name, parent)
    local info = FRAME_TYPES[tostring(frameType):lower()]
    if not info then error(("CreateFrame: Unknown frame type '%s'"):format(tostring(frameType)), 3) end
    parent = ResolveRelative(parent, "CreateFrame")
    if type(name) == "string" and name:find("$", 1, true) then
        local pname = parent and W[parent].name or ""
        name = name:gsub("%$[pP]arent", pname)
    end
    if name == "" then name = nil end
    local obj, s = NewObject(info.class, info.type, name)
    s.isFrame = true
    s.children, s.regions, s.scripts, s.events = {}, {}, {}, {}
    frames[#frames + 1] = obj
    if name then _G[name] = obj end
    if parent then
        s.parent = parent
        table.insert(W[parent].children, obj)
    end
    if info.init then info.init(obj, s) end
    Changed()
    return obj, s
end

function CreateFrame(frameType, name, parent, template, id)
    local obj = S.CreateFrameRaw(frameType, name, parent)
    if id then W[obj].frameID = tonumber(id) end
    if template then S.ApplyTemplates(obj, template) end
    S.RunScript(obj, "OnLoad")
    return obj
end

S.RegisterFrameType("Frame", "Frame")

---------------------------------------------------------------------------
-- Button and CheckButton
---------------------------------------------------------------------------
local Button = Class("Button", "Frame")

local function ButtonInit(obj, s)
    s.mouse, s.enabled, s.buttonState = true, true, "NORMAL"
    s.clicks = { LeftButtonUp = true }
    s.isButton = true
end
S.RegisterFrameType("Button", "Button", ButtonInit)
S.RegisterFrameType("ItemButton", "Button", ButtonInit)
S.RegisterFrameType("DropdownButton", "Button", ButtonInit)
S.RegisterFrameType("ContainedAlertFrame", "Button", ButtonInit)

local function ButtonTexture(self, key, layer, tex, ...)
    local s = State(self)
    if tex == nil then
        if s[key] then W[s[key]].file = nil; W[s[key]].color = nil; W[s[key]].atlas = nil; Repaint() end
        return
    end
    local region
    if type(tex) == "table" and W[tex] then
        region = tex
        local rs = W[region]
        if rs.parent ~= self then region:SetParent(self) end
        rs.layer = layer
    else
        region = s[key]
        if not region then region = Frame.CreateTexture(self, nil, layer) end
        if type(tex) == "string" and tex:find("[\\/]") == nil and tonumber(tex) == nil and S.atlasInfo and S.atlasInfo[tex] then
            region:SetAtlas(tex)
        else
            region:SetTexture(tex)
        end
    end
    s[key] = region
    W[region].buttonRole = key
    if #W[region].points == 0 then region:SetAllPoints(self) end
    if key == "highlight" and select(1, ...) then region:SetBlendMode(select(1, ...)) end
    Repaint()
end

function Button:SetNormalTexture(t) ButtonTexture(self, "normal", "ARTWORK", t) end
function Button:SetPushedTexture(t) ButtonTexture(self, "pushed", "ARTWORK", t) end
function Button:SetDisabledTexture(t) ButtonTexture(self, "disabled", "ARTWORK", t) end
function Button:SetHighlightTexture(t, blend) ButtonTexture(self, "highlight", "HIGHLIGHT", t, blend or "ADD") end
Button.SetNormalAtlas = Button.SetNormalTexture
Button.SetPushedAtlas = Button.SetPushedTexture
Button.SetDisabledAtlas = Button.SetDisabledTexture
Button.SetHighlightAtlas = Button.SetHighlightTexture
function Button:GetNormalTexture() return State(self).normal end
function Button:GetPushedTexture() return State(self).pushed end
function Button:GetDisabledTexture() return State(self).disabled end
function Button:GetHighlightTexture() return State(self).highlight end
function Button:ClearNormalTexture() ButtonTexture(self, "normal", "ARTWORK", nil) end
function Button:ClearPushedTexture() ButtonTexture(self, "pushed", "ARTWORK", nil) end
function Button:ClearDisabledTexture() ButtonTexture(self, "disabled", "ARTWORK", nil) end
function Button:ClearHighlightTexture() ButtonTexture(self, "highlight", "HIGHLIGHT", nil) end

local function ButtonFontString(self)
    local s = State(self)
    if not s.fontString then
        local fs = Frame.CreateFontString(self, nil, "OVERLAY")
        fs:SetPoint("CENTER")
        W[fs].fontObject = s.normalFont or fontObjects.GameFontNormal
        s.fontString = fs
    end
    return s.fontString
end
function Button:SetText(text)
    if text == nil and not State(self).fontString then return end
    ButtonFontString(self):SetText(text)
end
function Button:SetFormattedText(fmt, ...) self:SetText(fmt:format(...)) end
function Button:GetText() local fs = State(self).fontString return fs and fs:GetText() end
function Button:GetFontString() return State(self).fontString end
function Button:SetFontString(fs)
    local s = State(self)
    s.fontString = fs
    if fs and W[fs].parent ~= self then fs:SetParent(self) end
end
function Button:GetTextWidth() local fs = State(self).fontString return fs and fs:GetStringWidth() or 0 end
function Button:GetTextHeight() local fs = State(self).fontString return fs and fs:GetStringHeight() or 0 end
local function FontArg(font) if type(font) == "string" then return fontObjects[font] end return font end
function Button:SetNormalFontObject(font)
    local s = State(self)
    s.normalFont = FontArg(font)
    if s.fontString then W[s.fontString].fontObject = s.normalFont; Changed() end
end
function Button:SetHighlightFontObject(font) State(self).highlightFont = FontArg(font); Repaint() end
function Button:SetDisabledFontObject(font) State(self).disabledFont = FontArg(font); Repaint() end
function Button:GetNormalFontObject() return State(self).normalFont end
function Button:GetHighlightFontObject() return State(self).highlightFont end
function Button:GetDisabledFontObject() return State(self).disabledFont end
function Button:SetPushedTextOffset(x, y) State(self).pushedOffset = { x, y } end
function Button:GetPushedTextOffset() local o = State(self).pushedOffset or { 0, 0 } return o[1], o[2] end

function Button:Enable() self:SetEnabled(true) end
function Button:Disable() self:SetEnabled(false) end
function Button:SetEnabled(on)
    local s = State(self)
    on = on and true or false
    if s.enabled == on then return end
    s.enabled = on
    s.buttonState = on and "NORMAL" or "DISABLED"
    Repaint()
    S.RunScript(self, on and "OnEnable" or "OnDisable")
end
function Button:IsEnabled() return State(self).enabled end
function Button:RegisterForClicks(...)
    local s = State(self)
    s.clicks = {}
    for i = 1, select("#", ...) do
        local c = select(i, ...)
        if c then s.clicks[c] = true end
    end
end
function Button:RegisterForMouse(...) self:RegisterForClicks(...) end
function Button:LockHighlight() State(self).highlightLocked = true; Repaint() end
function Button:UnlockHighlight() State(self).highlightLocked = false; Repaint() end
function Button:IsHighlightLocked() return State(self).highlightLocked or false end
function Button:SetButtonState(state, lock) local s = State(self) s.buttonState = state; s.stateLocked = lock; Repaint() end
function Button:GetButtonState() return State(self).buttonState end
function Button:SetMotionScriptsWhileDisabled(on) State(self).motionWhileDisabled = on end
function Button:GetMotionScriptsWhileDisabled() return State(self).motionWhileDisabled or false end

-- Click(): what a real click does after the mouse checks.
function S.DoClick(self, button, down)
    local s = W[self]
    if not s or not s.enabled then return end
    button = button or "LeftButton"
    if s.isCheckButton then s.checked = not s.checked; Repaint() end
    S.RunScript(self, "PreClick", button, down or false)
    S.RunScript(self, "OnClick", button, down or false)
    if s.secureAction and S.SecureAction then S.Call(S.SecureAction, self, button) end
    S.RunScript(self, "PostClick", button, down or false)
end
function Button:Click(button, down) S.DoClick(self, button, down) end

local CheckButton = Class("CheckButton", "Button")
S.RegisterFrameType("CheckButton", "CheckButton", function(obj, s)
    ButtonInit(obj, s)
    s.isCheckButton = true
end)
function CheckButton:SetChecked(on) State(self).checked = on and true or false; Repaint() end
function CheckButton:GetChecked() return State(self).checked or false end
function CheckButton:SetCheckedTexture(t) ButtonTexture(self, "checkedTex", "OVERLAY", t) end
function CheckButton:GetCheckedTexture() return State(self).checkedTex end
function CheckButton:SetDisabledCheckedTexture(t) ButtonTexture(self, "disabledCheckedTex", "OVERLAY", t) end
function CheckButton:GetDisabledCheckedTexture() return State(self).disabledCheckedTex end
CheckButton.SetCheckedAtlas = CheckButton.SetCheckedTexture

---------------------------------------------------------------------------
-- EditBox
---------------------------------------------------------------------------
local EditBox = Class("EditBox", "Frame")
S.RegisterFrameType("EditBox", "EditBox", function(obj, s)
    s.isEditBox, s.mouse, s.enabled = true, true, true
    s.text, s.cursor, s.autoFocus = "", 0, true
    s.insets = { 0, 0, 0, 0 }
    s.history = {}
end)

local function Utf8Len(str) return strlenutf8(str) end

local function SetEditText(self, s, text, userInput)
    text = tostring(text or "")
    if s.maxLetters and s.maxLetters > 0 and Utf8Len(text) > s.maxLetters then
        local n, i = 0, 1
        while i <= #text do
            n = n + 1
            if n > s.maxLetters then text = text:sub(1, i - 1) break end
            local c = text:byte(i)
            i = i + (c >= 240 and 4 or c >= 224 and 3 or c >= 192 and 2 or 1)
        end
    end
    if s.maxBytes and s.maxBytes > 0 and #text > s.maxBytes then text = text:sub(1, s.maxBytes) end
    if text == s.text then return end
    s.text = text
    if s.cursor > #text then s.cursor = #text end
    Changed()
    S.RunScript(self, "OnTextChanged", userInput and true or false)
end
S.SetEditText = SetEditText

function EditBox:SetText(text)
    local s = State(self)
    SetEditText(self, s, text, false)
    s.cursor = #s.text
    S.RunScript(self, "OnTextSet")
end
function EditBox:GetText() return State(self).text end
function EditBox:Insert(text)
    local s = State(self)
    local t = tostring(text or "")
    local before, after = s.text:sub(1, s.cursor), s.text:sub(s.cursor + 1)
    SetEditText(self, s, before .. t .. after, false)
    s.cursor = math.min(#before + #t, #s.text)
end
function EditBox:SetNumeric(on) State(self).numeric = on and true or false end
function EditBox:IsNumeric() return State(self).numeric or false end
function EditBox:SetNumericFullRange(on) State(self).numeric = on and true or false end
function EditBox:GetNumber() return tonumber(State(self).text) or 0 end
function EditBox:SetNumber(n) self:SetText(tostring(n)) end
function EditBox:SetMaxLetters(n) State(self).maxLetters = tonumber(n) end
function EditBox:GetMaxLetters() return State(self).maxLetters or 0 end
function EditBox:SetMaxBytes(n) State(self).maxBytes = tonumber(n) end
function EditBox:GetMaxBytes() return State(self).maxBytes or 0 end
function EditBox:GetNumLetters() return Utf8Len(State(self).text) end
function EditBox:SetAutoFocus(on) State(self).autoFocus = on and true or false end
function EditBox:IsAutoFocus() return State(self).autoFocus end
function EditBox:SetFocus() S.SetFocus(self) end
function EditBox:ClearFocus() if S.focus == self then S.ClearFocus() end end
function EditBox:HasFocus() return S.focus == self end
function EditBox:SetMultiLine(on) State(self).multiLine = on and true or false end
function EditBox:IsMultiLine() return State(self).multiLine or false end
function EditBox:SetPassword(on) State(self).password = on and true or false; Repaint() end
function EditBox:IsPassword() return State(self).password or false end
function EditBox:HighlightText(from, to) State(self).highlightAll = true; Repaint() end
function EditBox:ClearHighlightText() State(self).highlightAll = nil; Repaint() end
function EditBox:SetCursorPosition(pos) local s = State(self) s.cursor = math.min(math.max(tonumber(pos) or 0, 0), #s.text); Repaint() end
function EditBox:GetCursorPosition() return State(self).cursor end
function EditBox:SetTextInsets(l, r, t, b) State(self).insets = { l or 0, r or 0, t or 0, b or 0 }; Repaint() end
function EditBox:GetTextInsets() local i = State(self).insets return i[1], i[2], i[3], i[4] end
EditBox.SetFont = FontString.SetFont
EditBox.GetFont = FontString.GetFont
EditBox.SetFontObject = FontString.SetFontObject
EditBox.GetFontObject = FontString.GetFontObject
EditBox.SetTextColor = FontString.SetTextColor
EditBox.GetTextColor = FontString.GetTextColor
EditBox.SetJustifyH = FontString.SetJustifyH
EditBox.GetJustifyH = FontString.GetJustifyH
EditBox.SetJustifyV = FontString.SetJustifyV
EditBox.GetJustifyV = FontString.GetJustifyV
EditBox.SetShadowColor = FontString.SetShadowColor
EditBox.SetShadowOffset = FontString.SetShadowOffset
EditBox.SetSpacing = FontString.SetSpacing
function EditBox:AddHistoryLine(line) table.insert(State(self).history, line) end
function EditBox:ClearHistory() State(self).history = {} end
function EditBox:SetHistoryLines() end
function EditBox:GetHistoryLines() return 0 end
function EditBox:SetBlinkSpeed() end
function EditBox:SetCountInvisibleLetters() end
function EditBox:SetAltArrowKeyMode() end
function EditBox:Enable() State(self).enabled = true; Repaint() end
function EditBox:Disable() local s = State(self) s.enabled = false; if S.focus == self then S.ClearFocus() end; Repaint() end
function EditBox:SetEnabled(on) if on then self:Enable() else self:Disable() end end
function EditBox:IsEnabled() return State(self).enabled end
function EditBox:IsInIMECompositionMode() return false end
function EditBox:SetVisibleTextByteLimit() end
function EditBox:GetVisibleTextByteLimit() return 0 end
function EditBox:SetSecureText() end
function EditBox:SetSecurityDisablePaste() end
function EditBox:ResetInputMode() end

function S.SetFocus(obj)
    if S.focus == obj then return end
    if S.focus then S.ClearFocus() end
    S.focus = obj
    Repaint()
    S.RunScript(obj, "OnEditFocusGained")
end
function S.ClearFocus()
    local old = S.focus
    if not old then return end
    S.focus = nil
    W[old].highlightAll = nil
    Repaint()
    S.RunScript(old, "OnEditFocusLost")
end
function GetCurrentKeyBoardFocus() return S.focus end

---------------------------------------------------------------------------
-- ScrollFrame, Slider, StatusBar
---------------------------------------------------------------------------
local ScrollFrame = Class("ScrollFrame", "Frame")
S.RegisterFrameType("ScrollFrame", "ScrollFrame", function(obj, s)
    s.isScrollFrame, s.vscroll, s.hscroll = true, 0, 0
end)

local function ScrollRanges(self, s)
    local child = s.scrollChild
    if not child then return 0, 0 end
    local cs = W[child]
    local w, h = self:GetWidth(), self:GetHeight()
    return math.max(0, (cs.width or 0) - w), math.max(0, (cs.height or 0) - h)
end

function ScrollFrame:SetScrollChild(child)
    local s = State(self)
    if s.scrollChild then W[s.scrollChild].scrollFrame = nil end
    s.scrollChild = child
    if child then
        local cs = W[child]
        cs.scrollFrame = self
        if cs.parent ~= self then child:SetParent(self) end
    end
    Changed()
    local xr, yr = ScrollRanges(self, s)
    S.RunScript(self, "OnScrollRangeChanged", xr, yr)
end
function ScrollFrame:GetScrollChild() return State(self).scrollChild end
function ScrollFrame:SetVerticalScroll(v)
    local s = State(self)
    v = tonumber(v) or 0
    if s.vscroll == v then return end
    s.vscroll = v
    Changed()
    S.RunScript(self, "OnVerticalScroll", v)
end
function ScrollFrame:GetVerticalScroll() return State(self).vscroll end
function ScrollFrame:SetHorizontalScroll(v)
    local s = State(self)
    s.hscroll = tonumber(v) or 0
    Changed()
    S.RunScript(self, "OnHorizontalScroll", s.hscroll)
end
function ScrollFrame:GetHorizontalScroll() return State(self).hscroll end
function ScrollFrame:GetVerticalScrollRange() local _, y = ScrollRanges(self, State(self)) return y end
function ScrollFrame:GetHorizontalScrollRange() local x = ScrollRanges(self, State(self)) return x end
function ScrollFrame:UpdateScrollChildRect()
    local s = State(self)
    local xr, yr = ScrollRanges(self, s)
    if s.lastRange ~= yr then
        s.lastRange = yr
        S.RunScript(self, "OnScrollRangeChanged", xr, yr)
    end
end

-- Scroll ranges change when the child resizes: re-announce them each frame (cheap compared to layout).
function S.UpdateScrollRanges()
    for _, f in ipairs(frames) do
        local s = W[f]
        if s.isScrollFrame and s.scrollChild and s.shown then ScrollFrame.UpdateScrollChildRect(f) end
    end
end

local function SetBarValue(self, s, v, userInput)
    v = tonumber(v) or 0
    v = math.min(math.max(v, s.min or 0), s.max or 1)
    if s.step and s.step > 0 and s.isSlider then
        v = (s.min or 0) + math.floor((v - (s.min or 0)) / s.step + 0.5) * s.step
    end
    if s.value == v then return end
    s.value = v
    Changed()
    S.RunScript(self, "OnValueChanged", v, userInput and true or false)
end
S.SetBarValue = SetBarValue

local function SetMinMax(self, s, lo, hi)
    lo, hi = tonumber(lo) or 0, tonumber(hi) or 0
    if hi < lo then error("SetMinMaxValues: min must be <= max", 3) end
    if s.min == lo and s.max == hi then return end
    s.min, s.max = lo, hi
    Changed()
    S.RunScript(self, "OnMinMaxChanged", lo, hi)
    if s.value and (s.value < lo or s.value > hi) then SetBarValue(self, s, s.value, false) end
end

local Slider = Class("Slider", "Frame")
S.RegisterFrameType("Slider", "Slider", function(obj, s)
    s.isSlider, s.mouse, s.enabled = true, true, true
    s.min, s.max, s.value, s.orientation = 0, 0, 0, "VERTICAL"
end)
function Slider:SetMinMaxValues(lo, hi) SetMinMax(self, State(self), lo, hi) end
function Slider:GetMinMaxValues() local s = State(self) return s.min, s.max end
function Slider:SetValue(v, treatAsMouseEvent) SetBarValue(self, State(self), v, treatAsMouseEvent) end
function Slider:GetValue() return State(self).value end
function Slider:SetValueStep(step) State(self).step = tonumber(step) end
function Slider:GetValueStep() return State(self).step or 0 end
function Slider:SetObeyStepOnDrag(on) State(self).obeyStep = on end
function Slider:GetObeyStepOnDrag() return State(self).obeyStep or false end
function Slider:SetStepsPerPage(n) State(self).stepsPerPage = n end
function Slider:GetStepsPerPage() return State(self).stepsPerPage or 1 end
function Slider:SetOrientation(o) State(self).orientation = o; Changed() end
function Slider:GetOrientation() return State(self).orientation end
function Slider:SetThumbTexture(tex)
    local s = State(self)
    local region = tex
    if type(tex) ~= "table" then
        region = s.thumb or Frame.CreateTexture(self, nil, "OVERLAY")
        if tex then region:SetTexture(tex) end
    end
    s.thumb = region
    W[region].thumbOf = self
    Changed()
end
function Slider:GetThumbTexture() return State(self).thumb end
function Slider:Enable() State(self).enabled = true; Repaint() end
function Slider:Disable() State(self).enabled = false; Repaint() end
function Slider:SetEnabled(on) State(self).enabled = on and true or false; Repaint() end
function Slider:IsEnabled() return State(self).enabled end
function Slider:IsDraggingThumb() return S.sliderDrag and S.sliderDrag.obj == self or false end

local StatusBar = Class("StatusBar", "Frame")
S.RegisterFrameType("StatusBar", "StatusBar", function(obj, s)
    s.isStatusBar, s.min, s.max, s.value, s.orientation = true, 0, 1, 0, "HORIZONTAL"
end)
function StatusBar:SetMinMaxValues(lo, hi) SetMinMax(self, State(self), lo, hi) end
function StatusBar:GetMinMaxValues() local s = State(self) return s.min, s.max end
function StatusBar:SetValue(v) SetBarValue(self, State(self), v, false) end
function StatusBar:GetValue() return State(self).value end
function StatusBar:SetStatusBarTexture(tex)
    local s = State(self)
    local region = tex
    if type(tex) ~= "table" then
        region = s.bar or Frame.CreateTexture(self, nil, "ARTWORK")
        region:SetTexture(tex)
    else
        if W[region].parent ~= self then region:SetParent(self) end
    end
    if s.barColor then W[region].vc = s.barColor end
    s.bar = region
    W[region].fillOf = self
    Changed()
end
StatusBar.SetStatusBarAtlas = StatusBar.SetStatusBarTexture
function StatusBar:GetStatusBarTexture()
    local s = State(self)
    if not s.bar then self:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar") end
    return s.bar
end
function StatusBar:SetStatusBarColor(r, g, b, a)
    local s = State(self)
    s.barColor = { r or 1, g or 1, b or 1, a or 1 }
    if s.bar then W[s.bar].vc = s.barColor end
    Repaint()
end
function StatusBar:GetStatusBarColor() local c = State(self).barColor or { 1, 1, 1, 1 } return c[1], c[2], c[3], c[4] end
function StatusBar:SetOrientation(o) State(self).orientation = o; Changed() end
function StatusBar:GetOrientation() return State(self).orientation end
function StatusBar:SetReverseFill(on) State(self).reverseFill = on; Changed() end
function StatusBar:GetReverseFill() return State(self).reverseFill or false end
function StatusBar:SetFillStyle(style) State(self).reverseFill = style == "REVERSE"; Changed() end
function StatusBar:SetRotatesTexture() end
function StatusBar:SetStatusBarDesaturated() end
function StatusBar:SetColorFill(r, g, b, a) self:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8"); self:SetStatusBarColor(r, g, b, a) end

---------------------------------------------------------------------------
-- Frame types that render nothing in the sandbox (models, cooldown swirls, etc.)
---------------------------------------------------------------------------
local Cooldown = Class("Cooldown", "Frame")
S.RegisterFrameType("Cooldown", "Cooldown")
function Cooldown:SetCooldown(start, duration)
    local s = State(self)
    s.cdStart, s.cdDuration = start, duration
end
function Cooldown:GetCooldownTimes() local s = State(self) return (s.cdStart or 0) * 1000, (s.cdDuration or 0) * 1000 end
function Cooldown:GetCooldownDuration() return (State(self).cdDuration or 0) * 1000 end
function Cooldown:Clear() local s = State(self) s.cdStart, s.cdDuration = nil, nil end
StubMethods(Cooldown, { "SetSwipeColor", "SetDrawEdge", "SetDrawSwipe", "SetDrawBling", "SetHideCountdownNumbers",
    "SetReverse", "SetSwipeTexture", "SetEdgeTexture", "SetBlingTexture", "SetCooldownDuration", "SetCooldownUNIX",
    "Pause", "Resume", "SetUseCircularEdge", "SetCountdownFont", "SetEdgeScale", "SetTexCoordRange" })

local Model = Class("Model", "Frame")
for _, t in ipairs({ "Model", "PlayerModel", "DressUpModel", "CinematicModel", "TabardModel", "ModelScene",
    "ColorSelect", "SimpleHTML", "MovieFrame", "Minimap", "Browser", "Checkout", "FogOfWarFrame",
    "OffScreenFrame", "ArchaeologyDigSiteFrame", "QuestPOIFrame", "ScenarioPOIFrame", "UnitPositionFrame",
    "WorldFrame" }) do
    S.RegisterFrameType(t, "Model")
end
StubMethods(Model, { "SetModel", "SetUnit", "SetDisplayInfo", "SetCreature", "SetCamera", "SetPortraitZoom",
    "SetRotation", "SetFacing", "SetPosition", "ClearModel", "SetAnimation", "RefreshUnit", "SetCamDistanceScale",
    "SetModelScale", "SetLight", "SetKeepModelOnHide", "SetSequence", "SetText", "SetColorRGB", "GetColorRGB",
    "SetZoom", "SetPlayerTexture", "SetBlipTexture", "SetMaskTexture" })

---------------------------------------------------------------------------
-- Animation groups (play instantly: OnPlay now, OnFinished after the longest duration)
---------------------------------------------------------------------------
local AnimationGroup = Class("AnimationGroup", "Object")
local Animation = Class("Animation", "Object")
for _, t in ipairs({ "Alpha", "Scale", "Translation", "Rotation", "Path", "LineScale", "LineTranslation",
    "TextureCoordTranslation", "FlipBook", "VertexColor" }) do
    Class(t, "Animation")
end

function Region:CreateAnimationGroup(name, template)
    local obj, s = NewObject("AnimationGroup", "AnimationGroup", name)
    s.parent, s.animations, s.scripts = self, {}, {}
    if name then _G[name] = obj end
    return obj
end
function AnimationGroup:CreateAnimation(animType, name)
    local className = Classes[animType or "Animation"] and animType or "Animation"
    local obj, s = NewObject(className, animType or "Animation", name)
    s.parent, s.duration, s.scripts = self, 0, {}
    table.insert(State(self).animations, obj)
    return obj
end
function AnimationGroup:SetScript(name, fn) State(self).scripts[name] = fn end
function AnimationGroup:GetScript(name) return State(self).scripts[name] end
function AnimationGroup:HookScript(name, fn)
    local s = State(self)
    local old = s.scripts[name]
    s.scripts[name] = old and function(...) old(...) fn(...) end or fn
end
function AnimationGroup:Play()
    local s = State(self)
    s.playing = true
    S.RunScript(self, "OnPlay")
    local longest = 0
    for _, a in ipairs(s.animations) do
        local as = W[a]
        longest = math.max(longest, (as.duration or 0) + (as.startDelay or 0))
    end
    if s.looping and s.looping ~= "NONE" then return end
    local token = {}
    s.token = token
    C_Timer.After(longest, function()
        if s.token == token and s.playing then
            s.playing = false
            S.RunScript(self, "OnFinished", false)
        end
    end)
end
function AnimationGroup:Stop()
    local s = State(self)
    if s.playing then
        s.playing, s.token = false, nil
        S.RunScript(self, "OnStop", false)
    end
end
function AnimationGroup:Finish() self:Stop() end
function AnimationGroup:Pause() State(self).playing = false end
function AnimationGroup:Restart() self:Stop(); self:Play() end
function AnimationGroup:IsPlaying() return State(self).playing or false end
function AnimationGroup:IsPaused() return false end
function AnimationGroup:IsDone() return not State(self).playing end
function AnimationGroup:SetLooping(l) State(self).looping = l end
function AnimationGroup:GetLooping() return State(self).looping or "NONE" end
function AnimationGroup:GetAnimations() return unpack(State(self).animations) end
function AnimationGroup:SetToFinalAlpha() end
function AnimationGroup:SetPlaying(on) if on then self:Play() else self:Stop() end end
function AnimationGroup:GetDuration() return 0 end
function AnimationGroup:GetProgress() return 0 end

function Animation:SetDuration(d) State(self).duration = tonumber(d) or 0 end
function Animation:GetDuration() return State(self).duration or 0 end
function Animation:SetStartDelay(d) State(self).startDelay = tonumber(d) or 0 end
function Animation:GetStartDelay() return State(self).startDelay or 0 end
function Animation:SetScript(name, fn) State(self).scripts[name] = fn end
function Animation:GetScript(name) return State(self).scripts[name] end
function Animation:SetTarget(t) State(self).target = t end
function Animation:GetTarget() return State(self).target end
function Animation:SetChildKey(k) State(self).childKey = k end
function Animation:GetRegionParent() return W[State(self).parent].parent end
function Animation:IsPlaying() return false end
StubMethods(Animation, { "SetFromAlpha", "SetToAlpha", "SetOrder", "SetSmoothing", "SetOffset", "SetScale",
    "SetScaleFrom", "SetScaleTo", "SetDegrees", "SetOrigin", "SetEndDelay", "SetTargetKey", "SetTargetName",
    "SetTargetParent", "SetFlipBookRows", "SetFlipBookColumns", "SetFlipBookFrames", "SetFlipBookFrameWidth",
    "SetFlipBookFrameHeight", "SetStartColor", "SetEndColor", "SetChange", "Play", "Stop", "Pause",
    "SetSmoothProgress", "SetRadians", "SetCurveType" })

---------------------------------------------------------------------------
-- Stubs for real widget methods not emulated yet
---------------------------------------------------------------------------
StubMethods(Frame, { "RegisterForEvents", "SetWindow", "LockHighlight", "UnlockHighlight",
    "SetDepth", "GetDepth", "SetPassThroughButtons", "SetMouseClickEnabled", "RotateTextures" })
StubMethods(Region, { "SetIgnoreParentScale", "SetPassThroughButtons", "SetCollapsesLayout" })

---------------------------------------------------------------------------
-- Render list
---------------------------------------------------------------------------
local hits = {}           -- mouse-enabled frames from the last render, topmost first
S.hits = hits
local fmt = string.format
local JS = S.JSONString

local function Num(v) return fmt("%.2f", v) end
local function Color(c)
    if not c then return "null" end
    return fmt("[%.3f,%.3f,%.3f,%.3f]", c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
end

local function Intersect(a, l, b, w, h)
    if not a then return { l, b, w, h } end
    local x1, y1 = math.max(a[1], l), math.max(a[2], b)
    local x2, y2 = math.min(a[1] + a[3], l + w), math.min(a[2] + a[4], b + h)
    return { x1, y1, math.max(0, x2 - x1), math.max(0, y2 - y1) }
end

local function Outside(clip, r)
    if not clip then return false end
    return r.l >= clip[1] + clip[3] or r.l + r.w <= clip[1] or r.b >= clip[2] + clip[4] or r.b + r.h <= clip[2]
end

-- Which state textures a button shows right now.
local function ButtonRegionShown(fs, role)
    if not role then return true end
    local enabled = fs.enabled ~= false
    local pushed = fs.buttonState == "PUSHED"
    if role == "normal" then return enabled and not (pushed and fs.pushed) or (not enabled and not fs.disabled) end
    if role == "pushed" then return enabled and pushed end
    if role == "disabled" then return not enabled end
    if role == "highlight" then return true end
    if role == "checkedTex" then return fs.checked and (enabled or not fs.disabledCheckedTex) end
    if role == "disabledCheckedTex" then return fs.checked and not enabled end
    return true
end

local function FontFor(fs, rs)
    -- A button's label switches font object with the button's state.
    if fs.fontString == rs.obj then
        if fs.enabled == false and fs.disabledFont then return fs.disabledFont end
        if S.hover == fs.obj and fs.highlightFont then return fs.highlightFont end
        if fs.normalFont then return fs.normalFont end
    end
    return nil
end

function S.BuildRender()
    local items = {}
    for i = #hits, 1, -1 do hits[i] = nil end
    local sh = S.screenH

    local function Emit(sortKey, body, clip)
        items[#items + 1] = { key = sortKey, body = body, clip = clip }
    end

    local function Visit(f, clip, alpha)
        local fs = W[f]
        if not fs.shown then return end
        local a = (fs.ignoreParentAlpha and 1 or alpha) * fs.alpha
        local r = Resolve(f)
        local strata, level = STRATA[EffectiveStrata(fs)] or 3, EffectiveLevel(fs)
        if r then
            if (fs.mouse or fs.wheel) and not Outside(clip, r) then
                hits[#hits + 1] = { obj = f, s = fs, l = r.l, b = r.b, w = r.w, h = r.h, clip = clip,
                    strata = strata, level = level, id = fs.id }
            end
            if fs.style or fs.backdrop then
                if not Outside(clip, r) then
                    local bd = fs.backdrop or {}
                    local stt = (fs.enabled == false and "d") or (fs.buttonState == "PUSHED" and "p")
                        or ((S.hover == f or fs.highlightLocked) and "h") or "n"
                    Emit({ strata, level, fs.id, 0, -9, 0 }, fmt(
                        '"k":"b","id":%d,"x":%s,"y":%s,"w":%s,"h":%s,"a":%.3f,"st":%s,"stt":%s,"chk":%s,"bg":%s,"bd":%s,"es":%s,"bgf":%s,"edf":%s',
                        fs.id, Num(r.l), Num(sh - r.b - r.h), Num(r.w), Num(r.h), a, JS(fs.style or "backdrop"),
                        JS(stt), fs.checked and "true" or "false",
                        Color(fs.backdropColor), Color(fs.backdropBorderColor), Num(bd.edgeSize or 0),
                        bd.bgFile and JS(bd.bgFile) or "null", bd.edgeFile and JS(bd.edgeFile) or "null"), clip)
                end
            end
            if fs.isEditBox and fs.text then
                local file, size, flags, color, jh = FontOf(fs)
                local text = fs.password and string.rep("*", strlenutf8(fs.text)) or fs.text
                local cursor = S.focus == f and strlenutf8(fs.text:sub(1, fs.cursor)) or -1
                Emit({ strata, level, fs.id, 4, 8, 0 }, fmt(
                    '"k":"e","id":%d,"x":%s,"y":%s,"w":%s,"h":%s,"a":%.3f,"t":%s,"fo":%s,"sz":%s,"col":%s,"jh":%s,"cur":%d,"ins":[%s,%s,%s,%s],"ml":%s,"hl":%s',
                    fs.id, Num(r.l), Num(sh - r.b - r.h), Num(r.w), Num(r.h), a * (fs.enabled == false and 0.5 or 1),
                    JS(text), JS(file), Num(size * EffectiveScale(fs)), Color(color), JS(jh == "CENTER" and "LEFT" or jh),
                    cursor, Num(fs.insets[1]), Num(fs.insets[2]), Num(fs.insets[3]), Num(fs.insets[4]),
                    fs.multiLine and "true" or "false", fs.highlightAll and "true" or "false"), clip)
            end
        end
        -- Regions (textures and font strings)
        local hovered = S.hover == f or fs.highlightLocked
        for _, region in ipairs(fs.regions) do
            local rs = W[region]
            if rs.shown and (rs.layer ~= "HIGHLIGHT" or hovered) and ButtonRegionShown(fs, rs.buttonRole) then
                local rr = Resolve(region)
                if rr and rr.w > 0 and rr.h > 0 and not Outside(clip, rr) then
                    local ra = a * rs.alpha
                    local key = { strata, level, fs.id, LAYERS[rs.layer] or 3, rs.sublevel or 0, rs.id }
                    local x, y = rr.l, sh - rr.b - rr.h
                    if rs.isFontString then
                        if rs.text and rs.text ~= "" then
                            local fo = FontFor(fs, rs)
                            local file, size, flags, color, jh, jv, shadow
                            if fo then
                                local fos = W[fo]
                                file, size, flags, color, jh, jv, shadow = FontProps(fos)
                                file, size = rs.file or file, rs.size or size
                                color, jh, jv = rs.color and fo == fs.normalFont and rs.color or color, rs.justifyH or jh, rs.justifyV or jv
                            else
                                file, size, flags, color, jh, jv, shadow = FontOf(rs)
                            end
                            if fs.isButton and fs.buttonState == "PUSHED" and fs.pushedOffset and fs.fontString == region then
                                x, y = x + fs.pushedOffset[1], y - fs.pushedOffset[2]
                            end
                            Emit(key, fmt(
                                '"k":"f","id":%d,"x":%s,"y":%s,"w":%s,"h":%s,"a":%.3f,"t":%s,"fo":%s,"sz":%s,"fl":%s,"col":%s,"jh":%s,"jv":%s,"wr":%s,"sh":%s,"ml":%d,"iw":%s',
                                rs.id, Num(x), Num(y), Num(rr.w), Num(rr.h), ra, JS(rs.text), JS(file),
                                Num(size * EffectiveScale(rs)), JS(flags or ""), Color(color), JS(jh or "CENTER"),
                                JS(jv or "MIDDLE"), (rs.wordWrap == false or rs.intrinsicW) and "false" or "true",
                                (shadow or rs.shadowOffset) and "true" or "false", rs.maxLines or 0,
                                rs.intrinsicW and "true" or "false"), clip)
                        end
                    elseif rs.file or rs.color or rs.atlas or rs.gradient then
                        Emit(key, fmt(
                            '"k":"t","id":%d,"x":%s,"y":%s,"w":%s,"h":%s,"a":%.3f,"tex":%s,"atl":%s,"c":%s,"vc":%s,"tc":%s,"bl":%s,"ds":%s,"rot":%s,"gr":%s',
                            rs.id, Num(x), Num(y), Num(rr.w), Num(rr.h), ra, rs.file and JS(rs.file) or "null",
                            rs.atlas and JS(rs.atlas) or "null", Color(rs.color), Color(rs.vc),
                            rs.tc and fmt("[%.4f,%.4f,%.4f,%.4f]", rs.tc[1], rs.tc[2], rs.tc[3], rs.tc[4]) or "null",
                            JS(rs.blend or "BLEND"), rs.desat and "true" or "false", Num(rs.rotation or 0),
                            rs.gradient and fmt("[%s,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f]", JS(rs.gradient[1]),
                                rs.gradient[2], rs.gradient[3], rs.gradient[4], rs.gradient[5], rs.gradient[6],
                                rs.gradient[7], rs.gradient[8], rs.gradient[9]) or "null"), clip)
                    end
                end
            end
        end
        -- Scroll frames clip only their scroll child (the template's scroll bar sits outside them).
        local childClip = clip
        if r and fs.clips then childClip = Intersect(clip, r.l, r.b, r.w, r.h) end
        local scrollClip = r and fs.isScrollFrame and Intersect(childClip, r.l, r.b, r.w, r.h)
        for _, child in ipairs(fs.children) do
            Visit(child, (scrollClip and child == fs.scrollChild) and scrollClip or childClip, a)
        end
    end

    for _, f in ipairs(frames) do
        if not W[f].parent then Visit(f, nil, 1) end
    end

    table.sort(items, function(p, q)
        local a, b = p.key, q.key
        for i = 1, 6 do
            if a[i] ~= b[i] then return a[i] < b[i] end
        end
        return false
    end)
    table.sort(hits, function(p, q)
        if p.strata ~= q.strata then return p.strata > q.strata end
        if p.level ~= q.level then return p.level > q.level end
        return p.id > q.id
    end)

    local out = {}
    for i, it in ipairs(items) do
        local clip = it.clip
        if clip then
            out[i] = fmt('{%s,"z":%d,"clip":[%s,%s,%s,%s]}', it.body, i, Num(clip[1]), Num(sh - clip[2] - clip[4]), Num(clip[3]), Num(clip[4]))
        else
            out[i] = fmt('{%s,"z":%d}', it.body, i)
        end
    end
    S.dirty = false
    return fmt('{"w":%s,"h":%s,"items":[%s]}', Num(S.screenW), Num(S.screenH), table.concat(out, ","))
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------
S.cursorX, S.cursorY = -1, -1
S.mods = { shift = false, ctrl = false, alt = false }

local function HitTest(x, y, filter)
    for _, h in ipairs(hits) do
        local s = h.s
        if s.shown and W[h.obj] and (not filter or filter(s)) then
            local ins = s.hitInsets
            local l, b, w, hh = h.l, h.b, h.w, h.h
            if ins then l, w, b, hh = l + ins[1], w - ins[1] - ins[2], b + ins[4], hh - ins[3] - ins[4] end
            local inside = x >= l and x <= l + w and y >= b and y <= b + hh
            if inside and h.clip then
                local c = h.clip
                inside = x >= c[1] and x <= c[1] + c[3] and y >= c[2] and y <= c[2] + c[4]
            end
            if inside then return h.obj end
        end
    end
end
S.HitTest = HitTest

-- Internal rebuilds (hit testing, hover, use case lookups) keep their result for the host: the next S.Frame hands it
-- over, so a change is never lost just because something read the layout first.
local function EnsureRendered()
    if S.dirty then
        S.lastRender = S.BuildRender()
        S.renderPending = true
    end
end
S.EnsureRendered = EnsureRendered

local function SetHover(obj)
    if S.hover == obj then return end
    local old = S.hover
    S.hover = obj
    Repaint()
    if old and W[old] then
        local os = W[old]
        if os.buttonState == "PUSHED" and not os.stateLocked then os.buttonState = os.enabled == false and "DISABLED" or "NORMAL" end
        if os.enabled ~= false or os.motionWhileDisabled or not os.isButton then S.RunScript(old, "OnLeave", true) end
    end
    if obj then
        local s = W[obj]
        if s.enabled ~= false or s.motionWhileDisabled or not s.isButton then S.RunScript(obj, "OnEnter", true) end
    end
end

local function SliderValueAt(s, x, y)
    local r = Resolve(s.obj)
    if not r then return s.value end
    local f
    if s.orientation == "HORIZONTAL" then f = (x - r.l) / math.max(r.w, 1)
    else f = 1 - (y - r.b) / math.max(r.h, 1) end
    f = math.min(math.max(f, 0), 1)
    return (s.min or 0) + f * ((s.max or 0) - (s.min or 0))
end

local function ApplyMove()
    local m = S.moving
    if m then
        local s = m.s
        local r = Resolve(s.obj)
        if r then
            local es = EffectiveScale(s)
            local l = S.cursorX - m.dx
            local top = S.cursorY - m.dy
            if s.clamped then
                l = math.min(math.max(l, 0), S.screenW - r.w)
                top = math.min(math.max(top, r.h), S.screenH)
            end
            s.points = { { point = "TOPLEFT", rel = UIParent, relPoint = "BOTTOMLEFT", x = l / es, y = top / es } }
            Changed()
        end
    end
    local z = S.sizing
    if z then
        local s = z.s
        local r = Resolve(s.obj)
        if r then
            local es = EffectiveScale(s)
            local b = s.resizeBounds or {}
            local w = math.max((S.cursorX - r.l) / es, b[1] or 1)
            local h = math.max((r.b + r.h - S.cursorY) / es, b[2] or 1)
            if b[3] and b[3] > 0 then w = math.min(w, b[3]) end
            if b[4] and b[4] > 0 then h = math.min(h, b[4]) end
            Region.SetSize(s.obj, w, h)
        end
    end
end

-- Host coordinates: UI units from the top-left. Converted to WoW's bottom-left origin.
function S.MouseMove(x, y)
    S.cursorX, S.cursorY = x, S.screenH - y
    if S.moving or S.sizing then ApplyMove() end
    local sd = S.sliderDrag
    if sd then SetBarValue(sd.obj, sd.s, SliderValueAt(sd.s, S.cursorX, S.cursorY), true) end
    local pd = S.pendingDrag
    if pd and not S.dragStarted and (math.abs(S.cursorX - pd.x) > 3 or math.abs(S.cursorY - pd.y) > 3) then
        S.dragStarted = true
        S.dragging = pd.obj
        S.RunScript(pd.obj, "OnDragStart", pd.button)
    end
    EnsureRendered()
    if not S.mouseDown then SetHover(HitTest(S.cursorX, S.cursorY)) end
end

local function SetMods(shift, ctrl, alt)
    if shift ~= nil then S.mods.shift, S.mods.ctrl, S.mods.alt = shift and true or false, ctrl and true or false, alt and true or false end
end

-- Modifier flags ride along with clicks (Alt+click, Shift+click) when the host knows them.
function S.MouseDown(button, shift, ctrl, alt)
    SetMods(shift, ctrl, alt)
    EnsureRendered()
    local target = HitTest(S.cursorX, S.cursorY)
    SetHover(target)
    S.mouseDown = { obj = target, button = button }
    if S.focus and S.focus ~= target then S.ClearFocus() end
    if not target then return end
    local s = W[target]
    if s.toplevel then Frame.Raise(target) end
    if s.isButton and s.enabled and not s.stateLocked then s.buttonState = "PUSHED"; Repaint() end
    if s.isEditBox and s.enabled then S.SetFocus(target) end
    if s.isSlider and s.enabled then
        S.sliderDrag = { obj = target, s = s }
        SetBarValue(target, s, SliderValueAt(s, S.cursorX, S.cursorY), true)
    end
    S.RunScript(target, "OnMouseDown", button)
    if s.drag and s.drag[button] then
        S.pendingDrag = { obj = target, button = button, x = S.cursorX, y = S.cursorY }
        S.dragStarted = false
    end
    if s.isButton and s.enabled and (s.clicks[button .. "Down"] or s.clicks.AnyDown) then
        S.DoClick(target, button, true)
    end
end

function S.MouseUp(button, shift, ctrl, alt)
    SetMods(shift, ctrl, alt)
    local down = S.mouseDown
    S.mouseDown = nil
    S.sliderDrag = nil
    local target = down and down.obj
    local dragged = S.dragStarted
    if S.pendingDrag then
        if S.dragStarted then S.RunScript(S.pendingDrag.obj, "OnDragStop") end
        S.pendingDrag, S.dragStarted = nil, false
    end
    S.moving, S.sizing, S.dragging = nil, nil, nil
    EnsureRendered()
    local over = HitTest(S.cursorX, S.cursorY)
    if target and W[target] then
        local s = W[target]
        if s.isButton and not s.stateLocked then s.buttonState = s.enabled and "NORMAL" or "DISABLED"; Repaint() end
        S.RunScript(target, "OnMouseUp", button, over == target)
        if over == target and not dragged and s.isButton and s.enabled
            and (s.clicks[button .. "Up"] or s.clicks.AnyUp) then
            S.DoClick(target, button, false)
        end
    end
    SetHover(over)
end

-- WoW recomputes mouse focus every frame: a frame that hides under the cursor gets OnLeave, one that appears
-- under it gets OnEnter, without the mouse moving.
function S.RefreshHover()
    if S.mouseDown or S.cursorX < 0 or S.cursorY < 0 then return end
    local h = S.hover
    if h and W[h] and IsVisible(W[h]) and not S.dirty then return end
    EnsureRendered()
    SetHover(HitTest(S.cursorX, S.cursorY))
end

function S.MouseWheel(delta)
    EnsureRendered()
    local obj = HitTest(S.cursorX, S.cursorY)
    while obj do
        local s = W[obj]
        if s.wheel then
            S.RunScript(obj, "OnMouseWheel", delta)
            return true
        end
        obj = s.parent
    end
    return false
end

function S.MouseLeave()
    S.cursorX, S.cursorY = -1, -1
    if not S.mouseDown then SetHover(nil) end
end

function IsShiftKeyDown() return S.mods.shift end
function IsControlKeyDown() return S.mods.ctrl end
function IsAltKeyDown() return S.mods.alt end
function IsLeftShiftKeyDown() return S.mods.shift end
function IsRightShiftKeyDown() return false end
function IsLeftControlKeyDown() return S.mods.ctrl end
function IsRightControlKeyDown() return false end
function IsLeftAltKeyDown() return S.mods.alt end
function IsRightAltKeyDown() return false end
function IsMetaKeyDown() return false end
function IsModifierKeyDown() return S.mods.shift or S.mods.ctrl or S.mods.alt end
function IsModifiedClick(action)
    if action == "CHATLINK" or action == "SPLITSTACK" then return S.mods.shift end
    if action == "DRESSUP" then return S.mods.ctrl end
    return false
end
function IsMouseButtonDown(button) return S.mouseDown ~= nil end
function GetCursorPosition() return math.max(S.cursorX, 0), math.max(S.cursorY, 0) end
function GetMouseFoci() return { S.hover or WorldFrame } end

local function PrevCharStart(text, pos)
    if pos <= 0 then return 0 end
    local i = pos
    repeat i = i - 1 until i <= 0 or not text:byte(i + 1) or text:byte(i + 1) < 128 or text:byte(i + 1) >= 192
    return i
end
local function NextCharEnd(text, pos)
    if pos >= #text then return #text end
    local c = text:byte(pos + 1)
    return pos + (c >= 240 and 4 or c >= 224 and 3 or c >= 192 and 2 or 1)
end

-- Key names as WoW spells them (ESCAPE, ENTER, BACKSPACE, LEFT, A, F1...). Returns true when consumed.
function S.KeyDown(key, shift, ctrl, alt)
    S.mods.shift, S.mods.ctrl, S.mods.alt = shift and true or false, ctrl and true or false, alt and true or false
    local f = S.focus
    if f then
        local s = W[f]
        local text, pos = s.text, s.cursor
        if key == "BACKSPACE" then
            if s.highlightAll then S.SetEditText(f, s, "", true); s.cursor = 0; s.highlightAll = nil
            elseif pos > 0 then
                local start = PrevCharStart(text, pos)
                s.cursor = start
                S.SetEditText(f, s, text:sub(1, start) .. text:sub(pos + 1), true)
            end
        elseif key == "DELETE" then
            if pos < #text then S.SetEditText(f, s, text:sub(1, pos) .. text:sub(NextCharEnd(text, pos) + 1), true) end
        elseif key == "LEFT" then s.cursor = PrevCharStart(text, pos); s.highlightAll = nil; Repaint()
            S.RunScript(f, "OnArrowPressed", key)
        elseif key == "RIGHT" then s.cursor = NextCharEnd(text, pos); s.highlightAll = nil; Repaint()
            S.RunScript(f, "OnArrowPressed", key)
        elseif key == "UP" or key == "DOWN" then S.RunScript(f, "OnArrowPressed", key)
        elseif key == "HOME" then s.cursor = 0; Repaint()
        elseif key == "END" then s.cursor = #text; Repaint()
        elseif key == "ENTER" then
            if s.multiLine and not S.HasScript(f, "OnEnterPressed") then S.Char("\n")
            else S.RunScript(f, "OnEnterPressed") end
        elseif key == "ESCAPE" then S.RunScript(f, "OnEscapePressed")
        elseif key == "TAB" then S.RunScript(f, "OnTabPressed")
        elseif key == "A" and ctrl then s.highlightAll = true; Repaint()
        else
            S.RunScript(f, "OnKeyDown", key)
        end
        return true
    end
    -- Keyboard-enabled frames, topmost first.
    for i = #frames, 1, -1 do
        local fr = frames[i]
        local s = W[fr]
        if s.keyboard and IsVisible(s) and S.HasScript(fr, "OnKeyDown") then
            S.RunScript(fr, "OnKeyDown", key)
            if not s.propagateKeys then return true end
        end
    end
    if key == "ESCAPE" then return CloseSpecialWindows and CloseSpecialWindows() or false end
    return false
end

function S.KeyUp(key, shift, ctrl, alt)
    S.mods.shift, S.mods.ctrl, S.mods.alt = shift and true or false, ctrl and true or false, alt and true or false
    for i = #frames, 1, -1 do
        local fr = frames[i]
        local s = W[fr]
        if s.keyboard and IsVisible(s) and S.HasScript(fr, "OnKeyUp") then S.RunScript(fr, "OnKeyUp", key) end
    end
end

-- Typed text (one or more characters, also used for paste).
function S.Char(text)
    local f = S.focus
    if not f then return false end
    local s = W[f]
    if s.numeric and not text:match("^%d+$") then return true end
    if s.highlightAll then s.text, s.cursor, s.highlightAll = "", 0, nil end
    local before, after = s.text:sub(1, s.cursor), s.text:sub(s.cursor + 1)
    local oldLen = #s.text
    S.SetEditText(f, s, before .. text .. after, true)
    s.cursor = math.min(#before + (#s.text - oldLen), #s.text)
    Repaint()
    S.RunScript(f, "OnChar", text)
    if text == " " then S.RunScript(f, "OnSpacePressed") end
    return true
end

---------------------------------------------------------------------------
-- Per-frame update: OnUpdate scripts on visible frames, then scroll range checks
---------------------------------------------------------------------------
function S.RunOnUpdate(elapsed)
    for i = 1, #frames do
        local f = frames[i]
        local s = W[f]
        if s.scripts.OnUpdate and IsVisible(s) then S.RunScript(f, "OnUpdate", elapsed) end
    end
    S.UpdateScrollRanges()
end

-- For the frame inspector (/fstack): frames under the cursor, topmost first.
function S.FrameStack()
    EnsureRendered()
    local out = {}
    for _, f in ipairs(frames) do
        local s = W[f]
        local r = IsVisible(s) and Resolve(f)
        if r and S.cursorX >= r.l and S.cursorX <= r.l + r.w and S.cursorY >= r.b and S.cursorY <= r.b + r.h then
            out[#out + 1] = { name = Object.GetDebugName(f), type = s.type, strata = EffectiveStrata(s),
                level = EffectiveLevel(s), mouse = s.mouse or false, id = s.id,
                rect = { r.l, S.screenH - r.b - r.h, r.w, r.h } }
        end
    end
    table.sort(out, function(a, b)
        local sa, sb = STRATA[a.strata], STRATA[b.strata]
        if sa ~= sb then return sa > sb end
        if a.level ~= b.level then return a.level > b.level end
        return a.id > b.id
    end)
    return S.JSON(out)
end
