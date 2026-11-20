-- Use case helpers: what is visible on screen (text, frames), finding a target the way a viewer would ("the button
-- that says AH sale"), and describing what sits under a point (record mode). Coordinates returned to the host are UI
-- units from the top-left, like the render list.
local S = SANDBOX
local W = S.W
local fmt = string.format

---------------------------------------------------------------------------
-- Text normalisation
---------------------------------------------------------------------------
-- Visible text: colour codes, links and textures removed; money icons become g/s/c.
local function Plain(text)
    text = tostring(text or "")
    text = text:gsub("|T([^|]-)|t", function(path)
        local p = path:lower()
        if p:find("goldicon") then return "g" end
        if p:find("silvericon") then return "s" end
        if p:find("coppericon") then return "c" end
        return ""
    end)
    text = text:gsub("|A.-|a", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]-:", ""):gsub("|r", "")
    text = text:gsub("|H.-|h(.-)|h", "%1"):gsub("|n", " "):gsub("||", "|")
    text = text:gsub("[\r\n\t]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return text
end
S.UCPlain = Plain

---------------------------------------------------------------------------
-- Visible tree walk (mirrors BuildRender: shown, alpha, clipping)
---------------------------------------------------------------------------
local function Intersect(a, l, b, w, h)
    if not a then return { l, b, w, h } end
    local x1, y1 = math.max(a[1], l), math.max(a[2], b)
    local x2, y2 = math.min(a[1] + a[3], l + w), math.min(a[2] + a[4], b + h)
    return { x1, y1, math.max(0, x2 - x1), math.max(0, y2 - y1) }
end

local function Visible(rect, clip)
    if rect.w <= 0 or rect.h <= 0 then return false end
    local l, b, w, h = rect.l, rect.b, rect.w, rect.h
    if clip then
        local c = Intersect(clip, l, b, w, h)
        if c[3] <= 0.5 or c[4] <= 0.5 then return false end
        l, b, w, h = c[1], c[2], c[3], c[4]
    end
    -- on screen
    return l < S.screenW and l + w > 0 and b < S.screenH and b + h > 0
end

-- Glyph bounds of a font string inside its rect (justification aware), WoW coordinates.
local function GlyphRect(rs, rr)
    local _, _, _, _, jh, jv = S.FontOf(rs)
    local gw = math.min(rr.w, math.max(S.FontStringWidth(rs), 1))
    local gh = math.min(rr.h, math.max(S.FontStringHeight(rs, rr.w), 1))
    local l = rr.l
    if jh == "RIGHT" then l = rr.l + rr.w - gw elseif jh ~= "LEFT" then l = rr.l + (rr.w - gw) / 2 end
    local b = rr.b + (rr.h - gh) / 2
    if jv == "TOP" then b = rr.b + rr.h - gh elseif jv == "BOTTOM" then b = rr.b end
    return { l = l, b = b, w = gw, h = gh }
end

-- Returns texts = { {obj, owner, text, plain, rect, glyph, kind} }, frames = { {obj, s, rect} }
local function Collect()
    S.EnsureRendered()
    local texts, frames = {}, {}
    local function Visit(f, clip, alpha)
        local fs = W[f]
        if not fs or not fs.shown then return end
        local a = (fs.ignoreParentAlpha and 1 or alpha) * (fs.alpha or 1)
        if a <= 0.02 then return end
        local r = S.Resolve(f)
        if r and Visible(r, clip) then
            frames[#frames + 1] = { obj = f, s = fs, rect = r }
            if fs.isEditBox and fs.text and fs.text ~= "" then
                texts[#texts + 1] = { obj = f, owner = f, text = fs.text, plain = Plain(fs.text), rect = r, glyph = r, kind = "edit" }
            end
        end
        for _, region in ipairs(fs.regions) do
            local rs = W[region]
            if rs and rs.isFontString and rs.shown and rs.text and rs.text ~= "" and (rs.alpha or 1) > 0.02
                and (rs.layer ~= "HIGHLIGHT" or S.hover == f) then
                local rr = S.Resolve(region)
                if rr and Visible(rr, clip) then
                    local plain = Plain(rs.text)
                    if plain ~= "" then
                        texts[#texts + 1] = { obj = region, owner = f, text = rs.text, plain = plain, rect = rr,
                            glyph = GlyphRect(rs, rr), kind = "text" }
                    end
                end
            end
        end
        local childClip = clip
        if r and fs.clips then childClip = Intersect(clip, r.l, r.b, r.w, r.h) end
        local scrollClip = r and fs.isScrollFrame and Intersect(childClip, r.l, r.b, r.w, r.h)
        for _, child in ipairs(fs.children) do
            Visit(child, (scrollClip and child == fs.scrollChild) and scrollClip or childClip, a)
        end
    end
    for _, f in ipairs(S.allFrames) do
        if not W[f].parent then Visit(f, nil, 1) end
    end
    return texts, frames
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function Name(obj)
    local s = obj and W[obj]
    if not s then return nil end
    local ok, name = pcall(obj.GetDebugName, obj)
    return ok and name or ("<" .. tostring(s.type) .. " " .. tostring(s.id) .. ">")
end

local function GlobalName(obj)
    local s = obj and W[obj]
    if s and s.name and _G[s.name] == obj then return s.name end
    return nil
end

local function IsAncestor(anc, obj)
    local s = obj and W[obj]
    while s do
        if s.obj == anc then return true end
        s = s.parent and W[s.parent]
    end
    return false
end

local function HostRect(r)
    return { r.l, S.screenH - r.b - r.h, r.w, r.h }
end

local function Center(r) return r.l + r.w / 2, r.b + r.h / 2 end

-- What a click at the centre of `rect` would hit, and whether that is the element itself (or its owner chain).
-- A label outside its button (an icon caption below the icon) clicks the button: its owner when that takes the mouse.
local function ClickInfo(rect, owner)
    local x, y = Center(rect)
    local hit = S.HitTest(x, y)
    if not hit and owner and W[owner] and W[owner].mouse then
        local orr = S.Resolve(owner)
        if orr then
            local ox, oy = Center(orr)
            local h2 = S.HitTest(ox, oy)
            if h2 and (h2 == owner or IsAncestor(owner, h2) or IsAncestor(h2, owner)) then x, y, hit = ox, oy, h2 end
        end
    end
    local info = { point = { x, S.screenH - y } }
    if hit then
        info.clickName = Name(hit)
        info.clickId = W[hit].id
        info.clickRect = HostRect(S.Resolve(hit) or rect)
        if owner and not (hit == owner or IsAncestor(hit, owner) or IsAncestor(owner, hit)) then
            info.covered = Name(hit)
        end
    end
    return info
end

local function Within(withinName)
    if not withinName or withinName == "" then return nil end
    local obj = _G[withinName]
    if type(obj) == "table" and W[obj] then return obj end
    -- dotted path: A.child.key
    return S.UCPath(withinName)
end

-- "A.key.2" -> object (parentKey fields, numeric segments index the table or the child list)
function S.UCPath(path)
    local obj
    for seg in tostring(path):gmatch("[^%.]+") do
        if obj == nil then
            obj = _G[seg]
        else
            local n = tonumber(seg)
            local nextObj = obj[n or seg]
            if nextObj == nil and n and W[obj] then nextObj = W[obj].children[n] end
            obj = nextObj
        end
        if type(obj) ~= "table" then return nil end
    end
    if obj and W[obj] then return obj end
    return nil
end

---------------------------------------------------------------------------
-- Host API
---------------------------------------------------------------------------
-- Every visible text on screen (optionally inside a frame), top to bottom.
function S.UCTextsJSON(withinName)
    local texts = Collect()
    local within = Within(withinName)
    if withinName and withinName ~= "" and not within then return S.JSON({ error = "no frame named " .. withinName }) end
    local out = {}
    for _, t in ipairs(texts) do
        if not within or IsAncestor(within, t.owner) then
            local item = { text = t.plain, kind = t.kind, owner = Name(t.owner), ownerId = W[t.owner].id,
                rect = HostRect(t.glyph) }
            local ci = ClickInfo(t.glyph, t.owner)
            item.clickName, item.clickId, item.covered, item.point = ci.clickName, ci.clickId, ci.covered, ci.point
            out[#out + 1] = item
        end
    end
    table.sort(out, function(a, b)
        if math.abs(a.rect[2] - b.rect[2]) > 3 then return a.rect[2] < b.rect[2] end
        return a.rect[1] < b.rect[1]
    end)
    return S.JSON(out)
end

-- Finds a target. spec: { text, within } | { frame } | { path } | { point = {x, y} }
-- Returns { matches = { { kind, name, text, rect, point, clickName, clickId, clickRect, covered, exact } } }
function S.UCFindJSON(literal)
    local fn = loadstring("return " .. literal, "target")
    local spec = fn and fn() or {}
    local out = {}
    S.EnsureRendered()   -- hit tests below need the current hit list (a window may have just opened)
    if spec.text then
        local texts = Collect()
        local within = Within(spec.within)
        if spec.within and not within then return S.JSON({ matches = {}, error = "no visible frame named " .. spec.within }) end
        local want = Plain(spec.text):lower()
        local function Loose(s) return (s:lower():gsub("[^%w%s]", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) end
        local wantLoose = Loose(want)
        for _, t in ipairs(texts) do
            if not within or IsAncestor(within, t.owner) then
                local have = t.plain:lower()
                local exact = have == want or (wantLoose ~= "" and Loose(have) == wantLoose)
                local contains = not exact and have:find(want, 1, true) ~= nil
                if exact or contains then
                    local m = ClickInfo(t.glyph, t.owner)
                    m.kind, m.name, m.text, m.exact = t.kind, Name(t.owner), t.plain, exact
                    m.strict = have == want   -- same text, not only after dropping punctuation
                    m.rect = HostRect(t.glyph)
                    m.ownerId = W[t.owner].id
                    out[#out + 1] = m
                end
            end
        end
    elseif spec.frame or spec.path then
        local obj = spec.frame and _G[spec.frame] or S.UCPath(spec.path)
        if type(obj) == "table" and W[obj] then
            local s = W[obj]
            local r = S.IsVisible(s) and S.Resolve(obj)
            if r and r.w > 0 and r.h > 0 then
                local m = ClickInfo(r, obj)
                m.kind, m.name, m.exact = "frame", Name(obj), true
                m.rect = HostRect(r)
                m.ownerId = s.id
                -- a frame's own label, if it has exactly one, for captions and reports
                local texts = Collect()
                for _, t in ipairs(texts) do
                    if t.owner == obj then m.text = m.text and (m.text .. " / " .. t.plain) or t.plain end
                end
                out[#out + 1] = m
            else
                return S.JSON({ matches = {}, error = (spec.frame or spec.path) .. " exists but is not visible" })
            end
        else
            return S.JSON({ matches = {}, error = "no frame " .. (spec.frame and ("named " .. spec.frame) or ("at path " .. spec.path)) })
        end
    elseif spec.point then
        local x, y = tonumber(spec.point[1]) or 0, tonumber(spec.point[2]) or 0
        local wy = S.screenH - y
        S.EnsureRendered()
        local hit = S.HitTest(x, wy)
        local m = { kind = "point", point = { x, y }, rect = { x - 1, y - 1, 2, 2 }, exact = true }
        if hit then m.clickName, m.clickId, m.name = Name(hit), W[hit].id, Name(hit) end
        out[#out + 1] = m
    end
    table.sort(out, function(a, b)
        if a.exact ~= b.exact then return a.exact end
        if math.abs(a.rect[2] - b.rect[2]) > 3 then return a.rect[2] < b.rect[2] end
        return a.rect[1] < b.rect[1]
    end)
    return S.JSON({ matches = out })
end

-- Record mode: what is under a host point, with candidate targets (texts in the clicked frame, its names).
function S.UCDescribePointJSON(x, y)
    S.EnsureRendered()
    local wy = S.screenH - y
    local hit = S.HitTest(x, wy)
    if not hit then return S.JSON({ point = { x, y } }) end
    local texts = Collect()
    local hs = W[hit]
    local mine = {}
    for _, t in ipairs(texts) do
        if t.owner == hit or IsAncestor(hit, t.owner) then mine[#mine + 1] = t.plain end
    end
    -- nearest named ancestor + parentKey path
    local path, s = {}, hs
    local base
    while s do
        if GlobalName(s.obj) then base = s.name break end
        if s.parentKey then table.insert(path, 1, s.parentKey) else path = nil break end
        s = s.parent and W[s.parent]
    end
    return S.JSON({
        point = { x, y }, hitName = Name(hit), hitId = hs.id, global = GlobalName(hit),
        path = (base and path and #path > 0) and (base .. "." .. table.concat(path, ".")) or nil,
        texts = mine, rect = HostRect(S.Resolve(hit)),
    })
end

-- Is a tooltip showing, and its lines.
function S.UCTooltipJSON()
    local out = {}
    for _, name in ipairs({ "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2" }) do
        local tt = _G[name]
        if tt and W[tt] and S.IsVisible(W[tt]) then
            local texts = Collect()
            local lines = {}
            for _, t in ipairs(texts) do if IsAncestor(tt, t.owner) then lines[#lines + 1] = t.plain end end
            out[#out + 1] = { name = name, lines = lines }
        end
    end
    return S.JSON(out)
end

-- Global names that hold visible frames created by addons (surface report).
function S.UCNamedFramesJSON()
    local _, frames = Collect()
    local out = {}
    for _, f in ipairs(frames) do
        local g = GlobalName(f.obj)
        if g and g ~= "UIParent" and g ~= "WorldFrame" then
            out[#out + 1] = { name = g, type = f.s.type, rect = HostRect(f.rect), mouse = f.s.mouse or false }
        end
    end
    return S.JSON(out)
end

-- Slash commands: { key, aliases }
function S.UCSlashJSON()
    local out = {}
    for key in pairs(SlashCmdList) do
        local aliases = {}
        local i = 1
        while _G["SLASH_" .. key .. i] do aliases[#aliases + 1] = _G["SLASH_" .. key .. i]; i = i + 1 end
        out[#out + 1] = { key = key, aliases = aliases }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return S.JSON(out)
end

-- Shape of a value for the surface report: keys and types, a few levels deep.
function S.UCShapeJSON(expr, depth)
    local fn = loadstring("return " .. expr, "shape")
    if not fn then return S.JSON({ error = "bad expression" }) end
    local ok, v = pcall(fn)
    if not ok then return S.JSON({ error = tostring(v) }) end
    depth = tonumber(depth) or 2
    local function Shape(x, d)
        local t = type(x)
        if t ~= "table" then
            if t == "string" then return #x > 40 and ("string: " .. x:sub(1, 40) .. "...") or ("string: " .. x) end
            return t .. ": " .. tostring(x)
        end
        local n, keys = 0, {}
        for k in pairs(x) do n = n + 1; if #keys < 12 then keys[#keys + 1] = k end end
        if d <= 0 then return fmt("table (%d keys)", n) end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local o = { _keys = n }
        for _, k in ipairs(keys) do o[tostring(k)] = Shape(x[k], d - 1) end
        return o
    end
    return S.JSON({ value = Shape(v, depth) })
end
