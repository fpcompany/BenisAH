local _, ns = ...

-- The BenisAH tab of the auction house: scan controls on top, the list of
-- finds below, one Buy button per row.
local UI = {
	offset = 0, -- index of the first visible entry, minus one
	rows = {},
}
ns.UI = UI

local Results, Scanner, Buyer = ns.Results, ns.Scanner, ns.Buyer

local TAB_ID = 'BenisAH'
local TAB_TEXT = 'BenisAH'
local ROW_HEIGHT = 24
local NUM_ROWS = 16
local UPDATE_INTERVAL = 0.1

-- column layout of the list: x offset of the column's right edge, and width
local COLUMNS = {
	{ key = 'avail', label = 'Avail', right = 250, width = 36 },
	{ key = 'each', label = 'Each', right = 335, width = 82 },
	{ key = 'limit', label = 'Vendor', right = 420, width = 82 },
	{ key = 'total', label = 'Total', right = 505, width = 82 },
	{ key = 'profit', label = 'Profit', right = 590, width = 82 },
}
local NAME_LEFT, NAME_WIDTH = 30, 180
local QTY_LEFT, QTY_WIDTH = 604, 40
local BUY_LEFT, BUY_WIDTH = 650, 56
local VIEW_LEFT, VIEW_WIDTH = 708, 50

local HINTS = {
	vendor = 'Press Scan to look for auctions with a buyout below their vendor price.',
	search = 'Enter an item name and the most you want to pay per item, then press Scan.',
	upgrade = 'Pick the slots, set the most you want to pay, then press Scan.',
}

local HEADERS = {
	vendor = { avail = 'Avail', each = 'Each', limit = 'Vendor', total = 'Total', profit = 'Profit' },
	search = { avail = 'Avail', each = 'Each', limit = 'Max', total = 'Total', profit = '' },
	upgrade = { avail = 'Avail', each = 'Slot', limit = 'Price', total = 'Score', profit = 'Gain' },
}

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

local function CreateLabel(parent, text, font)
	local label = parent:CreateFontString(nil, 'ARTWORK', font or 'GameFontNormalSmall')
	label:SetText(text or '')
	return label
end

local function CreateEditBox(parent, width, numeric, maxLetters)
	local box = CreateFrame('EditBox', nil, parent, 'InputBoxTemplate')
	box:SetSize(width, 20)
	box:SetAutoFocus(false)
	if numeric then box:SetNumeric(true) end
	if maxLetters then box:SetMaxLetters(maxLetters) end
	box:SetScript('OnEscapePressed', box.ClearFocus)
	box:SetScript('OnEnterPressed', box.ClearFocus)
	return box
end

local function CreateButton(parent, text, width)
	local button = CreateFrame('Button', nil, parent, 'UIPanelButtonTemplate')
	button:SetSize(width, 22)
	button:SetText(text)
	return button
end

-- a check button with a label that is clickable too
local function CreateCheck(parent, text)
	local check = CreateFrame('CheckButton', nil, parent, 'UICheckButtonTemplate')
	check:SetSize(24, 24)
	check.label = CreateLabel(check, text, 'GameFontHighlightSmall')
	check.label:SetPoint('LEFT', check, 'RIGHT', 0, 1)
	check:SetHitRectInsets(0, -check.label:GetStringWidth() - 2, 0, 0)
	return check
end

-- gold / silver / copper boxes
local function CreateMoneyInput(parent, onChanged)
	local frame = CreateFrame('Frame', nil, parent)
	frame:SetSize(170, 20)

	local function Box(width, maxLetters, suffix, anchor)
		local box = CreateEditBox(frame, width, true, maxLetters)
		if anchor then
			box:SetPoint('LEFT', anchor, 'RIGHT', 10, 0)
		else
			box:SetPoint('LEFT', 6, 0)
		end
		local label = CreateLabel(frame, suffix, 'GameFontHighlightSmall')
		label:SetPoint('LEFT', box, 'RIGHT', 2, 0)
		box:SetScript('OnTextChanged', function(_, userInput)
			if userInput and onChanged then onChanged(frame:GetCopper()) end
		end)
		return box, label
	end

	local goldLabel, silverLabel
	frame.gold, goldLabel = Box(50, 6, '|cffffd100g|r')
	frame.silver, silverLabel = Box(26, 2, '|cffc7c7cfs|r', goldLabel)
	frame.copper = Box(26, 2, '|cffeda55fc|r', silverLabel)

	function frame:GetCopper()
		return (self.gold:GetNumber() or 0) * 10000 + (self.silver:GetNumber() or 0) * 100
			+ (self.copper:GetNumber() or 0)
	end

	function frame:SetCopper(amount)
		amount = math.max(0, math.floor(amount or 0))
		self.gold:SetText(math.floor(amount / 10000))
		self.silver:SetText(math.floor(amount / 100) % 100)
		self.copper:SetText(amount % 100)
	end

	function frame:ClearFocus()
		self.gold:ClearFocus()
		self.silver:ClearFocus()
		self.copper:ClearFocus()
	end

	return frame
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

-- reads the input boxes into the saved settings
function UI:SaveSettings()
	local db = ns.db
	local delay = tonumber((self.delayBox:GetText():gsub(',', '.')))
	if delay then
		db.delay = math.min(math.max(delay, ns.MIN_DELAY), ns.MAX_DELAY)
	end
	db.searchName = strtrim(self.nameBox:GetText() or '')
	db.searchMax = self.maxPrice:GetCopper()
	db.exactMatch = self.exactCheck:GetChecked() and true or false
	db.upgradeMax = self.upgradeMaxPrice:GetCopper()
	self.delayBox:SetText(('%.1f'):format(db.delay))
end

function UI:LoadSettings()
	local db = ns.db
	self.delayBox:SetText(('%.1f'):format(db.delay))
	self.nameBox:SetText(db.searchName or '')
	self.maxPrice:SetCopper(db.searchMax or 0)
	self.exactCheck:SetChecked(db.exactMatch)
	self.upgradeMaxPrice:SetCopper(db.upgradeMax or 0)
	self:UpdateUpgradeMaxLabel()
	self:UpdateCategoryButton()
	self:UpdateSlotButton()
end

function UI:ClearFocus()
	self.delayBox:ClearFocus()
	self.nameBox:ClearFocus()
	self.maxPrice:ClearFocus()
	self.upgradeMaxPrice:ClearFocus()
	if self.options then self.options:ClearFocus() end
end

function UI:UpdateCategoryButton()
	local categories = ns.GetCategories()
	local selected = 0
	for _, category in ipairs(categories) do
		if not ns.db.skipCategories[category.name] then selected = selected + 1 end
	end
	self.categoryButton:SetText(('Categories (%d/%d)'):format(selected, #categories))
end

function UI:ShowCategoryMenu()
	MenuUtil.CreateContextMenu(self.categoryButton, function(_, root)
		root:CreateTitle('Categories to scan')
		local skip = ns.db.skipCategories
		for _, category in ipairs(ns.GetCategories()) do
			root:CreateCheckbox(category.name,
				function(name) return not skip[name] end,
				function(name)
					skip[name] = not skip[name] or nil
					UI:UpdateCategoryButton()
				end,
				category.name)
		end
	end)
end

-- "Max each" is a price, or with the sell price limit what may come on top of it
function UI:UpdateUpgradeMaxLabel()
	self.upgradeMaxLabel:SetText(ns.db.upgradeSellLimit and 'Sell price +' or 'Max each')
end

function UI:UpdateSlotButton()
	local slots = ns.Upgrade.SLOTS
	local selected = 0
	for _, slot in ipairs(slots) do
		if not ns.db.skipSlots[slot.key] then selected = selected + 1 end
	end
	self.slotButton:SetText(('Slots (%d/%d)'):format(selected, #slots))
end

function UI:ShowSlotMenu()
	local Upgrade = ns.Upgrade
	local plan = Upgrade:WeaponPlan()
	MenuUtil.CreateContextMenu(self.slotButton, function(_, root)
		root:CreateTitle('Slots to search')
		local skip = ns.db.skipSlots
		root:CreateButton('All', function()
			wipe(skip)
			UI:UpdateSlotButton()
		end)
		root:CreateButton('None', function()
			for _, slot in ipairs(Upgrade.SLOTS) do skip[slot.key] = true end
			UI:UpdateSlotButton()
		end)
		root:CreateDivider()
		for _, slot in ipairs(Upgrade.SLOTS) do
			root:CreateCheckbox(Upgrade:SlotLabel(slot, plan),
				function(key) return not skip[key] end,
				function(key)
					skip[key] = not skip[key] or nil
					UI:UpdateSlotButton()
				end,
				slot.key)
		end
	end)
end

function UI:SetMode(mode)
	if not HINTS[mode] then mode = 'vendor' end
	Scanner:Stop()
	Buyer:Cancel()
	ns.db.mode = mode
	self.offset = 0

	self.vendorCheck:SetChecked(mode == 'vendor')
	self.searchCheck:SetChecked(mode == 'search')
	self.upgradeCheck:SetChecked(mode == 'upgrade')
	self.categoryButton:SetShown(mode == 'vendor')
	self.searchOptions:SetShown(mode == 'search')
	self.upgradeOptions:SetShown(mode == 'upgrade')
	if mode ~= 'upgrade' and self.options then self.options:Hide() end
	for key, text in pairs(HEADERS[mode]) do
		self.headers[key]:SetText(text)
	end
	self.hint:SetText(HINTS[mode])
	self:MarkDirty()
end

function UI:ToggleScan()
	self:ClearFocus()
	if Scanner.running then
		Scanner:Stop()
	else
		self:SaveSettings()
		self.offset = 0
		Scanner:Start(ns.db.mode)
	end
	self:UpdateStatus()
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function Row_UpdateNumbers(row)
	local entry = row.entry
	if entry.slot then
		row.avail:SetText(entry.quantity)
		row.each:SetText(entry.slotLabel)
		row.limit:SetText(ns.Money(entry.buyout))
		row.total:SetText(('%.1f'):format(entry.score))
		row.profit:SetText(('|cff40ff40+%.1f|r'):format(entry.gain))
		return
	end
	local vendorMode = ns.db.mode == 'vendor'
	local total, count
	if entry.kind == 'commodity' then
		count = entry.buyQty or entry.quantity
		total = ns.CostFor(entry, count)
	else
		-- a lot of identical auctions: the buyout is per item
		count = entry.quantity
		total = entry.buyout * count
	end

	row.avail:SetText(entry.quantity)
	row.each:SetText(ns.Money(entry.unit))
	row.limit:SetText(ns.Money(vendorMode and entry.vendor or entry.limit))
	row.total:SetText(ns.Money(total))
	if vendorMode and entry.vendor then
		row.profit:SetText(ns.Money(entry.vendor * count - total))
	else
		row.profit:SetText('')
	end
end

local function Row_UpdateButton(row)
	local entry = row.entry
	local pending = Buyer.pending
	local text, enabled = 'Buy', true
	if entry.kind == 'item' and entry.quantity > 1 then
		text = 'Buy 1' -- one item of the lot per click
	end
	if entry.gone then
		text, enabled = 'Gone', false
	elseif entry.spent then
		text, enabled = '...', false -- looking up the lot's next auction
	elseif pending and pending.entry == entry then
		if pending.state == 'confirm' then
			text = 'Confirm'
		else
			text, enabled = '...', false
		end
	elseif pending then
		enabled = false
	end
	row.buy:SetText(text)
	row.buy:SetEnabled(enabled)
end

local function Row_SetEntry(row, entry)
	if row.entry ~= entry and row.qty:HasFocus() then
		row.qty:ClearFocus()
	end
	row.entry = entry
	if not entry then
		row:Hide()
		return
	end

	ns.ResolveInfo(entry)
	row.icon:SetTexture(entry.icon or 134400) -- question mark until the item loads
	row.name:SetText(entry.name or ('item ' .. entry.itemID))
	if entry.quality then
		local r, g, b = C_Item.GetItemQualityColor(entry.quality)
		row.name:SetTextColor(r or 1, g or 1, b or 1)
	else
		row.name:SetTextColor(1, 1, 1)
	end

	local isCommodity = entry.kind == 'commodity'
	row.qty:SetShown(isCommodity and not entry.gone)
	if isCommodity and not row.qty:HasFocus() then
		row.qty:SetText(entry.buyQty or entry.quantity)
	end

	Row_UpdateNumbers(row)
	Row_UpdateButton(row)
	row:SetAlpha(entry.gone and 0.4 or 1)
	row:Show()
end

local function Row_ShowTooltip(row)
	local entry = row.entry
	if not entry then return end
	GameTooltip:SetOwner(row.item, 'ANCHOR_RIGHT')
	if entry.link then
		GameTooltip:SetHyperlink(entry.link)
	else
		GameTooltip:SetItemByID(entry.itemID)
	end
	if entry.slot then
		GameTooltip:AddLine(' ')
		GameTooltip:AddLine(('Upgrade for %s: score %.1f -> %.1f (+%.1f)'):format(
			entry.slotLabel, entry.equippedScore, entry.score, entry.gain), 0.25, 1, 0.25)
		GameTooltip:AddLine('Replaces: ' .. (entry.equippedLink or 'nothing equipped'), 1, 1, 1)
		if entry.equippedLink then
			GameTooltip:AddLine('which sells for ' .. ns.Money(entry.equippedSell), 1, 1, 1)
		end
	end
	GameTooltip:Show()
end

local function CreateRow(parent, index)
	local row = CreateFrame('Frame', nil, parent)
	row:SetSize(760, ROW_HEIGHT)
	row:SetPoint('TOPLEFT', 4, -4 - (index - 1) * ROW_HEIGHT)

	if index % 2 == 0 then
		local stripe = row:CreateTexture(nil, 'BACKGROUND')
		stripe:SetAllPoints()
		stripe:SetColorTexture(1, 1, 1, 0.04)
	end

	-- icon and name: tooltip on hover, shift-click links the item
	row.item = CreateFrame('Button', nil, row)
	row.item:SetPoint('TOPLEFT', 4, 0)
	row.item:SetSize(NAME_LEFT + NAME_WIDTH - 4, ROW_HEIGHT)
	row.item:SetScript('OnEnter', function() Row_ShowTooltip(row) end)
	row.item:SetScript('OnLeave', function() GameTooltip:Hide() end)
	row.item:SetScript('OnClick', function()
		local entry = row.entry
		if not entry then return end
		ns.ResolveInfo(entry)
		if entry.link then HandleModifiedItemClick(entry.link) end
	end)

	row.icon = row:CreateTexture(nil, 'ARTWORK')
	row.icon:SetSize(20, 20)
	row.icon:SetPoint('LEFT', 6, 0)
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	row.name = CreateLabel(row, '', 'GameFontHighlight')
	row.name:SetPoint('LEFT', NAME_LEFT, 0)
	row.name:SetWidth(NAME_WIDTH)
	row.name:SetJustifyH('LEFT')
	row.name:SetWordWrap(false)

	for _, column in ipairs(COLUMNS) do
		local text = CreateLabel(row, '', 'GameFontHighlightSmall')
		text:SetPoint('RIGHT', row, 'LEFT', column.right, 0)
		text:SetWidth(column.width)
		text:SetJustifyH('RIGHT')
		text:SetWordWrap(false)
		row[column.key] = text
	end

	-- how many of a stackable item to buy
	row.qty = CreateEditBox(row, QTY_WIDTH, true, 5)
	row.qty:SetPoint('LEFT', QTY_LEFT, 0)
	row.qty:SetScript('OnTextChanged', function(box, userInput)
		local entry = row.entry
		if not (userInput and entry and entry.kind == 'commodity') then return end
		entry.qtyEdited = true
		entry.buyQty = math.max(1, math.min(box:GetNumber() or 1, entry.quantity))
		Row_UpdateNumbers(row)
	end)
	row.qty:SetScript('OnEditFocusLost', function(box)
		box:HighlightText(0, 0)
		local entry = row.entry
		if entry and entry.kind == 'commodity' then
			box:SetText(entry.buyQty or entry.quantity)
		end
	end)

	row.buy = CreateButton(row, 'Buy', BUY_WIDTH)
	row.buy:SetHeight(20)
	row.buy:SetPoint('LEFT', BUY_LEFT, 0)
	-- the purchase has to be made right here, inside the click
	row.buy:SetScript('OnClick', function()
		local entry = row.entry
		if not entry then return end
		row.qty:ClearFocus()
		Buyer:Buy(entry, entry.buyQty)
	end)

	-- opens the item in Blizzard's Buy tab
	row.view = CreateButton(row, 'View', VIEW_WIDTH)
	row.view:SetHeight(20)
	row.view:SetPoint('LEFT', VIEW_LEFT, 0)
	row.view:SetScript('OnClick', function()
		if row.entry then UI:ViewEntry(row.entry) end
	end)
	row.view:SetScript('OnEnter', function(button)
		GameTooltip:SetOwner(button, 'ANCHOR_RIGHT')
		GameTooltip:SetText('Show this item in the Buy tab')
		GameTooltip:AddLine('Reloads its auctions from the server. Buy or bid there with the default buttons.', 1, 1, 1, true)
		GameTooltip:Show()
	end)
	row.view:SetScript('OnLeave', function() GameTooltip:Hide() end)

	row:Hide()
	return row
end

--------------------------------------------------------------------------------
-- Jump to the default UI
--------------------------------------------------------------------------------

local VIEW_SELECT_WINDOW = 10 -- seconds to wait for the listing to load

-- Opens the entry's item in Blizzard's Buy tab, the same way clicking it in
-- the browse results would. The item view re-queries the item as it opens, so
-- what it shows is fresh. For a single auction, that auction is selected once
-- the listing arrived, which arms Blizzard's Bid / Buyout buttons.
function UI:ViewEntry(entry)
	local frame = AuctionHouseFrame
	local itemKey = entry.itemKey
	if not (itemKey and C_AuctionHouse.GetItemKeyInfo(itemKey)) then
		ns.Print('the item data is still loading, try again in a moment.')
		return
	end

	-- The Buy display mode first: it is the one that owns the Buy tab and the
	-- window title (the item view itself has no tab), and leaving our tab
	-- through it also stops the scan.
	frame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
	if entry.kind == 'item' then
		self.viewAuction = { itemKey = itemKey, auctionID = entry.auctionID, since = GetTime() }
	end
	frame:SelectBrowseResult({
		itemKey = itemKey,
		minPrice = entry.unit,
		totalQuantity = entry.quantity,
		containsOwnerItem = false,
	})
end

local function SelectViewedAuction(itemKey)
	local view = UI.viewAuction
	if not view then return end
	if GetTime() - view.since > VIEW_SELECT_WINDOW then
		UI.viewAuction = nil
		return
	end
	if not itemKey or itemKey.itemID ~= view.itemKey.itemID then return end

	local frame = AuctionHouseFrame
	local list = frame and frame.ItemBuyFrame and frame.ItemBuyFrame.ItemList
	if not (list and list:IsVisible()) then return end

	-- only once the auction is actually in the loaded results
	for index = 1, C_AuctionHouse.GetNumItemSearchResults(view.itemKey) do
		local result = C_AuctionHouse.GetItemSearchResultInfo(view.itemKey, index)
		if result and result.auctionID == view.auctionID then
			UI.viewAuction = nil
			pcall(list.SetSelectedEntryByCondition, list, function(rowData)
				return rowData.auctionID == view.auctionID
			end, true)
			return
		end
	end
end

ns.On('ITEM_SEARCH_RESULTS_UPDATED', SelectViewedAuction)
ns.On('ITEM_SEARCH_RESULTS_ADDED', SelectViewedAuction)
ns.On('AUCTION_HOUSE_CLOSED', function() UI.viewAuction = nil end)

--------------------------------------------------------------------------------
-- List
--------------------------------------------------------------------------------

-- something in the results changed
function UI:MarkDirty()
	self.dirty = true
end

function UI:Render()
	if self.rendering then return end
	self.rendering = true

	local entries = Results:List(ns.db.mode)
	local maxOffset = math.max(0, #entries - NUM_ROWS)
	self.offset = math.max(0, math.min(self.offset, maxOffset))

	self.slider:SetMinMaxValues(0, maxOffset)
	self.slider:SetValue(self.offset)
	self.slider:SetShown(maxOffset > 0)

	for index, row in ipairs(self.rows) do
		Row_SetEntry(row, entries[self.offset + index])
	end
	self.hint:SetShown(#entries == 0)

	self.rendering = false
end

function UI:Scroll(delta)
	self.offset = self.offset - delta * 3
	self:Render()
end

function UI:UpdateStatus()
	local mode = ns.db.mode
	local count = Results:Count(mode)
	local status = Scanner:GetStatus()
	if status then
		self.status:SetText(('%s, %d listed'):format(status, count))
	elseif count > 0 then
		self.status:SetText(('Stopped, %d listed'):format(count))
	else
		self.status:SetText('')
	end
	self.scanButton:SetText(Scanner.running and 'Stop' or 'Scan')
end

function UI:OnUpdate(elapsed)
	self.sinceUpdate = (self.sinceUpdate or 0) + elapsed
	if self.sinceUpdate < UPDATE_INTERVAL then return end
	self.sinceUpdate = 0

	if self.dirty then
		-- Dropping sold entries and re-sorting moves rows, which must not happen
		-- under a cursor that is about to click Buy: wait until it left the list.
		if not self.list:IsMouseOver() then
			Results:Compact(ns.db.mode)
			self.dirty = false
		end
		self:Render()
	end
	self:UpdateStatus()
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

function UI:BuildPanel()
	local panel = CreateFrame('Frame', 'BenisAHPanel', AuctionHouseFrame)
	panel:SetPoint('TOPLEFT', 8, -26)
	panel:SetPoint('BOTTOMRIGHT', -8, 30)
	panel:Hide()
	self.panel = panel

	-- The first two lines start right of the frame's portrait.
	local LEFT = 64

	-- line 1: mode, delay, scan button
	self.vendorCheck = CreateCheck(panel, 'Below vendor price')
	self.vendorCheck:SetPoint('TOPLEFT', LEFT, -4)
	self.vendorCheck:SetScript('OnClick', function() UI:SetMode('vendor') end)

	self.searchCheck = CreateCheck(panel, 'Item name and max price')
	self.searchCheck:SetPoint('LEFT', self.vendorCheck.label, 'RIGHT', 16, -1)
	self.searchCheck:SetScript('OnClick', function() UI:SetMode('search') end)

	self.upgradeCheck = CreateCheck(panel, 'Upgrades')
	self.upgradeCheck:SetPoint('LEFT', self.searchCheck.label, 'RIGHT', 16, -1)
	self.upgradeCheck:SetScript('OnClick', function() UI:SetMode('upgrade') end)

	self.scanButton = CreateButton(panel, 'Scan', 90)
	self.scanButton:SetPoint('TOPRIGHT', -4, -5)
	self.scanButton:SetScript('OnClick', function() UI:ToggleScan() end)

	local secondsLabel = CreateLabel(panel, 's', 'GameFontHighlightSmall')
	secondsLabel:SetPoint('RIGHT', self.scanButton, 'LEFT', -12, 0)
	self.delayBox = CreateEditBox(panel, 34, false, 4)
	self.delayBox:SetPoint('RIGHT', secondsLabel, 'LEFT', -3, 0)
	self.delayBox:SetJustifyH('CENTER')
	self.delayBox:SetScript('OnEditFocusLost', function(box)
		box:HighlightText(0, 0)
		UI:SaveSettings()
	end)
	local delayLabel = CreateLabel(panel, 'Delay between queries')
	delayLabel:SetPoint('RIGHT', self.delayBox, 'LEFT', -10, 0)

	-- line 2: options of the mode, status
	self.categoryButton = CreateButton(panel, 'Categories', 150)
	self.categoryButton:SetPoint('TOPLEFT', LEFT, -34)
	self.categoryButton:SetScript('OnClick', function() UI:ShowCategoryMenu() end)

	local options = CreateFrame('Frame', nil, panel)
	options:SetPoint('TOPLEFT', LEFT, -34)
	options:SetSize(540, 22)
	self.searchOptions = options

	local nameLabel = CreateLabel(options, 'Item')
	nameLabel:SetPoint('LEFT', 0, 0)
	self.nameBox = CreateEditBox(options, 170, false, 63)
	self.nameBox:SetPoint('LEFT', nameLabel, 'RIGHT', 10, 0)
	self.nameBox:SetScript('OnEnterPressed', function(box)
		box:ClearFocus()
		if not Scanner.running then UI:ToggleScan() end
	end)

	local maxLabel = CreateLabel(options, 'Max each')
	maxLabel:SetPoint('LEFT', self.nameBox, 'RIGHT', 14, 0)
	self.maxPrice = CreateMoneyInput(options)
	self.maxPrice:SetPoint('LEFT', maxLabel, 'RIGHT', 4, 0)

	self.exactCheck = CreateCheck(options, 'Exact name')
	self.exactCheck:SetPoint('LEFT', self.maxPrice, 'RIGHT', 0, 0)

	local upgrade = CreateFrame('Frame', nil, panel)
	upgrade:SetPoint('TOPLEFT', LEFT, -34)
	upgrade:SetSize(470, 22)
	self.upgradeOptions = upgrade

	self.slotButton = CreateButton(upgrade, 'Slots', 110)
	self.slotButton:SetPoint('LEFT', 0, 0)
	self.slotButton:SetScript('OnClick', function() UI:ShowSlotMenu() end)

	self.optionsButton = CreateButton(upgrade, 'Weights & options', 130)
	self.optionsButton:SetPoint('LEFT', self.slotButton, 'RIGHT', 6, 0)
	self.optionsButton:SetScript('OnClick', function()
		UI:BuildOptions()
		UI.options:SetShown(not UI.options:IsShown())
	end)

	self.upgradeMaxLabel = CreateLabel(upgrade, 'Max each')
	self.upgradeMaxLabel:SetPoint('LEFT', self.optionsButton, 'RIGHT', 14, 0)
	self.upgradeMaxPrice = CreateMoneyInput(upgrade)
	self.upgradeMaxPrice:SetPoint('LEFT', self.upgradeMaxLabel, 'RIGHT', 4, 0)

	self.status = CreateLabel(panel, '', 'GameFontHighlightSmall')
	self.status:SetPoint('TOPRIGHT', -6, -39)
	self.status:SetJustifyH('RIGHT')

	-- line 3: column headers
	self.headers = {}
	local itemHeader = CreateLabel(panel, 'Item')
	itemHeader:SetPoint('TOPLEFT', 4 + NAME_LEFT, -64)
	for _, column in ipairs(COLUMNS) do
		local header = CreateLabel(panel, column.label)
		header:SetPoint('TOPRIGHT', panel, 'TOPLEFT', 4 + column.right, -64)
		self.headers[column.key] = header
	end
	local qtyHeader = CreateLabel(panel, 'Buy')
	qtyHeader:SetPoint('TOPLEFT', 4 + QTY_LEFT, -64)

	-- the list
	local list = CreateFrame('Frame', nil, panel, 'InsetFrameTemplate')
	list:SetPoint('TOPLEFT', 0, -80)
	list:SetPoint('BOTTOMRIGHT', 0, 0)
	list:EnableMouseWheel(true)
	list:SetScript('OnMouseWheel', function(_, delta) UI:Scroll(delta) end)
	self.list = list

	for index = 1, NUM_ROWS do
		self.rows[index] = CreateRow(list, index)
	end

	self.hint = CreateLabel(list, '', 'GameFontDisable')
	self.hint:SetPoint('CENTER', 0, 20)

	local slider = CreateFrame('Slider', nil, list)
	slider:SetOrientation('VERTICAL')
	slider:SetPoint('TOPRIGHT', -5, -6)
	slider:SetPoint('BOTTOMRIGHT', -5, 6)
	slider:SetWidth(10)
	local track = slider:CreateTexture(nil, 'BACKGROUND')
	track:SetAllPoints()
	track:SetColorTexture(0, 0, 0, 0.35)
	local thumb = slider:CreateTexture(nil, 'OVERLAY')
	thumb:SetColorTexture(0.6, 0.6, 0.6, 0.9)
	thumb:SetSize(10, 40)
	slider:SetThumbTexture(thumb)
	slider:SetMinMaxValues(0, 0)
	slider:SetValueStep(1)
	slider:SetValue(0)
	slider:SetScript('OnValueChanged', function(_, value)
		if UI.rendering then return end
		UI.offset = math.floor(value + 0.5)
		UI:Render()
	end)
	self.slider = slider

	panel:SetScript('OnShow', function()
		UI.viewAuction = nil
		UI:LoadSettings()
		UI:SetMode(ns.db.mode)
		UI:Render()
		UI:UpdateStatus()
	end)
	-- Leaving the tab (or closing the auction house) ends the scan: its queries
	-- would overwrite whatever the other tabs are browsing.
	panel:SetScript('OnHide', function()
		Scanner:Stop()
		Buyer:Cancel()
		UI:ClearFocus()
	end)
	panel:SetScript('OnUpdate', function(_, elapsed) UI:OnUpdate(elapsed) end)
end

--------------------------------------------------------------------------------
-- Upgrade options: level, armor type, stat weights
--------------------------------------------------------------------------------

local function FormatWeight(value)
	return ('%g'):format(value or 0)
end

function UI:BuildOptions()
	if self.options then return end
	local Upgrade = ns.Upgrade
	Upgrade:EnsureWeights()

	local frame = CreateFrame('Frame', 'BenisAHUpgradeOptions', self.panel, 'BasicFrameTemplateWithInset')
	frame:SetSize(344, 400)
	frame:SetPoint('TOPLEFT', AuctionHouseFrame, 'TOPRIGHT', 4, 0)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:Hide()
	self.options = frame

	local title = CreateLabel(frame, 'Upgrade options', 'GameFontHighlight')
	title:SetPoint('TOP', 0, -5)

	local boxes = {}

	-- highest required level
	local levelLabel = CreateLabel(frame, 'Max required level')
	levelLabel:SetPoint('TOPLEFT', 16, -38)
	local levelBox = CreateEditBox(frame, 32, true, 3)
	levelBox:SetPoint('LEFT', levelLabel, 'RIGHT', 10, 0)
	levelBox:SetJustifyH('CENTER')
	levelBox:SetScript('OnTextChanged', function(box, userInput)
		if userInput then ns.db.upgradeMaxLevel = box:GetNumber() or 0 end
	end)
	local levelHint = CreateLabel(frame, '', 'GameFontDisableSmall')
	levelHint:SetPoint('LEFT', levelBox, 'RIGHT', 6, 0)
	boxes[#boxes + 1] = levelBox

	-- armor type
	local armorLabel = CreateLabel(frame, 'Armor type')
	armorLabel:SetPoint('TOPLEFT', 16, -68)
	local armorButton = CreateButton(frame, '', 140)
	armorButton:SetPoint('LEFT', armorLabel, 'RIGHT', 10, 0)
	local function ArmorText()
		local setting = ns.db.upgradeArmor
		if setting == 'auto' or not setting then
			return ('Auto (%s)'):format(Upgrade.ARMOR_NAMES[Upgrade:AutoArmorType()])
		end
		return (setting:gsub('^%l', string.upper))
	end
	armorButton:SetScript('OnClick', function()
		MenuUtil.CreateContextMenu(armorButton, function(_, root)
			root:CreateTitle('Armor type to search')
			local function IsSelected(value) return (ns.db.upgradeArmor or 'auto') == value end
			local function Select(value)
				ns.db.upgradeArmor = value
				armorButton:SetText(ArmorText())
			end
			root:CreateRadio(('Auto (%s)'):format(Upgrade.ARMOR_NAMES[Upgrade:AutoArmorType()]),
				IsSelected, Select, 'auto')
			for _, name in ipairs(Upgrade.ARMOR_NAMES) do
				root:CreateRadio(name, IsSelected, Select, name:lower())
			end
		end)
	end)

	-- price limit from the equipped item's sell price
	local sellCheck = CreateCheck(frame, 'Free: pay at most what the replaced item sells for')
	sellCheck:SetPoint('TOPLEFT', 12, -94)
	sellCheck:SetScript('OnClick', function(check)
		ns.db.upgradeSellLimit = check:GetChecked() and true or false
		UI:UpdateUpgradeMaxLabel()
	end)

	-- weights, in two columns
	local TOP = -130
	local weightsLabel = CreateLabel(frame, 'Stat weights (score = stat x weight)')
	weightsLabel:SetPoint('TOPLEFT', 16, TOP)

	local weightBoxes = {}
	local perColumn = math.ceil(#Upgrade.STATS / 2)
	for index, stat in ipairs(Upgrade.STATS) do
		local column = math.floor((index - 1) / perColumn)
		local line = (index - 1) % perColumn
		local label = CreateLabel(frame, stat.label, 'GameFontHighlightSmall')
		label:SetPoint('TOPLEFT', 16 + column * 164, TOP - 26 - line * 24)
		label:SetWidth(100)
		label:SetJustifyH('LEFT')

		local box = CreateEditBox(frame, 44, false, 6)
		box:SetPoint('LEFT', label, 'RIGHT', 4, 0)
		box:SetJustifyH('RIGHT')
		box:SetScript('OnTextChanged', function(edit, userInput)
			if not userInput then return end
			local value = tonumber((edit:GetText():gsub(',', '.')))
			if value then ns.db.weights[stat.key] = value end
		end)
		box:SetScript('OnEditFocusLost', function(edit)
			edit:HighlightText(0, 0)
			edit:SetText(FormatWeight(ns.db.weights[stat.key]))
		end)
		if stat.tip then
			box:SetScript('OnEnter', function()
				GameTooltip:SetOwner(box, 'ANCHOR_RIGHT')
				GameTooltip:SetText(stat.label)
				GameTooltip:AddLine(stat.tip, 1, 1, 1, true)
				GameTooltip:Show()
			end)
			box:SetScript('OnLeave', function() GameTooltip:Hide() end)
		end
		weightBoxes[stat.key] = box
		boxes[#boxes + 1] = box
	end

	-- Tab moves on to the next box
	for index, box in ipairs(boxes) do
		box:SetScript('OnTabPressed', function()
			local nextBox = boxes[index % #boxes + 1]
			nextBox:SetFocus()
			nextBox:HighlightText()
		end)
	end

	local function Refresh()
		local level = tonumber(ns.db.upgradeMaxLevel) or 0
		levelBox:SetText(level)
		levelHint:SetText(('0 = your level (%d)'):format(UnitLevel('player')))
		armorButton:SetText(ArmorText())
		sellCheck:SetChecked(ns.db.upgradeSellLimit)
		for key, box in pairs(weightBoxes) do
			box:SetText(FormatWeight(ns.db.weights[key]))
		end
	end

	local reset = CreateButton(frame, 'Enhancement Shaman preset', 190)
	reset:SetPoint('TOPLEFT', 12, TOP - 30 - perColumn * 24)
	reset:SetScript('OnClick', function()
		Upgrade:ResetWeights()
		Refresh()
	end)

	local note = CreateLabel(frame, 'Changes apply from the next scan pass.', 'GameFontDisableSmall')
	note:SetPoint('TOPLEFT', reset, 'BOTTOMLEFT', 4, -8)

	frame:SetHeight(-TOP + 30 + perColumn * 24 + 70)
	frame:SetScript('OnShow', Refresh)

	function frame:ClearFocus()
		for _, box in ipairs(boxes) do box:ClearFocus() end
	end
end

--------------------------------------------------------------------------------
-- Tab
--------------------------------------------------------------------------------

-- Without LibAHTab: a tab button of our own. It lives on a holder frame
-- because the tab template adds itself to its parent's Tabs list, which on
-- the auction house frame belongs to Blizzard's own three tabs.
function UI:CreateOwnTab()
	local frame = AuctionHouseFrame
	local emptyMode = {} -- a display mode that shows none of Blizzard's panels
	local lastTab = frame.Tabs and frame.Tabs[#frame.Tabs] or frame.AuctionsTab

	local holder = CreateFrame('Frame', nil, frame)
	holder:SetSize(10, 10)
	holder:SetPoint('LEFT', lastTab, 'RIGHT', -15, 0)

	local tab = CreateFrame('Button', 'BenisAHTab', holder, 'AuctionHouseFrameTabTemplate')
	tab:SetPoint('LEFT', holder, 'LEFT', 0, 0)
	tab:SetText(TAB_TEXT)
	PanelTemplates_TabResize(tab, 20, nil, 70)
	PanelTemplates_DeselectTab(tab)

	tab:SetScript('OnClick', function()
		frame:SetDisplayMode(emptyMode)
		for _, other in ipairs(frame.Tabs or {}) do
			PanelTemplates_DeselectTab(other)
		end
		PanelTemplates_SelectTab(tab)
		frame:SetTitle(TAB_TEXT)
		UI.panel:Show()
		PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
	end)

	-- any real display mode means one of Blizzard's tabs took over
	hooksecurefunc(frame, 'SetDisplayMode', function(_, displayMode)
		if displayMode ~= emptyMode then
			UI.panel:Hide()
			PanelTemplates_DeselectTab(tab)
		end
	end)
end

function UI:AttachTab()
	-- LibAHTab (shipped with Auctionator and others) keeps every addon's tab
	-- in one row and switches between them; use it when somebody loaded it.
	local lib = LibStub and LibStub('LibAHTab-1-0', true)
	if lib then
		local ok = pcall(function()
			if not lib:DoesIDExist(TAB_ID) then
				lib:CreateTab(TAB_ID, UI.panel, TAB_TEXT, TAB_TEXT)
			end
		end)
		if ok then return end
	end
	self:CreateOwnTab()
end

function UI:Init()
	if self.panel or not AuctionHouseFrame or not ns.db then return end
	self:BuildPanel()
	self:AttachTab()
end

ns.On('AUCTION_HOUSE_SHOW', function() UI:Init() end)
ns.On('ADDON_LOADED', function(name)
	if name == 'Blizzard_AuctionHouseUI' then UI:Init() end
end)
