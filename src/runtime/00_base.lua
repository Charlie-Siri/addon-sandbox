-- Base: the sandbox namespace, WoW's Lua dialect (globals it adds, libraries it removes), error handling, JSON.
-- Runs first. The host (TypeScript) has already set SANDBOX_HOST, a table of JS functions.
SANDBOX = {}
local S = SANDBOX
S.host = SANDBOX_HOST
SANDBOX_HOST = nil
local host = S.host

local traceback = debug.traceback
local osdate, ostime, osclock, osdifftime = os.date, os.time, os.clock, os.difftime
S.traceback = traceback

---------------------------------------------------------------------------
-- Libraries WoW doesn't have
---------------------------------------------------------------------------
io, os, debug, package, module, require, dofile, loadfile = nil, nil, nil, nil, nil, nil, nil, nil

---------------------------------------------------------------------------
-- Error handling (seterrorhandler / geterrorhandler / debugstack)
---------------------------------------------------------------------------
-- Errors reach the host's error console with a stack; dedup and counts happen there.
function S.ReportError(msg, stack)
    host.error(tostring(msg), stack or "")
end

local function DefaultErrorHandler(msg)
    S.ReportError(msg, traceback("", 2))
    return msg
end
local errorHandler = DefaultErrorHandler

function seterrorhandler(fn)
    if type(fn) ~= "function" then error("Usage: seterrorhandler(errfunc)", 2) end
    errorHandler = fn
end
function geterrorhandler() return errorHandler end

local function OnError(msg)
    local ok, err = pcall(errorHandler, msg)
    if not ok then S.ReportError("Error in error handler: " .. tostring(err), traceback("", 2)) end
    return msg
end

-- Calls addon code; errors go to the error handler like WoW's script dispatch. Returns ok, results...
function S.Call(fn, ...)
    local n = select("#", ...)
    if n == 0 then return xpcall(fn, OnError) end
    local args = { ... }
    return xpcall(function() return fn(unpack(args, 1, n)) end, OnError)
end

-- WoW's debugstack: traceback lines without the header, starting `start` levels up.
function debugstack(start, count1, count2)
    local tb = traceback("", (tonumber(start) or 1) + 1)
    tb = tb:gsub("^\nstack traceback:\n", "")
    return tb
end
function debuglocals() return "" end

---------------------------------------------------------------------------
-- Secure environment stand-ins (no taint model yet: everything is "insecure but allowed")
---------------------------------------------------------------------------
function issecure() return false end
function issecurevariable(t, name)
    if name == nil then return true, nil end
    return true, nil
end
function forceinsecure() end
function securecall(fn, ...)
    if type(fn) == "string" then fn = _G[fn] end
    if type(fn) ~= "function" then return end
    return select(2, S.Call(fn, ...))
end
securecallfunction = securecall
function secureexecuterange(t, fn, ...)
    for k, v in pairs(t) do securecall(fn, k, v, ...) end
end
function scrub(...) return ... end

-- hooksecurefunc([table,] name, hook): hook runs after the original with the same arguments.
function hooksecurefunc(t, name, hook)
    if type(t) == "string" then t, name, hook = _G, t, name end
    local original = t[name]
    if type(original) ~= "function" then
        error(("hooksecurefunc(): %s is not a function"):format(tostring(name)), 2)
    end
    t[name] = function(...)
        local r = { original(...) }
        local n = select("#", ...)
        local args = { ... }
        S.Call(function() hook(unpack(args, 1, n)) end)
        return unpack(r)
    end
end

---------------------------------------------------------------------------
-- String library extras
---------------------------------------------------------------------------
local function CharClass(chars)
    return "[" .. chars:gsub("[%^%]%-%%]", "%%%0") .. "]"
end

-- strsplit(delimiters, text, pieces): every character of `delimiters` splits.
function strsplit(delim, str, pieces)
    if type(str) ~= "string" then error("Usage: strsplit(delimiter, subject, pieces)", 2) end
    local pattern = CharClass(delim)
    local out, n, start = {}, 0, 1
    pieces = tonumber(pieces) or 0
    while true do
        if pieces > 0 and n >= pieces - 1 then break end
        local s, e = str:find(pattern, start)
        if not s then break end
        n = n + 1
        out[n] = str:sub(start, s - 1)
        start = e + 1
    end
    n = n + 1
    out[n] = str:sub(start)
    return unpack(out, 1, n)
end

function strsplittable(delim, str, pieces) return { strsplit(delim, str, pieces) } end

function strjoin(delim, ...)
    local n = select("#", ...)
    local t = { ... }
    for i = 1, n do
        if type(t[i]) ~= "string" and type(t[i]) ~= "number" then error("Usage: strjoin(delimiter, ...)", 2) end
    end
    return table.concat(t, delim, 1, n)
end

function strconcat(...) return table.concat({ ... }) end

function strtrim(str, chars)
    chars = chars and CharClass(chars) or "[ \t\r\n]"
    str = str:gsub("^" .. chars .. "+", "")
    return (str:gsub(chars .. "+$", ""))
end

function strlenutf8(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

function strcmputf8i(a, b)
    a, b = a:lower(), b:lower()
    if a == b then return 0 end
    return a < b and -1 or 1
end

function tostringall(...)
    local n = select("#", ...)
    local t = { ... }
    for i = 1, n do t[i] = tostring(t[i]) end
    return unpack(t, 1, n)
end

string.split, string.join, string.trim = strsplit, strjoin, strtrim

strbyte, strchar, strfind, strformat, strgmatch, strgsub = string.byte, string.char, string.find, string.format, string.gmatch, string.gsub
strlen, strlower, strmatch, strrep, strrev, strsub, strupper = string.len, string.lower, string.match, string.rep, string.reverse, string.sub, string.upper
format, gsub, gmatch = string.format, string.gsub, string.gmatch

---------------------------------------------------------------------------
-- Table and math extras
---------------------------------------------------------------------------
function wipe(t)
    for k in pairs(t) do t[k] = nil end
    return t
end
table.wipe = wipe
tinsert, tremove, sort, getn = table.insert, table.remove, table.sort, table.getn
foreach, foreachi = table.foreach, table.foreachi

abs, ceil, floor, max, min, mod, sqrt, exp, log, log10, frexp, ldexp = math.abs, math.ceil, math.floor, math.max,
    math.min, math.fmod, math.sqrt, math.exp, math.log, math.log10, math.frexp, math.ldexp
random, fastrandom, randomseed = math.random, math.random, math.randomseed
local rad, deg = math.rad, math.deg
-- WoW's global trig functions take degrees.
function sin(d) return math.sin(rad(d)) end
function cos(d) return math.cos(rad(d)) end
function tan(d) return math.tan(rad(d)) end
function asin(x) return deg(math.asin(x)) end
function acos(x) return deg(math.acos(x)) end
function atan(x) return deg(math.atan(x)) end
function atan2(y, x) return deg(math.atan2(y, x)) end
PI = math.pi

bit = {
    band = host.band, bor = host.bor, bxor = host.bxor, bnot = host.bnot,
    lshift = host.lshift, rshift = host.rshift, arshift = host.arshift,
    mod = function(a, b) return a % b end,
    tobit = function(a) return host.band(a, 0xFFFFFFFF) end,
}

---------------------------------------------------------------------------
-- Time
---------------------------------------------------------------------------
S.now = 0   -- seconds since the session started, advanced by the host's frame loop
function GetTime() return math.floor(S.now * 1000 + 0.5) / 1000 end
function GetTimePreciseSec() return S.now end
date, time, difftime = osdate, ostime, osdifftime
function GetServerTime() return ostime() end
function debugprofilestart() end
function debugprofilestop() return host.now() end
function GetFramerate() return S.fps or 60 end

---------------------------------------------------------------------------
-- print goes to the default chat frame (redefined once the chat frame exists)
---------------------------------------------------------------------------
function print(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    host.chat(table.concat(parts, " "), 1, 1, 1)
end

---------------------------------------------------------------------------
-- Missing-API reporting: each unimplemented-but-real API is reported once
---------------------------------------------------------------------------
local reportedMissing = {}
function S.Missing(name)
    if not reportedMissing[name] then
        reportedMissing[name] = true
        host.missing(name)
    end
end

-- A real WoW function the sandbox doesn't emulate yet: does nothing, reports itself once.
function S.Stub(name, ...)
    local results = { ... }
    local n = select("#", ...)
    return function()
        S.Missing(name)
        return unpack(results, 1, n)
    end
end

function S.Warn(msg) host.warn(tostring(msg)) end

---------------------------------------------------------------------------
-- JSON encoder (Lua -> host). Arrays are tables with 1..n keys only.
---------------------------------------------------------------------------
local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function EscapeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or ("\\u%04x"):format(c:byte())
    end) .. '"'
end
S.JSONString = EscapeString

local function IsArray(t)
    local n = #t
    if n == 0 then return next(t) == nil end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count == n
end

local function Encode(v, out, depth)
    local tv = type(v)
    if tv == "string" then
        out[#out + 1] = EscapeString(v)
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
        elseif v == math.floor(v) and math.abs(v) < 1e15 then out[#out + 1] = ("%d"):format(v)
        else out[#out + 1] = ("%.10g"):format(v) end
    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tv == "table" then
        if depth > 40 then out[#out + 1] = "null" return end
        if IsArray(v) and #v > 0 then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                Encode(v[i], out, depth + 1)
            end
            out[#out + 1] = "]"
        else
            out[#out + 1] = "{"
            local first = true
            for k, val in pairs(v) do
                local tk = type(k)
                if (tk == "string" or tk == "number") and type(val) ~= "function" then
                    if not first then out[#out + 1] = "," end
                    first = false
                    out[#out + 1] = EscapeString(tostring(k))
                    out[#out + 1] = ":"
                    Encode(val, out, depth + 1)
                end
            end
            out[#out + 1] = "}"
        end
    else
        out[#out + 1] = "null"
    end
end

function S.JSON(v)
    local out = {}
    Encode(v, out, 0)
    return table.concat(out)
end

---------------------------------------------------------------------------
-- Mixins (FrameXML's Mixin.lua)
---------------------------------------------------------------------------
function Mixin(object, ...)
    for i = 1, select("#", ...) do
        local mixin = select(i, ...)
        for k, v in pairs(mixin) do object[k] = v end
    end
    return object
end
function CreateFromMixins(...) return Mixin({}, ...) end
function CreateAndInitFromMixin(mixin, ...)
    local object = CreateFromMixins(mixin)
    object:Init(...)
    return object
end

---------------------------------------------------------------------------
-- TableUtil / MathUtil subset
---------------------------------------------------------------------------
function tContains(t, value)
    for _, v in pairs(t) do if v == value then return true end end
    return false
end
function tIndexOf(t, value)
    for i, v in ipairs(t) do if v == value then return i end end
end
function tInvert(t)
    local out = {}
    for k, v in pairs(t) do out[v] = k end
    return out
end
function tDeleteItem(t, value)
    local i = 1
    while t[i] do
        if t[i] == value then tremove(t, i) else i = i + 1 end
    end
end
function tAppendAll(t, add) for _, v in ipairs(add) do t[#t + 1] = v end end
function tFilter(t, pred, isIndexTable)
    local out = {}
    for k, v in pairs(t) do
        if pred(v) then if isIndexTable then out[#out + 1] = v else out[k] = v end end
    end
    return out
end
function tCompare(a, b, depth)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end
function CopyTable(t, shallow)
    local out = {}
    for k, v in pairs(t) do
        if type(v) == "table" and not shallow then out[k] = CopyTable(v) else out[k] = v end
    end
    return out
end
function GetKeysArray(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    return out
end
function GetValuesArray(t)
    local out = {}
    for _, v in pairs(t) do out[#out + 1] = v end
    return out
end
function TableIsEmpty(t) return next(t) == nil end
function TableHasAnyEntries(t) return next(t) ~= nil end
function Round(v) return math.floor(v + 0.5) end
function Clamp(v, lo, hi) return math.min(math.max(v, lo), hi) end
function Saturate(v) return Clamp(v, 0, 1) end
function Lerp(a, b, t) return a + (b - a) * t end
function ClampedPercentageBetween(v, lo, hi)
    if hi <= lo then return 0 end
    return Saturate((v - lo) / (hi - lo))
end
function FormatPercentage(p, round) return ("%d%%"):format(Round(p * 100)) end
function GenerateClosure(fn, ...)
    local n = select("#", ...)
    local bound = { ... }
    return function(...)
        local args = { unpack(bound, 1, n) }
        local m = select("#", ...)
        for i = 1, m do args[n + i] = select(i, ...) end
        return fn(unpack(args, 1, n + m))
    end
end
function nop() end
