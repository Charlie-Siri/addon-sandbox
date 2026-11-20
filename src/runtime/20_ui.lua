-- UI: font objects, colors, money text, UIParent, stand-ins for Blizzard's shared templates, GameTooltip,
-- chat frames and slash commands, popups, dropdowns, pools, EventRegistry.
-- Stand-in templates look like WoW's (CSS styles in the renderer) without Blizzard art.
local S = SANDBOX
local host = S.host
local W, State = S.W, S.State

---------------------------------------------------------------------------
-- Fonts
---------------------------------------------------------------------------
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
UNIT_NAME_FONT = "Fonts\\FRIZQT__.TTF"
DAMAGE_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
NAMEPLATE_FONT = "Fonts\\FRIZQT__.TTF"
local FRIZ, ARIALN, MORPH = "Fonts\\FRIZQT__.TTF", "Fonts\\ARIALN.TTF", "Fonts\\MORPHEUS.TTF"
local GOLD, WHITE, GREY = { 1, 0.82, 0 }, { 1, 1, 1 }, { 0.5, 0.5, 0.5 }

local FONTS = {
    -- name, file, size, flags, color, justifyH
    { "GameFontNormal", FRIZ, 12, "", GOLD }, { "GameFontHighlight", FRIZ, 12, "", WHITE },
    { "GameFontDisable", FRIZ, 12, "", GREY }, { "GameFontGreen", FRIZ, 12, "", { 0.1, 1, 0.1 } },
    { "GameFontRed", FRIZ, 12, "", { 1, 0.1, 0.1 } }, { "GameFontWhite", FRIZ, 12, "", WHITE },
    { "GameFontBlack", FRIZ, 12, "", { 0, 0, 0 } }, { "GameFontNormalSmall", FRIZ, 10, "", GOLD },
    { "GameFontHighlightSmall", FRIZ, 10, "", WHITE }, { "GameFontDisableSmall", FRIZ, 10, "", GREY },
    { "GameFontRedSmall", FRIZ, 10, "", { 1, 0.1, 0.1 } }, { "GameFontGreenSmall", FRIZ, 10, "", { 0.1, 1, 0.1 } },
    { "GameFontWhiteSmall", FRIZ, 10, "", WHITE }, { "GameFontBlackSmall", FRIZ, 10, "", { 0, 0, 0 } },
    { "GameFontNormalSmall2", FRIZ, 11, "", GOLD }, { "GameFontHighlightSmall2", FRIZ, 11, "", WHITE },
    { "GameFontNormalMed1", FRIZ, 13, "", GOLD }, { "GameFontHighlightMed1", FRIZ, 13, "", WHITE },
    { "GameFontNormalMed2", FRIZ, 14, "", GOLD }, { "GameFontHighlightMed2", FRIZ, 14, "", WHITE },
    { "GameFontNormalMed3", FRIZ, 15, "", GOLD }, { "GameFontHighlightMedium", FRIZ, 14, "", WHITE },
    { "GameFontNormalLarge", FRIZ, 16, "", GOLD }, { "GameFontHighlightLarge", FRIZ, 16, "", WHITE },
    { "GameFontDisableLarge", FRIZ, 16, "", GREY }, { "GameFontGreenLarge", FRIZ, 16, "", { 0.1, 1, 0.1 } },
    { "GameFontRedLarge", FRIZ, 16, "", { 1, 0.1, 0.1 } }, { "GameFontNormalLarge2", FRIZ, 18, "", GOLD },
    { "GameFontHighlightLarge2", FRIZ, 18, "", WHITE }, { "GameFontNormalHuge", FRIZ, 20, "", GOLD },
    { "GameFontHighlightHuge", FRIZ, 20, "", WHITE }, { "GameFontNormalHuge2", FRIZ, 24, "", GOLD },
    { "GameFontNormalOutline", FRIZ, 12, "OUTLINE", GOLD }, { "GameFontHighlightOutline", FRIZ, 12, "OUTLINE", WHITE },
    { "GameFontNormalLeft", FRIZ, 12, "", GOLD, "LEFT" }, { "GameFontHighlightLeft", FRIZ, 12, "", WHITE, "LEFT" },
    { "GameFontDisableLeft", FRIZ, 12, "", GREY, "LEFT" }, { "GameFontNormalCenter", FRIZ, 12, "", GOLD, "CENTER" },
    { "GameFontHighlightCenter", FRIZ, 12, "", WHITE, "CENTER" }, { "GameFontNormalRight", FRIZ, 12, "", GOLD, "RIGHT" },
    { "GameFontHighlightRight", FRIZ, 12, "", WHITE, "RIGHT" }, { "GameFontNormalSmallLeft", FRIZ, 10, "", GOLD, "LEFT" },
    { "GameFontHighlightSmallLeft", FRIZ, 10, "", WHITE, "LEFT" }, { "GameFontDisableSmallLeft", FRIZ, 10, "", GREY, "LEFT" },
    { "GameFontHighlightSmallRight", FRIZ, 10, "", WHITE, "RIGHT" }, { "GameFontNormalLeftGreen", FRIZ, 12, "", { 0.1, 1, 0.1 }, "LEFT" },
    { "GameFontNormalLeftRed", FRIZ, 12, "", { 1, 0.1, 0.1 }, "LEFT" }, { "GameFontNormalLeftGrey", FRIZ, 12, "", GREY, "LEFT" },
    { "GameFontHighlightSmallOutline", FRIZ, 10, "OUTLINE", WHITE }, { "GameFontNormalSmallOutline", FRIZ, 10, "OUTLINE", GOLD },
    { "GameFontHighlightLargeOutline", FRIZ, 16, "OUTLINE", WHITE }, { "GameFontNormalLargeOutline", FRIZ, 16, "OUTLINE", GOLD },
    { "NumberFontNormal", ARIALN, 14, "OUTLINE", WHITE }, { "NumberFontNormalSmall", ARIALN, 12, "OUTLINE", WHITE },
    { "NumberFontNormalLarge", ARIALN, 16, "OUTLINE", WHITE }, { "NumberFontNormalHuge", ARIALN, 30, "OUTLINE", WHITE },
    { "NumberFontNormalYellow", ARIALN, 14, "OUTLINE", { 1, 1, 0 } }, { "NumberFontNormalSmallGray", ARIALN, 12, "OUTLINE", GREY },
    { "NumberFontNormalRight", ARIALN, 14, "OUTLINE", WHITE, "RIGHT" }, { "NumberFont_Outline_Med", ARIALN, 13, "OUTLINE", WHITE },
    { "NumberFont_Outline_Large", ARIALN, 16, "OUTLINE", WHITE }, { "NumberFont_Shadow_Small", ARIALN, 12, "", WHITE },
    { "NumberFont_Shadow_Med", ARIALN, 14, "", WHITE },
    { "ChatFontNormal", ARIALN, 14, "", WHITE }, { "ChatFontSmall", ARIALN, 12, "", WHITE },
    { "GameTooltipText", FRIZ, 12, "", WHITE }, { "GameTooltipTextSmall", FRIZ, 10, "", WHITE },
    { "GameTooltipHeaderText", FRIZ, 14, "", WHITE },
    { "SystemFont_Tiny", FRIZ, 9, "", WHITE }, { "SystemFont_Small", FRIZ, 10, "", WHITE },
    { "SystemFont_Med1", FRIZ, 12, "", WHITE }, { "SystemFont_Med2", FRIZ, 13, "", WHITE },
    { "SystemFont_Med3", FRIZ, 14, "", WHITE }, { "SystemFont_Large", FRIZ, 16, "", WHITE },
    { "SystemFont_Huge1", FRIZ, 20, "", WHITE }, { "SystemFont_Outline_Small", FRIZ, 10, "OUTLINE", WHITE },
    { "SystemFont_Outline", FRIZ, 13, "OUTLINE", WHITE }, { "SystemFont_Shadow_Small", FRIZ, 10, "", WHITE },
    { "SystemFont_Shadow_Med1", FRIZ, 12, "", WHITE }, { "SystemFont_Shadow_Med2", FRIZ, 14, "", WHITE },
    { "SystemFont_Shadow_Med3", FRIZ, 15, "", WHITE }, { "SystemFont_Shadow_Large", FRIZ, 16, "", WHITE },
    { "SystemFont_Shadow_Huge1", FRIZ, 20, "", WHITE },
    { "QuestFont", FRIZ, 13, "", { 0.18, 0.12, 0.06 } }, { "QuestTitleFont", FRIZ, 18, "", { 0.18, 0.12, 0.06 } },
    { "QuestFontNormalSmall", FRIZ, 12, "", { 0.18, 0.12, 0.06 } },
    { "Fancy16Font", MORPH, 16, "", WHITE }, { "Fancy22Font", MORPH, 22, "", WHITE }, { "Fancy24Font", MORPH, 24, "", WHITE },
    { "DialogButtonNormalText", FRIZ, 12, "", GOLD }, { "DialogButtonHighlightText", FRIZ, 12, "", WHITE },
    { "ObjectiveFont", FRIZ, 12, "", WHITE }, { "ErrorFont", FRIZ, 16, "", { 1, 0.1, 0.1 } },
    { "SubZoneTextFont", FRIZ, 26, "OUTLINE", GOLD }, { "ZoneTextFont", FRIZ, 32, "OUTLINE", GOLD },
    { "AchievementPointsFont", FRIZ, 13, "", WHITE }, { "FriendsFont_Normal", FRIZ, 12, "", WHITE },
    { "FriendsFont_Small", FRIZ, 10, "", WHITE }, { "FriendsFont_Large", FRIZ, 14, "", WHITE },
}
for size = 9, 72 do
    if size <= 24 or size % 2 == 0 then FONTS[#FONTS + 1] = { ("Game%dFont"):format(size), FRIZ, size, "", WHITE } end
end
for _, f in ipairs(FONTS) do
    local font = S.NewFont(f[1])
    local s = W[font]
    s.file, s.size, s.flags = f[2], f[3], f[4]
    s.color = { f[5][1], f[5][2], f[5][3], 1 }
    s.justifyH = f[6] or "CENTER"
    s.shadow = { 0, 0, 0, 1 }
    s.shadowOffset = { 1, -1 }
end

---------------------------------------------------------------------------
-- Colors
---------------------------------------------------------------------------
ColorMixin = {}
function ColorMixin:OnLoad(r, g, b, a) self:SetRGBA(r, g, b, a) end
function ColorMixin:SetRGBA(r, g, b, a) self.r, self.g, self.b, self.a = r, g, b, a end
function ColorMixin:SetRGB(r, g, b) self:SetRGBA(r, g, b, nil) end
function ColorMixin:GetRGB() return self.r, self.g, self.b end
function ColorMixin:GetRGBA() return self.r, self.g, self.b, self.a or 1 end
function ColorMixin:GetRGBAsBytes() return self.r * 255, self.g * 255, self.b * 255 end
function ColorMixin:IsEqualTo(o) return self.r == o.r and self.g == o.g and self.b == o.b and (self.a or 1) == (o.a or 1) end
function ColorMixin:GenerateHexColor()
    return ("ff%02x%02x%02x"):format(Round(self.r * 255), Round(self.g * 255), Round(self.b * 255))
end
function ColorMixin:GenerateHexColorNoAlpha() return self:GenerateHexColor():sub(3) end
function ColorMixin:GenerateHexColorMarkup() return "|c" .. self:GenerateHexColor() end
function ColorMixin:WrapTextInColorCode(text) return WrapTextInColorCode(text, self:GenerateHexColor()) end
function CreateColor(r, g, b, a)
    local c = CreateFromMixins(ColorMixin)
    c:OnLoad(r, g, b, a)
    return c
end
function CreateColorFromHexString(hex)
    local a, r, g, b = hex:match("(%x%x)(%x%x)(%x%x)(%x%x)")
    return CreateColor(tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255, tonumber(a, 16) / 255)
end
function WrapTextInColorCode(text, hex) return ("|c%s%s|r"):format(hex, text) end
function WrapTextInColor(text, color) return color:WrapTextInColorCode(text) end

NORMAL_FONT_COLOR = CreateColor(1, 0.82, 0)
HIGHLIGHT_FONT_COLOR = CreateColor(1, 1, 1)
RED_FONT_COLOR = CreateColor(1, 0.125, 0.125)
DIM_RED_FONT_COLOR = CreateColor(0.8, 0.1, 0.1)
GREEN_FONT_COLOR = CreateColor(0.125, 1, 0.125)
GRAY_FONT_COLOR = CreateColor(0.5, 0.5, 0.5)
DISABLED_FONT_COLOR = CreateColor(0.5, 0.5, 0.5)
YELLOW_FONT_COLOR = CreateColor(1, 1, 0)
LIGHTYELLOW_FONT_COLOR = CreateColor(1, 1, 0.6)
ORANGE_FONT_COLOR = CreateColor(1, 0.5, 0.25)
WHITE_FONT_COLOR = CreateColor(1, 1, 1)
BLACK_FONT_COLOR = CreateColor(0, 0, 0)
LIGHTBLUE_FONT_COLOR = CreateColor(0.53, 0.67, 1)
BLUE_FONT_COLOR = CreateColor(0, 0.749, 0.953)
EPIC_PURPLE_COLOR = CreateColor(0.64, 0.21, 0.93)
PASSIVE_SPELL_FONT_COLOR = CreateColor(0.77, 0.64, 0)
TRANSMOGRIFY_FONT_COLOR = CreateColor(1, 0.5, 1)
NORMAL_FONT_COLOR_CODE = "|cffffd200"
HIGHLIGHT_FONT_COLOR_CODE = "|cffffffff"
RED_FONT_COLOR_CODE = "|cffff2020"
GREEN_FONT_COLOR_CODE = "|cff20ff20"
GRAY_FONT_COLOR_CODE = "|cff808080"
YELLOW_FONT_COLOR_CODE = "|cffffff00"
ORANGE_FONT_COLOR_CODE = "|cffff7f3f"
LIGHTYELLOW_FONT_COLOR_CODE = "|cffffff9a"
FONT_COLOR_CODE_CLOSE = "|r"

local QUALITY_HEX = { [0] = "9d9d9d", "ffffff", "1eff00", "0070dd", "a335ee", "ff8000", "e6cc80", "00ccff", "00ccff" }
ITEM_QUALITY_COLORS = {}
for q, hex in pairs(QUALITY_HEX) do
    local r, g, b = tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
    ITEM_QUALITY_COLORS[q] = { r = r, g = g, b = b, hex = "|cff" .. hex, color = CreateColor(r, g, b) }
end
function GetItemQualityColor(q)
    local c = ITEM_QUALITY_COLORS[q] or ITEM_QUALITY_COLORS[1]
    return c.r, c.g, c.b, c.hex:sub(3)
end
local CLASS_HEX = { WARRIOR = "c69b6d", PALADIN = "f48cba", HUNTER = "aad372", ROGUE = "fff468", PRIEST = "ffffff",
    DEATHKNIGHT = "c41e3a", SHAMAN = "0070dd", MAGE = "3fc7eb", WARLOCK = "8788ee", MONK = "00ff98", DRUID = "ff7c0a",
    DEMONHUNTER = "a330c9", EVOKER = "33937f" }
RAID_CLASS_COLORS = {}
for class, hex in pairs(CLASS_HEX) do
    local c = CreateColor(tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255)
    c.colorStr = "ff" .. hex
    RAID_CLASS_COLORS[class] = c
end
function GetClassColor(class)
    local c = RAID_CLASS_COLORS[class] or RAID_CLASS_COLORS.PRIEST
    return c.r, c.g, c.b, c.colorStr
end
function GetClassColorObj(class) return RAID_CLASS_COLORS[class] end

---------------------------------------------------------------------------
-- Money and time text
---------------------------------------------------------------------------
COPPER_PER_SILVER, SILVER_PER_GOLD, COPPER_PER_GOLD = 100, 100, 10000
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

function BreakUpLargeNumbers(n)
    local s = tostring(math.floor(n))
    local neg = s:sub(1, 1) == "-"
    if neg then s = s:sub(2) end
    s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (neg and "-" or "") .. s
end
FormatLargeNumber = BreakUpLargeNumbers

function GetMoneyString(money, separateThousands)
    money = math.floor(tonumber(money) or 0)
    local gold = math.floor(money / COPPER_PER_GOLD)
    local silver = math.floor(money / COPPER_PER_SILVER) % SILVER_PER_GOLD
    local copper = money % COPPER_PER_SILVER
    local goldText = separateThousands and BreakUpLargeNumbers(gold) or tostring(gold)
    local parts = {}
    if gold > 0 then parts[#parts + 1] = goldText .. GOLD_ICON end
    if silver > 0 then parts[#parts + 1] = silver .. SILVER_ICON end
    if copper > 0 or #parts == 0 then parts[#parts + 1] = copper .. COPPER_ICON end
    return table.concat(parts, " ")
end
GetCoinTextureString = GetMoneyString
function GetCoinText(money, separator)
    money = math.floor(tonumber(money) or 0)
    local gold, silver, copper = math.floor(money / 10000), math.floor(money / 100) % 100, money % 100
    local parts = {}
    if gold > 0 then parts[#parts + 1] = gold .. " Gold" end
    if silver > 0 then parts[#parts + 1] = silver .. " Silver" end
    if copper > 0 or #parts == 0 then parts[#parts + 1] = copper .. " Copper" end
    return table.concat(parts, separator or ", ")
end

local TIME_UNITS = {
    { 86400, "Day", "Days", "Day" }, { 3600, "Hour", "Hours", "Hr" }, { 60, "Minute", "Minutes", "Min" },
    { 1, "Second", "Seconds", "Sec" },
}
function SecondsToTime(seconds, noSeconds, notAbbreviated, maxCount, roundUp)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    maxCount = maxCount or 2
    local parts = {}
    for i, unit in ipairs(TIME_UNITS) do
        if #parts >= maxCount then break end
        if not (noSeconds and i == 4) then
            local n = math.floor(seconds / unit[1])
            if n > 0 then
                seconds = seconds - n * unit[1]
                if notAbbreviated then parts[#parts + 1] = n .. " " .. (n == 1 and unit[2] or unit[3])
                else parts[#parts + 1] = n .. " " .. unit[4] end
            end
        end
    end
    if #parts == 0 then return noSeconds and "0 Min" or "0 Sec" end
    return table.concat(parts, " ")
end
function SecondsToClock(seconds, displayZeroHours)
    seconds = math.max(0, math.floor(seconds))
    local h, m, s = math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60
    if h > 0 or displayZeroHours then return ("%d:%02d:%02d"):format(h, m, s) end
    return ("%02d:%02d"):format(m, s)
end

---------------------------------------------------------------------------
-- Screen roots
---------------------------------------------------------------------------
local function Screen(name)
    local f, s = S.CreateFrameRaw("Frame", name)
    s.isScreen, s.level, s.strata = true, 0, "MEDIUM"
    s.points = { { point = "TOPLEFT", relPoint = "TOPLEFT", x = 0, y = 0 } }
    return f
end
WorldFrame = Screen("WorldFrame")
W[WorldFrame].strata = "WORLD"
UIParent = Screen("UIParent")
function GetScreenWidth() return S.screenW end
function GetScreenHeight() return S.screenH end
function GetPhysicalScreenSize() return S.pixelW or S.screenW, S.pixelH or S.screenH end
function GetScreenDPIScale() return 1 end
UISpecialFrames, UIPanelWindows, UIMenus = {}, {}, {}

function S.SetScreen(w, h, pw, ph)
    S.screenW, S.screenH, S.pixelW, S.pixelH = w, h, pw, ph
    S.Changed()
end

-- Esc: hide special frames (and stand-in Blizzard panels). True if anything closed.
S.panels = {}
function CloseSpecialWindows()
    local found = false
    for _, name in ipairs(UISpecialFrames) do
        local f = _G[name]
        if f and W[f] and f:IsShown() then f:Hide(); found = true end
    end
    for _, panel in ipairs(S.panels) do
        if panel.frame:IsShown() then panel.close(); found = true end
    end
    if CloseDropDownMenus then CloseDropDownMenus() end
    return found
end
function ShowUIPanel(frame) if frame then frame:Show() end end
function HideUIPanel(frame) if frame then frame:Hide() end end
function CloseAllWindows() return CloseSpecialWindows() end

---------------------------------------------------------------------------
-- Template helpers
---------------------------------------------------------------------------
local function Template(name, fn, aliases)
    S.RegisterTemplate(name, fn)
    for _, alias in ipairs(aliases or {}) do S.RegisterTemplate(alias, fn) end
end

local function Style(f, style) W[f].style = style end
S.Style = Style

local function Child(parent, key, frameType, template, name)
    local pname = W[parent].name
    local child = CreateFrame(frameType, name and pname and (pname .. name) or nil, parent, template)
    if key then parent[key] = child; W[child].parentKey = key end
    return child
end

local function Label(parent, key, font, layer)
    local fs = parent:CreateFontString(W[parent].name and (W[parent].name .. key) or nil, layer or "OVERLAY", font)
    parent[key] = fs
    W[fs].parentKey = key
    return fs
end

-- Buttons -----------------------------------------------------------------
local function PanelButton(f)
    Style(f, "button")
    if not W[f].width then f:SetSize(80, 22) end
    f:SetNormalFontObject(GameFontNormal)
    f:SetHighlightFontObject(GameFontHighlight)
    f:SetDisabledFontObject(GameFontDisable)
    f:SetPushedTextOffset(1, -1)
    f:SetText("")
    f.Text = f:GetFontString()
    W[f.Text].parentKey = "Text"
    if f.Text then W[f.Text].wordWrap = false end
end
Template("UIPanelButtonTemplate", PanelButton, { "UIPanelButtonNoTooltipTemplate", "UIPanelDynamicResizeButtonTemplate",
    "GameMenuButtonTemplate", "UIMenuButtonStretchTemplate", "UIPanelButtonGrayTemplate", "SharedButtonTemplate",
    "SharedButtonSmallTemplate", "SharedGoldRedButtonTemplate", "MagicButtonTemplate", "UIPanelSquareButton",
    "BigRedRefreshButtonTemplate", "RefreshButtonTemplate", "StaticPopupButtonTemplate" })
function DynamicResizeButton_Resize(button)
    local w = button:GetTextWidth() + 40
    button:SetWidth(math.max(w, button.minWidth or 0))
end

local function CloseButton(f)
    Style(f, "close")
    if not W[f].width then f:SetSize(24, 24) end
    f:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        if parent then HideUIPanel(parent) end
    end)
end
Template("UIPanelCloseButton", CloseButton, { "UIPanelCloseButtonNoScripts", "UIPanelCloseButtonDefaultAnchors" })

local function TabButton(f)
    Style(f, "tab")
    if not W[f].width then f:SetSize(90, 24) end
    f:SetNormalFontObject(GameFontNormalSmall)
    f:SetHighlightFontObject(GameFontHighlightSmall)
    f:SetDisabledFontObject(GameFontHighlightSmall)
    f:SetText("")
    f.Text = f:GetFontString()
end
Template("TabButtonTemplate", TabButton, { "PanelTabButtonTemplate", "CharacterFrameTabButtonTemplate",
    "PanelTopTabButtonTemplate", "TabSystemButtonTemplate", "MinimalTabTemplate" })

function PanelTemplates_SetNumTabs(frame, n) frame.numTabs = n end
function PanelTemplates_TabResize(tab, padding, absoluteSize, minWidth, maxWidth)
    local w = absoluteSize or (tab:GetTextWidth() + (padding or 0) + 24)
    if minWidth then w = math.max(w, minWidth) end
    if maxWidth then w = math.min(w, maxWidth) end
    tab:SetWidth(w)
end
function PanelTemplates_SelectTab(tab) tab:Disable(); tab:LockHighlight() end
function PanelTemplates_DeselectTab(tab) tab:Enable(); tab:UnlockHighlight() end
function PanelTemplates_UpdateTabs(frame)
    for i = 1, frame.numTabs or 0 do
        local tab = frame.Tabs and frame.Tabs[i] or _G[(frame:GetName() or "") .. "Tab" .. i]
        if tab then
            if i == frame.selectedTab then PanelTemplates_SelectTab(tab) else PanelTemplates_DeselectTab(tab) end
        end
    end
end
function PanelTemplates_SetTab(frame, id) frame.selectedTab = id; PanelTemplates_UpdateTabs(frame) end
function PanelTemplates_GetSelectedTab(frame) return frame.selectedTab end
function PanelTemplates_EnableTab(frame, i) end
function PanelTemplates_DisableTab(frame, i) end
function PanelTemplates_ResizeTabsToFit() end

-- Item slot buttons
local function ItemButton(f)
    Style(f, "slot")
    if not W[f].width then f:SetSize(37, 37) end
    local icon = f:CreateTexture(W[f].name and (W[f].name .. "IconTexture") or nil, "BORDER")
    icon:SetAllPoints()
    f.icon, f.Icon = icon, icon
    local count = f:CreateFontString(W[f].name and (W[f].name .. "Count") or nil, "OVERLAY", "NumberFontNormal")
    count:SetPoint("BOTTOMRIGHT", -3, 2)
    count:SetJustifyH("RIGHT")
    count:Hide()
    f.Count = count
    f.IconBorder = f:CreateTexture(nil, "OVERLAY")
    f.IconBorder:SetAllPoints()
    f.IconBorder:Hide()
    f:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
end
Template("ItemButtonTemplate", ItemButton, { "ActionButtonTemplate", "LargeItemButtonTemplate", "SmallItemButtonTemplate",
    "ContainerFrameItemButtonTemplate", "LootButtonTemplate", "MerchantItemButtonTemplate" })
function SetItemButtonTexture(button, texture) if button.icon then button.icon:SetTexture(texture) end end
function SetItemButtonCount(button, count)
    if not button.Count then return end
    count = tonumber(count) or 0
    if count > 1 then button.Count:SetText(count); button.Count:Show() else button.Count:Hide() end
    button.count = count
end
function SetItemButtonQuality(button, quality)
    if not button.IconBorder then return end
    local c = quality and quality > 1 and ITEM_QUALITY_COLORS[quality]
    if c then
        button.IconBorder:SetColorTexture(0, 0, 0, 0)
        W[button].qualityColor = c
        button.IconBorder:Show()
    else
        button.IconBorder:Hide()
    end
end
function SetItemButtonDesaturated(button, on) if button.icon then button.icon:SetDesaturated(on) end end
function SetItemButtonTextureVertexColor(button, r, g, b) if button.icon then button.icon:SetVertexColor(r, g, b) end end
function SetItemButtonNormalTextureVertexColor() end

-- Check buttons -------------------------------------------------------------
local function CheckButtonT(f)
    Style(f, "check")
    if not W[f].width then f:SetSize(32, 32) end
    local text = f:CreateFontString(W[f].name and (W[f].name .. "Text") or nil, "ARTWORK", "GameFontNormalSmall")
    text:SetPoint("LEFT", f, "RIGHT", -2, 0)
    f.Text, f.text = text, text
    f:SetHitRectInsets(0, -100, 0, 0)
end
Template("UICheckButtonTemplate", CheckButtonT, { "ChatConfigCheckButtonTemplate", "InterfaceOptionsCheckButtonTemplate",
    "OptionsBaseCheckButtonTemplate", "OptionsCheckButtonTemplate", "SettingsCheckBoxTemplate", "UIRadioButtonTemplate",
    "MinimalCheckboxTemplate", "UICheckButtonArtTemplate" })

-- Frames --------------------------------------------------------------------
local function BasicFrame(f, inset)
    Style(f, "panel-titled")
    f.TitleBg = f:CreateTexture(nil, "BACKGROUND")
    f.TitleBg:SetPoint("TOPLEFT", 2, -2)
    f.TitleBg:SetPoint("TOPRIGHT", -2, -2)
    f.TitleBg:SetHeight(20)
    local close = Child(f, "CloseButton", "Button", "UIPanelCloseButton", "CloseButton")
    close:SetPoint("TOPRIGHT", 2, 1)
    if inset then
        local bg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
        bg:SetPoint("TOPLEFT", 4, -24)
        bg:SetPoint("BOTTOMRIGHT", -6, 4)
        bg:SetColorTexture(0, 0, 0, 0.35)
        f.InsetBg = bg
    end
end
Template("BasicFrameTemplate", function(f) BasicFrame(f, false) end)
Template("BasicFrameTemplateWithInset", function(f) BasicFrame(f, true) end)

local function SetTitle(self, title)
    local tt = self.TitleText or (self.TitleContainer and self.TitleContainer.TitleText)
    if tt then tt:SetText(title) end
end

local function PortraitFrame(f, withInset)
    Style(f, "panel-titled")
    local container = Child(f, "TitleContainer", "Frame")
    container:SetPoint("TOPLEFT", 58, -1)
    container:SetPoint("TOPRIGHT", -24, -1)
    container:SetHeight(20)
    local title = Label(container, "TitleText", "GameFontNormal")
    title:SetPoint("TOP", 0, -5)
    title:SetPoint("LEFT", 0, 0)
    title:SetPoint("RIGHT", 0, 0)
    W[title].wordWrap = false
    f.TitleText = title
    local close = Child(f, "CloseButton", "Button", "UIPanelCloseButton", "CloseButton")
    close:SetPoint("TOPRIGHT", 2, 1)
    f.PortraitContainer = Child(f, "PortraitContainer", "Frame")
    f.PortraitContainer:SetSize(1, 1)
    f.PortraitContainer:SetPoint("TOPLEFT")
    f.PortraitContainer.portrait = f.PortraitContainer:CreateTexture()
    f.portrait = f.PortraitContainer.portrait
    f.Bg = f:CreateTexture(nil, "BACKGROUND")
    if withInset then
        local inset = Child(f, "Inset", "Frame", "InsetFrameTemplate", "Inset")
        inset:SetPoint("TOPLEFT", 4, -60)
        inset:SetPoint("BOTTOMRIGHT", -6, 26)
    end
    f.SetTitle = SetTitle
    f.SetTitleFormatted = function(self, fmt, ...) SetTitle(self, fmt:format(...)) end
    f.SetPortraitToAsset = function() end
    f.SetPortraitToUnit = function() end
    f.SetPortraitTextureRaw = function() end
    f.SetPortraitAtlasRaw = function() end
    f.SetPortraitShown = function() end
    f.SetBorder = function() end
    f.GetTitleText = function(self) return self.TitleText end
end
Template("PortraitFrameTemplate", function(f) PortraitFrame(f, false) end, { "PortraitFrameTemplateMinimizable",
    "DefaultPanelTemplate", "DefaultPanelFlatTemplate", "DefaultPanelBaseTemplate", "SettingsFrameTemplate" })
Template("ButtonFrameTemplate", function(f) PortraitFrame(f, true) end, { "ButtonFrameTemplateMinimizable" })
function ButtonFrameTemplate_HidePortrait() end
function ButtonFrameTemplate_ShowPortrait() end
function ButtonFrameTemplate_HideAttic() end
function ButtonFrameTemplate_HideButtonBar(f) if f.Inset then f.Inset:SetPoint("BOTTOMRIGHT", -6, 4) end end
function ButtonFrameTemplate_ShowButtonBar() end

Template("InsetFrameTemplate", function(f) Style(f, "inset") end, { "InsetFrameTemplate2", "InsetFrameTemplate3",
    "InsetFrameTemplate4", "NineSliceCodeTemplate", "ThinBorderTemplate", "CommonInsetFrameTemplate" })
Template("TooltipBackdropTemplate", function(f) Style(f, "tooltip") end, { "TooltipBorderedFrameTemplate",
    "TooltipBorderBackdropTemplate", "GlowBoxTemplate", "DialogBorderTemplate", "DialogBorderDarkTemplate",
    "DialogBorderTranslucentTemplate", "DialogBorderOpaqueTemplate", "SimplePanelTemplate", "TranslucentFrameTemplate" })

-- Backdrop ----------------------------------------------------------------
BackdropTemplateMixin = {}
function BackdropTemplateMixin:SetBackdrop(info)
    local s = State(self)
    s.backdrop = info
    if info then
        s.backdropColor = s.backdropColor or { 1, 1, 1, 1 }
        s.backdropBorderColor = s.backdropBorderColor or { 1, 1, 1, 1 }
    end
    S.Repaint()
end
function BackdropTemplateMixin:GetBackdrop() return State(self).backdrop end
function BackdropTemplateMixin:SetBackdropColor(r, g, b, a) State(self).backdropColor = { r or 1, g or 1, b or 1, a or 1 }; S.Repaint() end
function BackdropTemplateMixin:GetBackdropColor() local c = State(self).backdropColor or { 1, 1, 1, 1 } return c[1], c[2], c[3], c[4] end
function BackdropTemplateMixin:SetBackdropBorderColor(r, g, b, a) State(self).backdropBorderColor = { r or 1, g or 1, b or 1, a or 1 }; S.Repaint() end
function BackdropTemplateMixin:GetBackdropBorderColor() local c = State(self).backdropBorderColor or { 1, 1, 1, 1 } return c[1], c[2], c[3], c[4] end
function BackdropTemplateMixin:ApplyBackdrop() end
function BackdropTemplateMixin:ClearBackdrop() State(self).backdrop = nil; S.Repaint() end
function BackdropTemplateMixin:OnBackdropLoaded()
    if self.backdropInfo then self:SetBackdrop(self.backdropInfo) end
    if self.backdropColor then self:SetBackdropColor(self.backdropColor:GetRGB()) end
    if self.backdropBorderColor then self:SetBackdropBorderColor(self.backdropBorderColor:GetRGB()) end
end
function BackdropTemplateMixin:OnBackdropSizeChanged() end
function BackdropTemplateMixin:HasBackdropInfo() return State(self).backdrop ~= nil end
function BackdropTemplateMixin:SetupTextureCoordinates() end
function BackdropTemplateMixin:SetBorderBlendMode() end
Template("BackdropTemplate", function(f)
    Mixin(f, BackdropTemplateMixin)
    if f.backdropInfo then f:OnBackdropLoaded() end
end)
BACKDROP_TOOLTIP_16_16_5555 = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileEdge = true, tileSize = 16, edgeSize = 16, insets = { left = 5, right = 5, top = 5, bottom = 5 } }
BACKDROP_TOOLTIP_0_16 = { edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16 }
BACKDROP_DIALOG_32_32 = { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } }
BACKDROP_DARK_DIALOG_32_32 = { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } }
BACKDROP_GOLD_DIALOG_32_32 = { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } }
BACKDROP_TEXT_PANEL_0_16 = { edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16 }

-- Edit boxes ----------------------------------------------------------------
function EditBox_ClearFocus(self) self:ClearFocus() end
function EditBox_HighlightText(self) self:HighlightText() end
function EditBox_ClearHighlight(self) self:HighlightText(0, 0) end
local function InputBox(f)
    Style(f, "input")
    f:SetFontObject(ChatFontNormal)
    f:SetTextInsets(0, 0, 0, 0)
    f:SetScript("OnEscapePressed", EditBox_ClearFocus)
    f:SetScript("OnEditFocusGained", EditBox_HighlightText)
    f:SetScript("OnEditFocusLost", EditBox_ClearHighlight)
end
Template("InputBoxTemplate", InputBox, { "InputBoxInstructionsTemplate", "LargeInputBoxTemplate", "InputBoxScriptTemplate",
    "AutoCompleteEditBoxTemplate", "ChatFrameEditBoxTemplate" })
Template("SearchBoxTemplate", function(f)
    InputBox(f)
    f:SetTextInsets(16, 20, 0, 0)
    local hint = Label(f, "Instructions", "GameFontDisableSmall")
    hint:SetPoint("LEFT", 16, 0)
    hint:SetText(SEARCH or "Search")
    f:HookScript("OnTextChanged", function(self) self.Instructions:SetShown(self:GetText() == "") end)
end, { "BagSearchBoxTemplate" })
SEARCH = "Search"

-- Scroll frames -------------------------------------------------------------
local function ScrollStep(sf) return sf.ScrollBar and sf.ScrollBar.scrollStep or sf:GetHeight() / 2 end

function ScrollFrame_OnLoad(self)
    local bar = self.ScrollBar
    if bar then bar:SetMinMaxValues(0, 0); bar:SetValue(0) end
    self.offset = 0
end
function ScrollFrame_OnScrollRangeChanged(self, xrange, yrange)
    local bar = self.ScrollBar
    if not bar then return end
    yrange = yrange or self:GetVerticalScrollRange()
    local value = math.min(bar:GetValue(), yrange)
    bar:SetMinMaxValues(0, yrange)
    bar:SetValue(value)
    if bar.ScrollUpButton then bar.ScrollUpButton:SetEnabled(value > 0) end
    if bar.ScrollDownButton then bar.ScrollDownButton:SetEnabled(value < yrange) end
    if self.scrollBarHideable then bar:SetShown(yrange > 0) end
end
function ScrollFrame_OnVerticalScroll(self, offset)
    local bar = self.ScrollBar
    if bar and bar:GetValue() ~= offset then bar:SetValue(offset) end
end
function ScrollFrameTemplate_OnMouseWheel(self, delta)
    local bar = self.ScrollBar
    if not bar then
        self:SetVerticalScroll(math.min(math.max(self:GetVerticalScroll() - delta * ScrollStep(self), 0), self:GetVerticalScrollRange()))
        return
    end
    bar:SetValue(bar:GetValue() - delta * ScrollStep(self))
end
UIPanelScrollFrame_OnLoad = ScrollFrame_OnLoad

local function ScrollFrameT(sf)
    local name = W[sf].name
    local bar = CreateFrame("Slider", name and (name .. "ScrollBar") or nil, sf)
    sf.ScrollBar = bar
    W[bar].parentKey = "ScrollBar"
    Style(bar, "scrollbar")
    bar:SetWidth(16)
    bar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 6, -16)
    bar:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 6, 16)
    bar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    bar:GetThumbTexture():SetSize(16, 24)
    bar:SetValueStep(1)
    bar:SetScript("OnValueChanged", function(self, value)
        sf:SetVerticalScroll(value)
        local lo, hi = self:GetMinMaxValues()
        if self.ScrollUpButton then self.ScrollUpButton:SetEnabled(value > lo) end
        if self.ScrollDownButton then self.ScrollDownButton:SetEnabled(value < hi) end
    end)
    local up = CreateFrame("Button", name and (name .. "ScrollBarScrollUpButton") or nil, bar)
    Style(up, "arrow-up")
    up:SetSize(16, 16)
    up:SetPoint("BOTTOM", bar, "TOP")
    up:SetScript("OnClick", function() bar:SetValue(bar:GetValue() - ScrollStep(sf)) end)
    bar.ScrollUpButton = up
    local down = CreateFrame("Button", name and (name .. "ScrollBarScrollDownButton") or nil, bar)
    Style(down, "arrow-down")
    down:SetSize(16, 16)
    down:SetPoint("TOP", bar, "BOTTOM")
    down:SetScript("OnClick", function() bar:SetValue(bar:GetValue() + ScrollStep(sf)) end)
    bar.ScrollDownButton = down
    sf:EnableMouseWheel(true)
    sf:SetScript("OnScrollRangeChanged", ScrollFrame_OnScrollRangeChanged)
    sf:SetScript("OnVerticalScroll", ScrollFrame_OnVerticalScroll)
    sf:SetScript("OnMouseWheel", ScrollFrameTemplate_OnMouseWheel)
    ScrollFrame_OnLoad(sf)
end
Template("UIPanelScrollFrameTemplate", ScrollFrameT, { "UIPanelScrollFrameTemplate2", "ScrollFrameTemplate",
    "UIPanelScrollFrameCodeTemplate", "InputScrollFrameTemplate", "MinimalScrollFrameTemplate" })

Template("FauxScrollFrameTemplate", function(sf)
    ScrollFrameT(sf)
    local child = CreateFrame("Frame", W[sf].name and (W[sf].name .. "ScrollChildFrame") or nil, sf)
    child:SetSize(300, 334)
    sf:SetScrollChild(child)
    sf.ScrollChildFrame = child
end)
function FauxScrollFrame_GetOffset(frame) return frame.offset or 0 end
function FauxScrollFrame_SetOffset(frame, offset) frame.offset = offset end
function FauxScrollFrame_OnVerticalScroll(self, value, itemHeight, updateFunction)
    local bar = self.ScrollBar
    if bar then bar:SetValue(value) end
    self.offset = math.floor(value / itemHeight + 0.5)
    if updateFunction then updateFunction(self) end
end
function FauxScrollFrame_Update(frame, numItems, numToDisplay, buttonHeight, button, smallWidth, bigWidth, highlightFrame, smallHighlightWidth, bigHighlightWidth, alwaysShowScrollBar)
    local bar = frame.ScrollBar
    local child = frame.ScrollChildFrame or frame:GetScrollChild()
    local showScrollBar = numItems > numToDisplay or alwaysShowScrollBar
    if child then child:SetHeight(numItems * buttonHeight) end
    if bar then
        local range = math.max(0, (numItems - numToDisplay) * buttonHeight)
        bar:SetMinMaxValues(0, range)
        bar:SetValueStep(buttonHeight)
        if showScrollBar then bar:Show() else bar:Hide(); frame.offset = 0 end
    end
    return showScrollBar
end

-- Sliders -------------------------------------------------------------------
local function SliderT(f)
    Style(f, "slider-h")
    f:SetOrientation("HORIZONTAL")
    if not W[f].width then f:SetSize(144, 17) end
    f:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    f:GetThumbTexture():SetSize(16, 16)
    local name = W[f].name
    local text = f:CreateFontString(name and (name .. "Text") or nil, "ARTWORK", "GameFontNormalSmall")
    text:SetPoint("BOTTOM", f, "TOP")
    local low = f:CreateFontString(name and (name .. "Low") or nil, "ARTWORK", "GameFontHighlightSmall")
    low:SetPoint("TOPLEFT", f, "BOTTOMLEFT", -4, 3)
    local high = f:CreateFontString(name and (name .. "High") or nil, "ARTWORK", "GameFontHighlightSmall")
    high:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 4, 3)
    f.Text, f.Low, f.High = text, low, high
end
Template("OptionsSliderTemplate", SliderT, { "UISliderTemplate", "HorizontalSliderTemplate", "MinimalSliderTemplate",
    "UISliderTemplateWithLabels", "OptionsSliderTemplateWithLabels" })

-- Plain-frame templates that only matter for their scripts in WoW.
for _, name in ipairs({ "SecureActionButtonTemplate", "SecureHandlerBaseTemplate", "SecureHandlerStateTemplate",
    "SecureHandlerClickTemplate", "SecureHandlerAttributeTemplate", "SecureFrameTemplate", "SecureUnitButtonTemplate",
    "SecureHandlerShowHideTemplate", "SecureHandlerEnterLeaveTemplate", "InsecureActionButtonTemplate",
    "ResizeLayoutFrame", "VerticalLayoutFrame", "HorizontalLayoutFrame", "GridLayoutFrame", "ManagedVerticalLayoutFrameTemplate",
    "EventFrame", "CallbackRegistrantTemplate", "DefaultScaleFrame", "PropagateMouseEventsTemplate", "UIParentLayoutTemplate" }) do
    Template(name, function() end)
end

---------------------------------------------------------------------------
-- GameTooltip
---------------------------------------------------------------------------
local Tooltip = S.Class("GameTooltip", "Frame")
local TT_PAD, TT_MAXW = 10, 280

local function TooltipInit(obj, s)
    s.style = "tooltip"
    s.strata = "TOOLTIP"
    s.shown = false
    s.lines = {}
    s.numLines = 0
    s.tooltipPadding = TT_PAD
    s.clamped = true
end
S.RegisterFrameType("GameTooltip", "GameTooltip", TooltipInit)

local function TooltipLine(self, s, i)
    local line = s.lines[i]
    if line then return line end
    local name = s.name
    local left = self:CreateFontString(name and (name .. "TextLeft" .. i) or nil, "ARTWORK", i == 1 and "GameTooltipHeaderText" or "GameTooltipText")
    local right = self:CreateFontString(name and (name .. "TextRight" .. i) or nil, "ARTWORK", i == 1 and "GameTooltipHeaderText" or "GameTooltipText")
    left:SetJustifyH("LEFT")
    right:SetJustifyH("RIGHT")
    line = { left = left, right = right }
    s.lines[i] = line
    return line
end

local function Layout(self, s)
    local width = s.minWidth or 0
    for i = 1, s.numLines do
        local line = s.lines[i]
        local lw = line.left:GetStringWidth()
        if line.wrap then lw = math.min(lw, TT_MAXW) end
        local rw = line.right:IsShown() and line.right:GetStringWidth() or 0
        width = math.max(width, lw + (rw > 0 and rw + 20 or 0))
    end
    width = math.min(math.max(width, 10), TT_MAXW + 40)
    local y = -TT_PAD
    for i = 1, s.numLines do
        local line = s.lines[i]
        line.left:ClearAllPoints()
        line.left:SetPoint("TOPLEFT", self, "TOPLEFT", TT_PAD, y)
        if line.wrap then line.left:SetWidth(width) else line.left:SetWidth(0); W[line.left].width = nil end
        line.right:ClearAllPoints()
        line.right:SetPoint("TOPRIGHT", self, "TOPRIGHT", -TT_PAD, y)
        local h = math.max(line.left:GetStringHeight(), line.right:IsShown() and line.right:GetStringHeight() or 0)
        y = y - h - 2
    end
    S.Region.SetSize(self, width + TT_PAD * 2, -y + TT_PAD - 2)
end

function Tooltip:SetOwner(owner, anchor, x, y)
    local s = State(self)
    self:ClearLines()
    s.owner, s.anchor = owner, anchor or "ANCHOR_LEFT"
    s.ox, s.oy = x or 0, y or 0
    self:ClearAllPoints()
    if owner then self:SetParent(UIParent) end
    local a = s.anchor
    if not owner or a == "ANCHOR_NONE" or a == "ANCHOR_PRESERVE" then return end
    if a == "ANCHOR_CURSOR" or a == "ANCHOR_CURSOR_RIGHT" or a == "ANCHOR_CURSOR_LEFT" then
        local cx, cy = GetCursorPosition()
        self:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", cx + 16 + s.ox, cy + s.oy)
    elseif a == "ANCHOR_RIGHT" then self:SetPoint("BOTTOMLEFT", owner, "TOPRIGHT", s.ox, s.oy)
    elseif a == "ANCHOR_LEFT" then self:SetPoint("BOTTOMRIGHT", owner, "TOPLEFT", s.ox, s.oy)
    elseif a == "ANCHOR_TOP" then self:SetPoint("BOTTOM", owner, "TOP", s.ox, s.oy)
    elseif a == "ANCHOR_BOTTOM" then self:SetPoint("TOP", owner, "BOTTOM", s.ox, s.oy)
    elseif a == "ANCHOR_TOPLEFT" then self:SetPoint("BOTTOMLEFT", owner, "TOPLEFT", s.ox, s.oy)
    elseif a == "ANCHOR_TOPRIGHT" then self:SetPoint("BOTTOMRIGHT", owner, "TOPRIGHT", s.ox, s.oy)
    elseif a == "ANCHOR_BOTTOMLEFT" then self:SetPoint("TOPRIGHT", owner, "BOTTOMLEFT", s.ox, s.oy)
    elseif a == "ANCHOR_BOTTOMRIGHT" then self:SetPoint("TOPLEFT", owner, "BOTTOMRIGHT", s.ox, s.oy)
    else self:SetPoint("BOTTOMLEFT", owner, "TOPRIGHT", s.ox, s.oy) end
end
function Tooltip:GetOwner() return State(self).owner end
function Tooltip:IsOwned(f) return State(self).owner == f end
function Tooltip:GetAnchorType() return State(self).anchor end
function Tooltip:SetAnchorType(anchor, x, y) local s = State(self) self:SetOwner(s.owner, anchor, x, y) end
function Tooltip:ClearLines()
    local s = State(self)
    for i = 1, #s.lines do
        local line = s.lines[i]
        line.left:SetText(nil); line.left:Hide()
        line.right:SetText(nil); line.right:Hide()
        line.wrap = nil
    end
    s.numLines = 0
    s.item, s.spell, s.unit = nil, nil, nil
    S.RunScript(self, "OnTooltipCleared")
end
function Tooltip:AddLine(text, r, g, b, wrap)
    local s = State(self)
    s.numLines = s.numLines + 1
    local line = TooltipLine(self, s, s.numLines)
    line.left:SetText(text ~= nil and tostring(text) or " ")
    if r then line.left:SetTextColor(r, g or 1, b or 1) else line.left:SetTextColor(1, 0.82, 0) end
    if s.numLines > 1 and not r then line.left:SetTextColor(1, 0.82, 0) end
    line.left:Show()
    line.wrap = wrap and true or nil
    W[line.left].wordWrap = wrap and true or false
    line.right:Hide()
    if self:IsShown() then Layout(self, s) end
end
function Tooltip:AddDoubleLine(left, right, lr, lg, lb, rr, rg, rb)
    local s = State(self)
    self:AddLine(left, lr, lg, lb)
    local line = s.lines[s.numLines]
    line.right:SetText(right ~= nil and tostring(right) or " ")
    line.right:SetTextColor(rr or 1, rg or 0.82, rb or 0)
    line.right:Show()
    if self:IsShown() then Layout(self, s) end
end
function Tooltip:SetText(text, r, g, b, a, wrap)
    self:ClearLines()
    self:AddLine(text, r or 1, g or 1, b or 1, wrap)
    self:Show()
end
function Tooltip:NumLines() return State(self).numLines end
function Tooltip:Show()
    local s = State(self)
    Layout(self, s)
    S.Region.Show(self)
end
function Tooltip:Hide()
    local s = State(self)
    S.Region.Hide(self)
    s.owner = nil
end
function Tooltip:FadeOut() self:Hide() end
function Tooltip:SetMinimumWidth(w) State(self).minWidth = w end
function Tooltip:GetMinimumWidth() return State(self).minWidth or 0 end
function Tooltip:SetPadding(r, b, l, t) end
function Tooltip:GetPadding() return 0, 0, 0, 0 end
function Tooltip:AddTexture() end
function Tooltip:AddSpellByID() end
function Tooltip:SetUnit(unit) local s = State(self) s.unit = unit; self:AddLine(UnitName(unit) or unit, 1, 1, 1) end
function Tooltip:GetUnit() local s = State(self) return s.unit and UnitName(s.unit), s.unit end
function Tooltip:GetSpell() end
function Tooltip:SetSpellByID(id) self:AddLine("Spell " .. tostring(id), 1, 1, 1) end
function Tooltip:IsUnit(unit) return State(self).unit == unit end
function Tooltip:GetTooltipData() local s = State(self) return s.data end
function Tooltip:SetCustomLineSpacing() end
function Tooltip:SetAllowShowWithNoLines() end
function Tooltip:IsTooltipType(t) return false end
function Tooltip:GetPrimaryTooltipData() return State(self).data end
function Tooltip:AppendText(text)
    local s = State(self)
    local line = s.lines[1]
    if line then line.left:SetText((line.left:GetText() or "") .. text) end
end
function Tooltip:SetBackdropColor() end
function Tooltip:SetBackdropBorderColor() end
S.Region = S.Classes.Region.methods
S.TooltipLayout = Layout

function GameTooltip_SetDefaultAnchor(tooltip, parent)
    tooltip:SetOwner(parent, "ANCHOR_NONE")
    tooltip:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -100, 100)
end
function GameTooltip_Hide() GameTooltip:Hide() end
function GameTooltip_AddNormalLine(tt, text, wrap) tt:AddLine(text, 1, 0.82, 0, wrap) end
function GameTooltip_AddHighlightLine(tt, text, wrap) tt:AddLine(text, 1, 1, 1, wrap) end
function GameTooltip_AddInstructionLine(tt, text, wrap) tt:AddLine(text, 0.1, 1, 0.1, wrap) end
function GameTooltip_AddErrorLine(tt, text, wrap) tt:AddLine(text, 1, 0.125, 0.125, wrap) end
function GameTooltip_AddBlankLineToTooltip(tt) tt:AddLine(" ") end
function GameTooltip_SetTitle(tt, text, color, wrap)
    tt:ClearLines()
    local r, g, b = 1, 1, 1
    if color then r, g, b = color:GetRGB() end
    tt:AddLine(text, r, g, b, wrap)
end
function GameTooltip_AddColoredLine(tt, text, color, wrap) tt:AddLine(text, color.r, color.g, color.b, wrap) end

Template("GameTooltipTemplate", function(f) end, { "SharedTooltipTemplate", "SharedNoHeaderTooltipTemplate" })
GameTooltip = CreateFrame("GameTooltip", "GameTooltip", UIParent)
ItemRefTooltip = CreateFrame("GameTooltip", "ItemRefTooltip", UIParent)
ShoppingTooltip1 = CreateFrame("GameTooltip", "ShoppingTooltip1", UIParent)
ShoppingTooltip2 = CreateFrame("GameTooltip", "ShoppingTooltip2", UIParent)
GameTooltip.shoppingTooltips = { ShoppingTooltip1, ShoppingTooltip2 }
EmbeddedItemTooltip = CreateFrame("GameTooltip", "EmbeddedItemTooltip", UIParent)

-- TooltipDataProcessor: post-calls run after a Set* call fills the tooltip.
local tooltipCalls = { pre = {}, post = {} }
TooltipDataProcessor = { AllTypes = "ALL" }
function TooltipDataProcessor.AddTooltipPostCall(dataType, fn)
    local t = tooltipCalls.post[dataType] or {}
    tooltipCalls.post[dataType] = t
    t[#t + 1] = fn
end
function TooltipDataProcessor.AddTooltipPreCall(dataType, fn)
    local t = tooltipCalls.pre[dataType] or {}
    tooltipCalls.pre[dataType] = t
    t[#t + 1] = fn
end
function TooltipDataProcessor.AddLinePostCall() end
function TooltipDataProcessor.AddLinePreCall() end
function S.TooltipPost(tooltip, dataType, data)
    State(tooltip).data = data
    for _, key in ipairs({ dataType, "ALL" }) do
        for _, fn in ipairs(tooltipCalls.post[key] or {}) do S.Call(fn, tooltip, data) end
    end
end

---------------------------------------------------------------------------
-- Message frames and chat
---------------------------------------------------------------------------
local MessageFrame = S.Class("ScrollingMessageFrame", "Frame")
S.Classes.MessageFrame = S.Classes.ScrollingMessageFrame
local function MessageInit(obj, s)
    s.messages = {}
    s.maxLines = 120
    s.offset = 0
    s.isMessageFrame = true
    local body = S.Classes.Frame.methods.CreateFontString(obj, nil, "OVERLAY", "ChatFontNormal")
    body:SetAllPoints()
    body:SetJustifyH("LEFT")
    body:SetJustifyV("BOTTOM")
    s.body = body
end
S.RegisterFrameType("ScrollingMessageFrame", "ScrollingMessageFrame", MessageInit)
S.RegisterFrameType("MessageFrame", "ScrollingMessageFrame", MessageInit)

local function ColorHex(r, g, b) return ("|cff%02x%02x%02x"):format((r or 1) * 255, (g or 1) * 255, (b or 1) * 255) end
local function RedrawMessages(self, s)
    local _, size = S.FontOf(W[s.body])
    local visible = math.max(1, math.floor(self:GetHeight() / size))
    local last = #s.messages - s.offset
    local lines = {}
    for i = math.max(1, last - visible + 1), last do
        local m = s.messages[i]
        lines[#lines + 1] = ColorHex(m.r, m.g, m.b) .. m.text .. "|r"
    end
    s.body:SetText(table.concat(lines, "\n"))
end
function MessageFrame:AddMessage(text, r, g, b, id, holdTime)
    local s = State(self)
    table.insert(s.messages, { text = tostring(text), r = r, g = g, b = b, id = id, time = GetTime() })
    while #s.messages > s.maxLines do table.remove(s.messages, 1) end
    RedrawMessages(self, s)
end
function MessageFrame:BackFillMessage(text, r, g, b) self:AddMessage(text, r, g, b) end
function MessageFrame:Clear() local s = State(self) s.messages = {}; RedrawMessages(self, s) end
function MessageFrame:SetMaxLines(n) State(self).maxLines = n end
function MessageFrame:GetMaxLines() return State(self).maxLines end
function MessageFrame:GetNumMessages() return #State(self).messages end
function MessageFrame:GetMessageInfo(i) local m = State(self).messages[i] if m then return m.text, m.r, m.g, m.b, m.id end end
function MessageFrame:ScrollUp() local s = State(self) s.offset = math.min(s.offset + 1, #s.messages - 1); RedrawMessages(self, s) end
function MessageFrame:ScrollDown() local s = State(self) s.offset = math.max(s.offset - 1, 0); RedrawMessages(self, s) end
function MessageFrame:ScrollToBottom() local s = State(self) s.offset = 0; RedrawMessages(self, s) end
function MessageFrame:ScrollToTop() local s = State(self) s.offset = math.max(#s.messages - 1, 0); RedrawMessages(self, s) end
function MessageFrame:AtBottom() return State(self).offset == 0 end
function MessageFrame:AtTop() local s = State(self) return s.offset >= #s.messages - 1 end
function MessageFrame:SetFontObject(font) W[State(self).body].fontObject = type(font) == "string" and S.fontObjects[font] or font; S.Changed() end
function MessageFrame:SetFont(...) State(self).body:SetFont(...) end
function MessageFrame:GetFont() return State(self).body:GetFont() end
function MessageFrame:SetJustifyH(j) State(self).body:SetJustifyH(j) end
function MessageFrame:SetTextColor(...) State(self).body:SetTextColor(...) end
function MessageFrame:SetShadowColor(...) end
function MessageFrame:SetShadowOffset(...) end
function MessageFrame:SetSpacing() end
function MessageFrame:SetIndentedWordWrap() end
function MessageFrame:SetInsertMode() end
function MessageFrame:SetFading() end
function MessageFrame:SetFadeDuration() end
function MessageFrame:SetTimeVisible() end
function MessageFrame:SetTextCopyable() end
function MessageFrame:GetScrollOffset() return State(self).offset end
function MessageFrame:SetScrollOffset(n) local s = State(self) s.offset = n; RedrawMessages(self, s) end
function MessageFrame:GetNumLinesDisplayed() return 0 end
function MessageFrame:RemoveMessagesByPredicate(pred)
    local s = State(self)
    for i = #s.messages, 1, -1 do if pred(s.messages[i].text) then table.remove(s.messages, i) end end
    RedrawMessages(self, s)
end
function MessageFrame:AdjustMessageColors() end
function MessageFrame:ResetAllFadeTimes() end

-- Chat frames: real message frames, hidden in the viewport; their output goes to the host chat panel.
NUM_CHAT_WINDOWS = 10
local function ChatAddMessage(self, text, r, g, b)
    host.chat(tostring(text), r or 1, g or 1, b or 1)
end
for i = 1, NUM_CHAT_WINDOWS do
    local cf = CreateFrame("ScrollingMessageFrame", "ChatFrame" .. i, UIParent)
    cf:Hide()
    cf:SetID(i)
    if i == 1 then cf.AddMessage = ChatAddMessage end
end
DEFAULT_CHAT_FRAME = ChatFrame1
SELECTED_CHAT_FRAME = ChatFrame1
ChatFrame1EditBox = CreateFrame("EditBox", "ChatFrame1EditBox", UIParent)
ChatFrame1EditBox:Hide()
ChatFrame1EditBox:SetAutoFocus(false)
ChatFrame1.editBox = ChatFrame1EditBox
CHAT_FRAMES = {}
for i = 1, NUM_CHAT_WINDOWS do CHAT_FRAMES[i] = "ChatFrame" .. i end

function print(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    DEFAULT_CHAT_FRAME:AddMessage(table.concat(parts, " "))
end
setprinthandler = function(fn) print = fn end
getprinthandler = function() return print end

function ChatFrame_AddMessageEventFilter() end
function ChatFrame_RemoveMessageEventFilter() end
function ChatFrame_GetMessageEventFilters() return {} end
function ChatFrame_OpenChat(text) host.openChat(text or "") end
function ChatEdit_GetActiveWindow() return nil end
function ChatEdit_InsertLink(link) return host.insertChat(link) end
function ChatEdit_ActivateChat() end
function ChatEdit_DeactivateChat() end
function ChatEdit_FocusActiveWindow() end
function ChatEdit_SendText() end
function ChatFrame_AddChannel() end
function ChatFrame_RemoveChannel() end
function FCF_GetCurrentChatFrame() return SELECTED_CHAT_FRAME end
function SendChatMessage(msg, chatType, language, target)
    chatType = (chatType or "SAY"):upper()
    local name = UnitName("player")
    if chatType == "WHISPER" then host.chat(("To [%s]: %s"):format(tostring(target), msg), 1, 0.5, 1)
    elseif chatType == "SAY" then host.chat(("[%s] says: %s"):format(name, msg), 1, 1, 1)
    else host.chat(("[%s] [%s]: %s"):format(chatType, name, msg), 0.67, 0.67, 1) end
    S.FireEvent("CHAT_MSG_" .. chatType, msg, name .. "-" .. GetRealmName(), "", "", name, "", 0, 0, "", 0, 0, UnitGUID("player"))
end

-- Slash commands ------------------------------------------------------------
SlashCmdList = {}
hash_SlashCmdList = {}

local function DumpValue(v, indent, depth, seen, out)
    local tv = type(v)
    if tv == "string" then return ("%q"):format(v):gsub("\\\n", "\\n") end
    if tv ~= "table" then return tostring(v) end
    if W[v] then return ("<%s %s>"):format(W[v].type, W[v].name or ("#" .. W[v].id)) end
    if seen[v] then return "<recursive>" end
    if depth >= 3 then return "<table>" end
    seen[v] = true
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta < tb end
        if ta == "number" or ta == "string" then return a < b end
        return tostring(a) < tostring(b)
    end)
    if #keys == 0 then return "{}" end
    local parts = { "{" }
    for i, k in ipairs(keys) do
        if i > 40 then parts[#parts + 1] = indent .. "  ... (" .. (#keys - 40) .. " more)" break end
        local key = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. DumpValue(k, "", 3, seen, out) .. "]")
        parts[#parts + 1] = indent .. "  " .. key .. "=" .. DumpValue(v[k], indent .. "  ", depth + 1, seen, out) .. ","
    end
    parts[#parts + 1] = indent .. "}"
    return table.concat(parts, "\n")
end
S.DumpValue = function(v) return DumpValue(v, "", 0, {}) end

function S.RunCode(code, chunkname)
    local fn, err = loadstring(code, chunkname or "/run")
    if not fn then S.ReportError(err, "") return end
    S.Call(fn)
end
function RunScript(code) S.RunCode(code, "RunScript") end

function S.Dump(expr)
    local fn, err = loadstring("return " .. expr, "/dump")
    if not fn then S.ReportError(err, "") return end
    local results = { S.Call(fn) }
    if not results[1] then return end
    host.chat("Dump: value=" .. expr, 1, 0.82, 0)
    local n = 0
    for i = 2, table.maxn(results) do
        n = n + 1
        host.chat(("[%d]=%s"):format(i - 1, DumpValue(results[i], "", 0, {})), 1, 1, 1)
    end
    if n == 0 then host.chat("empty result", 1, 1, 1) end
end

function S.ChatCommand(text)
    text = strtrim(tostring(text or ""))
    if text == "" then return end
    if text:sub(1, 1) ~= "/" then
        SendChatMessage(text, "SAY")
        return
    end
    local cmd, rest = text:match("^(/%S+)%s*(.-)$")
    local lower = cmd:lower()
    if lower == "/run" or lower == "/script" then return S.RunCode(rest) end
    if lower == "/dump" then return S.Dump(rest) end
    if lower == "/reload" or lower == "/reloadui" or (lower == "/console" and rest:lower() == "reloadui") then return host.reload() end
    if lower == "/fstack" then return host.fstack() end
    if lower == "/etrace" or lower == "/eventtrace" then return host.etrace() end
    if lower == "/help" then
        host.chat("Sandbox commands: /run, /dump, /reload, /fstack, /etrace. Addon commands work as in game.", 1, 1, 0)
        return
    end
    for key, fn in pairs(SlashCmdList) do
        local i = 1
        while true do
            local alias = _G["SLASH_" .. key .. i]
            if not alias then break end
            if alias:lower() == lower then
                S.Call(fn, rest, ChatFrame1EditBox)
                return
            end
            i = i + 1
        end
    end
    host.chat("Type '/help' for a listing of a few commands.", 1, 1, 0)
end

---------------------------------------------------------------------------
-- Static popups
---------------------------------------------------------------------------
StaticPopupDialogs = {}
STATICPOPUP_NUMDIALOGS = 4
local popups = {}

local function PopupButton(popup, key, x)
    local b = CreateFrame("Button", popup:GetName() .. key:gsub("^b", "B"), popup, "UIPanelButtonTemplate")
    b:SetSize(128, 21)
    popup[key] = b
    return b
end

local function GetPopup(i)
    if popups[i] then return popups[i] end
    local p = CreateFrame("Frame", "StaticPopup" .. i, UIParent)
    Style(p, "dialog")
    p:SetFrameStrata("DIALOG")
    p:SetSize(320, 100)
    p:SetPoint("TOP", UIParent, "TOP", 0, -135 - (i - 1) * 110)
    p:EnableMouse(true)
    p.text = p:CreateFontString("StaticPopup" .. i .. "Text", "ARTWORK", "GameFontHighlight")
    p.text:SetPoint("TOP", 0, -16)
    p.text:SetWidth(290)
    p.editBox = CreateFrame("EditBox", "StaticPopup" .. i .. "EditBox", p, "InputBoxTemplate")
    p.editBox:SetSize(240, 32)
    p.editBox:SetAutoFocus(false)
    p.EditBox = p.editBox
    PopupButton(p, "button1")
    PopupButton(p, "button2")
    PopupButton(p, "button3")
    p:Hide()
    popups[i] = p
    return p
end

local function HidePopup(p, reason)
    if not p:IsShown() then return end
    local info = p.which and StaticPopupDialogs[p.which]
    p:Hide()
    if info and info.OnHide then S.Call(info.OnHide, p, p.data) end
    p.which = nil
end

function StaticPopup_Show(which, arg1, arg2, data, insertedFrame)
    local info = StaticPopupDialogs[which]
    if not info then return nil end
    local p
    for i = 1, STATICPOPUP_NUMDIALOGS do
        local candidate = GetPopup(i)
        if candidate.which == which and not info.multiple then p = candidate break end
    end
    if not p then
        for i = 1, STATICPOPUP_NUMDIALOGS do
            local candidate = GetPopup(i)
            if not candidate:IsShown() then p = candidate break end
        end
    end
    if not p then return nil end
    p.which, p.data = which, data
    local text = info.text or ""
    text = text:format(arg1 or "", arg2 or "")
    p.text:SetText(text)
    local height = 32 + p.text:GetStringHeight() + 40
    if info.hasEditBox then
        p.editBox:ClearAllPoints()
        p.editBox:SetPoint("TOP", p.text, "BOTTOM", 0, -6)
        p.editBox:SetText("")
        p.editBox:Show()
        if info.maxLetters then p.editBox:SetMaxLetters(info.maxLetters) end
        height = height + 36
        p.editBox:SetScript("OnEnterPressed", function(eb)
            if info.EditBoxOnEnterPressed then S.Call(info.EditBoxOnEnterPressed, eb, p.data)
            elseif info.OnAccept then S.Call(info.OnAccept, p, p.data, p.data2); HidePopup(p, "clicked") end
        end)
        p.editBox:SetScript("OnEscapePressed", function(eb)
            if info.EditBoxOnEscapePressed then S.Call(info.EditBoxOnEscapePressed, eb, p.data)
            else HidePopup(p, "override") end
        end)
        p.editBox:SetScript("OnTextChanged", function(eb, user)
            if info.EditBoxOnTextChanged then S.Call(info.EditBoxOnTextChanged, eb, p.data) end
        end)
    else
        p.editBox:Hide()
    end
    p:SetHeight(height)
    local buttons = {}
    for idx, key in ipairs({ "button1", "button2", "button3" }) do
        local label = info[key]
        local b = p[key]
        if label then
            b:SetText(label)
            b:Show()
            buttons[#buttons + 1] = b
            b:SetScript("OnClick", function()
                local handler = idx == 1 and info.OnAccept or idx == 2 and info.OnCancel or info.OnAlt
                local keep
                if handler then
                    local ok, result = S.Call(handler, p, p.data, idx == 2 and "clicked" or p.data2)
                    keep = ok and result
                end
                if not keep then HidePopup(p, "clicked") end
            end)
        else
            b:Hide()
        end
    end
    local total = #buttons * 134 - 6
    for i, b in ipairs(buttons) do
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", p, "BOTTOM", -total / 2 + (i - 1) * 134, 14)
    end
    p:Show()
    if info.OnShow then S.Call(info.OnShow, p, data) end
    if info.hasEditBox then p.editBox:SetFocus() end
    return p
end
function StaticPopup_Hide(which, data)
    for _, p in ipairs(popups) do
        if p.which == which and (data == nil or p.data == data) then HidePopup(p, "override") end
    end
end
function StaticPopup_Visible(which)
    for i, p in ipairs(popups) do if p.which == which and p:IsShown() then return p:GetName(), p end end
end
function StaticPopup_FindVisible(which, data)
    for _, p in ipairs(popups) do if p.which == which and p:IsShown() and (data == nil or p.data == data) then return p end end
end
function StaticPopup_EscapePressed()
    for _, p in ipairs(popups) do
        local info = p.which and StaticPopupDialogs[p.which]
        if p:IsShown() and info and info.hideOnEscape then HidePopup(p, "override") return true end
    end
end
table.insert(S.panels, { frame = { IsShown = function() for _, p in ipairs(popups) do if p:IsShown() then return true end end return false end },
    close = function() StaticPopup_EscapePressed() end })

---------------------------------------------------------------------------
-- Dropdown menus (UIDropDownMenu and the 11.0 MenuUtil), one shared list frame
---------------------------------------------------------------------------
local menuList
local function MenuList()
    if menuList then return menuList end
    menuList = CreateFrame("Frame", "DropDownList1", UIParent)
    Style(menuList, "tooltip")
    menuList:SetFrameStrata("FULLSCREEN_DIALOG")
    menuList:EnableMouse(true)
    menuList:Hide()
    menuList.buttons = {}
    return menuList
end
local function MenuButton(list, i)
    local b = list.buttons[i]
    if b then return b end
    b = CreateFrame("Button", "DropDownList1Button" .. i, list)
    b:SetHeight(16)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b:SetNormalFontObject(GameFontHighlightSmallLeft)
    b:SetHighlightFontObject(GameFontHighlightSmallLeft)
    b:SetDisabledFontObject(GameFontDisableSmallLeft)
    b:SetText(" ")
    b:GetFontString():ClearAllPoints()
    b:GetFontString():SetPoint("LEFT", 20, 0)
    b.check = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.check:SetPoint("LEFT", 4, 0)
    list.buttons[i] = b
    return b
end

-- entries: { text, isTitle, disabled, checked (bool or fn), func, isSeparator }
local function OpenMenu(anchor, entries, xOffset, yOffset)
    local list = MenuList()
    local width = 80
    for i, e in ipairs(entries) do
        local b = MenuButton(list, i)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", list, "TOPLEFT", 8, -8 - (i - 1) * 16)
        b:SetPoint("RIGHT", list, "RIGHT", -8, 0)
        local checked = e.checked
        if type(checked) == "function" then local ok, v = S.Call(checked); checked = ok and v end
        b:SetText(e.isSeparator and "" or (e.text or ""))
        b.check:SetText(checked and "|cffffd100✓|r" or "")
        b:SetEnabled(not (e.disabled or e.isTitle or e.isSeparator))
        if e.isTitle then b:GetFontString():SetTextColor(1, 0.82, 0) else b:GetFontString():SetTextColor(1, 1, 1) end
        b:SetScript("OnClick", function()
            if e.func then S.Call(e.func, b, e.arg1, e.arg2, not checked) end
            if not e.keepShownOnClick then list:Hide() end
        end)
        b:Show()
        width = math.max(width, b:GetTextWidth() + 40)
    end
    for i = #entries + 1, #list.buttons do list.buttons[i]:Hide() end
    list:SetSize(width + 16, #entries * 16 + 16)
    list:ClearAllPoints()
    if anchor == "cursor" then
        local x, y = GetCursorPosition()
        list:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    else
        list:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", xOffset or 0, yOffset or 0)
    end
    list:Show()
end
S.OpenMenu = OpenMenu
function CloseDropDownMenus() if menuList then menuList:Hide() end end

UIDROPDOWNMENU_MENU_LEVEL, UIDROPDOWNMENU_MENU_VALUE, UIDROPDOWNMENU_OPEN_MENU = 1, nil, nil
local pendingEntries
function UIDropDownMenu_CreateInfo() return {} end
function UIDropDownMenu_AddButton(info, level)
    if pendingEntries then table.insert(pendingEntries, CopyTable(info, true)) end
end
function UIDropDownMenu_AddSeparator(level) UIDropDownMenu_AddButton({ isSeparator = true }, level) end
function UIDropDownMenu_Initialize(frame, init, displayMode, level, menuList)
    frame.initialize, frame.displayMode, frame.menuList = init, displayMode, menuList
end
function ToggleDropDownMenu(level, value, frame, anchor, xOffset, yOffset, menuListArg)
    local list = MenuList()
    if list:IsShown() and UIDROPDOWNMENU_OPEN_MENU == frame then list:Hide() return end
    UIDROPDOWNMENU_OPEN_MENU = frame
    pendingEntries = {}
    if frame.initialize then S.Call(frame.initialize, frame, level or 1, menuListArg or frame.menuList) end
    local entries = pendingEntries
    pendingEntries = nil
    if anchor == "cursor" then OpenMenu("cursor", entries) else OpenMenu(type(anchor) == "table" and anchor or frame, entries, xOffset, yOffset) end
end
function UIDropDownMenu_SetWidth(frame, width) frame:SetWidth(width + 40) end
function UIDropDownMenu_SetButtonWidth() end
function UIDropDownMenu_SetText(frame, text) if frame.Text then frame.Text:SetText(text) end end
function UIDropDownMenu_GetText(frame) return frame.Text and frame.Text:GetText() end
function UIDropDownMenu_SetSelectedValue(frame, value) frame.selectedValue = value end
function UIDropDownMenu_GetSelectedValue(frame) return frame.selectedValue end
function UIDropDownMenu_SetSelectedID(frame, id) frame.selectedID = id end
function UIDropDownMenu_GetSelectedID(frame) return frame.selectedID end
function UIDropDownMenu_SetSelectedName(frame, name) frame.selectedName = name; UIDropDownMenu_SetText(frame, name) end
function UIDropDownMenu_JustifyText(frame, justify) if frame.Text then frame.Text:SetJustifyH(justify) end end
function UIDropDownMenu_EnableDropDown(frame) if frame.Button then frame.Button:Enable() end end
function UIDropDownMenu_DisableDropDown(frame) if frame.Button then frame.Button:Disable() end end
function UIDropDownMenu_Refresh() end
function UIDropDownMenu_SetAnchor() end
function EasyMenu(menu, frame, anchor, x, y, displayMode)
    OpenMenu(anchor == "cursor" and "cursor" or (type(anchor) == "table" and anchor or frame), menu, x, y)
end
Template("UIDropDownMenuTemplate", function(f)
    Style(f, "dropdown")
    f:SetSize(150, 26)
    local text = Label(f, "Text", "GameFontHighlightSmall")
    text:SetPoint("LEFT", 12, 0)
    text:SetPoint("RIGHT", -28, 0)
    text:SetJustifyH("RIGHT")
    local button = Child(f, "Button", "Button", nil, "Button")
    button:SetSize(24, 24)
    button:SetPoint("RIGHT", -2, 0)
    Style(button, "arrow-down")
    button:SetScript("OnClick", function() ToggleDropDownMenu(1, nil, f, f, 0, 0) end)
end, { "UIDropDownMenuButtonTemplate", "WowStyle1DropdownTemplate", "WowStyle2DropdownTemplate" })

-- MenuUtil: generator(owner, rootDescription) builds entries.
local function NewDescription(entries)
    local d = {}
    function d:CreateButton(text, callback, data)
        local e = { text = text, func = function() if callback then callback(data) end end }
        entries[#entries + 1] = e
        return NewDescription(entries)
    end
    function d:CreateTitle(text) entries[#entries + 1] = { text = text, isTitle = true } return NewDescription(entries) end
    function d:CreateCheckbox(text, isSelected, setSelected, data)
        entries[#entries + 1] = { text = text, checked = function() return isSelected(data) end,
            func = function() setSelected(data) end, keepShownOnClick = true }
        return NewDescription(entries)
    end
    d.CreateRadio = d.CreateCheckbox
    function d:CreateDivider() entries[#entries + 1] = { isSeparator = true } end
    function d:CreateSpacer() entries[#entries + 1] = { isSeparator = true } end
    function d:SetTag() end
    function d:SetEnabled() end
    function d:SetTooltip() end
    function d:SetScrollMode() end
    function d:AddInitializer() end
    return d
end
MenuUtil = {}
function MenuUtil.CreateContextMenu(owner, generator)
    local entries = {}
    S.Call(generator, owner, NewDescription(entries))
    OpenMenu("cursor", entries)
    return MenuList()
end
function MenuUtil.CreateRootMenuDescription() return NewDescription({}) end
MenuResponse = { Open = 1, Refresh = 2, Close = 3, CloseAll = 4 }

---------------------------------------------------------------------------
-- Pools
---------------------------------------------------------------------------
local PoolMixin = {}
function PoolMixin:Acquire()
    local obj = table.remove(self.inactive)
    local isNew = false
    if not obj then obj = self.create(self); isNew = true end
    self.active[obj] = true
    self.numActive = self.numActive + 1
    return obj, isNew
end
function PoolMixin:Release(obj)
    if not self.active[obj] then return false end
    self.active[obj] = nil
    self.numActive = self.numActive - 1
    if self.reset then self.reset(self, obj) end
    table.insert(self.inactive, obj)
    return true
end
function PoolMixin:ReleaseAll()
    for obj in pairs(self.active) do self:Release(obj) end
end
function PoolMixin:EnumerateActive() return pairs(self.active) end
function PoolMixin:GetNumActive() return self.numActive end
function PoolMixin:IsActive(obj) return self.active[obj] == true end
function PoolMixin:GetNextActive(current) return (next(self.active, current)) end
function PoolMixin:EnumerateInactive() return ipairs(self.inactive) end
function CreateObjectPool(create, reset)
    local pool = CreateFromMixins(PoolMixin)
    pool.create, pool.reset, pool.active, pool.inactive, pool.numActive = create, reset, {}, {}, 0
    return pool
end
local function HideAndClear(_, region) region:Hide(); region:ClearAllPoints() end
function CreateFramePool(frameType, parent, template, reset, forbidden, initializer)
    return CreateObjectPool(function()
        local f = CreateFrame(frameType, nil, parent, template)
        if initializer then initializer(f) end
        return f
    end, reset or HideAndClear)
end
function CreateTexturePool(parent, layer, sublevel, template, reset)
    return CreateObjectPool(function() return parent:CreateTexture(nil, layer, template, sublevel) end, reset or HideAndClear)
end
function CreateFontStringPool(parent, layer, sublevel, template, reset)
    return CreateObjectPool(function() return parent:CreateFontString(nil, layer, template) end, reset or HideAndClear)
end
Pool_HideAndClearAnchors = HideAndClear
FramePool_HideAndClearAnchors = HideAndClear

---------------------------------------------------------------------------
-- Callback registry and EventRegistry
---------------------------------------------------------------------------
CallbackRegistryMixin = {}
function CallbackRegistryMixin:OnLoad() self.callbackTables = {} end
function CallbackRegistryMixin:SetUndefinedEventsAllowed() end
function CallbackRegistryMixin:GenerateCallbackEvents(events)
    self.Event = self.Event or {}
    for _, e in ipairs(events) do self.Event[e] = e end
end
function CallbackRegistryMixin:RegisterCallback(event, func, owner, ...)
    self.callbackTables = self.callbackTables or {}
    local t = self.callbackTables[event] or {}
    self.callbackTables[event] = t
    owner = owner or {}
    local n = select("#", ...)
    local args = { ... }
    t[owner] = n > 0 and function(o, ...) return func(o, unpack(args, 1, n), ...) end or func
    return owner
end
function CallbackRegistryMixin:RegisterCallbackWithHandle(event, func, owner, ...)
    owner = self:RegisterCallback(event, func, owner, ...)
    local registry = self
    return { Unregister = function() registry:UnregisterCallback(event, owner) end }
end
function CallbackRegistryMixin:UnregisterCallback(event, owner)
    local t = self.callbackTables and self.callbackTables[event]
    if t then t[owner] = nil end
end
function CallbackRegistryMixin:UnregisterEvents(events) for _, e in ipairs(events) do self.callbackTables[e] = nil end end
function CallbackRegistryMixin:TriggerEvent(event, ...)
    local t = self.callbackTables and self.callbackTables[event]
    if not t then return end
    local copy = {}
    for owner, func in pairs(t) do copy[owner] = func end
    for owner, func in pairs(copy) do S.Call(func, owner, ...) end
end
function CallbackRegistryMixin:HasRegistrantsForEvent(event)
    return self.callbackTables and self.callbackTables[event] and next(self.callbackTables[event]) ~= nil
end

EventRegistry = CreateFromMixins(CallbackRegistryMixin)
EventRegistry:OnLoad()
local registryFrame = CreateFrame("Frame")
registryFrame:SetScript("OnEvent", function(_, event, ...) EventRegistry:TriggerEvent(event, ...) end)
function EventRegistry:RegisterFrameEventAndCallback(frameEvent, func, owner, ...)
    registryFrame:RegisterEvent(frameEvent)
    return self:RegisterCallback(frameEvent, func, owner, ...)
end
function EventRegistry:RegisterFrameEventAndCallbackWithHandle(frameEvent, func, owner, ...)
    registryFrame:RegisterEvent(frameEvent)
    return self:RegisterCallbackWithHandle(frameEvent, func, owner, ...)
end
function EventRegistry:UnregisterFrameEventAndCallback(frameEvent, owner) self:UnregisterCallback(frameEvent, owner) end

EventUtil = {}
function EventUtil.ContinueOnAddOnLoaded(addon, fn)
    if C_AddOns and C_AddOns.IsAddOnLoaded(addon) then fn() return end
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:SetScript("OnEvent", function(self, _, name)
        if name == addon then self:UnregisterAllEvents(); fn() end
    end)
end
function EventUtil.RegisterOnceFrameEventAndCallback(event, fn, ...)
    local f = CreateFrame("Frame")
    f:RegisterEvent(event)
    f:SetScript("OnEvent", function(self, _, ...) self:UnregisterAllEvents(); fn(...) end)
end
function EventUtil.ContinueOnPlayerLogin(fn)
    if S.loggedIn then fn() else EventUtil.RegisterOnceFrameEventAndCallback("PLAYER_LOGIN", fn) end
end
function EventUtil.ContinueAfterAllEvents(fn) fn() end
function EventUtil.CreateFrameEventCallback() end

---------------------------------------------------------------------------
-- Settings (enough for addons to register options pages and open them)
---------------------------------------------------------------------------
local settingsCategories = {}
local settingsWindow
local function SettingsWindow()
    if settingsWindow then return settingsWindow end
    local f = CreateFrame("Frame", "SettingsPanel", UIParent, "PortraitFrameTemplate")
    f:SetSize(860, 600)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetTitle("Options")
    f:EnableMouse(true)
    f.Container = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    f.Container:SetPoint("TOPLEFT", 200, -30)
    f.Container:SetPoint("BOTTOMRIGHT", -10, 10)
    f.list = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    f.list:SetPoint("TOPLEFT", 10, -30)
    f.list:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", 192, 10)
    f.listButtons = {}
    f:Hide()
    tinsert(UISpecialFrames, "SettingsPanel")
    settingsWindow = f
    return f
end
local function ShowCategory(category)
    local f = SettingsWindow()
    for _, c in ipairs(settingsCategories) do
        if c.frame then c.frame:Hide() end
    end
    for i, c in ipairs(settingsCategories) do
        local b = f.listButtons[i]
        if not b then
            b = CreateFrame("Button", nil, f.list)
            b:SetHeight(20)
            b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 22)
            b:SetPoint("RIGHT", -6, 0)
            b:SetNormalFontObject(GameFontHighlightLeft)
            b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            f.listButtons[i] = b
        end
        b:SetText(c.name)
        b:SetScript("OnClick", function() ShowCategory(c) end)
    end
    if category and category.frame then
        local cf = category.frame
        cf:SetParent(f.Container)
        cf:ClearAllPoints()
        cf:SetAllPoints(f.Container)
        cf:Show()
        if cf.OnRefresh then S.Call(cf.OnRefresh, cf) end
        if cf.refresh then S.Call(cf.refresh, cf) end
    end
    f:Show()
end
local CategoryMixin = {}
function CategoryMixin:GetID() return self.ID end
function CategoryMixin:GetName() return self.name end
function CategoryMixin:SetName(n) self.name = n end
function CategoryMixin:GetParentCategory() return self.parent end
function CategoryMixin:HasSubcategories() return false end
Settings = {}
function Settings.RegisterCanvasLayoutCategory(frame, name)
    local c = CreateFromMixins(CategoryMixin)
    c.ID, c.name, c.frame = #settingsCategories + 1000, name, frame
    return c, { AddAnchorPoint = function() end }
end
function Settings.RegisterCanvasLayoutSubcategory(parent, frame, name)
    local c = Settings.RegisterCanvasLayoutCategory(frame, name)
    c.parent = parent
    table.insert(settingsCategories, c)
    return c
end
function Settings.RegisterVerticalLayoutCategory(name)
    local c = CreateFromMixins(CategoryMixin)
    c.ID, c.name, c.settings = #settingsCategories + 1000, name, {}
    return c, { AddInitializer = function() end }
end
Settings.RegisterVerticalLayoutSubcategory = function(parent, name) local c = Settings.RegisterVerticalLayoutCategory(name) c.parent = parent return c end
function Settings.RegisterAddOnCategory(category) table.insert(settingsCategories, category) end
function Settings.OpenToCategory(id)
    for _, c in ipairs(settingsCategories) do
        if c.ID == id or c.name == id or c == id then ShowCategory(c) return true end
    end
    ShowCategory(settingsCategories[1])
end
function Settings.GetCategory(id)
    for _, c in ipairs(settingsCategories) do if c.ID == id or c.name == id then return c end end
end
function Settings.RegisterAddOnSetting(category, variable, key, tbl, varType, name, default)
    local setting = { variable = variable, name = name, default = default }
    function setting:GetValue() if tbl[key] == nil then return default end return tbl[key] end
    function setting:SetValue(v) tbl[key] = v; if self.cb then S.Call(self.cb, self, v) end end
    function setting:SetValueChangedCallback(cb) self.cb = cb end
    function setting:GetVariable() return variable end
    function setting:GetName() return name end
    function setting:GetDefaultValue() return default end
    if category.settings then table.insert(category.settings, setting) end
    return setting
end
function Settings.RegisterProxySetting(category, variable, varType, name, default, getter, setter)
    local setting = { variable = variable, name = name }
    function setting:GetValue() return getter() end
    function setting:SetValue(v) setter(v) end
    function setting:SetValueChangedCallback() end
    return setting
end
function Settings.SetOnValueChangedCallback() end
function Settings.CreateCheckbox(category, setting, tooltip) return { setting = setting } end
Settings.CreateCheckBox = Settings.CreateCheckbox
function Settings.CreateSlider(category, setting, options, tooltip) return { setting = setting } end
function Settings.CreateDropdown(category, setting, options, tooltip) return { setting = setting } end
Settings.CreateDropDown = Settings.CreateDropdown
function Settings.CreateSliderOptions(min, max, step) return { min = min, max = max, step = step, SetLabelFormatter = function() end } end
function Settings.CreateControlTextContainer()
    local c = { data = {} }
    function c:Add(value, label) table.insert(self.data, { value = value, label = label }) end
    function c:GetData() return self.data end
    return c
end
function Settings.CreateElementInitializer() return {} end
function Settings.SetValue() end
function Settings.GetValue() end
Settings.VarType = { Boolean = "boolean", Number = "number", String = "string" }
Settings.Default = { True = true, False = false }
function InterfaceOptions_AddCategory(frame)
    local c = Settings.RegisterCanvasLayoutCategory(frame, frame.name or "?")
    Settings.RegisterAddOnCategory(c)
end
function InterfaceOptionsFrame_OpenToCategory(frame) Settings.OpenToCategory(type(frame) == "table" and frame.name or frame) end
