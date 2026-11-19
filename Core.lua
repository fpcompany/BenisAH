local ADDON_NAME, ns = ...

-- BenisAH: an auction house tab that hunts for cheap buyouts.
--
-- Works on the modern auction house (C_AuctionHouse), which is what both
-- retail (Midnight) and WoW Forever run. The rules that shape the addon:
--   * queries go through the server's throttle, one at a time (Scanner.lua)
--   * browse results are grouped per item, so every hit needs a second,
--     per-item query to get the actual auctions
--   * every purchase has to start from a hardware event, i.e. a click
--     (Buyer.lua); nothing is ever bought automatically

ns.TITLE = '|cff1784d1Benis|rAH'

local defaults = {
	delay = 1, -- seconds between server queries, on top of the server throttle
	mode = 'vendor', -- 'vendor' (below vendor price), 'search' (name + max price), 'watch' or 'upgrade'
	skipCategories = {}, -- [category name] = true for categories left out of the vendor scan
	minProfit = 0, -- copper; vendor mode drops lots whose total profit is lower
	searchName = '',
	searchMax = 0, -- copper, per unit
	exactMatch = false,
	-- watch mode: one item, by its exact name
	watchName = '',
	watchMax = 0, -- copper, per unit
	watchAlert = true, -- sound and taskbar flash when a cheap auction shows up
	-- upgrade mode
	skipSlots = {}, -- [slot key] = true for slots left out of the upgrade search
	upgradeMax = 0, -- copper, per item; 0 = no limit (or nothing extra with upgradeSellLimit)
	upgradeSellLimit = false, -- the limit is the sell price of the equipped item, plus upgradeMax
	upgradeMaxLevel = 0, -- highest required level; 0 = the character's level
	upgradeArmor = 'auto', -- 'auto', 'cloth', 'leather', 'mail' or 'plate'
	weights = {}, -- [stat key] = weight, filled from the presets in Upgrade.lua
}

ns.MIN_DELAY, ns.MAX_DELAY = 0.2, 60

function ns.Print(...)
	print(ns.TITLE .. ':', ...)
end

function ns.Debug(...)
	if ns.db and ns.db.debug then
		print('|cff1784d1BenisAH|r |cff999999debug:|r', ...)
	end
end

function ns.Money(copper)
	copper = math.max(0, math.floor((copper or 0) + 0.5))
	return GetMoneyString(copper)
end

-- item keys are tables; this makes them usable as table keys
function ns.KeyString(itemKey)
	return ('%d:%d:%d:%d'):format(itemKey.itemID or 0, itemKey.itemLevel or 0,
		itemKey.itemSuffix or 0, itemKey.battlePetSpeciesID or 0)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local handlers = {}
local listener = CreateFrame('Frame')

function ns.On(event, handler)
	if not handlers[event] then
		handlers[event] = {}
		listener:RegisterEvent(event)
	end
	table.insert(handlers[event], handler)
end

listener:SetScript('OnEvent', function(_, event, ...)
	for _, handler in ipairs(handlers[event]) do
		handler(...)
	end
end)

ns.On('ADDON_LOADED', function(name)
	if name ~= ADDON_NAME then return end
	BenisAHDB = BenisAHDB or {}
	for key, value in pairs(defaults) do
		if BenisAHDB[key] == nil then
			BenisAHDB[key] = type(value) == 'table' and {} or value
		end
	end
	ns.db = BenisAHDB
end)

--------------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------------

SLASH_BENISAH1 = '/benisah'
SLASH_BENISAH2 = '/bah'
SlashCmdList.BENISAH = function(msg)
	local cmd, arg = strtrim(msg or ''):lower():match('^(%S*)%s*(.-)$')
	if cmd == 'delay' and tonumber(arg) then
		ns.db.delay = math.min(math.max(tonumber(arg), ns.MIN_DELAY), ns.MAX_DELAY)
		ns.Print(('query delay set to %.1fs'):format(ns.db.delay))
		if ns.UI and ns.UI.panel then ns.UI:LoadSettings() end
	elseif cmd == 'stop' then
		ns.Scanner:Stop()
	elseif cmd == 'debug' then
		ns.db.debug = not ns.db.debug or nil
		ns.Print('purchase debug log ' .. (ns.db.debug and 'on' or 'off') .. '.')
	else
		ns.Print('open the auction house and pick the BenisAH tab.')
		ns.Print('/bah delay <seconds> - pause between server queries')
		ns.Print('/bah stop - stop a running scan')
		ns.Print('/bah debug - log what happens on every purchase')
	end
end
