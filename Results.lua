local _, ns = ...

-- The lists the UI shows, one per mode. An entry is either
--   kind = 'item'      one lot of identical single-item auctions: buyout is the
--                      price of one item, quantity how many the seller has
--                      up, auctionID one of them; each purchase buys one
--   kind = 'commodity' one stackable item; tiers = { { price, qty }, ... }
--                      cheapest first, holding only the units within the limit
-- Shared fields: key (item key string), itemKey, itemID, link, limit (highest
-- acceptable unit price), vendor (vendor sell price, vendor mode only),
-- unit (lowest unit price), profit, pass (last scan pass that confirmed it)
-- gone (sold, expired or bought; kept greyed at the bottom of the list),
-- bought (gone because it was bought here) and found (order of discovery).
-- Upgrade mode keeps one 'item' entry per equipment slot, which also carries
-- slot, slotLabel, order, score, gain, equippedLink and equippedScore.
local Results = {
	lists = { vendor = {}, search = {}, watch = {}, upgrade = {} },
}
ns.Results = Results

-- how many gone rows a list keeps below the live ones
local MAX_GONE = 100

-- increasing numbers that order rows by when they were found or went gone
local serial = 0
local function NextSerial()
	serial = serial + 1
	return serial
end

local function Changed()
	if ns.UI then ns.UI:MarkDirty() end
end

-- Watch mode: a new cheap auction (a new row, or more units on a commodity
-- row) sounds an alarm and flashes the taskbar, since the click is the slow part.
local ALERT_INTERVAL = 2 -- seconds; several finds in a row make one sound
local lastAlert = 0
local function Alert(mode)
	if mode ~= 'watch' or not ns.db.watchAlert then return end
	local now = GetTime()
	if now - lastAlert < ALERT_INTERVAL then return end
	lastAlert = now
	PlaySound(SOUNDKIT.RAID_WARNING or 8959, 'Master')
	if FlashClientIcon then FlashClientIcon() end
end

-- Adds a new row where Compact would put it: on top. While rows are held
-- (a click may be about to land), on top would push the row under the cursor
-- away, so it goes below the last live row instead and moves up later.
local function Insert(list, entry)
	local position = 1
	if ns.UI and ns.UI.list and ns.UI:HoldsRows() then
		position = #list + 1
		while position > 1 and list[position - 1].gone do
			position = position - 1
		end
	end
	table.insert(list, position, entry)
end

function Results:List(mode)
	return self.lists[mode]
end

function Results:Clear(mode)
	wipe(self.lists[mode])
	Changed()
end

function Results:Count(mode)
	local count = 0
	for _, entry in ipairs(self.lists[mode]) do
		if not entry.gone then count = count + 1 end
	end
	return count
end

-- Fills in name, icon and quality for display. Item data can arrive late, so
-- this is called again on every draw until it sticks.
function ns.ResolveInfo(entry)
	if entry.name and entry.quality and entry.icon then return end
	local name, link, quality, _, _, _, _, _, _, icon = C_Item.GetItemInfo(entry.link or entry.itemID)
	if name then
		entry.link = entry.link or link
		entry.quality = quality
		entry.icon = icon
	end
	-- the link's own text carries random suffixes ("... of the Bear")
	entry.name = entry.link and entry.link:match('%[(.-)%]') or name
	entry.icon = entry.icon or C_Item.GetItemIconByID(entry.itemID)
end

-- total price of the cheapest `quantity` units of a commodity entry
function ns.CostFor(entry, quantity)
	local remaining, total = quantity, 0
	for _, tier in ipairs(entry.tiers) do
		local take = math.min(tier.qty, remaining)
		total = total + take * tier.price
		remaining = remaining - take
		if remaining <= 0 then break end
	end
	return total
end

local function UpdateCommodityTotals(entry)
	local available, profit = 0, 0
	for _, tier in ipairs(entry.tiers) do
		available = available + tier.qty
		if entry.vendor then
			profit = profit + (entry.vendor - tier.price) * tier.qty
		end
	end
	entry.quantity = available
	entry.unit = entry.tiers[1] and entry.tiers[1].price or 0
	entry.profit = profit
	-- the buy amount follows the supply until the user types their own
	if not entry.qtyEdited or not entry.buyQty then
		entry.buyQty = available
	end
	entry.buyQty = math.max(1, math.min(entry.buyQty, available))
	if available <= 0 then entry.gone = true end
end

local function UpdateAuctionTotals(entry)
	entry.unit = entry.buyout
	entry.profit = entry.vendor and (entry.vendor - entry.buyout) * entry.quantity or 0
end

local function SameLot(entry, auction)
	return entry.buyout == auction.buyout and entry.link == auction.link
end

-- Replaces the auctions listed for one item key with `found`. Auctions that
-- are still up keep their entry (and their place in the list). A row whose
-- auction ID is gone carries on with an auction of the same lot: the server
-- hands a lot a new ID when one of it is bought. Rows that were bought from
-- (spent) are matched first.
function Results:SetAuctions(mode, key, found, pass)
	local list = self.lists[mode]
	local existing = {}
	for _, entry in ipairs(list) do
		if entry.kind == 'item' and entry.key == key and not entry.gone then
			existing[entry.auctionID] = entry
		end
	end

	local function Apply(entry, auction)
		entry.auctionID = auction.auctionID
		entry.quantity = auction.quantity
		entry.buyout = auction.buyout
		entry.vendor = auction.vendor
		entry.limit = auction.limit
		entry.link = entry.link or auction.link
		entry.spent = nil
		entry.pass = pass
		UpdateAuctionTotals(entry)
	end

	local fresh = {}
	for _, auction in ipairs(found) do
		local entry = existing[auction.auctionID]
		if entry then
			existing[auction.auctionID] = nil
			Apply(entry, auction)
		else
			fresh[#fresh + 1] = auction
		end
	end

	for _, auction in ipairs(fresh) do
		local adopted, adoptedID
		for auctionID, entry in pairs(existing) do
			if SameLot(entry, auction) and (not adopted or entry.spent) then
				adopted, adoptedID = entry, auctionID
			end
		end
		if adopted then existing[adoptedID] = nil end
		if adopted then
			Apply(adopted, auction)
		else
			local entry = { kind = 'item', key = key, itemID = auction.itemID, itemKey = auction.itemKey,
				link = auction.link, found = NextSerial() }
			Apply(entry, auction)
			Insert(list, entry)
			Alert(mode)
		end
	end

	for _, entry in pairs(existing) do
		entry.gone = true
	end
	Changed()
end

-- The client's auctions of an item changed without the scanner asking for
-- them, e.g. after a purchase. Rows whose auction ID is no longer among them
-- move to the same lot's new ID, since a Buy with the old one is dropped.
-- Nothing is marked gone here; a reload settles that.
function Results:SyncItem(itemKey)
	local AH = C_AuctionHouse
	if not (itemKey and AH.HasSearchResults(itemKey)) then return end
	local results, held = {}, {}
	for index = 1, AH.GetNumItemSearchResults(itemKey) do
		local result = AH.GetItemSearchResultInfo(itemKey, index)
		if result and result.buyoutAmount and not result.containsOwnerItem and not result.containsAccountItem then
			results[#results + 1] = result
			held[result.auctionID] = true
		end
	end

	local lost = {}
	for _, entry in ipairs(self.lists[ns.db.mode]) do
		if entry.kind == 'item' and entry.itemID == itemKey.itemID and not entry.gone and entry.auctionID then
			if held[entry.auctionID] then
				held[entry.auctionID] = 'taken'
			else
				lost[#lost + 1] = entry
			end
		end
	end

	local changed = false
	for _, entry in ipairs(lost) do
		for _, result in ipairs(results) do
			if held[result.auctionID] == true and result.buyoutAmount == entry.buyout
				and result.itemLink == entry.link then
				held[result.auctionID] = 'taken'
				ns.Debug(('lot moved from auction %d to %d'):format(entry.auctionID, result.auctionID))
				entry.auctionID = result.auctionID
				entry.quantity = math.max(result.quantity or 1, 1)
				UpdateAuctionTotals(entry)
				changed = true
				break
			end
		end
	end
	if changed then Changed() end
end

-- One item of a lot was bought. A lot is a group of identical auctions that
-- the server shows as one row, and every purchase takes one of them, so what
-- is left has to be looked up again before the row can be bought from.
function Results:TakeOne(entry)
	entry.quantity = entry.quantity - 1
	entry.bought = true -- only shows once the row is gone
	-- one upgrade per slot is all that is wanted
	if entry.quantity <= 0 or entry.slot then
		entry.gone = true
	else
		entry.spent = true
		UpdateAuctionTotals(entry)
	end
	Changed()
end

-- the row's auction is not there any more, the rest of its lot may be
function Results:MarkSpent(entry)
	entry.spent = true
	Changed()
end

-- the lookup of a lot's remaining auctions failed
function Results:DropSpent(mode, key)
	for _, entry in ipairs(self.lists[mode]) do
		if entry.key == key and entry.spent and not entry.gone then
			entry.gone = true
		end
	end
	Changed()
end

function Results:FindSlot(slot)
	for _, entry in ipairs(self.lists.upgrade) do
		if entry.slot == slot and not entry.gone then return entry end
	end
end

-- Shows `data` (see Upgrade:Apply) as the upgrade of one slot. Another
-- auction gets a new row and the old one turns grey, so a row never changes
-- into a different item right under the cursor.
function Results:SetUpgrade(slot, data, pass)
	local entry = self:FindSlot(slot)
	if entry and entry.auctionID ~= data.auctionID then
		entry.gone = true
		entry = nil
	end
	if not entry then
		entry = { kind = 'item', found = NextSerial() }
		Insert(self.lists.upgrade, entry)
	end
	for field, value in pairs(data) do
		entry[field] = value
	end
	entry.spent = nil
	entry.pass = pass
	UpdateAuctionTotals(entry)
	Changed()
end

-- Sets (or with tiers == nil / empty, drops) the commodity entry of one item key.
function Results:SetCommodity(mode, key, data, pass)
	local list = self.lists[mode]
	local entry
	for _, candidate in ipairs(list) do
		if candidate.kind == 'commodity' and candidate.key == key and not candidate.gone then
			entry = candidate
			break
		end
	end

	if data and #data.tiers > 0 then
		local before = 0
		if not entry then
			entry = { kind = 'commodity', key = key, itemID = data.itemID, itemKey = data.itemKey,
				found = NextSerial() }
			Insert(list, entry)
		else
			before = entry.quantity or 0
		end
		entry.tiers = data.tiers
		entry.limit = data.limit
		entry.vendor = data.vendor
		entry.pass = pass
		UpdateCommodityTotals(entry)
		-- fewer units means some sold; more means somebody posted
		if entry.quantity > before then Alert(mode) end
	elseif entry then
		entry.gone = true
	end
	Changed()
end

-- Takes bought units off a commodity entry, cheapest first.
function Results:Consume(entry, quantity)
	local remaining = quantity
	while remaining > 0 and entry.tiers[1] do
		local tier = entry.tiers[1]
		local take = math.min(tier.qty, remaining)
		tier.qty = tier.qty - take
		remaining = remaining - take
		if tier.qty <= 0 then table.remove(entry.tiers, 1) end
	end
	entry.bought = true
	entry.qtyEdited = false
	UpdateCommodityTotals(entry)
	Changed()
end

function Results:MarkGone(entry)
	entry.gone = true
	Changed()
end

-- the browse data of an item did not change since the last pass: keep its entries
function Results:Touch(mode, key, pass)
	for _, entry in ipairs(self.lists[mode]) do
		if entry.key == key and not entry.gone then
			entry.pass = pass
		end
	end
end

-- everything a finished pass did not see is no longer on the auction house
function Results:EndPass(mode, pass)
	local changed = false
	for _, entry in ipairs(self.lists[mode]) do
		if not entry.gone and entry.pass ~= pass then
			entry.gone = true
			changed = true
		end
	end
	if changed then Changed() end
end

local function NewestFirst(a, b)
	return a.found > b.found
end

-- order of the live rows
local comparators = {
	vendor = NewestFirst,
	search = NewestFirst,
	watch = NewestFirst,
	-- in equipment slot order
	upgrade = function(a, b)
		if a.order ~= b.order then return a.order < b.order end
		return a.gain > b.gain
	end,
}

-- Re-sorts: live rows on top, gone ones below them (the latest to go first),
-- and drops the oldest gone rows past MAX_GONE. This moves rows around, so
-- the UI only calls it while no click is about to land (UI:HoldsRows).
function Results:Compact(mode)
	local list = self.lists[mode]
	for _, entry in ipairs(list) do
		if entry.gone and not entry.goneOrder then
			entry.goneOrder = NextSerial()
		end
	end
	local live = comparators[mode]
	table.sort(list, function(a, b)
		if (a.gone or false) ~= (b.gone or false) then return not a.gone end
		if a.gone then return a.goneOrder > b.goneOrder end
		return live(a, b)
	end)
	local gone = 0
	for index = 1, #list do
		if list[index].gone then gone = gone + 1 end
	end
	for _ = MAX_GONE + 1, gone do
		list[#list] = nil
	end
end
