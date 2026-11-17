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
-- and gone (sold, expired or bought; shown greyed until the list compacts).
-- Upgrade mode keeps one 'item' entry per equipment slot, which also carries
-- slot, slotLabel, order, score, gain, equippedLink and equippedScore.
local Results = {
	lists = { vendor = {}, search = {}, upgrade = {} },
}
ns.Results = Results

local function Changed()
	if ns.UI then ns.UI:MarkDirty() end
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
-- are still up keep their entry (and their place in the list). A row that was
-- bought from (spent) carries on with the next auction of the same lot.
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
		local adopted
		for auctionID, entry in pairs(existing) do
			if entry.spent and SameLot(entry, auction) then
				adopted = entry
				existing[auctionID] = nil
				break
			end
		end
		if adopted then
			Apply(adopted, auction)
		else
			local entry = { kind = 'item', key = key, itemID = auction.itemID, itemKey = auction.itemKey,
				link = auction.link }
			Apply(entry, auction)
			list[#list + 1] = entry
		end
	end

	for _, entry in pairs(existing) do
		entry.gone = true
	end
	Changed()
end

-- One item of a lot was bought. A lot is a group of identical auctions that
-- the server shows as one row, and every purchase takes one of them, so what
-- is left has to be looked up again before the row can be bought from.
function Results:TakeOne(entry)
	entry.quantity = entry.quantity - 1
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
		entry = { kind = 'item' }
		table.insert(self.lists.upgrade, entry)
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
		if not entry then
			entry = { kind = 'commodity', key = key, itemID = data.itemID, itemKey = data.itemKey }
			list[#list + 1] = entry
		end
		entry.tiers = data.tiers
		entry.limit = data.limit
		entry.vendor = data.vendor
		entry.pass = pass
		UpdateCommodityTotals(entry)
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

local comparators = {
	-- best total profit first
	vendor = function(a, b)
		if a.profit ~= b.profit then return a.profit > b.profit end
		return a.unit < b.unit
	end,
	-- cheapest first
	search = function(a, b)
		if a.unit ~= b.unit then return a.unit < b.unit end
		return a.quantity > b.quantity
	end,
	-- in equipment slot order
	upgrade = function(a, b)
		if a.order ~= b.order then return a.order < b.order end
		return a.gain > b.gain
	end,
}

-- Drops gone entries and re-sorts. This moves rows around, so the UI only
-- calls it while the mouse is away from the list.
function Results:Compact(mode)
	local list = self.lists[mode]
	local kept = 0
	for index = 1, #list do
		local entry = list[index]
		if not entry.gone then
			kept = kept + 1
			list[kept] = entry
		end
	end
	for index = #list, kept + 1, -1 do
		list[index] = nil
	end
	table.sort(list, comparators[mode])
end
