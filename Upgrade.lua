local _, ns = ...

-- Upgrade mode: auctions that beat what the character has equipped.
--
-- Every selected slot becomes a browse query for the gear that fits it: the
-- heaviest armor type the character can wear, and for weapons the setup that
-- is equipped (a two-hander, two one-handers, or a one-hander with a shield or
-- an off-hand item), up to a required level. Items whose tooltip shows red
-- text (wrong weapon type, class, reputation...) are left out.
--
-- An item's score is the sum of its stats times the user's weights, plus its
-- weapon DPS times the DPS weight and (speed - 2.0) times the speed weight,
-- so slow weapons come out ahead. Browse results are scored as their base
-- item; an item whose stats can differ per auction (random suffix, another
-- item level) is always looked up before it counts. Per slot, the biggest
-- gain at or under the price limit is listed, the cheaper auction winning a
-- tie. Rings and trinkets compare against the weaker of the two equipped.
local Upgrade = {
	cache = {}, -- [item key] = { minPrice, quantity, auction } of looked up items
	scores = {}, -- [item link] = { score, usable }, rebuilt every pass
	baseline = {}, -- [slot key] = { score, link, otherItemID } of what is equipped
	passBest = {}, -- [slot key] = the best upgrade found this pass
}
ns.Upgrade = Upgrade

local EPSILON = 0.001
local BASE_SPEED = 2.0 -- weapons slower than this get a bonus, faster ones a malus
local WEAPON_CLASS = 2
local WAND_SUBCLASS = 19
-- bow, gun, thrown, crossbow, wand: scored with the ranged DPS weight
local RANGED_SUBCLASSES = { [2] = true, [3] = true, [16] = true, [18] = true, [19] = true }

local GetItemStats = C_Item and C_Item.GetItemStats or GetItemStats
local GetItemInfoInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant

--------------------------------------------------------------------------------
-- Stats and weights
--------------------------------------------------------------------------------

-- `mods` are the keys GetItemStats uses for the stat; when an item has several
-- of them, the biggest counts. The per spec presets are in Presets.lua.
-- Spell power counts items that raise damage and healing, or damage only;
-- healing power counts items that raise healing, or damage and healing. So
-- a healer weighs healing power and a caster spell power, never both.
Upgrade.STATS = {
	{ key = 'dps', label = 'Weapon DPS', mods = { 'ITEM_MOD_DAMAGE_PER_SECOND_SHORT' },
		tip = 'DPS of melee weapons. Ranged weapons and wands use Ranged DPS.' },
	{ key = 'rdps', label = 'Ranged/wand DPS',
		tip = 'DPS of bows, guns, crossbows, thrown weapons and wands.' },
	{ key = 'speed', label = 'Speed over 2.0s',
		tip = 'Added per second of weapon speed above 2.0 (taken off below it), so slow weapons win at similar DPS. Wands do not count.' },
	{ key = 'hit', label = 'Hit',
		mods = { 'ITEM_MOD_HIT_RATING_SHORT', 'ITEM_MOD_HIT_MELEE_RATING_SHORT', 'ITEM_MOD_HIT_SPELL_RATING_SHORT',
			'ITEM_MOD_HIT_RANGED_RATING_SHORT' } },
	{ key = 'crit', label = 'Crit',
		mods = { 'ITEM_MOD_CRIT_RATING_SHORT', 'ITEM_MOD_CRIT_MELEE_RATING_SHORT', 'ITEM_MOD_CRIT_SPELL_RATING_SHORT',
			'ITEM_MOD_CRIT_RANGED_RATING_SHORT' } },
	{ key = 'haste', label = 'Haste',
		mods = { 'ITEM_MOD_HASTE_RATING_SHORT', 'ITEM_MOD_HASTE_MELEE_RATING_SHORT', 'ITEM_MOD_HASTE_SPELL_RATING_SHORT',
			'ITEM_MOD_HASTE_RANGED_RATING_SHORT' } },
	{ key = 'expertise', label = 'Expertise', mods = { 'ITEM_MOD_EXPERTISE_RATING_SHORT' } },
	{ key = 'str', label = 'Strength', mods = { 'ITEM_MOD_STRENGTH_SHORT' } },
	{ key = 'agi', label = 'Agility', mods = { 'ITEM_MOD_AGILITY_SHORT' } },
	{ key = 'int', label = 'Intellect', mods = { 'ITEM_MOD_INTELLECT_SHORT' } },
	{ key = 'spi', label = 'Spirit', mods = { 'ITEM_MOD_SPIRIT_SHORT' } },
	{ key = 'sta', label = 'Stamina', mods = { 'ITEM_MOD_STAMINA_SHORT' } },
	{ key = 'ap', label = 'Attack power',
		mods = { 'ITEM_MOD_ATTACK_POWER_SHORT', 'ITEM_MOD_MELEE_ATTACK_POWER_SHORT',
			'ITEM_MOD_RANGED_ATTACK_POWER_SHORT', 'ITEM_MOD_FERAL_ATTACK_POWER_SHORT' } },
	{ key = 'arp', label = 'Armor pen.', mods = { 'ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT' } },
	{ key = 'sp', label = 'Spell power',
		mods = { 'ITEM_MOD_SPELL_POWER_SHORT', 'ITEM_MOD_SPELL_DAMAGE_DONE_SHORT' } },
	{ key = 'hp', label = 'Healing power',
		mods = { 'ITEM_MOD_SPELL_HEALING_DONE_SHORT', 'ITEM_MOD_SPELL_POWER_SHORT' } },
	{ key = 'pierce', label = 'Spell pierce', mods = { 'ITEM_MOD_SPELL_PENETRATION_SHORT' } },
	{ key = 'mp5', label = 'Mana per 5',
		mods = { 'ITEM_MOD_MANA_REGENERATION_SHORT', 'ITEM_MOD_POWER_REGEN0_SHORT' } },
	{ key = 'armor', label = 'Armor', mods = { 'RESISTANCE0_NAME' } },
	{ key = 'def', label = 'Defense', mods = { 'ITEM_MOD_DEFENSE_SKILL_RATING_SHORT' } },
	{ key = 'dodge', label = 'Dodge', mods = { 'ITEM_MOD_DODGE_RATING_SHORT' } },
	{ key = 'parry', label = 'Parry', mods = { 'ITEM_MOD_PARRY_RATING_SHORT' } },
	{ key = 'block', label = 'Block', mods = { 'ITEM_MOD_BLOCK_RATING_SHORT' } },
	{ key = 'blockval', label = 'Block value', mods = { 'ITEM_MOD_BLOCK_VALUE_SHORT' } },
}

-- Fills in every weight the user has not set: from the default preset on a
-- fresh install, 0 for a stat added since the weights were saved.
function Upgrade:EnsureWeights()
	local weights = ns.db.weights
	if next(weights) == nil then
		self:ApplyPreset(self.DEFAULT_PRESET)
		return
	end
	for _, stat in ipairs(self.STATS) do
		if type(weights[stat.key]) ~= 'number' then weights[stat.key] = 0 end
	end
end

--------------------------------------------------------------------------------
-- Tooltip: weapon speed, DPS fallback, usability
--------------------------------------------------------------------------------

-- turns a format string like "Requires Level %d" into a Lua pattern
local function FormatToPattern(format)
	local pattern = format:gsub('%%[ds]', '\001')
	pattern = pattern:gsub('[%(%)%.%+%-%*%?%[%]%^%$%%]', '%%%0')
	return (pattern:gsub('\001', '([%%d%%.,]+)'))
end

local LEVEL_PATTERN = FormatToPattern(ITEM_MIN_LEVEL or 'Requires Level %d')
local DPS_PATTERN = FormatToPattern(DPS_TEMPLATE or '(%s damage per second)')
local SPEED_PATTERN = '^' .. FormatToPattern(WEAPON_SPEED or 'Speed') .. '%s*([%d%.,]+)'

local function ToNumber(text)
	return text and tonumber((text:gsub(',', '.')))
end

local scanTip = CreateFrame('GameTooltip', 'BenisAHScanTooltip', nil, 'GameTooltipTemplate')

-- the sell price the tooltip shows, see SellPrice
local tooltipMoney
-- Old tooltips report their money line through this script. Modern ones
-- (Forever, Midnight) dropped it and are read through C_TooltipInfo instead.
if scanTip:HasScript('OnTooltipAddMoney') then
	pcall(scanTip.HookScript, scanTip, 'OnTooltipAddMoney', function(_, money)
		tooltipMoney = money
	end)
end

-- the sell price line of an equipped item's tooltip data, on modern clients
local function TooltipInfoSellPrice(invSlot)
	if not (C_TooltipInfo and C_TooltipInfo.GetInventoryItem
		and Enum.TooltipDataLineType and Enum.TooltipDataLineType.SellPrice) then
		return nil
	end
	local ok, data = pcall(C_TooltipInfo.GetInventoryItem, 'player', invSlot)
	if not ok or not data or not data.lines then return nil end
	for _, line in ipairs(data.lines) do
		if line.type == Enum.TooltipDataLineType.SellPrice and line.price then
			return line.price
		end
	end
end

-- What a vendor pays for an equipped item right now. A damaged item sells for
-- less than the price GetItemInfo knows, so the price is read from the item's
-- tooltip, which shows the real one. Failing that, the repair cost comes off.
local function SellPrice(invSlot, link)
	local base = select(11, C_Item.GetItemInfo(link)) or 0
	local price = TooltipInfoSellPrice(invSlot)
	if price then return price end
	tooltipMoney = nil
	scanTip:SetOwner(WorldFrame, 'ANCHOR_NONE')
	scanTip:ClearLines()
	local ok, _, _, repairCost = pcall(scanTip.SetInventoryItem, scanTip, 'player', invSlot)
	scanTip:Hide()
	if tooltipMoney then return tooltipMoney end
	if ok and (repairCost or 0) > 0 then return math.max(0, base - repairCost) end
	return base
end

-- Red text in a tooltip means the character cannot use the item (weapon type,
-- class, reputation...). The level requirement is red too while the item is
-- above the character's level, but the level is checked on its own.
local function ScanTooltip(link)
	local info = { usable = true }
	scanTip:SetOwner(WorldFrame, 'ANCHOR_NONE')
	scanTip:ClearLines()
	if not pcall(scanTip.SetHyperlink, scanTip, link) then
		scanTip:Hide()
		return info
	end
	for line = 1, scanTip:NumLines() do
		for _, side in ipairs({ 'Left', 'Right' }) do
			local fontString = _G['BenisAHScanTooltipText' .. side .. line]
			local text = fontString and fontString:IsShown() and fontString:GetText()
			if text and text ~= '' then
				-- red either as the line's color or as a color code in the text
				local r, g, b = fontString:GetTextColor()
				local red = (r > 0.95 and g < 0.2 and b < 0.2) or text:lower():find('|cffff2020', 1, true)
				text = text:gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', '')
				if red and not text:match(LEVEL_PATTERN) then
					info.usable = false
				end
				info.speed = info.speed or ToNumber(text:match(SPEED_PATTERN))
				info.dps = info.dps or ToNumber(text:match(DPS_PATTERN))
			end
		end
	end
	scanTip:Hide()
	return info
end

-- score of one item, see the top of the file
function Upgrade:Score(link)
	local known = self.scores[link]
	if known then return known.score, known end

	local stats = GetItemStats(link) or {}
	local tip = ScanTooltip(link)
	local weights = ns.db.weights
	local _, _, _, _, _, classID, subClassID = GetItemInfoInstant(link)
	local ranged = classID == WEAPON_CLASS and RANGED_SUBCLASSES[subClassID]
	local wand = ranged and subClassID == WAND_SUBCLASS

	local dps = tonumber(stats.ITEM_MOD_DAMAGE_PER_SECOND_SHORT) or 0
	if dps == 0 then dps = tip.dps or 0 end
	local score = 0
	for _, stat in ipairs(self.STATS) do
		local value = 0
		if stat.key == 'dps' then
			value = ranged and 0 or dps
		elseif stat.key == 'rdps' then
			value = ranged and dps or 0
		elseif stat.key == 'speed' then
			value = (tip.speed and not wand) and (tip.speed - BASE_SPEED) or 0
		else
			for _, mod in ipairs(stat.mods or {}) do
				value = math.max(value, tonumber(stats[mod]) or 0)
			end
		end
		score = score + value * (weights[stat.key] or 0)
	end

	known = { score = score, usable = tip.usable }
	self.scores[link] = known
	return score, known
end

--------------------------------------------------------------------------------
-- Slots
--------------------------------------------------------------------------------

local function Set(...)
	local set = {}
	for index = 1, select('#', ...) do set[select(index, ...)] = true end
	return set
end

local function WeaponFilters(...)
	local filters = {}
	for index = 1, select('#', ...) do
		filters[index] = { classID = 2, subClassID = select(index, ...) }
	end
	return filters
end

-- one-handed: axe, mace, sword, fist, dagger; two-handed: axe, mace, polearm, sword, staff
local ONE_HAND_FILTERS = WeaponFilters(0, 4, 7, 13, 15)
local HANDS = {
	twoHand = { label = '2H', filters = WeaponFilters(1, 5, 6, 8, 10), locs = Set('INVTYPE_2HWEAPON') },
	mainHand = { label = '1H', filters = ONE_HAND_FILTERS, locs = Set('INVTYPE_WEAPON', 'INVTYPE_WEAPONMAINHAND') },
	offHand = { label = '1H', filters = ONE_HAND_FILTERS, locs = Set('INVTYPE_WEAPON', 'INVTYPE_WEAPONOFFHAND') },
	shield = { label = 'shield', filters = { { classID = 4, subClassID = 6 } }, locs = Set('INVTYPE_SHIELD') },
	held = { label = 'held item', filters = { { classID = 4, subClassID = 0, inventoryType = 23 } },
		locs = Set('INVTYPE_HOLDABLE') },
	ranged = { label = 'ranged', filters = WeaponFilters(2, 3, 18), locs = Set('INVTYPE_RANGED', 'INVTYPE_RANGEDRIGHT') },
}

-- inv: equipment slot ids; armor: inventory types searched in the armor type
-- the character wears; filters: fixed item class filters; hand: weapon slot
Upgrade.SLOTS = {
	{ key = 'head', label = 'Head', inv = { 1 }, armor = { 1 }, locs = Set('INVTYPE_HEAD') },
	{ key = 'neck', label = 'Neck', inv = { 2 }, filters = { { classID = 4, subClassID = 0, inventoryType = 2 } },
		locs = Set('INVTYPE_NECK') },
	{ key = 'shoulder', label = 'Shoulder', inv = { 3 }, armor = { 3 }, locs = Set('INVTYPE_SHOULDER') },
	{ key = 'back', label = 'Back', inv = { 15 }, filters = { { classID = 4, subClassID = 1, inventoryType = 16 } },
		locs = Set('INVTYPE_CLOAK') },
	{ key = 'chest', label = 'Chest', inv = { 5 }, armor = { 5, 20 }, locs = Set('INVTYPE_CHEST', 'INVTYPE_ROBE') },
	{ key = 'wrist', label = 'Wrist', inv = { 9 }, armor = { 9 }, locs = Set('INVTYPE_WRIST') },
	{ key = 'hands', label = 'Hands', inv = { 10 }, armor = { 10 }, locs = Set('INVTYPE_HAND') },
	{ key = 'waist', label = 'Waist', inv = { 6 }, armor = { 6 }, locs = Set('INVTYPE_WAIST') },
	{ key = 'legs', label = 'Legs', inv = { 7 }, armor = { 7 }, locs = Set('INVTYPE_LEGS') },
	{ key = 'feet', label = 'Feet', inv = { 8 }, armor = { 8 }, locs = Set('INVTYPE_FEET') },
	{ key = 'finger', label = 'Ring', inv = { 11, 12 }, filters = { { classID = 4, subClassID = 0, inventoryType = 11 } },
		locs = Set('INVTYPE_FINGER') },
	{ key = 'trinket', label = 'Trinket', inv = { 13, 14 },
		filters = { { classID = 4, subClassID = 0, inventoryType = 12 } }, locs = Set('INVTYPE_TRINKET') },
	{ key = 'mainhand', label = 'Main hand', inv = { 16 }, hand = 'main' },
	{ key = 'offhand', label = 'Off hand', inv = { 17 }, hand = 'off' },
}
-- Clients with a ranged slot (Forever) search it for bows, guns, crossbows,
-- thrown weapons and wands; tooltips with red text drop what the class
-- cannot use. Retail has no such slot and keeps ranged weapons in main hand.
do
	local ok, rangedSlot = pcall(GetInventorySlotInfo, 'RangedSlot')
	if ok and rangedSlot == 18 then
		Upgrade.SLOTS[#Upgrade.SLOTS + 1] = { key = 'ranged', label = 'Ranged', inv = { 18 },
			filters = WeaponFilters(2, 3, 16, 18, 19),
			locs = Set('INVTYPE_RANGED', 'INVTYPE_RANGEDRIGHT', 'INVTYPE_THROWN') }
	end
end
for index, slot in ipairs(Upgrade.SLOTS) do slot.order = index end

local function EquipLoc(invSlot)
	local link = GetInventoryItemLink('player', invSlot)
	return link and select(4, GetItemInfoInstant(link)) or nil
end

-- What to look for in the weapon slots, following what is equipped: no setup
-- is ever switched for another. Off hand is nil when there is nothing to match.
function Upgrade:WeaponPlan()
	local main, off = EquipLoc(16), EquipLoc(17)
	local plan = {}
	if main == 'INVTYPE_2HWEAPON' or (not main and not off) then
		plan.main = HANDS.twoHand
		plan.offNote = 'none with a 2H'
		return plan
	elseif main == 'INVTYPE_RANGED' or main == 'INVTYPE_RANGEDRIGHT' then
		plan.main = HANDS.ranged
	else
		plan.main = HANDS.mainHand
	end
	if off == 'INVTYPE_SHIELD' then
		plan.off = HANDS.shield
	elseif off == 'INVTYPE_HOLDABLE' then
		plan.off = HANDS.held
	elseif off == 'INVTYPE_WEAPON' or off == 'INVTYPE_WEAPONOFFHAND' then
		plan.off = HANDS.offHand
	else
		plan.offNote = 'nothing equipped'
	end
	return plan
end

function Upgrade:SlotLabel(slot, plan)
	if not slot.hand then return slot.label end
	plan = plan or self:WeaponPlan()
	local hand = plan[slot.hand]
	if hand then return ('%s (%s)'):format(slot.label, hand.label) end
	return ('%s (%s)'):format(slot.label, plan.offNote or 'none')
end

--------------------------------------------------------------------------------
-- Armor type and level
--------------------------------------------------------------------------------

Upgrade.ARMOR_NAMES = { 'Cloth', 'Leather', 'Mail', 'Plate' }
local ARMOR_IDS = { cloth = 1, leather = 2, mail = 3, plate = 4 }

local CLASS_ARMOR = {
	WARRIOR = 4, PALADIN = 4, DEATHKNIGHT = 4,
	HUNTER = 3, SHAMAN = 3, EVOKER = 3,
	ROGUE = 2, DRUID = 2, MONK = 2, DEMONHUNTER = 2,
}
-- the passive spells that teach an armor type
local ARMOR_SPELLS = { [2] = 9077, [3] = 8737, [4] = 750 }

-- The heaviest armor type the class wears. Where the heavier types come with
-- level (mail and plate at 40 on the older rule sets), the character knows
-- the armor spell once it has them; if it knows none, the class decides.
function Upgrade:AutoArmorType()
	local best = CLASS_ARMOR[select(2, UnitClass('player'))] or 1
	local IsKnown = IsPlayerSpell or IsSpellKnown
	if IsKnown then
		for armor = best, 2, -1 do
			if IsKnown(ARMOR_SPELLS[armor]) then return armor end
		end
	end
	return best
end

function Upgrade:ArmorType()
	return ARMOR_IDS[ns.db.upgradeArmor] or self:AutoArmorType()
end

function Upgrade:MaxLevel()
	local level = tonumber(ns.db.upgradeMaxLevel) or 0
	return level > 0 and level or UnitLevel('player')
end

--------------------------------------------------------------------------------
-- Pass
--------------------------------------------------------------------------------

function Upgrade:Reset()
	wipe(self.cache)
	wipe(self.passBest)
end

local function Signature(filters)
	local parts = {}
	for index, filter in ipairs(filters) do
		parts[index] = ('%s:%s:%s'):format(filter.classID or '', filter.subClassID or '', filter.inventoryType or '')
	end
	return table.concat(parts, ',')
end

function Upgrade:Baseline(slot)
	local equipped = {}
	for index, invSlot in ipairs(slot.inv) do
		local link = GetInventoryItemLink('player', invSlot)
		equipped[index] = { link = link, invSlot = invSlot, score = link and self:Score(link) or 0,
			itemID = link and GetItemInfoInstant(link) or nil }
	end
	local weaker, other = equipped[1], equipped[2]
	if other and other.score < weaker.score then
		weaker, other = other, weaker
	end
	local sell = weaker.link and SellPrice(weaker.invSlot, weaker.link) or 0

	-- the most an upgrade for this slot may cost
	local extra = ns.db.upgradeMax or 0
	local limit
	if ns.db.upgradeSellLimit then
		limit = sell + extra -- free: paid for by selling what it replaces
	else
		limit = extra > 0 and extra or math.huge
	end
	return { score = weaker.score, link = weaker.link, sell = sell, limit = limit,
		otherItemID = other and other.itemID }
end

-- Takes a fresh look at what is equipped and returns the browse queries of
-- the pass, or nil when no slot is left to search.
function Upgrade:BeginPass()
	self:EnsureWeights()
	wipe(self.scores)
	wipe(self.baseline)
	wipe(self.passBest)
	self.maxLevel = self:MaxLevel()
	self.maxPrice = 0 -- the highest limit of any slot, for the browse results
	local armor = self:ArmorType()
	local plan = self:WeaponPlan()

	local queries, bySignature = {}, {}
	for _, slot in ipairs(self.SLOTS) do
		local filters, locs
		if slot.armor then
			filters, locs = {}, slot.locs
			for index, inventoryType in ipairs(slot.armor) do
				filters[index] = { classID = 4, subClassID = armor, inventoryType = inventoryType }
			end
		elseif slot.hand then
			local hand = plan[slot.hand]
			if hand then filters, locs = hand.filters, hand.locs end
		else
			filters, locs = slot.filters, slot.locs
		end

		if filters and not ns.db.skipSlots[slot.key] then
			local base = self:Baseline(slot)
			self.baseline[slot.key] = base
			self.maxPrice = math.max(self.maxPrice, base.limit)
			local target = { slot = slot, locs = locs, armor = slot.armor and armor }
			-- main and off hand look for the same one-handers: one query for both
			local signature = Signature(filters)
			local query = bySignature[signature]
			if query then
				query.label = query.label .. ' + ' .. slot.label
			else
				query = { label = slot.label, searchString = '', itemClassFilters = filters,
					maxLevel = self.maxLevel, targets = {} }
				bySignature[signature] = query
				queries[#queries + 1] = query
			end
			query.targets[#query.targets + 1] = target
		end
	end

	if #queries == 0 then
		ns.Print('pick at least one slot to search.')
		return nil
	end
	return queries
end

local function Better(gain, price, than)
	if not than then return true end
	if gain > than.gain + EPSILON then return true end
	return gain > than.gain - EPSILON and price < than.buyout
end

-- shows the slot's best find, see FinishPass for the rows of the last pass
function Upgrade:Publish(slotKey, final)
	local best = self.passBest[slotKey]
	if not best then return end
	local pass = ns.Scanner.pass
	local shown = ns.Results:FindSlot(slotKey)
	-- Until the pass is over, the row of the last pass only gives way to
	-- something better, so it does not flicker while this pass catches up.
	if not final and shown and shown.pass ~= pass and shown.auctionID ~= best.auctionID
		and not Better(best.gain, best.buyout, shown) then
		return
	end
	ns.Results:SetUpgrade(slotKey, best, pass)
end

-- every slot shows what this pass found; Results:EndPass drops the rest
function Upgrade:FinishPass()
	for slotKey in pairs(self.passBest) do
		self:Publish(slotKey, true)
	end
end

-- an auction of this item was bought or failed: never list it from memory
function Upgrade:Forget(key)
	self.cache[key] = nil
	for slotKey, best in pairs(self.passBest) do
		if best.key == key then self.passBest[slotKey] = nil end
	end
end

--------------------------------------------------------------------------------
-- Candidates
--------------------------------------------------------------------------------

-- a browse result of `query`; may wait for the item's data to load
function Upgrade:Consider(result, query)
	local itemID = result.itemKey.itemID
	if C_Item.GetItemInfo(itemID) then
		self:Evaluate(result, query)
	else
		ns.Scanner:LoadItem(itemID, function() self:Evaluate(result, query) end)
	end
end

function Upgrade:Evaluate(result, query)
	local itemKey = result.itemKey
	local _, link, _, itemLevel, reqLevel, _, _, _, equipLoc, _, _, _, subClassID = C_Item.GetItemInfo(itemKey.itemID)
	if not link or (reqLevel or 0) > self.maxLevel then return end

	local slots = {}
	for _, target in ipairs(query.targets) do
		local base = self.baseline[target.slot.key]
		if target.locs[equipLoc] and (not target.armor or subClassID == target.armor)
			and result.minPrice <= base.limit
			and base.otherItemID ~= itemKey.itemID then -- not the same ring or trinket twice
			slots[#slots + 1] = target
		end
	end
	if #slots == 0 then return end

	local score, info = self:Score(link)
	if not info.usable then return end

	-- The base item's stats are the auction's stats unless a suffix or another
	-- item level changes them. A plain suffix can be scored from a made-up
	-- link; if that gives other stats than the base item, they are trusted.
	local suffix = itemKey.itemSuffix or 0
	local exact = suffix == 0
	if suffix > 0 then
		local suffixScore = self:Score(('item:%d::::::%d'):format(itemKey.itemID, suffix))
		if math.abs(suffixScore - score) > EPSILON then
			score, exact = suffixScore, true
		end
	end
	if (itemKey.itemLevel or 0) > 0 and itemLevel and itemKey.itemLevel ~= itemLevel then
		exact = false
	end

	local estimate = -math.huge
	local candidate = { key = ns.KeyString(itemKey), itemKey = itemKey, minPrice = result.minPrice,
		quantity = result.totalQuantity, score = score, exact = exact, targets = slots }
	for _, target in ipairs(slots) do
		estimate = math.max(estimate, score - self.baseline[target.slot.key].score)
	end
	if exact and estimate <= EPSILON then return end
	candidate.estimate = estimate
	ns.Scanner:AddUpgradeCandidate(candidate)
end

-- true when the candidate is settled without asking the server
function Upgrade:Resolve(candidate)
	if candidate.exact then
		local useful = false
		for _, target in ipairs(candidate.targets) do
			local gain = candidate.score - self.baseline[target.slot.key].score
			if gain > EPSILON and Better(gain, candidate.minPrice, self.passBest[target.slot.key]) then
				useful = true
				break
			end
		end
		if not useful then return true end
	end

	local known = self.cache[candidate.key]
	if known and known.minPrice == candidate.minPrice and known.quantity == candidate.quantity then
		self:Apply(candidate, known.auction)
		return true
	end
	return false
end

-- the cheapest buyable auction of the candidate (nil if there is none); the
-- slots' price limits are checked in Apply
function Upgrade:OnAuction(candidate, auction)
	self.cache[candidate.key] = { minPrice = candidate.minPrice, quantity = candidate.quantity, auction = auction }
	self:Apply(candidate, auction)
end

function Upgrade:Apply(candidate, auction)
	if not auction then return end
	local score, info = self:Score(auction.link)
	if not info.usable then return end
	for _, target in ipairs(candidate.targets) do
		local slotKey = target.slot.key
		local base = self.baseline[slotKey]
		local gain = score - base.score
		if gain > EPSILON and auction.buyout <= base.limit
			and Better(gain, auction.buyout, self.passBest[slotKey]) then
			self.passBest[slotKey] = {
				slot = slotKey,
				slotLabel = target.slot.label,
				order = target.slot.order,
				key = candidate.key,
				itemKey = candidate.itemKey,
				itemID = candidate.itemKey.itemID,
				auctionID = auction.auctionID,
				link = auction.link,
				buyout = auction.buyout,
				quantity = auction.quantity,
				limit = base.limit,
				equippedSell = base.sell,
				score = score,
				gain = gain,
				equippedLink = base.link,
				equippedScore = base.score,
			}
			self:Publish(slotKey, false)
		end
	end
end
