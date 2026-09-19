-- Baked into the client patch by Bake-TransmogWardrobe.ps1 from modules/mod-transmog/client/TransmogWardrobe.
-- Do not edit this copy: change the source and bake again.
local TransmogWardrobe_ok, TransmogWardrobe_err = pcall(function()
--[[
    Transmog Wardrobe - client addon for mod-transmog (WoW 3.3.5a).

    Browse the appearances your character has collected, preview them on your character, search them by name
    and apply them to your equipped items. Applying needs Snooeepy (the transmogrifier NPC) nearby; browsing
    and previewing work anywhere.

    Open it with /tmog (or /wardrobe), or with the "Open Collection" option in Snooeepy's conversation.

    It talks to the server through the core's addon channel: every request is the chat command ".wardrobe ..."
    sent with the "AzerothCore" prefix, and every reply line comes back tagged (see README.md).
]]

local PREFIX = "AzerothCore"

local PAGE_SIZE = 24
local COLS, ROWS = 6, 4
local CELL, GAP = 40, 6

-- Equipment slots as the server numbers them (client inventory slot id = server slot + 1).
local SLOTS = {
    { slot = 0,  token = "HeadSlot",          name = "Head" },
    { slot = 2,  token = "ShoulderSlot",      name = "Shoulders" },
    { slot = 14, token = "BackSlot",          name = "Cloak" },
    { slot = 4,  token = "ChestSlot",         name = "Chest" },
    { slot = 3,  token = "ShirtSlot",         name = "Shirt" },
    { slot = 18, token = "TabardSlot",        name = "Tabard" },
    { slot = 8,  token = "WristSlot",         name = "Wrists" },
    { slot = 9,  token = "HandsSlot",         name = "Hands" },
    { slot = 5,  token = "WaistSlot",         name = "Waist" },
    { slot = 6,  token = "LegsSlot",          name = "Legs" },
    { slot = 7,  token = "FeetSlot",          name = "Feet" },
    { slot = 15, token = "MainHandSlot",      name = "Main Hand" },
    { slot = 16, token = "SecondaryHandSlot", name = "Off Hand" },
    { slot = 17, token = "RangedSlot",        name = "Ranged" },
}

-- Where each slot button sits: { x, y } from the window's top-left corner.
local SLOT_POS = {
    [0]  = { 24, -70 },  [2]  = { 24, -120 }, [14] = { 24, -170 }, [4]  = { 24, -220 },
    [3]  = { 24, -270 }, [18] = { 24, -320 }, [8]  = { 24, -370 },
    [9]  = { 340, -70 }, [5]  = { 340, -120 }, [6]  = { 340, -170 }, [7]  = { 340, -220 },
    [15] = { 135, -425 }, [16] = { 185, -425 }, [17] = { 235, -425 },
}

-- Result codes the server replies with (1..10 are the module's own TransmogStrings, 100+ are wardrobe results).
local RESULT_TEXT = {
    [1]   = "Transmogrified!",
    [2]   = "That slot is empty.",
    [3]   = "That appearance is not valid.",
    [4]   = "That appearance was not found.",
    [5]   = "Nothing is equipped in that slot.",
    [6]   = "That appearance can't be used on this item.",
    [7]   = "You don't have enough money.",
    [8]   = "You don't have enough tokens.",
    [9]   = "Look restored.",
    [10]  = "There is nothing to restore.",
    [100] = "Move next to Snooeepy first.",
    [101] = "That appearance is not in your collection.",
    [102] = "That slot can't be changed.",
    [103] = "The collection system is turned off on this server.",
    [104] = "This slot can't be hidden.",
}
local RESULT_OK = { [1] = true, [9] = true }

local floor = math.floor
local format = string.format

local state = {
    slot = nil,      -- selected server slot
    page = 1,
    pages = 1,
    total = 0,
    shown = 0,       -- item id the equipped item currently looks like (1 = hidden, 0 = none)
    search = "-",    -- "-" means no search
    ids = {},        -- item ids on the current page
    selected = nil,  -- item id chosen for preview
    near = false,    -- a Warpweaver is close enough to apply
    slots = {},      -- [slot] = { equipped, shown, flags, cost }
}

------------------------------------------------------------------------------------------------------------------------
-- Talking to the server
------------------------------------------------------------------------------------------------------------------------

local counter = 0
local pending = {}   -- [4 character request id] = { lines = {}, callback = fn, sentAt = time }

local function Send(command, callback)
    counter = (counter + 1) % 10000
    local id = format("%04d", counter)
    pending[id] = { lines = {}, callback = callback, sentAt = GetTime() }
    SendAddonMessage(PREFIX, "i" .. id .. command, "WHISPER", UnitName("player"))
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")

eventFrame:SetScript("OnEvent", function(self, event, prefix, message)
    if event ~= "CHAT_MSG_ADDON" or prefix ~= PREFIX or not message then
        return
    end
    local op = message:sub(1, 1)
    local id = message:sub(2, 5)
    local request = pending[id]
    if not request then
        return
    end
    if op == "m" then
        request.lines[#request.lines + 1] = message:sub(6)
    elseif op == "o" or op == "f" then
        pending[id] = nil
        if request.callback then
            request.callback(op == "o", request.lines)
        end
    end
    -- "a" (acknowledged) needs no action
end)

------------------------------------------------------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------------------------------------------------------

local function FormatMoney(copper)
    if not copper or copper <= 0 then
        return "Free"
    end
    local gold = floor(copper / 10000)
    local silver = floor((copper % 10000) / 100)
    local rest = copper % 100
    local parts = {}
    if gold > 0 then parts[#parts + 1] = "|cffffd700" .. gold .. "g|r" end
    if silver > 0 then parts[#parts + 1] = "|cffc7c7cf" .. silver .. "s|r" end
    if rest > 0 then parts[#parts + 1] = "|cffeda55f" .. rest .. "c|r" end
    return table.concat(parts, " ")
end

-- A hidden tooltip: asking it for an item we have never seen makes the client fetch that item from the server.
local scanTip = CreateFrame("GameTooltip", "TransmogWardrobeScanTip", UIParent, "GameTooltipTemplate")
local queried = {}

local function RequestItem(id)
    if id and not queried[id] then
        queried[id] = true
        scanTip:SetOwner(UIParent, "ANCHOR_NONE")
        scanTip:SetHyperlink("item:" .. id)
    end
end

-- Icon and quality of an item; either can be nil until the client has received the item.
local function ItemDetails(id)
    local name, link, quality, _, _, _, _, _, _, texture = GetItemInfo(id)
    if not texture and GetItemIcon then
        texture = GetItemIcon(id)
    end
    return texture, quality, name, link
end

------------------------------------------------------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------------------------------------------------------

local frame = CreateFrame("Frame", "TransmogWardrobeFrame", UIParent)
frame:SetSize(820, 520)
frame:SetPoint("CENTER")
frame:SetFrameStrata("HIGH")
frame:SetToplevel(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetClampedToScreen(true)
frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:Hide()
tinsert(UISpecialFrames, "TransmogWardrobeFrame")   -- Escape closes the window

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 24, -22)
title:SetText("Transmog Wardrobe")

local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", -6, -6)

-- Character preview -----------------------------------------------------------------------------------------------------

local model = CreateFrame("DressUpModel", "TransmogWardrobeModel", frame)
model:SetSize(250, 340)
model:SetPoint("TOPLEFT", 80, -62)
model:EnableMouse(true)
model:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
        self.dragging = true
        self.startX = GetCursorPosition()
        self.startFacing = self.facing or 0
    end
end)
model:SetScript("OnMouseUp", function(self)
    self.dragging = nil
end)
model:SetScript("OnUpdate", function(self)
    if self.dragging then
        local x = GetCursorPosition()
        self.facing = (self.startFacing or 0) + (x - (self.startX or x)) / 60
        self:SetFacing(self.facing)
    end
end)

local function ResetModel()
    model:SetUnit("player")
    model.facing = 0
    model:SetFacing(0)
end

local function PreviewItem(id)
    ResetModel()
    if id then
        RequestItem(id)
        model:TryOn("item:" .. id)
    end
end

-- Slot buttons ----------------------------------------------------------------------------------------------------------

local slotButtons = {}

local function UpdateSlotButton(entry)
    local button = entry.button
    local info = state.slots[entry.slot]
    local texture = GetInventoryItemTexture("player", entry.inventoryId)
    button.icon:SetTexture(texture or entry.emptyTexture)
    button.icon:SetDesaturated(not texture)
    if info and bit.band(info.flags, 4) ~= 0 then
        button.mark:Show()
    else
        button.mark:Hide()
    end
    if state.slot == entry.slot then
        button.selected:Show()
    else
        button.selected:Hide()
    end
    if info and info.equipped ~= 0 and bit.band(info.flags, 1) == 0 then
        button.icon:SetVertexColor(1, 0.35, 0.35)   -- equipped, but its look can't be changed
    else
        button.icon:SetVertexColor(1, 1, 1)
    end
end

local function UpdateAllSlotButtons()
    for _, entry in ipairs(slotButtons) do
        UpdateSlotButton(entry)
    end
end

-- Item grid -------------------------------------------------------------------------------------------------------------

local gridButtons = {}
local pageLabel, selectedText, costText, statusText, nearText
local applyButton, hideButton, restoreButton, restoreAllButton, prevButton, nextButton

local function SetStatus(text, good)
    if good then
        statusText:SetTextColor(0.3, 1, 0.3)
    else
        statusText:SetTextColor(1, 0.4, 0.4)
    end
    statusText:SetText(text or "")
end

local function UpdateButtons()
    local info = state.slot and state.slots[state.slot]
    local canApply = state.near and state.selected and info and bit.band(info.flags, 1) ~= 0
    if canApply then applyButton:Enable() else applyButton:Disable() end

    if state.near and info and bit.band(info.flags, 2) ~= 0 and state.shown ~= 1 then
        hideButton:Enable()
    else
        hideButton:Disable()
    end
    if state.near and info and bit.band(info.flags, 4) ~= 0 then
        restoreButton:Enable()
    else
        restoreButton:Disable()
    end

    local anyLook = false
    for _, slotInfo in pairs(state.slots) do
        if bit.band(slotInfo.flags, 4) ~= 0 then anyLook = true end
    end
    if state.near and anyLook then restoreAllButton:Enable() else restoreAllButton:Disable() end

    if state.page > 1 then prevButton:Enable() else prevButton:Disable() end
    if state.page < state.pages then nextButton:Enable() else nextButton:Disable() end

    if state.near then
        nearText:SetText("")
    else
        nearText:SetText("Move next to Snooeepy to apply looks. You can still browse and preview.")
    end
    costText:SetText(info and ("Cost: " .. FormatMoney(info.cost)) or "")
end

local function UpdateSelectedText()
    if not state.selected then
        selectedText:SetText("Click an appearance to preview it.")
        return
    end
    local _, _, name, link = ItemDetails(state.selected)
    selectedText:SetText(link or name or ("Item " .. state.selected))
end

local function UpdateGrid()
    local unresolved = false
    for index = 1, PAGE_SIZE do
        local button = gridButtons[index]
        local id = state.ids[index]
        if id then
            button.itemId = id
            RequestItem(id)
            local texture, quality = ItemDetails(id)
            if not texture then unresolved = true end
            button.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            local r, g, b = 0.5, 0.5, 0.5
            if quality then r, g, b = GetItemQualityColor(quality) end
            button:SetBackdropBorderColor(r, g, b)
            if state.selected == id then button.selected:Show() else button.selected:Hide() end
            button:Show()
        else
            button.itemId = nil
            button:Hide()
        end
    end
    pageLabel:SetText(format("Page %d / %d  (%d)", state.page, state.pages, state.total))
    UpdateSelectedText()
    UpdateButtons()
    frame.unresolved = unresolved and 20 or 0   -- keep retrying for a few seconds while item data arrives
end

-- Server round trips ----------------------------------------------------------------------------------------------------

local function ParseResult(lines)
    for _, line in ipairs(lines) do
        local code = line:match("^R (%d+)")
        if code then
            return tonumber(code)
        end
    end
    return nil
end

local function RequestPage(slot, page)
    Send(format("wardrobe list %d %d %s", slot, page, state.search), function(ok, lines)
        local code = ParseResult(lines)
        if code and RESULT_TEXT[code] then
            SetStatus(RESULT_TEXT[code], false)
            return
        end
        local ids = {}
        local gotHeader = false
        for _, line in ipairs(lines) do
            local s, p, pages, total, shown = line:match("^L (%d+) (%d+) (%d+) (%d+) (%d+)")
            if s then
                gotHeader = true
                state.slot = tonumber(s)
                state.page = tonumber(p)
                state.pages = tonumber(pages)
                state.total = tonumber(total)
                state.shown = tonumber(shown)
            elseif line:sub(1, 2) == "I " then
                for id in line:sub(3):gmatch("%d+") do
                    ids[#ids + 1] = tonumber(id)
                end
            end
        end
        if not gotHeader then
            SetStatus("The server did not answer the collection request.", false)
            return
        end
        state.ids = ids
        UpdateGrid()
        UpdateAllSlotButtons()
    end)
end

local function RefreshSlots(thenDo)
    Send("wardrobe slots", function(ok, lines)
        if not ok then
            SetStatus("The server does not answer the wardrobe commands (is mod-transmog up to date?).", false)
            return
        end
        state.slots = {}
        for _, line in ipairs(lines) do
            local near = line:match("^N (%d+)")
            if near then
                state.near = (tonumber(near) == 1)
            else
                local s, equipped, shown, flags, cost = line:match("^S (%d+) (%d+) (%d+) (%d+) (%d+)")
                if s then
                    state.slots[tonumber(s)] = {
                        equipped = tonumber(equipped), shown = tonumber(shown),
                        flags = tonumber(flags), cost = tonumber(cost),
                    }
                end
            end
        end
        UpdateAllSlotButtons()
        UpdateButtons()
        if thenDo then thenDo() end
    end)
end

local function SelectSlot(slot)
    state.slot = slot
    state.selected = nil
    state.ids = {}
    state.page = 1
    state.pages = 1
    state.total = 0
    ResetModel()
    SetStatus("", true)
    for _, entry in ipairs(SLOTS) do
        if entry.slot == slot then
            frame.slotTitle:SetText(entry.name)
        end
    end
    UpdateAllSlotButtons()
    UpdateGrid()
    RequestPage(slot, 1)
end

-- After a change on the server: reload the slot states, the current page and the character preview.
local function Refresh()
    RefreshSlots(function()
        if state.slot then
            RequestPage(state.slot, state.page)
        end
    end)
    ResetModel()
    if state.selected then
        PreviewItem(state.selected)
    end
end

local function RunAction(command)
    Send(command, function(ok, lines)
        local code = ParseResult(lines)
        if code then
            SetStatus(RESULT_TEXT[code] or ("Server result " .. code), RESULT_OK[code] or false)
        else
            SetStatus("The server did not accept that.", false)
        end
        Refresh()
    end)
end

-- Build the slot buttons ------------------------------------------------------------------------------------------------

for _, entry in ipairs(SLOTS) do
    local inventoryId, emptyTexture = GetInventorySlotInfo(entry.token)
    entry.inventoryId = inventoryId
    entry.emptyTexture = emptyTexture

    local button = CreateFrame("Button", nil, frame)
    button:SetSize(40, 40)
    local pos = SLOT_POS[entry.slot]
    button:SetPoint("TOPLEFT", pos[1], pos[2])

    button.icon = button:CreateTexture(nil, "BORDER")
    button.icon:SetAllPoints()

    button.mark = button:CreateTexture(nil, "OVERLAY")     -- a look is applied to this slot
    button.mark:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    button.mark:SetSize(16, 16)
    button.mark:SetPoint("BOTTOMRIGHT", 2, -2)
    button.mark:Hide()

    button.selected = button:CreateTexture(nil, "OVERLAY")
    button.selected:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    button.selected:SetBlendMode("ADD")
    button.selected:SetSize(74, 74)
    button.selected:SetPoint("CENTER")
    button.selected:Hide()

    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    button:SetScript("OnClick", function()
        SelectSlot(entry.slot)
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GetInventoryItemLink("player", entry.inventoryId) then
            GameTooltip:SetInventoryItem("player", entry.inventoryId)
        else
            GameTooltip:SetText(entry.name)
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    entry.button = button
    slotButtons[#slotButtons + 1] = entry
end

-- Right-hand panel ------------------------------------------------------------------------------------------------------

local RIGHT = 420

frame.slotTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
frame.slotTitle:SetPoint("TOPLEFT", RIGHT, -26)
frame.slotTitle:SetText("Choose a slot")

local searchBox = CreateFrame("EditBox", "TransmogWardrobeSearchBox", frame, "InputBoxTemplate")
searchBox:SetSize(190, 20)
searchBox:SetPoint("TOPLEFT", RIGHT + 6, -62)
searchBox:SetAutoFocus(false)
searchBox:SetMaxLetters(40)

local searchHint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
searchHint:SetPoint("LEFT", searchBox, "LEFT", 6, 0)
searchHint:SetText("Search by name")
searchBox:SetScript("OnEditFocusGained", function() searchHint:Hide() end)
searchBox:SetScript("OnEditFocusLost", function(self)
    if self:GetText() == "" then searchHint:Show() end
end)

local function DoSearch()
    local text = strtrim(searchBox:GetText() or "")
    state.search = (text == "") and "-" or text
    if state.slot then
        state.selected = nil
        RequestPage(state.slot, 1)
    end
    searchBox:ClearFocus()
end
searchBox:SetScript("OnEnterPressed", DoSearch)
searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local searchButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
searchButton:SetSize(70, 22)
searchButton:SetPoint("LEFT", searchBox, "RIGHT", 6, 0)
searchButton:SetText("Search")
searchButton:SetScript("OnClick", DoSearch)

local clearSearchButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
clearSearchButton:SetSize(50, 22)
clearSearchButton:SetPoint("LEFT", searchButton, "RIGHT", 4, 0)
clearSearchButton:SetText("Clear")
clearSearchButton:SetScript("OnClick", function()
    searchBox:SetText("")
    searchHint:Show()
    DoSearch()
end)

for index = 1, PAGE_SIZE do
    local col = (index - 1) % COLS
    local row = floor((index - 1) / COLS)
    local button = CreateFrame("Button", nil, frame)
    button:SetSize(CELL, CELL)
    button:SetPoint("TOPLEFT", RIGHT + 6 + col * (CELL + GAP), -100 - row * (CELL + GAP))
    button:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })

    button.icon = button:CreateTexture(nil, "BACKGROUND")
    button.icon:SetPoint("TOPLEFT", 2, -2)
    button.icon:SetPoint("BOTTOMRIGHT", -2, 2)

    button.selected = button:CreateTexture(nil, "OVERLAY")
    button.selected:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    button.selected:SetBlendMode("ADD")
    button.selected:SetSize(74, 74)
    button.selected:SetPoint("CENTER")
    button.selected:Hide()

    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    button:SetScript("OnClick", function(self)
        if self.itemId then
            state.selected = self.itemId
            PreviewItem(self.itemId)
            UpdateGrid()
        end
    end)
    button:SetScript("OnEnter", function(self)
        if self.itemId then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. self.itemId)
            GameTooltip:Show()
        end
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    button:Hide()
    gridButtons[index] = button
end

prevButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
prevButton:SetSize(80, 22)
prevButton:SetPoint("TOPLEFT", RIGHT + 6, -300)
prevButton:SetText("< Prev")
prevButton:SetScript("OnClick", function()
    if state.slot and state.page > 1 then
        RequestPage(state.slot, state.page - 1)
    end
end)

nextButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
nextButton:SetSize(80, 22)
nextButton:SetPoint("TOPLEFT", RIGHT + 202, -300)
nextButton:SetText("Next >")
nextButton:SetScript("OnClick", function()
    if state.slot and state.page < state.pages then
        RequestPage(state.slot, state.page + 1)
    end
end)

pageLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
pageLabel:SetPoint("TOP", frame, "TOPLEFT", RIGHT + 144, -304)

selectedText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
selectedText:SetPoint("TOPLEFT", RIGHT + 6, -340)
selectedText:SetWidth(360)
selectedText:SetJustifyH("LEFT")

costText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
costText:SetPoint("TOPLEFT", RIGHT + 6, -364)

statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
statusText:SetPoint("TOPLEFT", RIGHT + 6, -388)
statusText:SetWidth(370)
statusText:SetJustifyH("LEFT")

applyButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
applyButton:SetSize(100, 24)
applyButton:SetPoint("TOPLEFT", RIGHT + 6, -420)
applyButton:SetText("Apply")
applyButton:SetScript("OnClick", function()
    if state.slot and state.selected then
        RunAction(format("wardrobe apply %d %d", state.slot, state.selected))
    end
end)

hideButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
hideButton:SetSize(100, 24)
hideButton:SetPoint("LEFT", applyButton, "RIGHT", 6, 0)
hideButton:SetText("Hide slot")
hideButton:SetScript("OnClick", function()
    if state.slot then
        RunAction(format("wardrobe hide %d", state.slot))
    end
end)

restoreButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
restoreButton:SetSize(100, 24)
restoreButton:SetPoint("LEFT", hideButton, "RIGHT", 6, 0)
restoreButton:SetText("Restore slot")
restoreButton:SetScript("OnClick", function()
    if state.slot then
        RunAction(format("wardrobe clear %d", state.slot))
    end
end)

restoreAllButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
restoreAllButton:SetSize(110, 24)
restoreAllButton:SetPoint("TOPLEFT", RIGHT + 6, -452)
restoreAllButton:SetText("Restore all")
restoreAllButton:SetScript("OnClick", function()
    RunAction("wardrobe clearall")
end)

nearText = frame:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
nearText:SetPoint("TOPLEFT", RIGHT + 6, -484)
nearText:SetWidth(380)
nearText:SetJustifyH("LEFT")

local resetButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
resetButton:SetSize(120, 24)
resetButton:SetPoint("TOPLEFT", 24, -470)
resetButton:SetText("Reset preview")
resetButton:SetScript("OnClick", function()
    state.selected = nil
    ResetModel()
    UpdateGrid()
end)

-- Waiting for item data (names and icons arrive a moment after they are first requested) and for slow replies
frame:SetScript("OnUpdate", function(self, elapsed)
    self.timer = (self.timer or 0) + elapsed
    if self.timer < 0.5 then
        return
    end
    self.timer = 0

    if (self.unresolved or 0) > 0 then
        self.unresolved = self.unresolved - 1
        UpdateGrid()
    end

    local now = GetTime()
    for id, request in pairs(pending) do
        if now - request.sentAt > 8 then
            pending[id] = nil
            SetStatus("No answer from the server (is the module built with the .wardrobe commands?).", false)
        end
    end
end)

frame:SetScript("OnShow", function()
    ResetModel()
    RefreshSlots(function()
        if not state.slot then
            SelectSlot(0)
        else
            RequestPage(state.slot, state.page)
        end
    end)
    UpdateAllSlotButtons()
end)

local slotEvents = CreateFrame("Frame")
slotEvents:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
slotEvents:SetScript("OnEvent", function()
    if frame:IsShown() then
        UpdateAllSlotButtons()
    end
end)

------------------------------------------------------------------------------------------------------------------------
-- Opening the window
------------------------------------------------------------------------------------------------------------------------

local function Toggle()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end

SLASH_TRANSMOGWARDROBE1 = "/tmog"
SLASH_TRANSMOGWARDROBE2 = "/wardrobe"
SlashCmdList["TRANSMOGWARDROBE"] = Toggle

-- The Warpweaver's "Open Collection" conversation option: the server sends an addon message with this prefix
local openEvents = CreateFrame("Frame")
openEvents:RegisterEvent("CHAT_MSG_ADDON")
openEvents:SetScript("OnEvent", function(self, event, prefix, message, distribution, sender)
    if prefix == "TMOGWARDROBE" and message == "OPEN" and (not sender or sender == UnitName("player")) then
        frame:Show()
    end
end)

end)
if not TransmogWardrobe_ok then
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4040TransmogWardrobe failed to load:|r " .. tostring(TransmogWardrobe_err))
    elseif geterrorhandler then
        geterrorhandler()(TransmogWardrobe_err)
    end
end
