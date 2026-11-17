local _, ns = ...

-- Scans the auction house in a loop until stopped.
--
-- A pass sends one browse query per selected category (vendor mode), one
-- name query (search mode) or one query per selected equipment slot (upgrade
-- mode, see Upgrade.lua) and pages through the results. Browse results are
-- grouped per item and only carry the lowest price, so every item whose lowest
-- price is within the limit becomes a candidate and gets its own search query,
-- which returns the real auctions. Candidates are checked before the next
-- browse page is requested, so finds show up early.
--
-- Only one query is ever in flight: the next one is sent once the previous
-- answer arrived, the user's delay passed, the server throttle is ready and no
-- purchase is pending.
local Scanner = {
	running = false,
	token = 0, -- bumped on start/stop, invalidates late item-data callbacks
	pass = 0,
}
ns.Scanner = Scanner

local AH = C_AuctionHouse
local Results = ns.Results

local RESPONSE_TIMEOUT = 8 -- seconds to wait for an answer before moving on
local INFO_TIMEOUT = 4 -- seconds to wait for item data (vendor prices)
local MAX_EXTRA_PAGES = 5 -- extra result pages requested per item

local BROWSE_SORTS = {
	{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
	{ sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false },
}
local ITEM_SORTS = {
	{ sortOrder = Enum.AuctionHouseSortOrder.Buyout, reverseSort = false },
}

-- The default UI always sends every rarity filter; a query without them is
-- not guaranteed to return anything.
local function QualityFilters()
	local filters = {}
	for _, group in ipairs(AH.GetFilterGroups and AH.GetFilterGroups() or {}) do
		if group.category == Enum.AuctionHouseFilterCategory.Rarity then
			for _, filter in ipairs(group.filters) do
				filters[#filters + 1] = filter
			end
		end
	end
	if #filters == 0 then
		for _, name in ipairs({ 'PoorQuality', 'CommonQuality', 'UncommonQuality', 'RareQuality',
			'EpicQuality', 'LegendaryQuality', 'ArtifactQuality' }) do
			local filter = Enum.AuctionHouseFilter[name]
			if filter then filters[#filters + 1] = filter end
		end
	end
	return filters
end

-- the auction house's top-level categories ("tabs") that can be browsed
function ns.GetCategories()
	local categories = {}
	for _, category in ipairs(AuctionCategories or {}) do
		local isToken = category.HasFlag and category:HasFlag('WOW_TOKEN_FLAG')
		if not isToken and category.filters and #category.filters > 0 then
			categories[#categories + 1] = { name = category.name, filters = category.filters }
		end
	end
	return categories
end

--------------------------------------------------------------------------------
-- Start / stop
--------------------------------------------------------------------------------

function Scanner:Start(mode)
	if self.running then self:Stop() end

	local queries = {}
	if mode == 'vendor' then
		for _, category in ipairs(ns.GetCategories()) do
			if not ns.db.skipCategories[category.name] then
				queries[#queries + 1] = {
					label = category.name,
					searchString = '',
					itemClassFilters = category.filters,
				}
			end
		end
		if #queries == 0 then
			ns.Print('pick at least one category to scan.')
			return false
		end
	elseif mode == 'upgrade' then
		-- the queries are built again every pass, from what is equipped then
		queries = ns.Upgrade:BeginPass()
		if not queries then return false end
		ns.Upgrade:Reset()
	else
		local name = strtrim(ns.db.searchName or '')
		if name == '' then
			ns.Print('enter an item name first.')
			return false
		end
		if (ns.db.searchMax or 0) <= 0 then
			ns.Print('enter a max price first.')
			return false
		end
		queries[1] = { label = name, searchString = name, exact = ns.db.exactMatch }
		self.maxPrice = ns.db.searchMax
	end

	self.mode = mode
	self.queries = queries
	self.oneShot = false
	self.token = self.token + 1
	self.running = true
	self.pass = 0
	self.cache = {} -- [key] = browse data of items whose auctions are already known
	self.lastSent = 0
	Results:Clear(mode)
	self:BeginPass()
	self.driver:Show()
	return true
end

function Scanner:Stop()
	if not self.running then return end
	self.running = false
	self.oneShot = false
	self.token = self.token + 1
	self.waiting = nil
	self.driver:Hide()
end

-- Looks up the auctions of one listed item again, ahead of everything else.
-- Works without a scan running too: then it is the only query sent.
function Scanner:Refresh(entry)
	local candidate = { key = entry.key, itemKey = entry.itemKey, vendor = entry.vendor, limit = entry.limit }
	if entry.kind == 'item' and entry.vendor then
		candidate.limit = entry.vendor - 1
	end
	self:Invalidate(entry.key)

	if self.running then
		table.insert(self.queue, 1, candidate)
		return
	end

	self.mode = ns.db.mode
	self.queries = {}
	self.oneShot = true
	self.token = self.token + 1
	self.running = true
	self.cache = self.cache or {}
	self.lastSent = self.lastSent or 0
	self.queryIndex = 0
	self.browseOpen = false
	self.seen = {}
	self.queue = { candidate }
	self.more = nil
	self.pendingInfo = 0
	self.infoActivity = GetTime()
	self.waiting = nil
	self.driver:Show()
end

function Scanner:BeginPass()
	self.pass = self.pass + 1
	self.queryIndex = 0
	self.browseOpen = false -- a browse query with result pages left
	self.seen = {} -- item keys already evaluated this pass
	self.queue = {} -- candidates waiting for their search query
	self.more = nil -- candidate that needs another page of search results
	self.pendingInfo = 0 -- items waiting for their item data
	self.infoActivity = GetTime()
	self.waiting = nil -- the query in flight
	self.queueSorted = false

	if self.mode == 'upgrade' then
		local queries = ns.Upgrade:BeginPass()
		if not queries then
			self:Stop()
			return
		end
		self.queries = queries
		self.maxPrice = ns.Upgrade.maxPrice -- per slot limits come from what is equipped
	end
end

function Scanner:FinishPass()
	if self.mode == 'upgrade' then ns.Upgrade:FinishPass() end
	Results:EndPass(self.mode, self.pass)
	self:BeginPass()
end

-- the auctions of this item changed (bought, failed to buy): look again
function Scanner:Invalidate(key)
	if self.cache then self.cache[key] = nil end
	ns.Upgrade:Forget(key)
end

function Scanner:QueueLength()
	return self.queue and #self.queue or 0
end

function Scanner:GetStatus()
	if not self.running then return nil end
	if self.oneShot then return 'Refreshing' end
	local query = self.queries[self.queryIndex]
	return ('Pass %d: %s (%d/%d), %d to check'):format(self.pass, query and query.label or 'starting',
		math.max(self.queryIndex, 1), #self.queries, self:QueueLength())
end

--------------------------------------------------------------------------------
-- Driver
--------------------------------------------------------------------------------

function Scanner:Tick()
	if not self.running then return end
	local now = GetTime()

	if self.waiting then
		if now - self.waiting.since > RESPONSE_TIMEOUT then
			self:Abandon()
		end
		return
	end

	if ns.Buyer:IsBusy() then return end
	if now - self.lastSent < (ns.db.delay or 1) then return end
	if not AH.IsThrottledMessageSystemReady() then return end

	self:Next(now)
end

-- no answer (or a failure): skip what was asked and carry on
function Scanner:Abandon()
	local waiting = self.waiting
	self.waiting = nil
	if not waiting then return end
	if waiting.kind == 'browse' or waiting.kind == 'browseMore' then
		self.browseOpen = false
		return
	end

	-- No event came, but the client may hold results for this item anyway
	-- (it does when the same item was searched moments ago): use those.
	local itemKey = waiting.candidate.itemKey
	if AH.HasSearchResults(itemKey) then
		self.waiting = waiting
		local info = AH.GetItemKeyInfo(itemKey)
		if info and info.isCommodity then
			self:OnCommodityResults(itemKey.itemID)
		else
			self:OnItemResults(itemKey)
		end
	else
		Results:DropSpent(self.mode, waiting.candidate.key)
	end
end

function Scanner:Wait(kind, candidate, pages)
	local now = GetTime()
	self.waiting = { kind = kind, candidate = candidate, pages = pages or 0, since = now }
	self.lastSent = now
end

function Scanner:Next(now)
	-- 1. more result pages of the item being checked
	if self.more then
		local more = self.more
		self.more = nil
		self:Wait('detailMore', more.candidate, more.pages)
		local itemKey = more.candidate.itemKey
		local full
		if more.commodity then
			full = AH.RequestMoreCommoditySearchResults(itemKey.itemID)
		else
			full = AH.RequestMoreItemSearchResults(itemKey)
		end
		if full then -- nothing was requested, so nothing will answer
			self.waiting = nil
			self:Remember(more.candidate)
		end
		return
	end

	-- 2. the next candidate; upgrade candidates wait until browsing is done
	-- (step 6), so that they can be checked best first
	local candidate = self.mode ~= 'upgrade' and table.remove(self.queue, 1)
	if candidate then
		self:Wait('detail', candidate)
		local info = AH.GetItemKeyInfo(candidate.itemKey)
		-- commodities come sorted by unit price; the default UI sends them no sorts
		local sorts = (info and not info.isCommodity) and ITEM_SORTS or {}
		AH.SendSearchQuery(candidate.itemKey, sorts, false)
		return
	end

	-- 3. the next page of the current browse query
	if self.browseOpen then
		if not AH.HasFullBrowseResults() then
			self:Wait('browseMore')
			AH.RequestMoreBrowseResults()
			return
		end
		self.browseOpen = false
	end

	-- 4. the next browse query
	if self.queryIndex < #self.queries then
		self.queryIndex = self.queryIndex + 1
		local query = self.queries[self.queryIndex]
		local filters = QualityFilters()
		if query.exact then
			filters[#filters + 1] = Enum.AuctionHouseFilter.ExactMatch
		end
		self:Wait('browse')
		AH.SendBrowseQuery({
			searchString = query.searchString,
			sorts = BROWSE_SORTS,
			filters = filters,
			itemClassFilters = query.itemClassFilters,
			minLevel = query.maxLevel and 0 or nil,
			maxLevel = query.maxLevel,
		})
		return
	end

	-- 5. item data (vendor prices, stats) still loading: give it a moment
	if self.pendingInfo > 0 and now - self.infoActivity < INFO_TIMEOUT then
		return
	end

	-- 6. upgrade candidates
	if self.mode == 'upgrade' and self:NextUpgrade() then
		return
	end

	if self.oneShot then
		self:Stop() -- a refresh of one item: nothing else to do
		return
	end
	self:FinishPass()
end

--------------------------------------------------------------------------------
-- Browse results
--------------------------------------------------------------------------------

function Scanner:AddCandidate(result, vendor, limit)
	local key = ns.KeyString(result.itemKey)
	local known = self.cache[key]
	if known and known.minPrice == result.minPrice and known.quantity == result.totalQuantity then
		-- nothing was posted or sold since the last look
		Results:Touch(self.mode, key, self.pass)
		return
	end
	self.queue[#self.queue + 1] = {
		key = key,
		itemKey = result.itemKey,
		vendor = vendor,
		limit = limit,
		minPrice = result.minPrice,
		quantity = result.totalQuantity,
	}
end

-- Sends the search query of the most promising upgrade candidate. Candidates
-- that are settled without one (no longer able to win, or unchanged since the
-- last look) are skipped. Returns false once none is left.
function Scanner:NextUpgrade()
	if not self.queueSorted then
		table.sort(self.queue, function(a, b) return a.estimate > b.estimate end)
		self.queueSorted = true
	end
	while #self.queue > 0 do
		local candidate = table.remove(self.queue, 1)
		if not ns.Upgrade:Resolve(candidate) then
			self:Wait('detail', candidate)
			AH.SendSearchQuery(candidate.itemKey, ITEM_SORTS, false)
			return true
		end
	end
	return false
end

function Scanner:AddUpgradeCandidate(candidate)
	self.queue[#self.queue + 1] = candidate
	self.queueSorted = false
end

-- Calls back once the item's data is loaded, unless the scan moved on to
-- another pass by then. Step 5 of Next waits for these.
function Scanner:LoadItem(itemID, callback)
	local token, pass = self.token, self.pass
	self.pendingInfo = self.pendingInfo + 1
	Item:CreateFromItemID(itemID):ContinueOnItemLoad(function()
		if token ~= self.token or pass ~= self.pass then return end
		self.pendingInfo = self.pendingInfo - 1
		self.infoActivity = GetTime()
		callback()
	end)
end

function Scanner:Remember(candidate)
	self.cache[candidate.key] = { minPrice = candidate.minPrice, quantity = candidate.quantity }
end

function Scanner:EvaluateVendor(result, retried)
	local itemID = result.itemKey.itemID
	local sellPrice = select(11, C_Item.GetItemInfo(itemID))
	if sellPrice then
		if sellPrice > 0 and result.minPrice < sellPrice then
			self:AddCandidate(result, sellPrice, sellPrice - 1)
		end
		return
	end
	if retried then return end

	-- item data is not cached yet; it arrives asynchronously
	local token, pass = self.token, self.pass
	self.pendingInfo = self.pendingInfo + 1
	Item:CreateFromItemID(itemID):ContinueOnItemLoad(function()
		if token ~= self.token or pass ~= self.pass then return end
		self.pendingInfo = self.pendingInfo - 1
		self.infoActivity = GetTime()
		self:EvaluateVendor(result, true)
	end)
end

function Scanner:ProcessBrowse(results)
	for _, result in ipairs(results or {}) do
		local itemKey = result.itemKey
		local key = ns.KeyString(itemKey)
		if not self.seen[key] then
			self.seen[key] = true
			local isPet = (itemKey.battlePetSpeciesID or 0) > 0
			if result.minPrice and result.minPrice > 0 and (result.totalQuantity or 0) > 0 then
				if self.mode == 'search' then
					if result.minPrice <= self.maxPrice then
						self:AddCandidate(result, nil, self.maxPrice)
					end
				elseif self.mode == 'upgrade' then
					if not isPet and result.minPrice <= self.maxPrice then
						ns.Upgrade:Consider(result, self.queries[self.queryIndex])
					end
				elseif not isPet then
					self:EvaluateVendor(result)
				end
			end
		end
	end
end

function Scanner:OnBrowseResults(added)
	local waiting = self.waiting
	if not (self.running and waiting) then return end
	if waiting.kind ~= 'browse' and waiting.kind ~= 'browseMore' then return end
	self.waiting = nil
	self.browseOpen = true
	self.infoActivity = GetTime()
	-- a full update re-reads everything; already evaluated items are skipped
	self:ProcessBrowse(added or AH.GetBrowseResults())
end

--------------------------------------------------------------------------------
-- Search results (the auctions of one item)
--------------------------------------------------------------------------------

function Scanner:TakeDetail(itemID)
	local waiting = self.waiting
	if not (self.running and waiting) then return end
	if waiting.kind ~= 'detail' and waiting.kind ~= 'detailMore' then return end
	if waiting.candidate.itemKey.itemID ~= itemID then return end
	self.waiting = nil
	return waiting
end

function Scanner:FinishDetail(waiting, wantMore, isCommodity)
	if wantMore and waiting.pages < MAX_EXTRA_PAGES then
		self.more = { candidate = waiting.candidate, pages = waiting.pages + 1, commodity = isCommodity }
	else
		self:Remember(waiting.candidate)
	end
end

function Scanner:OnItemResults(itemKey)
	local waiting = self:TakeDetail(itemKey.itemID)
	if not waiting then return end
	local candidate = waiting.candidate
	itemKey = candidate.itemKey

	if self.mode == 'upgrade' then
		-- sorted by buyout: the first buyable auction is the cheapest, and all
		-- auctions of one item key have the same stats
		local auction
		for index = 1, AH.GetNumItemSearchResults(itemKey) do
			local result = AH.GetItemSearchResultInfo(itemKey, index)
			local buyout = result and result.buyoutAmount
			if buyout and buyout > 0 and result.itemLink
				and not result.containsOwnerItem and not result.containsAccountItem then
				auction = { auctionID = result.auctionID, link = result.itemLink, buyout = buyout,
					quantity = math.max(result.quantity or 1, 1) }
				break
			end
		end
		ns.Upgrade:OnAuction(candidate, auction)
		return
	end

	local found = {}
	local lastOpen = false -- the last loaded auction still qualifies (or has no buyout)
	local count = AH.GetNumItemSearchResults(itemKey)
	for index = 1, count do
		local result = AH.GetItemSearchResultInfo(itemKey, index)
		if result then
			-- the buyout is the price of ONE item; quantity counts the identical
			-- auctions of the seller that the server folded into this row
			local buyout = result.buyoutAmount
			local quantity = math.max(result.quantity or 1, 1)
			lastOpen = not buyout or buyout == 0
			-- own auctions (this character's or the account's) cannot be bought
			if buyout and buyout > 0 and not result.containsOwnerItem and not result.containsAccountItem then
				local vendor, limit = candidate.vendor, candidate.limit
				if self.mode == 'vendor' and result.itemLink then
					-- the exact item can vendor for more or less than its base item
					local sellPrice = select(11, C_Item.GetItemInfo(result.itemLink))
					if sellPrice and sellPrice > 0 then
						vendor, limit = sellPrice, sellPrice - 1
					end
				end
				if buyout <= limit then
					lastOpen = true
					found[#found + 1] = {
						auctionID = result.auctionID,
						itemID = itemKey.itemID,
						itemKey = itemKey,
						link = result.itemLink,
						quantity = quantity,
						buyout = buyout,
						vendor = vendor,
						limit = limit,
					}
				end
			end
		end
	end

	Results:SetAuctions(self.mode, candidate.key, found, self.pass)
	self:FinishDetail(waiting, count > 0 and lastOpen and not AH.HasFullItemSearchResults(itemKey), false)
end

function Scanner:OnCommodityResults(itemID)
	local waiting = self:TakeDetail(itemID)
	if not waiting then return end
	local candidate = waiting.candidate
	if self.mode == 'upgrade' then return end -- gear is never a commodity

	local tiers = {}
	local lastOpen = false
	local count = AH.GetNumCommoditySearchResults(itemID)
	for index = 1, count do
		local result = AH.GetCommoditySearchResultInfo(itemID, index)
		if result then
			local quantity = (result.quantity or 0) - (result.numOwnerItems or 0)
			lastOpen = result.unitPrice <= candidate.limit
			if lastOpen and quantity > 0 then
				local last = tiers[#tiers]
				if last and last.price == result.unitPrice then
					last.qty = last.qty + quantity
				else
					tiers[#tiers + 1] = { price = result.unitPrice, qty = quantity }
				end
			end
		end
	end
	table.sort(tiers, function(a, b) return a.price < b.price end)

	Results:SetCommodity(self.mode, candidate.key, {
		itemID = itemID,
		itemKey = candidate.itemKey,
		tiers = tiers,
		limit = candidate.limit,
		vendor = candidate.vendor,
	}, self.pass)
	self:FinishDetail(waiting, count > 0 and lastOpen and not AH.HasFullCommoditySearchResults(itemID), true)
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

Scanner.driver = CreateFrame('Frame')
Scanner.driver:Hide()
Scanner.driver:SetScript('OnUpdate', function() Scanner:Tick() end)

ns.On('AUCTION_HOUSE_BROWSE_RESULTS_UPDATED', function() Scanner:OnBrowseResults() end)
ns.On('AUCTION_HOUSE_BROWSE_RESULTS_ADDED', function(added) Scanner:OnBrowseResults(added) end)
ns.On('AUCTION_HOUSE_BROWSE_FAILURE', function()
	local waiting = Scanner.waiting
	if waiting and (waiting.kind == 'browse' or waiting.kind == 'browseMore') then
		Scanner:Abandon()
	end
end)
ns.On('ITEM_SEARCH_RESULTS_UPDATED', function(itemKey) Scanner:OnItemResults(itemKey) end)
ns.On('ITEM_SEARCH_RESULTS_ADDED', function(itemKey) Scanner:OnItemResults(itemKey) end)
ns.On('COMMODITY_SEARCH_RESULTS_UPDATED', function(itemID) Scanner:OnCommodityResults(itemID) end)
ns.On('COMMODITY_SEARCH_RESULTS_ADDED', function(itemID) Scanner:OnCommodityResults(itemID) end)
ns.On('AUCTION_HOUSE_CLOSED', function() Scanner:Stop() end)
