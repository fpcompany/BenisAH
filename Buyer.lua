local _, ns = ...

-- Purchases. Every purchase starts inside a click handler, because the
-- auction house only accepts PlaceBid / StartCommoditiesPurchase from a
-- hardware event.
--
-- Single items are bought with one PlaceBid at the buyout price. Identical
-- auctions of a seller show up as one lot, and each click buys one item of it.
--
-- Stackable items (commodities) go through a server quote:
--   click -> StartCommoditiesPurchase -> COMMODITY_PRICE_UPDATED (the quote)
--         -> ConfirmCommoditiesPurchase -> COMMODITY_PURCHASE_SUCCEEDED
-- The quote is confirmed automatically, but only when its total is within
-- quantity x limit; anything dearer is cancelled. Should the server not act on
-- the automatic confirm, the row's button turns into "Confirm" and a second
-- click sends it from a hardware event.
local Buyer = {
	-- purchases since the auction house was opened; value is what a vendor
	-- pays for them, profit that minus what they cost (vendor mode only)
	session = { count = 0, spent = 0, profit = 0 },
}
ns.Buyer = Buyer

local AH = C_AuctionHouse
local Results = ns.Results

local QUOTE_TIMEOUT = 10 -- seconds to wait for a commodity quote
local AUTO_CONFIRM_TIMEOUT = 4 -- seconds before falling back to a manual confirm
local PURCHASE_TIMEOUT = 10 -- seconds to wait for the purchase result

-- pending = { kind, entry, state = 'quote' | 'buying' | 'confirm', since, ... }

function Buyer:Record(count, spent, vendorValue)
	local session = self.session
	session.count = session.count + count
	session.spent = session.spent + spent
	if vendorValue then
		session.profit = session.profit + vendorValue - spent
	end
end

function Buyer:IsBusy()
	return self.pending ~= nil
end

local function Refresh()
	if ns.UI then ns.UI:MarkDirty() end
end

local function ItemText(entry)
	ns.ResolveInfo(entry)
	return entry.link or entry.name or ('item ' .. entry.itemID)
end

function Buyer:SetPending(pending)
	self.pending = pending
	if pending then
		pending.since = GetTime()
		self.timer:Show()
	else
		self.timer:Hide()
	end
	Refresh()
end

-- The search result of an item entry's auction, if the client holds it.
-- PlaceBid on an auction the client does not hold is dropped without a word.
function Buyer:FindLoaded(entry)
	local itemKey = entry.itemKey
	if entry.kind ~= 'item' or not (itemKey and entry.auctionID and AH.HasSearchResults(itemKey)) then
		return nil
	end
	for index = 1, AH.GetNumItemSearchResults(itemKey) do
		local result = AH.GetItemSearchResultInfo(itemKey, index)
		if result and result.auctionID == entry.auctionID then
			return result, index
		end
	end
end

-- What the client holds for an item auction right now (debug log only).
local function DescribeAuction(entry)
	local itemKey = entry.itemKey
	if not (itemKey and AH.HasSearchResults(itemKey)) then
		return 'client holds no search results for this item'
	end
	local count = AH.GetNumItemSearchResults(itemKey)
	local result, index = Buyer:FindLoaded(entry)
	if result then
		return ('auction %d is result %d/%d: buyout %s, qty %s, own %s'):format(entry.auctionID, index, count,
			tostring(result.buyoutAmount), tostring(result.quantity),
			tostring(result.containsOwnerItem or result.containsAccountItem))
	end
	return ('auction %d is NOT among the %d results the client holds'):format(entry.auctionID, count)
end

function Buyer:Fail(reason)
	local pending = self.pending
	if not pending then return end
	ns.Debug(('fail after %.1fs: %s'):format(GetTime() - pending.since, tostring(reason)))
	if pending.kind == 'item' then ns.Debug(DescribeAuction(pending.entry)) end
	if pending.kind == 'commodity' and pending.state ~= 'buying' then
		AH.CancelCommoditiesPurchase()
	end
	-- whatever went wrong, the scanner should look at this item again
	ns.Scanner:Invalidate(pending.entry.key)
	self:SetPending(nil)
	if reason then
		ns.Print(('%s not bought: %s'):format(ItemText(pending.entry), reason))
	end
end

-- Called from the Buy button's OnClick (a hardware event).
function Buyer:Buy(entry, quantity)
	local pending = self.pending
	if pending then
		-- second click on a quote that was not confirmed automatically
		if pending.entry == entry and pending.state == 'confirm' then
			pending.state = 'buying'
			pending.auto = false
			pending.since = GetTime()
			AH.ConfirmCommoditiesPurchase(pending.itemID, pending.quantity)
			Refresh()
		end
		return
	end
	if entry.gone or entry.spent or entry.loading then return end

	if entry.kind == 'item' then
		local loaded = self:FindLoaded(entry)
		if not loaded or loaded.buyoutAmount ~= entry.buyout then
			-- the purchase would be dropped: load the auctions, then click again
			ns.Debug(DescribeAuction(entry))
			ns.Scanner:Load(entry)
			return
		end
		if GetMoney() < entry.buyout then
			ns.Print('not enough money for ' .. ItemText(entry) .. '.')
			return
		end
		ns.Debug(('PlaceBid %d for %s (row qty %d), throttle ready %s, scan waiting on %s'):format(
			entry.auctionID, tostring(entry.buyout), entry.quantity,
			tostring(AH.IsThrottledMessageSystemReady()),
			ns.Scanner.waiting and ns.Scanner.waiting.kind or 'nothing'))
		ns.Debug(DescribeAuction(entry))
		self:SetPending({ kind = 'item', entry = entry, state = 'buying', auctionID = entry.auctionID })
		AH.PlaceBid(entry.auctionID, entry.buyout)
	else
		quantity = math.floor(tonumber(quantity) or 0)
		quantity = math.max(1, math.min(quantity, entry.quantity))
		if GetMoney() < ns.CostFor(entry, quantity) then
			ns.Print('not enough money for ' .. quantity .. 'x ' .. ItemText(entry) .. '.')
			return
		end
		self:SetPending({
			kind = 'commodity',
			entry = entry,
			state = 'quote',
			itemID = entry.itemID,
			quantity = quantity,
			limitTotal = entry.limit * quantity,
		})
		AH.StartCommoditiesPurchase(entry.itemID, quantity)
	end
end

-- The commodity's listing was out of date (the quote came in dearer, or the
-- price is gone): look it up again. The amount box follows what is left
-- within the limit; the button shows '...' until then.
function Buyer:Reload(entry)
	entry.qtyEdited = false
	ns.Scanner:Load(entry)
end

function Buyer:Cancel()
	if self.pending then self:Fail(nil) end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function Buyer:OnQuote(unitPrice, totalPrice)
	local pending = self.pending
	if not pending or pending.kind ~= 'commodity' or pending.state == 'buying' then return end

	if totalPrice > pending.limitTotal then
		self:Fail(('the quote of %s is above your limit of %s; reloading what is left.'):format(
			ns.Money(totalPrice), ns.Money(pending.limitTotal)))
		self:Reload(pending.entry)
	elseif totalPrice > GetMoney() then
		self:Fail('not enough money.')
	else
		pending.total = totalPrice
		if pending.state == 'quote' then
			pending.state = 'buying'
			pending.auto = true
			pending.since = GetTime()
			AH.ConfirmCommoditiesPurchase(pending.itemID, pending.quantity)
		end
		Refresh()
	end
end

function Buyer:OnCommodityBought()
	local pending = self.pending
	if not pending or pending.kind ~= 'commodity' then return end
	local entry = pending.entry
	local message = ('bought %dx %s for %s'):format(pending.quantity, ItemText(entry), ns.Money(pending.total))
	if entry.vendor then
		message = message .. (' (vendors for %s)'):format(ns.Money(entry.vendor * pending.quantity))
	end
	ns.Print(message .. '.')
	PlaySound(SOUNDKIT.LOOT_WINDOW_COIN_SOUND)
	self:Record(pending.quantity, pending.total or 0, entry.vendor and entry.vendor * pending.quantity)
	Results:Consume(entry, pending.quantity)
	ns.Scanner:Invalidate(entry.key)
	self:SetPending(nil)
end

function Buyer:OnItemBought(auctionID)
	local pending = self.pending
	if not pending or pending.kind ~= 'item' or pending.auctionID ~= auctionID then return end
	local entry = pending.entry
	local message = ('bought %s for %s'):format(ItemText(entry), ns.Money(entry.buyout))
	if entry.vendor then
		message = message .. (' (vendors for %s)'):format(ns.Money(entry.vendor))
	end
	ns.Print(message .. '.')
	PlaySound(SOUNDKIT.LOOT_WINDOW_COIN_SOUND)
	self:Record(1, entry.buyout, entry.vendor)
	Results:TakeOne(entry)
	if entry.gone then
		ns.Scanner:Invalidate(entry.key)
	else
		ns.Scanner:Refresh(entry) -- find the lot's next auction
	end
	self:SetPending(nil)
end

function Buyer:OnError(auctionHouseError)
	local pending = self.pending
	if not pending then return end
	local errors = Enum.AuctionHouseError
	if auctionHouseError == errors.ItemNotFound or auctionHouseError == errors.ItemNotAvailable
		or auctionHouseError == errors.Unavailable then
		local entry = pending.entry
		if entry.kind == 'item' and entry.quantity > 1 and not entry.slot then
			-- somebody else got this one; the rest of the lot may still be up
			Results:MarkSpent(entry)
			ns.Scanner:Refresh(entry)
		else
			Results:MarkGone(entry)
		end
	end
	local text = AuctionHouseUtil and AuctionHouseUtil.GetErrorText(auctionHouseError)
	self:Fail((text and text ~= '') and text or 'the auction house refused the purchase.')
end

function Buyer:OnUpdate()
	local pending = self.pending
	if not pending then
		self.timer:Hide()
		return
	end
	local elapsed = GetTime() - pending.since

	if pending.state == 'quote' then
		if elapsed > QUOTE_TIMEOUT then
			self:Fail('no price quote from the auction house.')
		end
	elseif pending.state == 'confirm' then
		if AH.GetQuoteDurationRemaining() <= 0 then
			self:Fail('the price quote expired.')
		end
	elseif pending.kind == 'commodity' and pending.auto then
		if elapsed > AUTO_CONFIRM_TIMEOUT then
			if AH.GetQuoteDurationRemaining() > 0 then
				-- the automatic confirm went unanswered: ask for a click
				pending.state = 'confirm'
				pending.auto = false
				Refresh()
			else
				self:Fail('no answer from the auction house.')
			end
		end
	elseif elapsed > PURCHASE_TIMEOUT then
		self:Fail('no answer from the auction house.')
	end
end

Buyer.timer = CreateFrame('Frame')
Buyer.timer:Hide()
Buyer.timer:SetScript('OnUpdate', function() Buyer:OnUpdate() end)

ns.On('COMMODITY_PRICE_UPDATED', function(unitPrice, totalPrice) Buyer:OnQuote(unitPrice, totalPrice) end)
ns.On('COMMODITY_PRICE_UNAVAILABLE', function()
	local pending = Buyer.pending
	if pending and pending.kind == 'commodity' then
		Buyer:Fail('that price is no longer available; reloading what is left.')
		Buyer:Reload(pending.entry)
	end
end)
ns.On('COMMODITY_PURCHASE_SUCCEEDED', function() Buyer:OnCommodityBought() end)
ns.On('COMMODITY_PURCHASE_FAILED', function()
	if Buyer.pending and Buyer.pending.kind == 'commodity' then
		Buyer.pending.state = 'buying' -- the quote is spent, nothing left to cancel
		Buyer:Fail('the purchase failed.')
	end
end)
ns.On('AUCTION_HOUSE_PURCHASE_COMPLETED', function(auctionID) Buyer:OnItemBought(auctionID) end)
ns.On('AUCTION_HOUSE_SHOW_ERROR', function(auctionHouseError) Buyer:OnError(auctionHouseError) end)
-- A click that lands while a scan query is still in flight is queued by the
-- client's throttle; if the client drops it instead, say so rather than wait.
ns.On('AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED', function()
	local pending = Buyer.pending
	if pending and (pending.state == 'quote' or pending.kind == 'item') then
		Buyer:Fail('the auction house was busy, click Buy again.')
	end
end)
ns.On('AUCTION_HOUSE_CLOSED', function()
	Buyer:Cancel()
	Buyer.session = { count = 0, spent = 0, profit = 0 }
end)

-- Debug log: everything the auction house says while a purchase is pending.
-- Events are registered one by one, as not every client knows all of them.
local debugFrame = CreateFrame('Frame')
for _, event in ipairs({
	'AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED',
	'AUCTION_HOUSE_THROTTLED_MESSAGE_SENT',
	'AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED',
	'AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED',
	'AUCTION_HOUSE_THROTTLED_SYSTEM_READY',
	'AUCTION_HOUSE_PURCHASE_COMPLETED',
	'AUCTION_HOUSE_SHOW_ERROR',
	'AUCTION_HOUSE_SHOW_NOTIFICATION',
	'AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION',
	'UI_ERROR_MESSAGE',
}) do
	pcall(debugFrame.RegisterEvent, debugFrame, event)
end
debugFrame:SetScript('OnEvent', function(_, event, ...)
	local pending = Buyer.pending
	if not (pending and ns.db and ns.db.debug) then return end
	local args = {}
	for index = 1, select('#', ...) do
		args[index] = tostring((select(index, ...)))
	end
	ns.Debug(('+%.1fs %s %s'):format(GetTime() - pending.since, event, table.concat(args, ', ')))
end)
