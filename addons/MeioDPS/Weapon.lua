-- Weapon damage: auto attacks, weapon abilities and weapon tooltips, from the character
-- sheet's own numbers. UnitDamage and UnitRangedDamage already include attack power, buffs
-- and percent modifiers; attack power is taken back out where an ability swings at a
-- normalised speed instead of the weapon's (the client data says which).

local _, ns = ...

local canaccess = canaccessvalue or function() return true end

local AP_PER_DPS = 14
-- the speeds instant attacks are worked out at, whatever the weapon's own speed
local NORMAL_DAGGER, NORMAL_ONE_HAND, NORMAL_TWO_HAND, NORMAL_RANGED = 1.7, 2.4, 3.3, 2.8
local WEAPON, DAGGER, WAND, FISHING_POLE = 2, 15, 19, 20
local MAIN_HAND, RANGED_SLOT = 16, 18
local RANGED_SLOTS = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true }

-- auto attack spells: Attack, Auto Shot, Shoot (wand), a warrior's or rogue's shots
ns.AUTO = { [6603] = "melee", [75] = "ranged", [5019] = "wand", [2480] = "ranged",
    [7918] = "ranged", [7919] = "ranged", [2764] = "ranged" }

local function Num(v)
    if v ~= nil and canaccess(v) and type(v) == "number" then return v end
end
ns.Num = Num

local function AllReadable(...)
    for i = 1, select("#", ...) do
        if not canaccess((select(i, ...))) then return false end
    end
    return true
end

-- Combat can make these stats secret: the last readable values stand in
local last = {}

local function AttackPower(ranged)
    local key = ranged and "rap" or "ap"
    local get = ranged and UnitRangedAttackPower or UnitAttackPower
    if not get then return 0 end
    local base, pos, neg = get("player")
    if AllReadable(base, pos, neg) then
        base, pos, neg = Num(base), Num(pos), Num(neg)
        if base then last[key] = math.max(0, base + (pos or 0) + (neg or 0)) end
    end
    return last[key] or 0
end
ns.AttackPower = AttackPower

local function RangedItem()
    local id = GetInventoryItemID and GetInventoryItemID("player", RANGED_SLOT)
    if not id then return nil end
    return select(7, C_Item.GetItemInfoInstant(id))
end

function ns.HasWand()
    if HasWandEquipped then return HasWandEquipped() and true or false end
    return RangedItem() == WAND
end

-- One hand's auto attack, "main", "off" or "ranged": { lo, hi, avg, speed, pos, neg, pct },
-- nil with nothing there
function ns.Swing(hand)
    local lo, hi, speed, pos, neg, pct
    if hand == "ranged" then
        if not UnitRangedDamage then return nil end
        speed, lo, hi, pos, neg, pct = UnitRangedDamage("player")
    else
        if not (UnitDamage and UnitAttackSpeed) then return nil end
        local mainLo, mainHi, offLo, offHi
        mainLo, mainHi, offLo, offHi, pos, neg, pct = UnitDamage("player")
        local mainSpeed, offSpeed = UnitAttackSpeed("player")
        if hand == "off" then
            lo, hi, speed = offLo, offHi, offSpeed
        else
            lo, hi, speed = mainLo, mainHi, mainSpeed
        end
    end
    if not AllReadable(lo, hi, speed, pos, neg, pct) then return last[hand] end
    lo, hi, speed = Num(lo), Num(hi), Num(speed)
    if not (lo and hi and speed and speed > 0 and hi > 0) then
        last[hand] = nil
        return nil
    end
    pct = Num(pct)
    last[hand] = { lo = lo, hi = hi, avg = (lo + hi) / 2, speed = speed, pos = Num(pos) or 0,
        neg = Num(neg) or 0, pct = pct and pct > 0 and pct or 1 }
    return last[hand]
end

local function NormalSpeed(ranged, speed)
    if ranged then return NORMAL_RANGED end
    local id = GetInventoryItemID and GetInventoryItemID("player", MAIN_HAND)
    if not id then return speed end
    local _, _, _, equipLoc, _, _, subclass = C_Item.GetItemInfoInstant(id)
    if subclass == DAGGER then return NORMAL_DAGGER end
    if equipLoc == "INVTYPE_2HWEAPON" then return NORMAL_TWO_HAND end
    return NORMAL_ONE_HAND
end

-- A weapon ability (Data.lua WEAPON entry) with your weapon: { lo, hi, avg, weapon (the
-- weapon alone), apPart, ap, speed (the one used), weaponSpeed, swing (a plain swing) }
function ns.WeaponHit(w)
    local s = ns.Swing(w.ranged and "ranged" or "main")
    if not s then return nil end
    local ap = AttackPower(w.ranged)
    local speed = w.n and NormalSpeed(w.ranged, s.speed) or s.speed
    local apPart = ap / AP_PER_DPS * speed
    local share = (w.pct or 100) / 100
    -- the sheet's numbers back to the bare weapon: no buffs, percent or attack power
    local function Bare(v)
        return math.max(0, v / s.pct - s.pos - s.neg - ap / AP_PER_DPS * s.speed)
    end
    local function Hit(v)
        return ((Bare(v) + apPart) * share + (w.bonus or 0) + s.pos + s.neg) * s.pct
    end
    local lo, hi = Hit(s.lo), Hit(s.hi)
    return { lo = lo, hi = hi, avg = (lo + hi) / 2, weapon = (Bare(s.lo) + Bare(s.hi)) / 2,
        apPart = apPart, ap = ap, speed = speed, weaponSpeed = s.speed, swing = s.avg,
        share = share, bonus = w.bonus or 0, buffs = s.pos + s.neg, pct = s.pct }
end

-- Chance to hit and crit for an attack against a mob of your level: 5% misses (24% for
-- white swings with two weapons) less your hit from gear; crits double
function ns.AttackChances(ranged, dualWield)
    local hitMod = GetHitModifier and Num(GetHitModifier()) or 0
    local miss = (dualWield and 24 or 5) - hitMod
    local getCrit = ranged and GetRangedCritChance or GetCritChance
    local crit = getCrit and Num(getCrit()) or 0
    local hit = math.min(100, math.max(0, 100 - miss)) / 100
    return hit, math.min(hit, math.max(0, crit / 100))
end

---------------------------------------------------------------------------
-- Weapon tooltips
---------------------------------------------------------------------------
local function Pattern(template, fallback)
    local text = type(template) == "string" and template or fallback
    return "^" .. text:gsub("[%(%)%.%[%]%+%-%*%?%^%$]", "%%%0"):gsub("%%s", "([%%d%%.,]+)")
        .. "$"
end
local DPS_PATTERN = Pattern(DPS_TEMPLATE, "(%s damage per second)")
local SPEED_PATTERN = Pattern(SPEED and SPEED .. " %s", "Speed %s")

local function Number(text)
    return tonumber((text:gsub(",", ".")))
end

-- The weapon's damage per second and speed from its tooltip lines, nil for anything else
function ns.ItemWeapon(data)
    local id = data and Num(data.id)
    if not id then return nil end
    local _, _, _, equipLoc, _, class, subclass = C_Item.GetItemInfoInstant(id)
    if class ~= WEAPON or subclass == WAND or subclass == FISHING_POLE then return nil end
    local dps, speed
    for _, line in ipairs(type(data.lines) == "table" and data.lines or {}) do
        local left, right = line.leftText, line.rightText
        if type(left) == "string" and canaccess(left) then
            local v = left:match(DPS_PATTERN)
            if v then dps = Number(v) end
        end
        if type(right) == "string" and canaccess(right) then
            local v = right:match(SPEED_PATTERN)
            if v then speed = Number(v) end
        end
    end
    if not (dps and speed and speed > 0) then return nil end
    return { dps = dps, speed = speed, ranged = RANGED_SLOTS[equipLoc] or false }
end

-- What the weapon would do in your hands: its DPS plus your attack power, with the buffs
-- and percent modifiers on you now
function ns.ItemDPS(item)
    local ap = AttackPower(item.ranged)
    local s = ns.Swing(item.ranged and "ranged" or "main")
    local buffs, pct = s and s.pos + s.neg or 0, s and s.pct or 1
    local swing = (item.dps * item.speed + ap / AP_PER_DPS * item.speed + buffs) * pct
    return swing / item.speed, ap, ap / AP_PER_DPS * pct, swing
end
