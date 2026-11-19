local _, ns = ...

-- Stat weight presets for the upgrade finder, one per spec.
--
-- Source: the pre-raid EP tables of wowforeverbislist.com (2026-11-18), which
-- come from WoWSims Forever; Holy Paladin, Restoration Shaman and Restoration
-- Druid are that site's own estimates. The site gives Hit, Crit, Haste and
-- Expertise per 1%, items give rating, so those are divided by the rating that
-- makes 1% at level 60: 10 hit, 14 crit, 12 dodge, 15 parry, 5 block (from
-- comparing Forever items with their classic versions; not confirmed in game).
-- Haste and expertise conversions are not published; they are taken as 10 per
-- 1%, the level 60 values of the same rating table. Defense is per point.
-- Caps (8% hit melee, 17% spell hit, 6.5% expertise, 440 defense) are not
-- modeled: past them those stats are worth about nothing.
--
-- No source weighs weapon DPS. `weapon` is the DPS weight the weapon buttons
-- use: 14 attack power make 1 DPS, so 14 times the spec's attack power weight
-- (derived from Strength where the table has no attack power row), and 0 for
-- casters, healers and druids, whose forms ignore the weapon. `ranged` is the
-- weight of ranged weapon DPS: a hunter's bow, or a caster's wand, where 1
-- is a judgement call (a wand point of DPS against a point of spell power).
-- `speed` is the weapon button the preset picks.

local Upgrade = ns.Upgrade

local function Spec(class, spec, speed, weapon, ranged, weights)
	weights.dps = weapon
	weights.rdps = ranged
	return { key = (class .. spec):gsub('%W', ''):lower(), class = class, spec = spec,
		speed = speed, weapon = weapon, weights = weights }
end

-- per rating point, see above
local HIT, CRIT, HASTE, EXP = 10, 14, 10, 10

Upgrade.PRESETS = {
	Spec('Warrior', 'Arms', 'slow', 14, 0, { hit = 47 / HIT, crit = 31.22 / CRIT, str = 2.2, agi = 1.71,
		expertise = 14.6 / EXP, haste = 11.9 / HASTE, ap = 1, arp = 0.45 }),
	Spec('Warrior', 'Fury', 'slow', 14, 0, { expertise = 23.5 / EXP, crit = 31.64 / CRIT, str = 2.2,
		haste = 17.6 / HASTE, agi = 1.7, hit = 16.9 / HIT, ap = 1, arp = 0.39 }),
	Spec('Warrior', 'Protection', 'any', 3.2, 0, { def = 15, expertise = 19.3 / EXP, sta = 1, str = 0.54,
		blockval = 0.53, agi = 0.44, crit = 5.24 / CRIT, ap = 0.23, hit = 0.35 / HIT }),

	Spec('Paladin', 'Holy', 'none', 0, 0, { hp = 1, mp5 = 0.7, crit = 7 / CRIT, haste = 5 / HASTE,
		int = 0.45, spi = 0.15, sta = 0.1 }),
	Spec('Paladin', 'Protection', 'none', 0, 0, { def = 15, block = 5.63 / 5, sta = 1, dodge = 10.62 / 12,
		parry = 10.99 / 15, agi = 0.71, blockval = 0.56, expertise = 3.04 / EXP, hit = 0.73 / HIT }),
	-- 1 Strength is 2 attack power for paladins: attack power about 1.2
	Spec('Paladin', 'Retribution', 'slow', 16.8, 0, { hit = 68.3 / HIT, expertise = 51 / EXP,
		crit = 43.12 / CRIT, str = 2.4, sp = 2.36, agi = 2.23, int = 2.06, ap = 1.2 }),

	Spec('Hunter', 'Beast Mastery', 'slow', 0, 14, { crit = 34.63 / CRIT, hit = 20.53 / HIT, agi = 2.95,
		haste = 18.95 / HASTE, int = 1.21, ap = 1 }),
	Spec('Hunter', 'Marksmanship', 'slow', 0, 14, { crit = 34.53 / CRIT, hit = 19 / HIT, agi = 2.93,
		haste = 24.67 / HASTE, int = 1.23, ap = 1 }),
	Spec('Hunter', 'Survival', 'slow', 0, 14, { crit = 35 / CRIT, hit = 19.17 / HIT, agi = 3.38,
		haste = 20.83 / HASTE, int = 1.71, ap = 1 }),

	Spec('Rogue', 'Assassination', 'any', 14, 0, { hit = 28 / HIT, expertise = 27.7 / EXP, agi = 2.06,
		crit = 28.28 / CRIT, haste = 19.3 / HASTE, str = 1.1, ap = 1, pierce = 0.65 }),
	Spec('Rogue', 'Combat', 'slow', 14, 0, { expertise = 25.5 / EXP, hit = 24.2 / HIT, agi = 1.96,
		haste = 17.2 / HASTE, crit = 23.8 / CRIT, str = 1.1, ap = 1, arp = 0.41 }),
	Spec('Rogue', 'Subtlety', 'slow', 14, 0, { expertise = 24.2 / EXP, hit = 21.2 / HIT, agi = 1.93,
		crit = 22.82 / CRIT, haste = 14.3 / HASTE, str = 1.1, ap = 1, arp = 0.33 }),

	Spec('Priest', 'Discipline', 'none', 0, 1, { hp = 1, crit = 9.8 / CRIT, mp5 = 0.4, int = 0.2,
		spi = 0.15, haste = 1.5 / HASTE, sta = 0.1 }),
	Spec('Priest', 'Holy', 'none', 0, 1, { hp = 1, mp5 = 0.6, haste = 5 / HASTE, int = 0.35, spi = 0.3,
		crit = 4.2 / CRIT, sta = 0.1 }),
	Spec('Priest', 'Shadow', 'none', 0, 1, { pierce = 2.28, hit = 11.4 / HIT, sp = 1, crit = 11.76 / CRIT,
		haste = 7.3 / HASTE, mp5 = 0.3, int = 0.24 }),

	Spec('Shaman', 'Elemental', 'none', 0, 0, { pierce = 1.81, haste = 12.3 / HASTE, hit = 11.8 / HIT,
		sp = 1, crit = 8.54 / CRIT, int = 0.19 }),
	-- 1 Strength is 2 attack power for shamans: attack power about 1.1
	Spec('Shaman', 'Enhancement', 'slow', 15.4, 0, { hit = 52 / HIT, expertise = 35 / EXP,
		haste = 28.1 / HASTE, pierce = 2.52, crit = 33.88 / CRIT, str = 2.2, int = 1.99, agi = 1.32, ap = 1.1 }),
	Spec('Shaman', 'Restoration', 'none', 0, 0, { hp = 1, mp5 = 0.6, haste = 5 / HASTE, crit = 6 / CRIT,
		int = 0.4, spi = 0.35, sta = 0.1 }),

	Spec('Mage', 'Arcane', 'none', 0, 1, { pierce = 2.63, haste = 22.61 / HASTE, hit = 17.14 / HIT, sp = 1,
		int = 0.97, crit = 10.83 / CRIT, mp5 = 0.4 }),
	Spec('Mage', 'Fire', 'none', 0, 1, { pierce = 2.15, hit = 16.11 / HIT, sp = 1, crit = 11.71 / CRIT,
		haste = 5.93 / HASTE, int = 0.31 }),
	Spec('Mage', 'Frost', 'none', 0, 1, { pierce = 2.25, hit = 16.18 / HIT, haste = 10.9 / HASTE, sp = 1,
		crit = 9.78 / CRIT, int = 0.22, sta = 0.1 }),

	Spec('Warlock', 'Affliction', 'none', 0, 1, { pierce = 1.06, sp = 1, crit = 10 / CRIT, hit = 6.88 / HIT,
		int = 0.36, mp5 = 0.31, haste = 2.82 / HASTE }),
	Spec('Warlock', 'Demonology', 'none', 0, 1, { pierce = 1.39, hit = 11.67 / HIT, sp = 1,
		crit = 7.86 / CRIT, haste = 5.34 / HASTE, mp5 = 0.36, int = 0.35 }),
	Spec('Warlock', 'Destruction', 'none', 0, 1, { pierce = 1.45, hit = 12.18 / HIT, sp = 1,
		crit = 9.39 / CRIT, haste = 4.58 / HASTE, mp5 = 0.34 }),

	Spec('Druid', 'Balance', 'none', 0, 0, { pierce = 2.07, hit = 14.5 / HIT, sp = 1, haste = 9.5 / HASTE,
		crit = 10.64 / CRIT, int = 0.2 }),
	Spec('Druid', 'Feral (Cat)', 'none', 0, 0, { agi = 2.69, str = 2.44, hit = 21.38 / HIT,
		crit = 29.04 / CRIT, expertise = 20.12 / EXP, haste = 16.12 / HASTE, ap = 1 }),
	Spec('Druid', 'Feral (Bear)', 'none', 0, 0, { def = 15, expertise = 17.71 / EXP, sta = 1,
		hit = 6.86 / HIT, str = 0.48, agi = 0.43, crit = 5.07 / CRIT, haste = 3.57 / HASTE }),
	Spec('Druid', 'Restoration', 'none', 0, 0, { hp = 1, mp5 = 0.6, spi = 0.45, int = 0.35,
		haste = 3.5 / HASTE, crit = 3 / CRIT, sta = 0.1 }),
}

Upgrade.DEFAULT_PRESET = 'shamanenhancement'

-- class token of UnitClass -> preset class name
Upgrade.PRESET_CLASSES = {
	WARRIOR = 'Warrior', PALADIN = 'Paladin', HUNTER = 'Hunter', ROGUE = 'Rogue', PRIEST = 'Priest',
	SHAMAN = 'Shaman', MAGE = 'Mage', WARLOCK = 'Warlock', DRUID = 'Druid',
}

-- speed weight per second over 2.0, as a share of the DPS weight: one second
-- slower is worth 1.5 DPS
Upgrade.SPEED_SHARE = 1.5

function Upgrade:FindPreset(key)
	for _, preset in ipairs(self.PRESETS) do
		if preset.key == key then return preset end
	end
end

-- round to 3 significant digits, so the boxes stay readable
local function Round(value)
	if value == 0 then return 0 end
	local scale = 10 ^ (2 - math.floor(math.log10(math.abs(value))))
	return math.floor(value * scale + 0.5) / scale
end

-- the weights of a preset, every stat the preset leaves out at 0
function Upgrade:PresetWeights(preset)
	local weights = {}
	for _, stat in ipairs(self.STATS) do
		weights[stat.key] = Round(preset.weights[stat.key] or 0)
	end
	weights.speed = 0
	local speed = self:WeaponSpeedWeights(preset.speed, preset.weapon, preset.weights.rdps)
	weights.dps, weights.speed = speed.dps, speed.speed
	return weights
end

-- Weapon DPS and speed weights for a weapon choice: 'slow', 'fast', 'any'
-- or 'none'. `dps` is the DPS weight to use, `rdps` the ranged one, which
-- slow and fast also follow (a hunter's bow).
function Upgrade:WeaponSpeedWeights(choice, dps, rdps)
	if choice == 'none' then return { dps = 0, speed = 0 } end
	local base = math.max(dps or 0, rdps or 0)
	local share = choice == 'slow' and self.SPEED_SHARE or choice == 'fast' and -self.SPEED_SHARE or 0
	return { dps = Round(dps or 0), speed = Round(base * share) }
end

function Upgrade:ApplyPreset(key)
	local preset = self:FindPreset(key)
	if not preset then return end
	local weights = ns.db.weights
	wipe(weights)
	for statKey, value in pairs(self:PresetWeights(preset)) do weights[statKey] = value end
	ns.db.weightPreset = key
	ns.db.weaponChoice = preset.speed
end

-- The weapon buttons: keep the DPS weight the user has, or take the preset's
-- (or 14, one attack power's worth) when there is none yet.
function Upgrade:ApplyWeaponChoice(choice)
	local weights = ns.db.weights
	local dps = weights.dps or 0
	if dps <= 0 and choice ~= 'none' then
		local preset = self:FindPreset(ns.db.weightPreset)
		dps = preset and preset.weapon or 0
		-- hunters and casters keep 0: their weapon is the ranged one
		if dps <= 0 and (weights.rdps or 0) <= 0 then dps = 14 * math.max(weights.ap or 0, 1) end
	end
	local result = self:WeaponSpeedWeights(choice, dps, weights.rdps)
	weights.dps, weights.speed = result.dps, result.speed
	ns.db.weaponChoice = choice
end
