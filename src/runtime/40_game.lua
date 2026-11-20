-- Game systems driven by the fake world (S.world): items, bags, money, merchant, loot, Auction House,
-- professions. Each system has a stand-in Blizzard window registered for its events before any addon loads,
-- so event order matches the client (Blizzard's handlers run first).
local S = SANDBOX
local host = S.host
local W, State = S.W, S.State

local QUESTION_ICON = 134400
local COIN_ICON = 133784

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------
local TYPE_NAMES = { [0] = "Consumable", "Container", "Weapon", "Gem", "Armor", "Reagent", "Projectile", "Tradeskill",
    "Item Enhancement", "Recipe", "Money", "Quiver", "Quest", "Key", "Permanent", "Miscellaneous", "Glyph",
    "Battle Pets", "WoW Token", "Profession" }

-- shortcut: items missing from the world get a placeholder name and a derived sell price; import real item data to replace them.
local function FallbackSellPrice(id) return (id * 7919) % 240 + 5 end

local function ItemRec(id)
    id = tonumber(id)
    if not id or id <= 0 then return nil end
    local w = S.world.items[id]
    return {
        id = id, known = w ~= nil,
        name = w and w.name or ("Item " .. id),
        quality = w and w.quality or 1,
        sellPrice = w and w.sellPrice or FallbackSellPrice(id),
        icon = w and w.icon or QUESTION_ICON,
        stack = w and w.stack or 20,
        classID = w and w.classID or 7,
        subclassID = w and w.subclassID or 0,
        itemLevel = w and w.itemLevel or 1,
        minLevel = w and w.minLevel or 0,
        equipLoc = w and w.equipLoc or "",
        bind = w and w.bind or 0,
        reagent = w and w.reagent or false,
    }
end
S.Item = ItemRec

local function ItemLink(r)
    local hex = ITEM_QUALITY_COLORS[r.quality] and ITEM_QUALITY_COLORS[r.quality].hex or "|cffffffff"
    return ("%s|Hitem:%d::::::::%d:::::::::|h[%s]|h|r"):format(hex, r.id, UnitLevel("player"), r.name)
end
S.ItemLink = ItemLink

-- Accepts an item ID, "item:123", a full link or a known item name.
local function ItemID(item)
    if type(item) == "number" then return item end
    if type(item) ~= "string" then return nil end
    local id = tonumber(item) or tonumber(item:match("item:(%d+)"))
    if id then return id end
    for k, v in pairs(S.world.items) do if v.name == item then return k end end
end
S.ItemID = ItemID

-- Item data arrives asynchronously in the client; simulate it unless the world says items are pre-cached.
local cached = {}
local requested = {}
local function IsCached(id)
    if S.world.client.itemsCached then return true end
    return cached[id] == true
end
local function RequestItem(id)
    if cached[id] or requested[id] then return end
    requested[id] = true
    C_Timer.After(tonumber(S.world.client.itemLoadDelay) or 0.05, function()
        cached[id] = true
        requested[id] = nil
        S.FireEvent("GET_ITEM_INFO_RECEIVED", id, true)
        S.FireEvent("ITEM_DATA_LOAD_RESULT", id, true)
    end)
end
S.RequestItem = RequestItem

C_Item = {}
function C_Item.GetItemInfo(item)
    local id = ItemID(item)
    local r = ItemRec(id)
    if not r then return nil end
    if not IsCached(id) then RequestItem(id) return nil end
    return r.name, ItemLink(r), r.quality, r.itemLevel, r.minLevel, TYPE_NAMES[r.classID] or "Miscellaneous", "Other",
        r.stack, r.equipLoc, r.icon, r.sellPrice, r.classID, r.subclassID, r.bind, 0, nil, r.reagent
end
GetItemInfo = C_Item.GetItemInfo
function C_Item.GetItemInfoInstant(item)
    local r = ItemRec(ItemID(item))
    if not r then return nil end
    return r.id, TYPE_NAMES[r.classID] or "Miscellaneous", "Other", r.equipLoc, r.icon, r.classID, r.subclassID
end
GetItemInfoInstant = C_Item.GetItemInfoInstant
function C_Item.GetItemNameByID(item)
    local id = ItemID(item)
    if not id then return nil end
    if not IsCached(id) then RequestItem(id) return nil end
    return ItemRec(id).name
end
function C_Item.GetItemIconByID(item) local r = ItemRec(ItemID(item)) return r and r.icon end
function C_Item.GetItemQualityByID(item)
    local id = ItemID(item)
    if not id then return nil end
    if not IsCached(id) then RequestItem(id) return nil end
    return ItemRec(id).quality
end
function C_Item.GetItemLink(location) return nil end
function C_Item.RequestLoadItemDataByID(item) local id = ItemID(item) if id then RequestItem(id) end end
C_Item.RequestLoadItemData = function() end
function C_Item.IsItemDataCachedByID(item) local id = ItemID(item) return id and IsCached(id) or false end
function C_Item.DoesItemExistByID(item) return ItemID(item) ~= nil end
function C_Item.GetItemMaxStackSizeByID(item) local r = ItemRec(ItemID(item)) return r and r.stack end
function C_Item.GetItemQualityColor(q) return GetItemQualityColor(q) end
function C_Item.GetItemSpell() return nil end
function C_Item.IsEquippableItem() return false end
function C_Item.IsConsumableItem() return false end
function C_Item.GetItemClassInfo(classID) return TYPE_NAMES[classID] end
function C_Item.GetItemSubClassInfo() return "Other" end
GetItemClassInfo, GetItemSubClassInfo = C_Item.GetItemClassInfo, C_Item.GetItemSubClassInfo
function C_Item.IsItemKeystoneByID() return false end
function C_Item.GetDetailedItemLevelInfo(item) local r = ItemRec(ItemID(item)) return r and r.itemLevel end
GetDetailedItemLevelInfo = C_Item.GetDetailedItemLevelInfo
function C_Item.IsCosmeticItem() return false end
function C_Item.IsBound() return false end
function C_Item.GetStackCount() return 1 end
function C_Item.GetItemID() return nil end
function C_Item.DoesItemExist() return false end
function C_Item.IsItemInRange() return true end

-- Item / ItemMixin (ObjectAPI/Item.lua)
ItemMixin = {}
_G.Item = {}
function _G.Item:CreateFromItemID(id)
    local obj = CreateFromMixins(ItemMixin)
    obj.itemID = tonumber(id)
    return obj
end
function _G.Item:CreateFromItemLink(link) local obj = _G.Item:CreateFromItemID(ItemID(link)); obj.itemLink = link; return obj end
function _G.Item:CreateFromBagAndSlot(bag, slot) return _G.Item:CreateFromItemID(C_Container.GetContainerItemID(bag, slot)) end
function ItemMixin:GetItemID() return self.itemID end
function ItemMixin:IsItemEmpty() return not self.itemID end
function ItemMixin:IsItemDataCached() return self.itemID and IsCached(self.itemID) or false end
function ItemMixin:GetItemName() return C_Item.GetItemNameByID(self.itemID) end
function ItemMixin:GetItemLink() local r = Item and S.ItemRec(self.itemID) return r and ItemLink(r) end
function ItemMixin:GetItemQuality() return C_Item.GetItemQualityByID(self.itemID) end
function ItemMixin:GetItemIcon() return C_Item.GetItemIconByID(self.itemID) end
function ItemMixin:GetItemQualityColor() local q = self:GetItemQuality() return ITEM_QUALITY_COLORS[q or 1] end
function ItemMixin:ContinueOnItemLoad(cb)
    if self:IsItemDataCached() then cb() return end
    local id = self.itemID
    local f = CreateFrame("Frame")
    f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    f:SetScript("OnEvent", function(frame, _, loaded)
        if loaded == id then frame:UnregisterAllEvents(); cb() end
    end)
    RequestItem(id)
end
function ItemMixin:ContinueWithCancelOnItemLoad(cb)
    local cancelled = false
    self:ContinueOnItemLoad(function() if not cancelled then cb() end end)
    return function() cancelled = true end
end

---------------------------------------------------------------------------
-- Money and bags
---------------------------------------------------------------------------
function GetMoney() return math.floor(S.Player().money or 0) end
function S.AddMoney(delta, silent)
    local p = S.Player()
    p.money = math.max(0, math.floor((p.money or 0) + delta))
    S.FireEvent("PLAYER_MONEY")
    if delta > 0 and not silent then
        local text = "You loot " .. GetCoinText(delta)
        host.chat(text, 1, 1, 0)
        S.FireEvent("CHAT_MSG_MONEY", text)
    end
end

local function Bags()
    local bags = S.world.bags
    if next(bags) == nil then bags[0] = { size = 16, slots = {} } end
    return bags
end

C_Container = {}
function C_Container.GetContainerNumSlots(bag) local b = Bags()[bag] return b and b.size or 0 end
function C_Container.GetContainerNumFreeSlots(bag)
    local b = Bags()[bag]
    if not b then return 0, 0 end
    local used = 0
    for slot = 1, b.size do if b.slots[slot] then used = used + 1 end end
    return b.size - used, 0
end
function C_Container.GetContainerItemInfo(bag, slot)
    local b = Bags()[bag]
    local entry = b and b.slots and b.slots[slot]
    if not entry then return nil end
    local r = ItemRec(entry.id)
    return { iconFileID = r.icon, stackCount = entry.count or 1, isLocked = false, quality = r.quality, isReadable = false,
        hasLoot = false, hyperlink = ItemLink(r), isFiltered = false, hasNoValue = r.sellPrice == 0, itemID = r.id, isBound = false,
        itemName = r.name }
end
function C_Container.GetContainerItemID(bag, slot)
    local b = Bags()[bag]
    local entry = b and b.slots and b.slots[slot]
    return entry and entry.id
end
function C_Container.GetContainerItemLink(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    return info and info.hyperlink
end
function C_Container.GetBagName(bag) return bag == 0 and "Backpack" or ("Bag " .. bag) end
function C_Container.ContainerIDToInventoryID(bag) return 30 + bag end
function C_Container.GetSortBagsRightToLeft() return false end
function C_Container.SortBags() end
function C_Container.PickupContainerItem() S.Missing("C_Container.PickupContainerItem") end
function C_Container.SplitContainerItem() S.Missing("C_Container.SplitContainerItem") end
function C_Container.GetContainerItemCooldown() return 0, 0, 1 end
function C_Container.IsContainerFiltered() return false end
function C_Container.GetBagSlotFlag() return false end
NUM_BAG_SLOTS, NUM_TOTAL_EQUIPPED_BAG_SLOTS, BACKPACK_CONTAINER = 4, 5, 0

function C_Item.GetItemCount(item)
    local id = ItemID(item)
    if not id then return 0 end
    local total = 0
    for _, b in pairs(Bags()) do
        for slot = 1, b.size do
            local e = b.slots[slot]
            if e and e.id == id then total = total + (e.count or 1) end
        end
    end
    return total
end
GetItemCount = C_Item.GetItemCount

local function BagUpdate(bag)
    S.FireEvent("BAG_UPDATE", bag)
    C_Timer.After(0, function() S.FireEvent("BAG_UPDATE_DELAYED") end)
end

-- Adds items to the bags, stacking first. Returns how many didn't fit.
function S.AddItem(id, count, quiet)
    local r = ItemRec(id)
    if not r then return count end
    count = count or 1
    local left = count
    local touched = {}
    local bags = Bags()
    for bag = 0, 5 do
        local b = bags[bag]
        if b then
            for slot = 1, b.size do
                local e = b.slots[slot]
                if left > 0 and e and e.id == r.id and (e.count or 1) < r.stack then
                    local add = math.min(r.stack - (e.count or 1), left)
                    e.count = (e.count or 1) + add
                    left = left - add
                    touched[bag] = true
                end
            end
        end
    end
    for bag = 0, 5 do
        local b = bags[bag]
        if b then
            for slot = 1, b.size do
                if left > 0 and not b.slots[slot] then
                    local add = math.min(r.stack, left)
                    b.slots[slot] = { id = r.id, count = add }
                    left = left - add
                    touched[bag] = true
                end
            end
        end
    end
    for bag in pairs(touched) do BagUpdate(bag) end
    local got = count - left
    if got > 0 and not quiet then
        local text = ("You receive item: %s%s."):format(ItemLink(r), got > 1 and ("x" .. got) or "")
        host.chat(text, 0, 0.67, 0)
        S.FireEvent("CHAT_MSG_LOOT", text, UnitName("player"))
    end
    if left > 0 then
        host.chat("Inventory is full.", 1, 0.1, 0.1)
        S.FireEvent("UI_ERROR_MESSAGE", 0, "Inventory is full.")
    end
    return left
end

-- Removes up to `count` of an item. Returns how many were removed.
function S.RemoveItem(id, count)
    local removed = 0
    for bag, b in pairs(Bags()) do
        for slot = b.size, 1, -1 do
            local e = b.slots[slot]
            if e and e.id == id and removed < count then
                local take = math.min(e.count or 1, count - removed)
                e.count = (e.count or 1) - take
                removed = removed + take
                if e.count <= 0 then b.slots[slot] = nil end
                BagUpdate(bag)
            end
        end
    end
    return removed
end

-- Purchases, sales and crafts are answered by the server a moment later; the client sees money and bags change then.
local SERVER_DELAY = 0.1
local function Server(fn) C_Timer.After(SERVER_DELAY, fn) end
S.Server = Server

local function UIError(text)
    host.chat(text, 1, 0.1, 0.1)
    S.FireEvent("UI_ERROR_MESSAGE", 0, text)
end

---------------------------------------------------------------------------
-- Item tooltips
---------------------------------------------------------------------------
local Tooltip = S.Classes.GameTooltip.methods

local function SetTooltipItem(tt, id, extra)
    local r = ItemRec(id)
    if not r then return end
    local s = State(tt)
    tt:ClearLines()
    local c = ITEM_QUALITY_COLORS[r.quality] or ITEM_QUALITY_COLORS[1]
    tt:AddLine(r.name, c.r, c.g, c.b)
    if r.classID == 7 or r.reagent then tt:AddLine("Crafting Reagent", 0.4, 0.73, 1) end
    if extra then extra(tt, r) end
    if r.sellPrice and r.sellPrice > 0 then
        tt:AddDoubleLine("Sell Price:", GetMoneyString(r.sellPrice), 1, 1, 1, 1, 1, 1)
    end
    s.item = r.id
    S.TooltipPost(tt, Enum.TooltipDataType.Item, { type = Enum.TooltipDataType.Item, id = r.id, hyperlink = ItemLink(r),
        lines = {} })
    tt:Show()
    return true
end
S.SetTooltipItem = SetTooltipItem

function Tooltip:SetItemByID(id) return SetTooltipItem(self, tonumber(id)) end
function Tooltip:SetHyperlink(link)
    local id = ItemID(link)
    if id then return SetTooltipItem(self, id) end
    self:SetText(tostring(link))
end
function Tooltip:SetItemKey(itemID) return SetTooltipItem(self, itemID) end
function Tooltip:SetBagItem(bag, slot)
    local id = C_Container.GetContainerItemID(bag, slot)
    if id then return SetTooltipItem(self, id) end
end
function Tooltip:SetMerchantItem(index)
    local m = S.openMerchant
    local entry = m and m.items[index]
    if entry then return SetTooltipItem(self, entry.id) end
end
function Tooltip:SetLootItem(slot)
    local s = S.lootSlots and S.lootSlots[slot]
    if s and s.id and not s.cleared then return SetTooltipItem(self, s.id) end
end
function Tooltip:SetRecipeResultItem(recipeID)
    local recipe = S.FindRecipe(recipeID)
    if recipe then return SetTooltipItem(self, recipe.output) end
end
function Tooltip:SetRecipeReagentItem(recipeID, slotIndex)
    local recipe = S.FindRecipe(recipeID)
    local reagent = recipe and recipe.reagents[slotIndex]
    if reagent then return SetTooltipItem(self, reagent.id) end
end
function Tooltip:GetItem()
    local id = State(self).item
    if not id then return nil end
    local r = ItemRec(id)
    return r.name, ItemLink(r), r.id
end
function Tooltip:SetInventoryItem() S.Missing("GameTooltip:SetInventoryItem") end
function Tooltip:SetAuctionItem() S.Missing("GameTooltip:SetAuctionItem") end
function Tooltip:SetCurrencyToken() S.Missing("GameTooltip:SetCurrencyToken") end
function Tooltip:SetCompareItem() return false end

---------------------------------------------------------------------------
-- Stand-in panel helper
---------------------------------------------------------------------------
local function Panel(name, title, width, height, onClose)
    local f = CreateFrame("Frame", name, UIParent, "PortraitFrameTemplate")
    f:SetSize(width, height)
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
    f:SetFrameStrata("MEDIUM")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetTitle(title)
    f:Hide()
    f.CloseButton:SetScript("OnClick", onClose)
    table.insert(S.panels, { frame = f, close = onClose })
    return f
end

local function MoneyText(parent, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    return fs
end

---------------------------------------------------------------------------
-- Merchant
---------------------------------------------------------------------------
MERCHANT_ITEMS_PER_PAGE = 10
local function Merchant() return S.openMerchant end

function GetMerchantNumItems() local m = Merchant() return m and #m.items or 0 end
local function MerchantEntry(index) local m = Merchant() return m and m.items[index] end
function GetMerchantItemInfo(index)
    local e = MerchantEntry(index)
    if not e then return nil end
    local r = ItemRec(e.id)
    return r.name, r.icon, e.price or 0, e.stack or 1, e.available or -1, true, true, e.extendedCost or false, nil, nil
end
function GetMerchantItemID(index) local e = MerchantEntry(index) return e and e.id end
function GetMerchantItemLink(index) local e = MerchantEntry(index) return e and ItemLink(ItemRec(e.id)) end
function GetMerchantItemMaxStack(index) local e = MerchantEntry(index) return e and ItemRec(e.id).stack or 0 end
function GetMerchantItemCostInfo() return 0 end
function GetMerchantItemCostItem() return nil end
function GetNumBuybackItems() return 0 end
function GetBuybackItemInfo() return nil end
function GetBuybackItemLink() return nil end
function CanMerchantRepair() return false end
function GetRepairAllCost() return 0, false end
function MerchantFrame_UpdateBuybackInfo() end
C_MerchantFrame = {}
function C_MerchantFrame.GetItemInfo(index)
    local e = MerchantEntry(index)
    if not e then return nil end
    local r = ItemRec(e.id)
    return { name = r.name, texture = r.icon, price = e.price or 0, stackCount = e.stack or 1,
        numAvailable = e.available or -1, isPurchasable = true, isUsable = true, hasExtendedCost = e.extendedCost or false,
        currencyID = nil, spellID = nil, isQuestStartItem = false }
end
function C_MerchantFrame.IsMerchantItemRefundable() return false end
function C_MerchantFrame.GetBuybackItemID() return nil end
function C_MerchantFrame.GetNumJunkItems() return 0 end
function C_MerchantFrame.IsSellAllJunkEnabled() return false end

function BuyMerchantItem(index, quantity)
    local e = MerchantEntry(index)
    if not e then return end
    local stack = e.stack or 1
    quantity = quantity or stack
    if e.available and e.available >= 0 then quantity = math.min(quantity, e.available * stack) end
    if quantity <= 0 then UIError("That item is sold out.") return end
    local cost = math.floor((e.price or 0) * quantity / stack + 0.5)
    if cost > GetMoney() then UIError("You don't have enough money.") return end
    Server(function()
        local left = S.AddItem(e.id, quantity)
        local bought = quantity - left
        if bought <= 0 then return end
        S.AddMoney(-math.floor((e.price or 0) * bought / stack + 0.5))
        if e.available and e.available >= 0 then e.available = math.max(0, e.available - math.ceil(bought / stack)) end
        S.FireEvent("MERCHANT_UPDATE")
    end)
end

-- Selling: using a bag item while a merchant is open.
function C_Container.UseContainerItem(bag, slot)
    local b = Bags()[bag]
    local e = b and b.slots[slot]
    if not e then return end
    if not Merchant() then S.Missing("C_Container.UseContainerItem (outside a merchant)") return end
    local r = ItemRec(e.id)
    if not r.sellPrice or r.sellPrice <= 0 then UIError("The merchant doesn't want that item.") return end
    if e.locked then return end
    e.locked = true
    Server(function()
        if b.slots[slot] ~= e then return end
        b.slots[slot] = nil
        S.AddMoney(r.sellPrice * (e.count or 1), true)
        BagUpdate(bag)
        S.FireEvent("MERCHANT_UPDATE")
    end)
end
UseContainerItem = C_Container.UseContainerItem

local merchant = Panel("MerchantFrame", "Merchant", 336, 447, function() CloseMerchant() end)
merchant.page, merchant.selectedTab = 1, 1
local merchantPageText = merchant:CreateFontString("MerchantPageText", "OVERLAY", "GameFontNormalSmall")
merchantPageText:SetPoint("BOTTOM", merchant, "BOTTOM", 0, 34)
local function MerchantPage(delta)
    merchant.page = math.max(1, merchant.page + delta)
    MerchantFrame_UpdateMerchantInfo()
end
local prev = CreateFrame("Button", "MerchantPrevPageButton", merchant, "UIPanelButtonTemplate")
prev:SetSize(60, 22)
prev:SetPoint("BOTTOMLEFT", 20, 26)
prev:SetText("< Prev")
prev:SetScript("OnClick", function() MerchantPage(-1) end)
local nextButton = CreateFrame("Button", "MerchantNextPageButton", merchant, "UIPanelButtonTemplate")
nextButton:SetSize(60, 22)
nextButton:SetPoint("BOTTOMRIGHT", -20, 26)
nextButton:SetText("Next >")
nextButton:SetScript("OnClick", function() MerchantPage(1) end)
local hint = merchant:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("BOTTOM", 0, 10)
hint:SetText("Right-click an item to buy")

for i = 1, MERCHANT_ITEMS_PER_PAGE do
    local item = CreateFrame("Frame", "MerchantItem" .. i, merchant)
    item:SetSize(153, 44)
    local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
    item:SetPoint("TOPLEFT", merchant, "TOPLEFT", 11 + col * 160, -69 - row * 52)
    local button = CreateFrame("Button", "MerchantItem" .. i .. "ItemButton", item, "ItemButtonTemplate")
    button:SetPoint("TOPLEFT", 0, 0)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetMerchantItem(self:GetID())
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnClick", function(self, mouse)
        if mouse == "RightButton" then BuyMerchantItem(self:GetID(), 1) end
    end)
    item.ItemButton = button
    item.Name = item:CreateFontString("MerchantItem" .. i .. "Name", "OVERLAY", "GameFontNormalSmall")
    item.Name:SetPoint("TOPLEFT", button, "TOPRIGHT", 6, 0)
    item.Name:SetSize(105, 26)
    item.Name:SetJustifyH("LEFT")
    item.Name:SetJustifyV("TOP")
    item.Money = MoneyText(item)
    item.Money:SetPoint("BOTTOMLEFT", button, "BOTTOMRIGHT", 6, 0)
end

function MerchantFrame_UpdateMerchantInfo()
    local m = Merchant()
    local count = m and #m.items or 0
    local pages = math.max(1, math.ceil(count / MERCHANT_ITEMS_PER_PAGE))
    merchant.page = math.min(merchant.page, pages)
    merchant:SetTitle(m and m.name or "Merchant")
    for i = 1, MERCHANT_ITEMS_PER_PAGE do
        local index = (merchant.page - 1) * MERCHANT_ITEMS_PER_PAGE + i
        local item = _G["MerchantItem" .. i]
        local e = m and m.items[index]
        if e then
            local r = ItemRec(e.id)
            local c = ITEM_QUALITY_COLORS[r.quality] or ITEM_QUALITY_COLORS[1]
            item.Name:SetText(r.name)
            item.Name:SetTextColor(c.r, c.g, c.b)
            item.ItemButton:SetID(index)
            SetItemButtonTexture(item.ItemButton, r.icon)
            SetItemButtonCount(item.ItemButton, e.stack or 1)
            local money = GetMoneyString(e.price or 0)
            if e.available and e.available >= 0 then money = money .. (" |cffff8040(%d)|r"):format(e.available) end
            item.Money:SetText(money)
            item:Show()
        else
            item:Hide()
        end
    end
    merchantPageText:SetText(("Page %d of %d"):format(merchant.page, pages))
    prev:SetEnabled(merchant.page > 1)
    nextButton:SetEnabled(merchant.page < pages)
end

merchant:RegisterEvent("MERCHANT_SHOW")
merchant:RegisterEvent("MERCHANT_UPDATE")
merchant:RegisterEvent("MERCHANT_CLOSED")
merchant:SetScript("OnEvent", function(self, event)
    if event == "MERCHANT_SHOW" then
        self.page = 1
        ShowUIPanel(self)
        MerchantFrame_UpdateMerchantInfo()
    elseif event == "MERCHANT_UPDATE" then
        if self:IsShown() then MerchantFrame_UpdateMerchantInfo() end
    else
        HideUIPanel(self)
    end
end)

function S.OpenMerchant(index)
    local m = S.world.merchants[index]
    if not m then return end
    if S.openMerchant then CloseMerchant() end
    m.items = m.items or {}
    S.openMerchant = m
    S.FireEvent("MERCHANT_SHOW")
end
function CloseMerchant()
    if not S.openMerchant then return end
    S.FireEvent("MERCHANT_CLOSED")
    S.openMerchant = nil
end

---------------------------------------------------------------------------
-- Loot (retail-style loot window: LootFrame.ScrollBox elements with .Item and GetSlotIndex())
---------------------------------------------------------------------------
function GetNumLootItems() return S.lootSlots and #S.lootSlots or 0 end
local function LootSlotData(slot) return S.lootSlots and S.lootSlots[slot] end
function GetLootSlotType(slot)
    local s = LootSlotData(slot)
    if not s or s.cleared then return Enum.LootSlotType.None end
    return s.money and Enum.LootSlotType.Money or Enum.LootSlotType.Item
end
function LootSlotHasItem(slot) local s = LootSlotData(slot) return s ~= nil and not s.cleared and s.id ~= nil end
function GetLootSlotInfo(slot)
    local s = LootSlotData(slot)
    if not s or s.cleared then return nil end
    if s.money then return COIN_ICON, GetCoinText(s.money, "\n"), 0, nil, 0, false, false, nil, false end
    local r = ItemRec(s.id)
    return r.icon, r.name, s.count or 1, nil, r.quality, false, false, nil, false
end
function GetLootSlotLink(slot)
    local s = LootSlotData(slot)
    if s and s.id and not s.cleared then return ItemLink(ItemRec(s.id)) end
end
function GetLootSourceInfo(slot) return "Creature-0-0-0-0-1-0000000000", 1 end
function IsFishingLoot() return false end
function GetLootMethod() return "freeforall" end
function GetLootThreshold() return 2 end
function LootSlot(slot)
    local s = LootSlotData(slot)
    if not s or s.cleared then return end
    if s.money then S.AddMoney(s.money)
    else
        local left = S.AddItem(s.id, s.count or 1)
        if left > 0 then return end
    end
    s.cleared = true
    S.FireEvent("LOOT_SLOT_CLEARED", slot)
    for _, other in ipairs(S.lootSlots) do if not other.cleared then return end end
    CloseLoot()
end
function CloseLoot()
    if not S.lootSlots then return end
    S.FireEvent("LOOT_CLOSED")
    S.lootSlots = nil
end
function ConfirmLootSlot(slot) LootSlot(slot) end

local loot = CreateFrame("Frame", "LootFrame", UIParent, "PortraitFrameTemplate")
loot:SetSize(220, 300)
loot:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 380, -180)
loot:SetFrameStrata("HIGH")
loot:EnableMouse(true)
loot:SetTitle("Items")
loot:Hide()
loot.CloseButton:SetScript("OnClick", function() CloseLoot() end)
table.insert(S.panels, { frame = loot, close = function() CloseLoot() end })
local scrollBox = CreateFrame("Frame", nil, loot)
scrollBox:SetPoint("TOPLEFT", 10, -30)
scrollBox:SetPoint("BOTTOMRIGHT", -10, 10)
loot.ScrollBox = scrollBox
local lootElements = {}
local function LootElement(i)
    local e = lootElements[i]
    if e then return e end
    e = CreateFrame("Button", nil, scrollBox)
    e:SetSize(200, 42)
    e.Item = CreateFrame("Button", nil, e, "ItemButtonTemplate")
    e.Item:SetPoint("LEFT", 2, 0)
    e.Item:SetSize(36, 36)
    e.Text = e:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    e.Text:SetPoint("LEFT", e.Item, "RIGHT", 8, 0)
    e.Text:SetWidth(140)
    e.Text:SetJustifyH("LEFT")
    e.GetSlotIndex = function(self) return self.slotIndex end
    local function enter(self)
        local owner = self.Item or self
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        GameTooltip:SetLootItem(e.slotIndex)
        GameTooltip:Show()
    end
    e:SetScript("OnEnter", enter)
    e:SetScript("OnLeave", function() GameTooltip:Hide() end)
    e:SetScript("OnClick", function() LootSlot(e.slotIndex) end)
    e.Item:SetScript("OnEnter", function() enter(e) end)
    e.Item:SetScript("OnLeave", function() GameTooltip:Hide() end)
    e.Item:SetScript("OnClick", function() LootSlot(e.slotIndex) end)
    lootElements[i] = e
    return e
end
function scrollBox:ForEachFrame(fn)
    for _, e in ipairs(lootElements) do
        if e:IsShown() then fn(e, { slotIndex = e.slotIndex }) end
    end
end
function scrollBox:EnumerateFrames()
    local shown = {}
    for _, e in ipairs(lootElements) do if e:IsShown() then shown[#shown + 1] = e end end
    local i = 0
    return function() i = i + 1; return shown[i] end
end
function scrollBox:GetFrames() local out = {} for _, e in ipairs(lootElements) do if e:IsShown() then out[#out + 1] = e end end return out end

local function LootFrameUpdate()
    local n = 0
    for slot, s in ipairs(S.lootSlots or {}) do
        if not s.cleared then
            n = n + 1
            local e = LootElement(n)
            e.slotIndex = slot
            e:ClearAllPoints()
            e:SetPoint("TOPLEFT", scrollBox, "TOPLEFT", 0, -(n - 1) * 44)
            local texture, name, quantity, _, quality = GetLootSlotInfo(slot)
            SetItemButtonTexture(e.Item, texture)
            SetItemButtonCount(e.Item, quantity)
            local c = ITEM_QUALITY_COLORS[quality or 1] or ITEM_QUALITY_COLORS[1]
            e.Text:SetText(name)
            e.Text:SetTextColor(c.r, c.g, c.b)
            e:Show()
        end
    end
    for i = n + 1, #lootElements do lootElements[i]:Hide() end
    loot:SetHeight(40 + n * 44)
end
loot:RegisterEvent("LOOT_OPENED")
loot:RegisterEvent("LOOT_SLOT_CLEARED")
loot:RegisterEvent("LOOT_CLOSED")
loot:SetScript("OnEvent", function(self, event)
    if event == "LOOT_OPENED" then
        LootFrameUpdate()
        self:Show()
    elseif event == "LOOT_SLOT_CLEARED" then
        LootFrameUpdate()
    else
        self:Hide()
    end
end)

function S.OpenLoot(index)
    local preset = S.world.loot[index]
    if not preset then return end
    if S.lootSlots then CloseLoot() end
    local slots = {}
    if preset.money and preset.money > 0 then slots[#slots + 1] = { money = preset.money } end
    for _, item in ipairs(preset.items or {}) do slots[#slots + 1] = { id = item.id, count = item.count or 1 } end
    S.lootSlots = slots
    local auto = S.world.client.autoLoot and true or false
    S.FireEvent("LOOT_READY", auto)
    S.FireEvent("LOOT_OPENED", auto, false)
    if auto then
        for slot = 1, #slots do LootSlot(slot) end
    end
end

---------------------------------------------------------------------------
-- Auction House
---------------------------------------------------------------------------
Enum.ItemCommodityStatus = { Unknown = 0, Item = 1, Commodity = 2 }
local REPLICATE_THROTTLE = 15 * 60
local function IsCommodity(id) return ItemRec(id).stack > 1 end
local function Listings(id)
    local list = S.world.auctions[id] or {}
    local copy = {}
    for _, l in ipairs(list) do copy[#copy + 1] = { unitPrice = l[1], quantity = l[2] } end
    table.sort(copy, function(a, b) return a.unitPrice < b.unitPrice end)
    return copy
end

C_AuctionHouse = {}
local replicate, browse, commodityResults, itemResults = {}, {}, {}, {}
local nextAuctionID = 1000

function C_AuctionHouse.MakeItemKey(itemID, itemLevel, itemSuffix, battlePetSpeciesID)
    return { itemID = itemID, itemLevel = itemLevel or 0, itemSuffix = itemSuffix or 0, battlePetSpeciesID = battlePetSpeciesID or 0 }
end
function C_AuctionHouse.GetItemKeyInfo(key)
    local r = ItemRec(key and key.itemID)
    if not r then return nil end
    return { itemID = r.id, battlePetSpeciesID = 0, itemName = r.name, quality = r.quality, iconFileID = r.icon,
        isPet = false, isCommodity = IsCommodity(r.id), isEquipment = false }
end
function C_AuctionHouse.GetItemCommodityStatus(id)
    return IsCommodity(id) and Enum.ItemCommodityStatus.Commodity or Enum.ItemCommodityStatus.Item
end
function C_AuctionHouse.IsThrottledMessageSystemReady() return true end
function C_AuctionHouse.CloseAuctionHouse()
    if not S.ahOpen then return end
    S.ahOpen = false
    S.FireEvent("AUCTION_HOUSE_CLOSED")
end

function C_AuctionHouse.ReplicateItems()
    if not S.ahOpen then return end
    if S.lastReplicate and S.now - S.lastReplicate < REPLICATE_THROTTLE and not S.world.client.ahNoThrottle then
        S.Warn("C_AuctionHouse.ReplicateItems: throttled (once per 15 min); reset it from the dev panel")
        return
    end
    S.lastReplicate = S.now
    replicate = {}
    local ids = {}
    for id in pairs(S.world.auctions) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        for _, l in ipairs(S.world.auctions[id]) do
            nextAuctionID = nextAuctionID + 1
            replicate[#replicate + 1] = { id = id, count = l[2], buyout = l[1] * l[2], auctionID = nextAuctionID }
        end
    end
    -- The client streams the data and fires this several times.
    C_Timer.After(0.4, function() S.FireEvent("REPLICATE_ITEM_LIST_UPDATE") end)
    C_Timer.After(0.6, function() S.FireEvent("REPLICATE_ITEM_LIST_UPDATE") end)
end
function C_AuctionHouse.GetNumReplicateItems() return #replicate end
function C_AuctionHouse.GetReplicateItemInfo(index)
    local a = replicate[(tonumber(index) or -1) + 1]   -- 0-based, like the client
    if not a then return nil end
    local r = ItemRec(a.id)
    return r.name, r.icon, a.count, r.quality, true, r.minLevel, "PLAYER_LEVEL", 0, 0, a.buyout, 0, false, nil,
        "Seller", "Seller-" .. GetRealmName(), 0, r.id, true
end
function C_AuctionHouse.GetReplicateItemLink(index)
    local a = replicate[(tonumber(index) or -1) + 1]
    return a and ItemLink(ItemRec(a.id))
end
function C_AuctionHouse.GetReplicateItemTimeLeft() return 3 end
function C_AuctionHouse.GetReplicateItemBattlePetInfo() return nil end

local function BrowseEntry(id)
    local list = Listings(id)
    if #list == 0 then return nil end
    local total = 0
    for _, l in ipairs(list) do total = total + l.quantity end
    return { itemKey = C_AuctionHouse.MakeItemKey(id), totalQuantity = total, minPrice = list[1].unitPrice,
        containsOwnerItem = false, containsAccountItem = false }
end
local function DeliverBrowse(results)
    browse = results
    C_Timer.After(0.2, function() S.FireEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") end)
end
function C_AuctionHouse.SearchForItemKeys(keys, sorts)
    if not S.ahOpen then return end
    local results = {}
    for _, key in ipairs(keys or {}) do
        local e = key and BrowseEntry(key.itemID)
        if e then results[#results + 1] = e end
    end
    DeliverBrowse(results)
end
function C_AuctionHouse.SendBrowseQuery(query)
    if not S.ahOpen then return end
    local text = query and query.searchString and query.searchString:lower() or ""
    local results = {}
    for id in pairs(S.world.auctions) do
        if text == "" or ItemRec(id).name:lower():find(text, 1, true) then
            local e = BrowseEntry(id)
            if e then results[#results + 1] = e end
        end
    end
    table.sort(results, function(a, b) return a.minPrice < b.minPrice end)
    DeliverBrowse(results)
end
function C_AuctionHouse.GetBrowseResults() return CopyTable(browse) end
function C_AuctionHouse.GetNumBrowseResults() return #browse end
function C_AuctionHouse.HasFullBrowseResults() return true end
function C_AuctionHouse.RequestMoreBrowseResults() end
function C_AuctionHouse.HasSearchResults(key) return itemResults[key and key.itemID] ~= nil end

function C_AuctionHouse.SendSearchQuery(itemKey, sorts, separateOwnerItems)
    if not S.ahOpen or not itemKey then return end
    local id = itemKey.itemID
    local list = Listings(id)
    for _, l in ipairs(list) do nextAuctionID = nextAuctionID + 1; l.auctionID = nextAuctionID end
    if IsCommodity(id) then
        commodityResults[id] = list
        C_Timer.After(0.2, function() S.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", id) end)
    else
        itemResults[id] = list
        C_Timer.After(0.2, function() S.FireEvent("ITEM_SEARCH_RESULTS_UPDATED", itemKey, nil) end)
    end
end
C_AuctionHouse.SendSellSearchQuery = C_AuctionHouse.SendSearchQuery
function C_AuctionHouse.GetNumCommoditySearchResults(id) return commodityResults[id] and #commodityResults[id] or 0 end
function C_AuctionHouse.GetCommoditySearchResultInfo(id, index)
    local l = commodityResults[id] and commodityResults[id][index]
    if not l then return nil end
    return { itemID = id, quantity = l.quantity, unitPrice = l.unitPrice, auctionID = l.auctionID, owners = {},
        totalNumberOfOwners = 1, timeLeftSeconds = 43200, numOwnerItems = 0, containsOwnerItem = false,
        containsAccountItem = false }
end
function C_AuctionHouse.HasFullCommoditySearchResults() return true end
function C_AuctionHouse.RequestMoreCommoditySearchResults() return false end
function C_AuctionHouse.GetNumItemSearchResults(key) local l = key and itemResults[key.itemID] return l and #l or 0 end
function C_AuctionHouse.GetItemSearchResultInfo(key, index)
    local l = key and itemResults[key.itemID] and itemResults[key.itemID][index]
    if not l then return nil end
    return { itemKey = key, owners = {}, totalNumberOfOwners = 1, timeLeft = 3, auctionID = l.auctionID,
        quantity = l.quantity, itemLink = ItemLink(ItemRec(key.itemID)), containsOwnerItem = false, containsAccountItem = false,
        containsSocketedItem = false, minBid = 0, bidAmount = 0, buyoutAmount = l.unitPrice * l.quantity,
        timeLeftSeconds = 43200 }
end
function C_AuctionHouse.HasFullItemSearchResults() return true end
function C_AuctionHouse.RequestMoreItemSearchResults() return false end
function C_AuctionHouse.GetAuctionHouseItemListingNumItemResults() return 0 end
for _, name in ipairs({ "PostItem", "PostCommodity", "CancelAuction", "QueryOwnedAuctions", "QueryBids" }) do
    C_AuctionHouse[name] = S.Stub("C_AuctionHouse." .. name)
end
-- Buying: removes the cheapest listings first. Returns the total price, or nil if not enough is listed.
local function PriceFor(itemID, quantity)
    local total, left = 0, quantity
    for _, l in ipairs(Listings(itemID)) do
        local take = math.min(l.quantity, left)
        total = total + take * l.unitPrice
        left = left - take
        if left == 0 then return total end
    end
end
local function TakeListings(itemID, quantity)
    local list = S.world.auctions[itemID] or {}
    table.sort(list, function(a, b) return a[1] < b[1] end)
    local left = quantity
    for i = 1, #list do
        local take = math.min(list[i][2], left)
        list[i][2] = list[i][2] - take
        left = left - take
    end
    for i = #list, 1, -1 do if list[i][2] <= 0 then table.remove(list, i) end end
    if #list == 0 then S.world.auctions[itemID] = nil end
end

local commodityPurchase
function C_AuctionHouse.StartCommoditiesPurchase(itemID, quantity)
    if not S.ahOpen then return end
    local total = PriceFor(itemID, quantity)
    commodityPurchase = { itemID = itemID, quantity = quantity, total = total }
    Server(function()
        if total then S.FireEvent("COMMODITY_PRICE_UPDATED", math.ceil(total / quantity), total) end
    end)
end
function C_AuctionHouse.ConfirmCommoditiesPurchase(itemID, quantity)
    local p = commodityPurchase
    commodityPurchase = nil
    Server(function()
        local total = p and p.itemID == itemID and PriceFor(itemID, quantity)
        if not total or total > GetMoney() then
            UIError(total and "You don't have enough money." or "Not enough listed.")
            S.FireEvent("COMMODITY_PURCHASE_FAILED")
            return
        end
        TakeListings(itemID, quantity)
        S.AddMoney(-total)
        S.AddItem(itemID, quantity)
        S.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    end)
end
function C_AuctionHouse.CancelCommoditiesPurchase() commodityPurchase = nil end

-- Buyout of a non-commodity auction from the last item search.
function C_AuctionHouse.PlaceBid(auctionID, bidAmount)
    for itemID, list in pairs(itemResults) do
        for i, l in ipairs(list) do
            if l.auctionID == auctionID then
                Server(function()
                    if bidAmount > GetMoney() then UIError("You don't have enough money.") return end
                    table.remove(list, i)
                    TakeListings(itemID, l.quantity)
                    S.AddMoney(-bidAmount)
                    S.AddItem(itemID, l.quantity)
                    S.FireEvent("AUCTION_HOUSE_PURCHASE_COMPLETED", auctionID)
                end)
                return
            end
        end
    end
    UIError("That auction is gone.")
end

-- Dev panel: buy the way the AH window does (commodities: start, see the price, confirm; items: search, buy out).
function S.BuyFromAH(itemID, quantity)
    if not S.ahOpen then S.Warn("Open the Auction House first") return end
    if IsCommodity(itemID) then
        C_AuctionHouse.StartCommoditiesPurchase(itemID, quantity)
        C_Timer.After(0.3, function() C_AuctionHouse.ConfirmCommoditiesPurchase(itemID, quantity) end)
    else
        local key = C_AuctionHouse.MakeItemKey(itemID)
        C_AuctionHouse.SendSearchQuery(key, {}, true)
        C_Timer.After(0.4, function()
            local info = C_AuctionHouse.GetItemSearchResultInfo(key, 1)
            if info then C_AuctionHouse.PlaceBid(info.auctionID, info.buyoutAmount) else S.Warn("Nothing listed") end
        end)
    end
end

function C_AuctionHouse.GetNumOwnedAuctions() return 0 end
function C_AuctionHouse.GetOwnedAuctionInfo() return nil end
function C_AuctionHouse.GetCancelCost() return 0 end
function C_AuctionHouse.CalculateCommodityDeposit() return 0 end
function C_AuctionHouse.CalculateItemDeposit() return 0 end

local ah = Panel("AuctionHouseFrame", "Auction House", 640, 440, function() C_AuctionHouse.CloseAuctionHouse() end)
ah.summary = ah:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
ah.summary:SetPoint("TOPLEFT", 20, -70)
ah.summary:SetJustifyH("LEFT")
ah.list = ah:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ah.list:SetPoint("TOPLEFT", 20, -100)
ah.list:SetPoint("RIGHT", -20, 0)
ah.list:SetJustifyH("LEFT")
ah.list:SetJustifyV("TOP")
ah.list:SetSpacing(3)
local function UpdateAHSummary()
    local items, listings = 0, 0
    local cheapest = {}
    for id, list in pairs(S.world.auctions) do
        items = items + 1
        listings = listings + #list
        local e = BrowseEntry(id)
        if e then cheapest[#cheapest + 1] = { id = id, min = e.minPrice, qty = e.totalQuantity } end
    end
    table.sort(cheapest, function(a, b) return ItemRec(a.id).name < ItemRec(b.id).name end)
    ah.summary:SetText(("Sandbox AH: %d listings for %d items"):format(listings, items))
    local lines = {}
    for i = 1, math.min(#cheapest, 16) do
        local c = cheapest[i]
        lines[#lines + 1] = ("%s  |cffffffffx%d|r  from %s"):format(ItemLink(ItemRec(c.id)), c.qty, GetMoneyString(c.min))
    end
    if #cheapest > 16 then lines[#lines + 1] = ("|cff888888... and %d more|r"):format(#cheapest - 16) end
    ah.list:SetText(table.concat(lines, "\n"))
end
ah:RegisterEvent("AUCTION_HOUSE_SHOW")
ah:RegisterEvent("AUCTION_HOUSE_CLOSED")
ah:SetScript("OnEvent", function(self, event)
    if event == "AUCTION_HOUSE_SHOW" then UpdateAHSummary(); ShowUIPanel(self) else HideUIPanel(self) end
end)

function S.OpenAH()
    if S.ahOpen then return end
    S.ahOpen = true
    S.FireEvent("AUCTION_HOUSE_SHOW")
end
function S.ResetAHThrottle() S.lastReplicate = nil end

---------------------------------------------------------------------------
-- Professions
---------------------------------------------------------------------------
local function Professions() return S.world.professions end
function S.FindRecipe(recipeID)
    recipeID = tonumber(recipeID)
    for name, prof in pairs(Professions()) do
        local r = prof.recipes and prof.recipes[recipeID]
        if r then return r, name, prof end
    end
end
local FindRecipe = S.FindRecipe

local function ProfessionInfo(name)
    local prof = name and Professions()[name]
    if not prof then return nil end
    return { professionID = prof.skillLineID or 185, professionName = name, skillLevel = prof.skillLevel or 1,
        maxSkillLevel = prof.maxSkillLevel or 300, skillModifier = 0, isPrimaryProfession = not prof.secondary,
        parentProfessionID = nil, parentProfessionName = name, expansionName = "Forever", displayName = name,
        profession = prof.profession }
end

local function CraftableCount(recipe)
    local n = math.huge
    for _, reagent in ipairs(recipe.reagents or {}) do
        n = math.min(n, math.floor(GetItemCount(reagent.id) / math.max(reagent.qty or 1, 1)))
    end
    return n == math.huge and 0 or n
end

C_TradeSkillUI = {}
function C_TradeSkillUI.GetAllRecipeIDs()
    local prof = S.openProfession and Professions()[S.openProfession]
    local ids = {}
    if prof then for id in pairs(prof.recipes or {}) do ids[#ids + 1] = id end end
    table.sort(ids)
    return ids
end
C_TradeSkillUI.GetFilteredRecipeIDs = C_TradeSkillUI.GetAllRecipeIDs
function C_TradeSkillUI.GetRecipeInfo(recipeID)
    local r = FindRecipe(recipeID)
    if not r then return nil end
    local craftable = CraftableCount(r)
    return { recipeID = tonumber(recipeID), name = r.name, learned = r.learned and true or false,
        icon = r.icon or ItemRec(r.output).icon, craftable = r.learned and true or false, disabled = false,
        isRecraft = false, isDummyRecipe = false, categoryID = 0, numAvailable = craftable, hyperlink = nil,
        firstCraft = false, supportsQualities = false, isEnchantingRecipe = false, sourceType = r.learned and 1 or 2,
        favorite = false, alternateVerb = nil, numSkillUps = 1, relativeDifficulty = 1, maxQuality = 0 }
end
function C_TradeSkillUI.GetRecipeSchematic(recipeID, isRecraft)
    local r = FindRecipe(recipeID)
    if not r then return nil end
    local slots = {}
    for i, reagent in ipairs(r.reagents or {}) do
        slots[i] = { slotIndex = i, reagents = { { itemID = reagent.id } }, quantityRequired = reagent.qty or 1,
            reagentType = Enum.CraftingReagentType.Basic, required = true, dataSlotType = 1, dataSlotIndex = i }
    end
    return { recipeID = tonumber(recipeID), name = r.name, icon = r.icon or ItemRec(r.output).icon, outputItemID = r.output,
        quantityMin = r.qmin or 1, quantityMax = r.qmax or r.qmin or 1, reagentSlotSchematics = slots,
        recipeType = Enum.TradeskillRecipeType.Item, isRecraft = false, hasCraftingOperationInfo = false }
end
function C_TradeSkillUI.GetRecipeSourceText(recipeID) local r = FindRecipe(recipeID) return r and r.source end
function C_TradeSkillUI.GetBaseProfessionInfo() return ProfessionInfo(S.openProfession) end
C_TradeSkillUI.GetChildProfessionInfo = C_TradeSkillUI.GetBaseProfessionInfo
function C_TradeSkillUI.GetProfessionInfoByRecipeID(recipeID) return ProfessionInfo(select(2, FindRecipe(recipeID))) end
function C_TradeSkillUI.IsTradeSkillReady() return S.openProfession ~= nil end
function C_TradeSkillUI.IsTradeSkillLinked() return false end
function C_TradeSkillUI.IsTradeSkillGuild() return false end
function C_TradeSkillUI.IsTradeSkillGuildMember() return false end
function C_TradeSkillUI.IsNPCCrafting() return false end
function C_TradeSkillUI.IsRuneforging() return false end
function C_TradeSkillUI.IsRecipeProfessionLearned(recipeID) return FindRecipe(recipeID) ~= nil end
function C_TradeSkillUI.GetRecipeOutputItemData(recipeID)
    local r = FindRecipe(recipeID)
    if r then return { itemID = r.output, hyperlink = ItemLink(ItemRec(r.output)) } end
end
function C_TradeSkillUI.GetRecipeLink(recipeID)
    local r = FindRecipe(recipeID)
    return r and ("|cffffd000|Henchant:%d|h[%s]|h|r"):format(recipeID, r.name)
end
function C_TradeSkillUI.GetRecipeNumReagents(recipeID) local r = FindRecipe(recipeID) return r and #r.reagents or 0 end
function C_TradeSkillUI.GetCraftableCount(recipeID) local r = FindRecipe(recipeID) return r and CraftableCount(r) or 0 end
function C_TradeSkillUI.GetTradeSkillLine()
    local info = ProfessionInfo(S.openProfession)
    if info then return info.professionID, info.professionName, info.skillLevel, info.maxSkillLevel end
end
GetTradeSkillLine = function()
    local info = ProfessionInfo(S.openProfession)
    if info then return info.professionName, info.skillLevel, info.maxSkillLevel end
    return "UNKNOWN", 0, 0
end

local professions = Panel("ProfessionsFrame", "Professions", 560, 460, function() C_TradeSkillUI.CloseTradeSkill() end)
professions:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -96)
local recipeScroll = CreateFrame("ScrollFrame", "ProfessionsFrameRecipeScroll", professions, "UIPanelScrollFrameTemplate")
recipeScroll:SetPoint("TOPLEFT", 12, -64)
recipeScroll:SetPoint("BOTTOMLEFT", 12, 12)
recipeScroll:SetWidth(230)
local recipeList = CreateFrame("Frame", nil, recipeScroll)
recipeList:SetSize(230, 10)
recipeScroll:SetScrollChild(recipeList)
local recipeRows = {}
local detail = professions:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
detail:SetPoint("TOPLEFT", 280, -70)
detail:SetPoint("RIGHT", -16, 0)
detail:SetJustifyH("LEFT")
detail:SetJustifyV("TOP")
detail:SetSpacing(3)
local craftButton = CreateFrame("Button", "ProfessionsFrameCraftButton", professions, "UIPanelButtonTemplate")
craftButton:SetSize(100, 22)
craftButton:SetPoint("BOTTOMRIGHT", -16, 16)
craftButton:SetText("Create")
professions.selected = nil

local function UpdateDetail()
    local r = professions.selected and FindRecipe(professions.selected)
    if not r then detail:SetText("|cff888888Select a recipe.|r"); craftButton:Disable() return end
    local lines = { "|cffffd100" .. r.name .. "|r" .. (r.learned and "" or "  |cffff8040(not learned)|r"), "" }
    local qty = (r.qmin == r.qmax or not r.qmax) and tostring(r.qmin or 1) or ("%d-%d"):format(r.qmin, r.qmax)
    lines[#lines + 1] = ("Makes %sx %s"):format(qty, ItemLink(ItemRec(r.output)))
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cffffd100Reagents|r"
    for _, reagent in ipairs(r.reagents or {}) do
        local have = GetItemCount(reagent.id)
        local color = have >= (reagent.qty or 1) and "|cffffffff" or "|cffff5050"
        lines[#lines + 1] = ("%s%d/%d|r %s"):format(color, have, reagent.qty or 1, ItemLink(ItemRec(reagent.id)))
    end
    if not r.learned and r.source then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "|cffffd100Source|r"
        lines[#lines + 1] = r.source
    end
    detail:SetText(table.concat(lines, "\n"))
    craftButton:SetEnabled(r.learned and CraftableCount(r) > 0)
end

local function UpdateRecipeList()
    local ids = C_TradeSkillUI.GetAllRecipeIDs()
    table.sort(ids, function(a, b)
        local ra, rb = FindRecipe(a), FindRecipe(b)
        if (ra.learned and 1 or 0) ~= (rb.learned and 1 or 0) then return ra.learned and true or false end
        return ra.name < rb.name
    end)
    for i, id in ipairs(ids) do
        local row = recipeRows[i]
        if not row then
            row = CreateFrame("Button", nil, recipeList)
            row:SetSize(226, 18)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * 18)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            row:SetNormalFontObject(GameFontHighlightSmallLeft)
            row:SetText(" ")
            row:GetFontString():ClearAllPoints()
            row:GetFontString():SetPoint("LEFT", 4, 0)
            row:GetFontString():SetPoint("RIGHT", -4, 0)
            row:GetFontString():SetWordWrap(false)
            row:SetScript("OnClick", function(self)
                professions.selected = self.recipeID
                S.FireEvent("TRADE_SKILL_ITEM_SELECTED", self.recipeID)
                UpdateDetail()
            end)
            recipeRows[i] = row
        end
        local r = FindRecipe(id)
        row.recipeID = id
        local count = CraftableCount(r)
        row:SetText((r.learned and "" or "|cff808080") .. r.name .. (count > 0 and r.learned and (" [" .. count .. "]") or ""))
        if professions.selected == id then row:LockHighlight() else row:UnlockHighlight() end
        row:Show()
    end
    for i = #ids + 1, #recipeRows do recipeRows[i]:Hide() end
    recipeList:SetHeight(math.max(#ids * 18, 1))
    UpdateDetail()
end

function C_TradeSkillUI.CraftRecipe(recipeID, count)
    local r = FindRecipe(recipeID)
    if not r or not r.learned then return end
    count = math.min(count or 1, CraftableCount(r))
    for n = 1, count do
        -- Like the client: the cast succeeds, then reagents leave and the product arrives.
        C_Timer.After((n - 1) * 0.5, function()
            if CraftableCount(r) < 1 then return end
            S.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", ("Cast-3-0-0-0-%d-%08X"):format(recipeID, math.random(0, 0x7fffffff)), tonumber(recipeID))
            Server(function()
                for _, reagent in ipairs(r.reagents or {}) do S.RemoveItem(reagent.id, reagent.qty or 1) end
                S.AddItem(r.output, math.random(r.qmin or 1, r.qmax or r.qmin or 1))
                S.FireEvent("TRADE_SKILL_LIST_UPDATE")
                if n == count then S.FireEvent("UPDATE_TRADESKILL_CAST_COMPLETE", false) end
            end)
        end)
    end
end
craftButton:SetScript("OnClick", function()
    if professions.selected then C_TradeSkillUI.CraftRecipe(professions.selected, 1) end
end)

professions:RegisterEvent("TRADE_SKILL_SHOW")
professions:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
professions:RegisterEvent("TRADE_SKILL_CLOSE")
professions:RegisterEvent("BAG_UPDATE_DELAYED")
professions:SetScript("OnEvent", function(self, event)
    if event == "TRADE_SKILL_SHOW" then
        local info = ProfessionInfo(S.openProfession)
        self:SetTitle(("%s (%d/%d)"):format(info.professionName, info.skillLevel, info.maxSkillLevel))
        ShowUIPanel(self)
        UpdateRecipeList()
    elseif event == "TRADE_SKILL_CLOSE" then
        HideUIPanel(self)
    elseif self:IsShown() then
        UpdateRecipeList()
    end
end)

function S.OpenProfession(name, recipeID)
    if not Professions()[name] then return end
    if S.openProfession and S.openProfession ~= name then C_TradeSkillUI.CloseTradeSkill() end
    local wasOpen = S.openProfession == name
    S.openProfession = name
    if recipeID then professions.selected = recipeID end
    if not wasOpen then
        S.FireEvent("TRADE_SKILL_SHOW")
        C_Timer.After(0.1, function()
            if S.openProfession == name then
                S.FireEvent("TRADE_SKILL_DATA_SOURCE_CHANGED")
                S.FireEvent("TRADE_SKILL_LIST_UPDATE")
            end
        end)
    else
        UpdateRecipeList()
    end
end
function C_TradeSkillUI.CloseTradeSkill()
    if not S.openProfession then return end
    S.FireEvent("TRADE_SKILL_CLOSE")
    S.openProfession = nil
end
function C_TradeSkillUI.OpenRecipe(recipeID)
    local _, name = FindRecipe(recipeID)
    if name then S.OpenProfession(name, tonumber(recipeID)) end
end
function C_TradeSkillUI.OpenTradeSkill(skillLineID)
    for name, prof in pairs(Professions()) do
        if prof.skillLineID == skillLineID then S.OpenProfession(name) return true end
    end
    return false
end
function C_TradeSkillUI.SetRecipeItemNameFilter() end
function C_TradeSkillUI.SetShowLearned() end
function C_TradeSkillUI.SetShowUnlearned() end
function C_TradeSkillUI.GetCategories() return {} end
function C_TradeSkillUI.GetCategoryInfo() return nil end

function GetProfessions()
    local names = {}
    for name in pairs(Professions()) do names[#names + 1] = name end
    table.sort(names)
    return names[1] and 1 or nil, names[2] and 2 or nil, nil, nil, nil
end
function GetProfessionInfo(index)
    local names = {}
    for name in pairs(Professions()) do names[#names + 1] = name end
    table.sort(names)
    local name = names[index]
    local info = ProfessionInfo(name)
    if not info then return nil end
    local count = 0
    for _ in pairs(Professions()[name].recipes or {}) do count = count + 1 end
    return name, 136243, info.skillLevel, info.maxSkillLevel, count, 0, info.professionID, 0, 0, 0
end

---------------------------------------------------------------------------
-- Dev panel actions
---------------------------------------------------------------------------
function S.SetCombat(on)
    on = on and true or false
    if (S.Player().inCombat or false) == on then return end
    S.Player().inCombat = on
    S.FireEvent(on and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
end

-- What the dev panel shows about open windows.
function S.GameStateJSON()
    return S.JSON({
        merchant = S.openMerchant and S.openMerchant.name or false,
        ah = S.ahOpen or false,
        loot = S.lootSlots ~= nil,
        profession = S.openProfession or false,
        mail = S.mailOpen or false,
        mailCount = #(S.world.mail or {}),
        combat = S.Player().inCombat or false,
        money = GetMoney(),
        ahThrottle = S.lastReplicate and math.max(0, math.floor(REPLICATE_THROTTLE - (S.now - S.lastReplicate))) or 0,
    })
end

---------------------------------------------------------------------------
-- Mail (inbox API + a stand-in mailbox). Mails live in S.world.mail:
-- { sender, subject, money, items = { {id, count} }, invoice = { type, item, buyer, bid, buyout, deposit, consignment, count } }
---------------------------------------------------------------------------
local function Mails()
    S.world.mail = S.world.mail or {}
    return S.world.mail
end
local function MailUpdated()
    S.FireEvent("MAIL_INBOX_UPDATE")
    S.FireEvent("UPDATE_PENDING_MAIL")
end
local function DropIfEmpty(index)
    local m = Mails()[index]
    if m and (m.money or 0) == 0 and #(m.items or {}) == 0 then table.remove(Mails(), index) end
end

function GetInboxNumItems() local n = #Mails() return n, n end
function GetInboxHeaderInfo(index)
    local m = Mails()[index]
    if not m then return nil end
    local items = #(m.items or {})
    return m.invoice and 133784 or 133468, nil, m.sender or "?", m.subject or "", m.money or 0, 0, 30,
        items > 0 and items or nil, m.read or false, false, false, true, false
end
function GetInboxInvoiceInfo(index)
    local inv = Mails()[index] and Mails()[index].invoice
    if not inv then return nil end
    return inv.type, inv.item, inv.buyer, inv.bid, inv.buyout, inv.deposit or 0, inv.consignment or 0, 0, 0, inv.count, false
end
function GetInboxText(index)
    local m = Mails()[index]
    if not m then return nil end
    m.read = true
    return m.body or "", nil, nil, false, false
end
function GetInboxItem(index, attachment)
    local a = Mails()[index] and Mails()[index].items and Mails()[index].items[attachment]
    if not a then return nil end
    local r = ItemRec(a.id)
    return r.name, r.id, r.icon, a.count or 1, r.quality, true
end
function GetInboxItemLink(index, attachment)
    local a = Mails()[index] and Mails()[index].items and Mails()[index].items[attachment]
    return a and ItemLink(ItemRec(a.id))
end
function HasNewMail() for _, m in ipairs(Mails()) do if not m.read then return true end end return false end
function CheckInbox() MailUpdated() end
function InboxItemCanDelete() return true end
function GetLatestThreeSenders() local m = Mails() return m[1] and m[1].sender, m[2] and m[2].sender, m[3] and m[3].sender end

-- The server answers each request a moment later, by mail index at the time of the request, like the client.
function TakeInboxMoney(index)
    local m = Mails()[index]
    if not m or (m.money or 0) == 0 then return end
    Server(function()
        local i = tIndexOf(Mails(), m)
        if not i or (m.money or 0) == 0 then return end
        local money = m.money
        m.money = 0
        S.AddMoney(money, true)
        DropIfEmpty(i)
        MailUpdated()
    end)
end
function TakeInboxItem(index, attachment)
    local m = Mails()[index]
    if not m or not (m.items or {})[attachment or 1] then return end
    Server(function()
        local i = tIndexOf(Mails(), m)
        local a = i and table.remove(m.items, attachment or 1)
        if not a then return end
        S.AddItem(a.id, a.count or 1)
        DropIfEmpty(i)
        MailUpdated()
    end)
end
function AutoLootMailItem(index)
    local m = Mails()[index]
    if not m then return end
    Server(function()
        local i = tIndexOf(Mails(), m)
        if not i then return end
        if (m.money or 0) > 0 then S.AddMoney(m.money, true); m.money = 0 end
        for _, a in ipairs(m.items or {}) do S.AddItem(a.id, a.count or 1) end
        m.items = {}
        table.remove(Mails(), i)
        MailUpdated()
    end)
end
function DeleteInboxItem(index)
    if Mails()[index] then table.remove(Mails(), index); MailUpdated() end
end
function ReturnInboxItem(index) DeleteInboxItem(index) end
function CloseMail()
    if not S.mailOpen then return end
    S.mailOpen = false
    S.FireEvent("MAIL_CLOSED")
end

local mailbox = Panel("MailFrame", "Inbox", 338, 424, function() CloseMail() end)
local MAIL_ROWS = 7
local mailRows = {}
local mailEmpty = mailbox:CreateFontString(nil, "OVERLAY", "GameFontDisable")
mailEmpty:SetPoint("CENTER")
mailEmpty:SetText("No mail")
for i = 1, MAIL_ROWS do
    local row = CreateFrame("Button", "MailItem" .. i, mailbox)
    row:SetSize(306, 42)
    row:SetPoint("TOPLEFT", 16, -66 - (i - 1) * 46)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.icon = CreateFrame("Button", "MailItem" .. i .. "Button", row, "ItemButtonTemplate")
    row.icon:SetSize(36, 36)
    row.icon:SetPoint("LEFT", 2, 0)
    row.icon:EnableMouse(false)
    row.sender = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.sender:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -2)
    row.subject = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.subject:SetPoint("TOPLEFT", row.sender, "BOTTOMLEFT", 0, -3)
    row.subject:SetWidth(170)
    row.subject:SetJustifyH("LEFT")
    row.subject:SetWordWrap(false)
    row.money = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.money:SetPoint("RIGHT", -6, 0)
    -- Click: take the money (or the items), like opening the mail and clicking the attachment.
    row:SetScript("OnClick", function(self)
        local _, _, _, _, money, _, _, items = GetInboxHeaderInfo(self.index)
        if money and money > 0 then TakeInboxMoney(self.index) elseif items then AutoLootMailItem(self.index) end
    end)
    mailRows[i] = row
end
local openAll = CreateFrame("Button", "OpenAllMail", mailbox, "UIPanelButtonTemplate")
openAll:SetSize(110, 22)
openAll:SetPoint("BOTTOM", 0, 14)
openAll:SetText("Open All")
-- Like Blizzard's Open All: one mail at a time, newest index first, waiting between requests.
openAll:SetScript("OnClick", function(self)
    self:Disable()
    local function step()
        local n = GetInboxNumItems()
        if n == 0 or not S.mailOpen then self:Enable() return end
        AutoLootMailItem(n)
        C_Timer.After(0.3, step)
    end
    step()
end)

local function UpdateMailbox()
    local n = GetInboxNumItems()
    for i = 1, MAIL_ROWS do
        local row = mailRows[i]
        local icon, _, sender, subject, money, _, _, items = GetInboxHeaderInfo(i)
        if icon then
            row.index = i
            SetItemButtonTexture(row.icon, icon)
            row.sender:SetText(sender)
            row.subject:SetText(subject)
            row.money:SetText(money > 0 and GetMoneyString(money) or (items and (items .. " item" .. (items > 1 and "s" or "")) or ""))
            row:Show()
        else
            row:Hide()
        end
    end
    mailEmpty:SetShown(n == 0)
    mailbox:SetTitle(("Inbox (%d)"):format(n))
end
mailbox:RegisterEvent("MAIL_SHOW")
mailbox:RegisterEvent("MAIL_INBOX_UPDATE")
mailbox:RegisterEvent("MAIL_CLOSED")
mailbox:SetScript("OnEvent", function(self, event)
    if event == "MAIL_SHOW" then ShowUIPanel(self); UpdateMailbox()
    elseif event == "MAIL_CLOSED" then HideUIPanel(self)
    elseif self:IsShown() then UpdateMailbox() end
end)

function S.OpenMail()
    if S.mailOpen then return end
    S.mailOpen = true
    S.FireEvent("MAIL_SHOW")
    MailUpdated()
end

-- Dev panel: post bag items on the AH and have them sell; the money arrives by mail like the client's
-- "Auction successful" invoice (5% cut, deposit refunded).
function S.SellOnAH(itemID, quantity, unitPrice, delay)
    local have = GetItemCount(itemID)
    if have < quantity then S.Warn(("You only have %d of item %d"):format(have, itemID)) return end
    S.RemoveItem(itemID, quantity)
    local r = ItemRec(itemID)
    local bid = math.floor(unitPrice * quantity + 0.5)
    local cut = math.floor(bid * 0.05 + 0.5)
    C_Timer.After(delay or 1, function()
        table.insert(Mails(), 1, { sender = GetZoneText() .. " Auction House", subject = "Auction successful: " .. r.name,
            money = bid - cut, items = {}, invoice = { type = "seller", item = r.name, buyer = "Buyer", bid = bid,
            buyout = bid, deposit = 0, consignment = cut, count = quantity } })
        host.chat(("A buyer has been found for your auction of %s."):format(r.name), 1, 1, 0)
        S.FireEvent("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", 1, r.name)
        MailUpdated()
    end)
end

---------------------------------------------------------------------------
-- Bags window (combined): right-click uses the item (sells it at a merchant), hover shows its tooltip.
---------------------------------------------------------------------------
local BAG_COLS = 8
local bagsFrame = CreateFrame("Frame", "ContainerFrameCombinedBags", UIParent, "PortraitFrameTemplate")
bagsFrame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -20, 60)
bagsFrame:SetFrameStrata("MEDIUM")
bagsFrame:SetToplevel(true)
bagsFrame:EnableMouse(true)
bagsFrame:SetTitle("Bags")
bagsFrame:Hide()
bagsFrame.money = bagsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
bagsFrame.money:SetPoint("BOTTOMRIGHT", -12, 10)
local bagButtons = {}
local function UpdateBags()
    local n = 0
    for bag = 0, 5 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            n = n + 1
            local b = bagButtons[n]
            if not b then
                b = CreateFrame("Button", "ContainerFrameCombinedBagsItem" .. n, bagsFrame, "ItemButtonTemplate")
                b:SetSize(36, 36)
                b:SetPoint("TOPLEFT", 12 + ((n - 1) % BAG_COLS) * 39, -30 - math.floor((n - 1) / BAG_COLS) * 39)
                b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                b:SetScript("OnEnter", function(self)
                    if not C_Container.GetContainerItemID(self.bag, self.slot) then return end
                    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                    GameTooltip:SetBagItem(self.bag, self.slot)
                    GameTooltip:Show()
                end)
                b:SetScript("OnLeave", function() GameTooltip:Hide() end)
                b:SetScript("OnClick", function(self, mouse)
                    if mouse == "RightButton" then C_Container.UseContainerItem(self.bag, self.slot) end
                end)
                bagButtons[n] = b
            end
            b.bag, b.slot = bag, slot
            local info = C_Container.GetContainerItemInfo(bag, slot)
            SetItemButtonTexture(b, info and info.iconFileID)
            SetItemButtonCount(b, info and info.stackCount or 0)
            SetItemButtonDesaturated(b, info and info.isLocked)
            b:Show()
        end
    end
    for i = n + 1, #bagButtons do bagButtons[i]:Hide() end
    bagsFrame:SetSize(24 + BAG_COLS * 39 - 3, 60 + math.ceil(n / BAG_COLS) * 39)
    bagsFrame.money:SetText(GetMoneyString(GetMoney()))
end
bagsFrame:RegisterEvent("BAG_UPDATE_DELAYED")
bagsFrame:RegisterEvent("PLAYER_MONEY")
bagsFrame:SetScript("OnEvent", function(self) if self:IsShown() then UpdateBags() end end)
bagsFrame:SetScript("OnShow", UpdateBags)
tinsert(UISpecialFrames, "ContainerFrameCombinedBags")
function ToggleAllBags() bagsFrame:SetShown(not bagsFrame:IsShown()) end
function OpenAllBags() bagsFrame:Show() end
function CloseAllBags() bagsFrame:Hide() end
ToggleBackpack = ToggleAllBags
