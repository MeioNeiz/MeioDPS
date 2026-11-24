-- MeioDPS: damage, DPS and damage per mana (rage, energy) on your spell, ability, auto
-- attack and weapon tooltips, worked out from the tooltip's own numbers and the character
-- sheet's, plus what each really did, from Blizzard's damage meter.
--
-- Forever closes the combat log to addons and hides UNIT_COMBAT amounts in combat, but after
-- a fight the damage meter's per-spell totals are readable. MeioDPS counts your casts (and
-- your pet's) of each spell during the fight and divides; melee, which casts nothing, is
-- divided by the seconds your auto attack was on. That "Measured" figure includes
-- everything the estimate can't: resists, misses, crits, talents, mobs dying before a DoT
-- finished.

local ADDON, ns = ...

local GCD = 1.5
local MIN_CASTS = 3 -- measured figure shown from this many casts on
local MIN_ATTACK_SECONDS = 10 -- measured melee shown from this much auto attacking on
local PRE_PULL = 6 -- seconds before combat whose casts count towards the fight
local METER_TRIES, METER_RETRY = 20, 0.5
local SOUL_SHARD = 6265
local MAX_RANKS = 6 -- rank comparison rows on Shift
local POWER_NAMES = { [0] = "mana", [1] = "rage", [2] = "focus", [3] = "energy" }
-- the damage meter's melee row: its spell ID or name
local MELEE_ROWS = { [1] = true, [6603] = true }
local MELEE_NAMES = { Melee = true, Attack = true, ["Auto Attack"] = true }

local LABEL = { 1, 0.82, 0 }
local VALUE = { 1, 1, 1 }
local DIM = { 0.65, 0.65, 0.65 }
local REAL = { 0.45, 1, 0.45 }
local BAD = { 1, 0.5, 0.5 }

local DEFAULTS = {
    enabled = true, mana = true, heal = true, shards = true, lifetap = true, ranks = true,
    expected = true, measured = true, auto = true, weapon = true,
}
local db, charDB

local canaccess = canaccessvalue or function() return true end
local isSecret = issecretvalue or function() return false end
local Num = ns.Num

local function Say(msg) print("|cffb090ffMeioDPS:|r " .. msg) end
ns.Say = Say

local function Readable(v)
    if isSecret(v) or type(v) ~= "table" then return false end
    if type(canaccesstable) ~= "function" then return true end
    local ok, allowed = pcall(canaccesstable, v)
    return ok and allowed == true
end

-- meter rows for triggered spells (Hellfire Effect) count for the spell you cast
local PARENT = {}
for id, s in pairs(ns.SPELLS) do
    for _, t in ipairs(s.trig or {}) do PARENT[t] = id end
end

-- what MeioDPS counts casts of: spells, weapon abilities and shots (melee casts nothing)
local function Counted(id)
    return ns.SPELLS[id] or ns.WEAPON[id] or ns.AUTO[id] and ns.AUTO[id] ~= "melee"
end

---------------------------------------------------------------------------
-- Reading the spell
---------------------------------------------------------------------------
-- Descriptions can turn secret in combat: the last readable one stands in
local descCache = {}
local function Description(id)
    local text = C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(id)
    if text and canaccess(text) and text ~= "" then
        descCache[id] = text
        return text
    end
    return descCache[id]
end

local function CastSeconds(id)
    local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
    local ms = info and Num(info.castTime)
    return ms and ms / 1000 or 0
end

-- the spell's cost and its power ("mana", "rage", "energy", "focus"), nil when free
local function Cost(id)
    if not C_Spell.GetSpellPowerCost then return nil end
    local costs = C_Spell.GetSpellPowerCost(id)
    if type(costs) ~= "table" or not canaccess(costs) then return nil end
    for _, c in ipairs(costs) do
        local cost, power = Num(c.cost), POWER_NAMES[Num(c.type)]
        if cost and cost > 0 and power then return cost, power end
    end
end

-- the spell's own cooldown and the global cooldown it starts (1 s for rogues), in seconds
local function Cooldowns(id)
    if not GetSpellBaseCooldown then return 0, GCD end
    local cd, gcd = GetSpellBaseCooldown(id)
    cd, gcd = Num(cd), Num(gcd)
    return (cd or 0) / 1000, gcd and gcd > 0 and gcd / 1000 or GCD
end

-- Equal-level spell hit: 96% plus gear, capped at 99%
local function HitChance()
    local bonus = GetSpellHitModifier and Num(GetSpellHitModifier()) or 0
    return math.min(99, math.max(0, 96 + bonus)) / 100
end

-- Forever has one spell crit chance for every school
local function CritChance()
    local c = GetSpellCritChance and Num(GetSpellCritChance()) or 0
    return math.max(0, c) / 100
end

-- a weapon ability as if its description named the numbers
local function WeaponParse(w)
    local h = ns.WeaponHit(w)
    if not h then return nil end
    return { direct = h.avg, lo = h.lo, hi = h.hi, school = "physical", schoolIndex = 1,
        hit = h }
end

-- Everything one tooltip needs, or nil when the spell does no damage we can read
local function Analyze(id)
    local w = ns.WEAPON[id]
    local p
    if w then
        p = WeaponParse(w)
        if p then p.aoe = ns.IsArea((Description(id) or ""):lower()) end
    else
        p = ns.ParseDescription(Description(id))
    end
    if not p then return nil end
    local data = ns.SPELLS[id] or w or {}
    local a = { p = p, data = data, weapon = w }
    if p.ap then
        a.apBonus = ns.AttackPower(data.ranged) * p.ap
        p.direct, p.lo, p.hi = p.direct + a.apBonus, p.lo + a.apBonus, p.hi + a.apBonus
    end
    a.total = (p.direct or 0) + (p.dot or 0)
    a.cast = CastSeconds(id)
    a.channel = data.ch or false
    a.cooldown, a.gcd = Cooldowns(id)
    -- your time each cast takes: the channel, else the cast time or the global cooldown;
    -- an on-next-swing attack takes your swing
    if w and w.swing then
        a.time, a.timeKind = p.hit.weaponSpeed, "swing"
    elseif a.channel and p.dotTime then
        a.time, a.timeKind = p.dotTime, "channel"
    elseif a.cast >= a.gcd then
        a.time, a.timeKind = a.cast, "cast"
    else
        a.time, a.timeKind = a.gcd, "GCD"
    end
    a.dps = a.total / a.time
    -- a DoT outlasting the cast: its DPS is over its duration, apart from the cast's
    a.lasting = p.dot and not a.channel and p.dotTime and p.dotTime > a.time or false
    a.rateTime = a.lasting and p.dotTime or a.time
    a.cost, a.power = Cost(id)
    a.mana = a.power == "mana" and a.cost or nil
    a.attack = w ~= nil or data.melee or data.ranged or false
    if a.attack then
        -- attacks roll once: a crit doubles, periodic damage doesn't crit
        a.hit, a.crit = ns.AttackChances(data.ranged)
        a.expected = (p.direct or 0) * (a.hit + a.crit) + (p.dot or 0) * a.hit
    else
        -- spells roll hit, then crit for 1.5x on the direct part
        a.hit = HitChance()
        a.crit = CritChance()
        a.expected = (p.direct or 0) * a.hit * (1 + a.crit * 0.5) + (p.dot or 0) * a.hit
    end
    return a
end
ns.Analyze = Analyze

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------
local function Line(tt, label, value, color)
    color = color or VALUE
    tt:AddDoubleLine(label, value, LABEL[1], LABEL[2], LABEL[3], color[1], color[2], color[3])
end

local function Fmt(v)
    if v >= 100 then return ("%d"):format(math.floor(v + 0.5)) end
    return (("%.1f"):format(v):gsub("%.0$", ""))
end

local function Secs(v)
    v = math.floor(v * 100 + 0.5) / 100
    return (v == math.floor(v)) and ("%d s"):format(v) or ("%s s"):format(v)
end

local function Pct(v) return ("%d%%"):format(math.floor(v * 100 + 0.5)) end

local function Chances(hit, crit)
    return ("(hit %d%%, crit %.1f%%)"):format(math.floor(hit * 100 + 0.5), crit * 100)
end

local function Measured(id)
    local m = charDB and charDB.measured[id]
    if not m then return nil end
    if id == "melee" then return (m.seconds or 0) >= MIN_ATTACK_SECONDS and m or nil end
    if m.casts >= MIN_CASTS then return m end
end
ns.Measured = Measured

-- one "Shift: more" per tooltip across our addons; the flag is cleared with the tooltip
local function AddShiftHint(tt)
    if tt.meioShiftHint then return end
    tt.meioShiftHint = true
    tt:AddLine("|cff999999Shift: more|r")
end

local function AddShardLine(tt, id)
    local need = db.shards and ns.SHARDS[id]
    if not need then return end
    local count = C_Item and C_Item.GetItemCount or GetItemCount
    local have = count and Num(count(SOUL_SHARD))
    local label = need == 1 and "Soul Shard" or "Soul Shards"
    if not have then return Line(tt, label, tostring(need)) end
    Line(tt, label, ("%d  (you have %d)"):format(need, have), have < need and BAD or VALUE)
end

-- Life Tap's numbers come from its own description, so talents and spirit are in them.
-- Its formula scales health and mana alike, so the ratio only shows when something makes
-- it other than 1.
local function AddLifeTapLines(tt, id)
    local health, mana = ns.ParseLifeTap(Description(id))
    if not health then return end
    tt:AddLine(" ")
    if mana ~= health then Line(tt, "Mana per health", ("%.2f"):format(mana / health)) end
    local power = Enum.PowerType and Enum.PowerType.Mana or 0
    local now, max = Num(UnitPower("player", power)), Num(UnitPowerMax("player", power))
    if not (now and max) then return end
    if now >= max then return Line(tt, "To full mana", "full now", DIM) end
    local taps = math.ceil((max - now) / mana)
    local cost = taps * health
    local hp = Num(UnitHealth("player"))
    Line(tt, "To full mana", ("%d tap%s  (%d health)"):format(taps, taps == 1 and "" or "s",
        cost), hp and cost >= hp and BAD or VALUE)
end

-- spell name -> its IDs in Data.lua (all ranks), built on the first Shift
local byName
local function SameName(id)
    if not byName then
        byName = {}
        for other in pairs(ns.SPELLS) do
            local name = C_Spell.GetSpellName(other)
            if name then
                byName[name] = byName[name] or {}
                table.insert(byName[name], other)
            end
        end
    end
    return byName[C_Spell.GetSpellName(id) or ""] or {}
end

local function Known(id)
    return C_SpellBook.IsSpellKnown(id) and true or false
end

-- your ranks of the spell side by side, for downranking: highest MAX_RANKS, plus the best
-- per mana if it's lower than those
local function AddRankLines(tt, id)
    local rows = {}
    for _, other in ipairs(SameName(id)) do
        local a = (other == id or Known(other)) and Analyze(other)
        if a and a.mana then
            local sub = C_Spell.GetSpellSubtext and C_Spell.GetSpellSubtext(other)
            sub = sub and canaccess(sub) and sub ~= "" and sub or "?"
            rows[#rows + 1] = { id = other, label = sub, rank = tonumber(sub:match("%d+")) or 0,
                perMana = a.total / a.mana, perSecond = a.dps }
        end
    end
    if #rows < 2 then return end
    table.sort(rows, function(x, y) return x.rank > y.rank end)
    local best = rows[1]
    for _, r in ipairs(rows) do if r.perMana > best.perMana then best = r end end
    if #rows > MAX_RANKS then
        local keep = { unpack(rows, 1, MAX_RANKS) }
        if best.rank < keep[MAX_RANKS].rank then keep[MAX_RANKS] = best end
        rows = keep
    end
    tt:AddLine(" ")
    Line(tt, "Your ranks", "per mana, per cast second", DIM)
    for i = #rows, 1, -1 do
        local r = rows[i]
        local value = ("%.2f, %s"):format(r.perMana, Fmt(r.perSecond))
        Line(tt, r.id == id and r.label .. " (this)" or r.label,
            r == best and value .. "  best" or value, r == best and REAL or VALUE)
    end
end

local function Range(lo, hi)
    lo, hi = math.floor(lo + 0.5), math.floor(hi + 0.5)
    return lo ~= hi and (" (%d-%d)"):format(lo, hi) or ""
end

local function DamageText(a, per)
    local p = a.p
    if p.points then per = (" at %d combo points%s"):format(p.points, per) end
    if p.direct and p.dot then
        return ("%s + %s over %s = %s%s"):format(Fmt(p.direct), Fmt(p.dot), Secs(p.dotTime),
            Fmt(a.total), per)
    elseif p.direct then
        return Fmt(p.direct) .. Range(p.lo, p.hi) .. per
    end
    return ("%s over %s%s"):format(Fmt(p.dot), Secs(p.dotTime), per)
end

-- Pet spells: the description's number, so "base". Forever's demons get a server-set share
-- of your spell power (Warlock Pet Scaling, 416189) on top, at the spell's coefficient.
-- The pet's mana, hit and crit aren't yours, so no per mana, expected or ranks.
local function PetSpellPower()
    if not (GetPetSpellBonusDamage and UnitExists("pet")) then return nil end
    return Num(GetPetSpellBonusDamage())
end

local function AddCostLine(tt, a, damage)
    if not (db.mana and a.cost and not a.data.pet) then return end
    Line(tt, "Per " .. a.power, ("%.2f  (%d %s)"):format(damage / a.cost, a.cost, a.power))
end

-- Shift on a weapon ability: how the hit adds up
local function AddWeaponMaths(tt, a)
    local h, w = a.p.hit, a.weapon
    local sum = ("%s weapon + %s attack power"):format(Fmt(h.weapon), Fmt(h.apPart))
    if h.share ~= 1 then sum = ("(%s) x %s"):format(sum, Pct(h.share)) end
    if h.bonus ~= 0 then sum = sum .. " + " .. Fmt(h.bonus) end
    if h.buffs ~= 0 then sum = ("%s %s %s buffs"):format(sum, h.buffs > 0 and "+" or "-",
        Fmt(math.abs(h.buffs))) end
    if h.pct ~= 1 then sum = ("(%s) x %s"):format(sum, Pct(h.pct)) end
    Line(tt, "Per hit", sum, DIM)
    Line(tt, "Attack power", ("%d / 14 x %s %s"):format(h.ap, Secs(h.speed),
        w.n and "(normalised)" or "weapon speed"), DIM)
end

local function AddSpellLines(tt, id)
    local a = Analyze(id)
    if not a then return end
    local p = a.p
    local shift = IsShiftKeyDown()
    local per = p.aoe and " per target" or ""
    local pet = a.data.pet
    local damage = pet and "Base damage" or "Damage"
    local swing = a.weapon and a.weapon.swing

    tt:AddLine(" ")
    -- shields hit back when struck: no cast rate to divide by, so no DPS
    if a.data.proc then
        local hit = (p.direct or 0) + (p.dot or 0)
        local n = a.data.charges
        local whole = n and hit * n
        Line(tt, damage, n and ("%s per hit, %d hits = %s"):format(Fmt(hit), n, Fmt(whole))
            or (Fmt(hit) .. " per hit"))
        if whole then AddCostLine(tt, a, whole) end
        local m = db.measured and Measured(id)
        if m then
            Line(tt, "Measured", ("%s per cast  (%d casts)"):format(Fmt(m.damage / m.casts),
                m.casts), REAL)
        end
        return
    end
    -- on your next swing: the swing happens anyway, so what it adds is the difference
    if swing then
        Line(tt, damage, ("%s%s, +%s over a swing"):format(Fmt(p.direct), Range(p.lo, p.hi),
            Fmt(p.direct - p.hit.swing)))
    else
        Line(tt, damage, DamageText(a, per))
    end
    -- a DoT has two rates: DPS while it ticks, and damage for each second spent casting it
    if swing then
        -- no rate of its own
    elseif a.lasting then
        Line(tt, "DPS", ("%s  (over %s)"):format(Fmt(a.total / a.rateTime), Secs(a.rateTime)))
        Line(tt, "Per cast second", ("%s  (%s %s)"):format(Fmt(a.dps), Secs(a.time),
            a.timeKind))
    else
        Line(tt, "DPS", ("%s  (%s %s)"):format(Fmt(a.dps), Secs(a.time), a.timeKind))
    end
    AddCostLine(tt, a, a.total)
    if db.heal and p.heal and p.heal > 0 then
        Line(tt, "Heals you", db.mana and a.mana
            and ("%s  (%.2f per mana)"):format(Fmt(p.heal), p.heal / a.mana) or Fmt(p.heal))
    end
    AddShardLine(tt, id)
    -- per second only says something new when the time isn't 1 s
    local perSecond = not swing and a.rateTime ~= 1
    if db.expected and not pet then
        local rate = not perSecond and "" or (", %s DPS"):format(Fmt(a.expected / a.rateTime))
        Line(tt, "Expected", ("%s%s  %s"):format(Fmt(a.expected), rate,
            Chances(a.hit, a.crit)), DIM)
    end
    local m = db.measured and Measured(id)
    if m then
        local avg = m.damage / m.casts
        local rate = not perSecond and " per cast" or (", %s DPS"):format(Fmt(avg / a.rateTime))
        Line(tt, "Measured", ("%s%s  (%d casts)"):format(Fmt(avg), rate, m.casts), REAL)
    end

    if not shift then
        AddShiftHint(tt)
        return
    end
    local d = a.data
    if a.weapon then
        AddWeaponMaths(tt, a)
    elseif pet and d.d and (d.d > 0 or d.p > 0) then
        local sp = PetSpellPower()
        Line(tt, "Pet spell power", ("+%s per 100  (%.3f)%s"):format(Fmt((d.d + d.p) * 100),
            d.d + d.p, sp and ("; pet has %d"):format(sp) or ""), DIM)
    elseif d.d and (d.d > 0 or d.p > 0) then
        local parts = {}
        if d.d > 0 then parts[#parts + 1] = ("%.3f direct"):format(d.d) end
        if d.p > 0 then parts[#parts + 1] = ("%.3f over time"):format(d.p) end
        Line(tt, "Spell power", ("+%s per 100  (%s)"):format(Fmt((d.d + d.p) * 100),
            table.concat(parts, ", ")), DIM)
    end
    if a.apBonus then
        Line(tt, "Attack power", ("+%s  (%s of %d)"):format(Fmt(a.apBonus), Pct(p.ap),
            ns.AttackPower(d.ranged)), DIM)
    elseif p.apUnknown then
        Line(tt, "Attack power", "adds more; the tooltip doesn't say how much", DIM)
    end
    if not swing then
        local worked = ("%s / %s = %s"):format(Fmt(a.total), Secs(a.time), Fmt(a.dps))
        if a.lasting then
            worked = ("%s / %s = %s DPS, / %s cast = %s"):format(Fmt(a.total),
                Secs(a.rateTime), Fmt(a.total / a.rateTime), Secs(a.time), Fmt(a.dps))
        end
        Line(tt, "Worked out", worked, DIM)
    end
    if a.cooldown > a.time then
        Line(tt, "Cooldown", ("%s, so at most %s DPS over time"):format(Secs(a.cooldown),
            Fmt(a.total / a.cooldown)), DIM)
    end
    if m then
        local fights = m.fights or 0
        Line(tt, "Measured from", ("%d fight%s, %d damage"):format(fights,
            fights == 1 and "" or "s", m.damage), DIM)
    elseif db.measured then
        local have = charDB and charDB.measured[id]
        Line(tt, "Measured", ("after %d casts in fights  (%d so far)"):format(MIN_CASTS,
            have and have.casts or 0), DIM)
    end
    if db.ranks and not pet and not a.weapon then AddRankLines(tt, id) end
end

local function AddMeleeLines(tt, shift)
    local main = ns.Swing("main")
    if not main then return end
    local off = ns.Swing("off")
    local mainDPS = main.avg / main.speed
    local offDPS = off and off.avg / off.speed or 0
    tt:AddLine(" ")
    if off then
        Line(tt, "Damage", ("%s main hand, %s off hand"):format(Fmt(main.avg), Fmt(off.avg)))
        Line(tt, "DPS", ("%s  (%s + %s)"):format(Fmt(mainDPS + offDPS), Fmt(mainDPS),
            Fmt(offDPS)))
    else
        Line(tt, "Damage", ("%s%s per swing"):format(Fmt(main.avg), Range(main.lo, main.hi)))
        Line(tt, "DPS", ("%s  (%s per swing)"):format(Fmt(mainDPS), Secs(main.speed)))
    end
    if db.expected then
        local hit, crit = ns.AttackChances(false, off ~= nil)
        Line(tt, "Expected", ("%s DPS  %s"):format(Fmt((mainDPS + offDPS) * (hit + crit)),
            Chances(hit, crit)), DIM)
    end
    local m = db.measured and Measured("melee")
    if m then
        Line(tt, "Measured", ("%s DPS while attacking  (%d fight%s)"):format(
            Fmt(m.damage / m.seconds), m.fights, m.fights == 1 and "" or "s"), REAL)
    end
    if not shift then return AddShiftHint(tt) end
    local ap = ns.AttackPower(false)
    Line(tt, "Attack power", ("+%s DPS  (%d / 14)"):format(Fmt(ap / 14 * main.pct), ap), DIM)
    if off then
        Line(tt, "Swings", ("%s main hand, %s off hand"):format(Secs(main.speed),
            Secs(off.speed)), DIM)
    end
    local have = charDB and charDB.measured.melee
    if m then
        Line(tt, "Measured from", ("%d fight%s, %d damage in %d s"):format(m.fights,
            m.fights == 1 and "" or "s", m.damage, m.seconds), DIM)
    elseif db.measured then
        Line(tt, "Measured", ("after %d s of auto attack  (%d so far)"):format(
            MIN_ATTACK_SECONDS, have and have.seconds or 0), DIM)
    end
end

local function AddShotLines(tt, id, shift)
    local wand = ns.AUTO[id] == "wand"
    if wand ~= ns.HasWand() then return end
    local s = ns.Swing("ranged")
    if not s then return end
    tt:AddLine(" ")
    Line(tt, "Damage", ("%s%s per shot"):format(Fmt(s.avg), Range(s.lo, s.hi)))
    Line(tt, "DPS", ("%s  (%s per shot)"):format(Fmt(s.avg / s.speed), Secs(s.speed)))
    if db.expected then
        local hit, crit, expected
        -- a wand shot is a spell: spell hit, and crits for 1.5x
        if wand then
            hit, crit = HitChance(), CritChance()
            expected = s.avg * hit * (1 + crit * 0.5)
        else
            hit, crit = ns.AttackChances(true)
            expected = s.avg * (hit + crit)
        end
        Line(tt, "Expected", ("%s, %s DPS  %s"):format(Fmt(expected), Fmt(expected / s.speed),
            Chances(hit, crit)), DIM)
    end
    local m = db.measured and Measured(id)
    if m then
        local avg = m.damage / m.casts
        Line(tt, "Measured", ("%s, %s DPS  (%d shots)"):format(Fmt(avg), Fmt(avg / s.speed),
            m.casts), REAL)
    end
    if not shift then return AddShiftHint(tt) end
    if not wand then
        local ap = ns.AttackPower(true)
        Line(tt, "Attack power", ("+%s DPS  (%d / 14)"):format(Fmt(ap / 14 * s.pct), ap), DIM)
    end
    if m then
        Line(tt, "Measured from", ("%d fight%s, %d damage"):format(m.fights or 0,
            m.fights == 1 and "" or "s", m.damage), DIM)
    elseif db.measured then
        local have = charDB and charDB.measured[id]
        Line(tt, "Measured", ("after %d shots in fights  (%d so far)"):format(MIN_CASTS,
            have and have.casts or 0), DIM)
    end
end

local function AddAutoLines(tt, id)
    if ns.AUTO[id] == "melee" then return AddMeleeLines(tt, IsShiftKeyDown()) end
    AddShotLines(tt, id, IsShiftKeyDown())
end

-- Pet bar buttons (SetPetAction): the data's id, else the spell in the button's slot
local function PetActionSpell(tt, data)
    local id = data and Num(data.id)
    if id and ns.SPELLS[id] then return id end
    local info = tt.GetProcessingTooltipInfo and tt:GetProcessingTooltipInfo()
    local args = Readable(info) and Readable(info.getterArgs) and info.getterArgs
    local slot = args and Num(args[1])
    if not (slot and GetPetActionInfo) then return id end
    return Num((select(7, GetPetActionInfo(slot)))) or id
end

local function Report(ok, err)
    if not ok and not ns.reported then
        ns.reported = true
        Say("tooltip error (reported once): " .. tostring(err))
    end
end

local function OnSpellTooltip(tt, data)
    if not db or not db.enabled or tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
    local id = data and data.id
    if data and Num(data.type) == Enum.TooltipDataType.PetAction then
        id = PetActionSpell(tt, data)
    end
    if not (id and canaccess(id) and type(id) == "number") then return end
    local add
    if ns.AUTO[id] then
        add = db.auto and AddAutoLines
    else
        add = (ns.SPELLS[id] or ns.WEAPON[id]) and AddSpellLines
            or db.lifetap and ns.LIFE_TAP[id] and AddLifeTapLines
            or db.shards and ns.SHARDS[id] and function()
                tt:AddLine(" ")
                AddShardLine(tt, id)
            end
    end
    if add then Report(pcall(add, tt, id)) end
end

-- the weapon's DPS with your attack power, under the weapon's own
local function AddItemLines(tt, data)
    local item = ns.ItemWeapon(data)
    if not item then return end
    local dps, ap, apDPS, swing = ns.ItemDPS(item)
    Line(tt, "With your attack power", Fmt(dps) .. " DPS")
    if not IsShiftKeyDown() then return AddShiftHint(tt) end
    Line(tt, item.ranged and "Per shot" or "Per swing", ("%s at %s"):format(Fmt(swing),
        Secs(item.speed)), DIM)
    Line(tt, "Attack power", ("+%s DPS  (%d / 14)"):format(Fmt(apDPS), ap), DIM)
end

local itemTooltips = {}
local function OnItemTooltip(tt, data)
    if not (db and db.enabled and db.weapon and itemTooltips[tt]) then return end
    Report(pcall(AddItemLines, tt, data))
end

---------------------------------------------------------------------------
-- Measuring: casts per fight against the damage meter's totals
---------------------------------------------------------------------------
local casts = {} -- spellID -> times cast since the last fight was read
local lastCount = {} -- spellID -> GetTime() of the last counted cast
local attackFrom -- GetTime() your auto attack came on, while it is on
local attackSeconds = 0 -- auto attack time since the last fight was read

local function CountCast(id)
    if not (id and canaccess(id) and type(id) == "number") then return end
    if not Counted(id) then return end
    local now = GetTime()
    -- a channel reports both SUCCEEDED and CHANNEL_START
    if lastCount[id] and now - lastCount[id] < 0.3 then return end
    lastCount[id] = now
    local list = casts[id] or {}
    list[#list + 1] = now
    casts[id] = list
end

-- combat started: only the casts just before it (the pull) belong to this fight
local function TrimToPull()
    local cutoff = GetTime() - PRE_PULL
    for id, list in pairs(casts) do
        local keep = {}
        for _, t in ipairs(list) do if t >= cutoff then keep[#keep + 1] = t end end
        casts[id] = #keep > 0 and keep or nil
    end
    attackSeconds = 0
    if attackFrom then attackFrom = math.max(attackFrom, cutoff) end
end

local function TakeCasts()
    local counted = {}
    for id, list in pairs(casts) do counted[id] = #list end
    wipe(casts)
    return counted
end

local function TakeAttackTime()
    local now = GetTime()
    local seconds = attackSeconds + (attackFrom and now - attackFrom or 0)
    attackSeconds = 0
    if attackFrom then attackFrom = now end
    return seconds
end

-- a pet's rows carry its name
local function FromPet(row)
    local name = row.creatureName
    if isSecret(name) then return true end
    return type(name) == "string" and name ~= ""
end

-- the key a meter row's damage counts under: the spell, "melee", or its name
local function RowKey(row, id)
    local name = C_Spell.GetSpellName(id)
    if MELEE_ROWS[id] or name and MELEE_NAMES[name] then
        return not FromPet(row) and "melee" or nil
    end
    local key = PARENT[id] or id
    -- unknown IDs (a ground spell's area hits) are matched by name in Learn
    if not Counted(key) then key = name or key end
    return key
end

-- this fight's damage per spell guid (you, by default) cast, or nil and why
local function MeterTotals(guid)
    local DM = C_DamageMeter
    if type(DM) ~= "table" or type(DM.GetCombatSessionSourceFromType) ~= "function" then
        return nil, "no damage meter"
    end
    if type(DM.IsDamageMeterAvailable) == "function" then
        local ok, available = pcall(DM.IsDamageMeterAvailable)
        if ok and available == false then return nil, "damage meter switched off" end
    end
    local types = Enum and Enum.DamageMeterType
    local sessions = Enum and Enum.DamageMeterSessionType
    local damageDone = types and types.DamageDone or 0
    local current = sessions and sessions.Current or 1
    local ok, totals, why = pcall(function()
        local src = DM.GetCombatSessionSourceFromType(current, damageDone,
            guid or UnitGUID("player"))
        if not Readable(src) or not Readable(src.combatSpells) then return nil, "wait" end
        local list = src.combatSpells
        local n = #list
        if isSecret(n) or n == 0 then return nil, "wait" end
        local out = {}
        for i = 1, n do
            local row = list[i]
            if Readable(row) then
                local id, amount = row.spellID, row.totalAmount
                if isSecret(id) or isSecret(amount) then return nil, "wait" end
                if type(id) == "number" and type(amount) == "number" then
                    local key = RowKey(row, id)
                    if key then out[key] = (out[key] or 0) + amount end
                    if db.debug then
                        Say(("meter row %d %s: %d -> %s"):format(id,
                            C_Spell.GetSpellName(id) or "?", amount, tostring(key)))
                    end
                end
            end
        end
        return out
    end)
    if not ok then return nil, "unreadable" end
    return totals, why
end

-- Damage under a spell's name, not its ID, goes to the ranks of it cast this fight,
-- shared by casts
local function ByName(counted, totals, id, n)
    local name = C_Spell.GetSpellName(id)
    local damage = name and totals[name]
    if not damage then return nil end
    local all = 0
    for other, k in pairs(counted) do
        if C_Spell.GetSpellName(other) == name then all = all + k end
    end
    return damage * n / all
end

local function LearnMelee(totals, seconds)
    local damage = totals.melee
    if not (damage and seconds > 0) then return end
    local m = charDB.measured.melee or { damage = 0, seconds = 0, fights = 0 }
    m.damage, m.seconds, m.fights = m.damage + damage, m.seconds + seconds, m.fights + 1
    charDB.measured.melee = m
    if db.debug then Say(("fight: melee %d s, meter %d"):format(seconds, damage)) end
end

local function Learn(counted, totals, seconds)
    for id, n in pairs(counted) do
        local damage = totals[id] or ByName(counted, totals, id, n)
        if n > 0 and damage then
            local m = charDB.measured[id] or { damage = 0, casts = 0, fights = 0 }
            m.damage, m.casts, m.fights = m.damage + damage, m.casts + n, m.fights + 1
            charDB.measured[id] = m
        end
        if db.debug then
            Say(("fight: %s x%d, meter %s"):format(C_Spell.GetSpellName(id) or id, n,
                tostring(damage)))
        end
    end
    LearnMelee(totals, seconds)
end

-- The meter lists a pet's spells under its owner (rows with a creatureName). Should a pet
-- show as a source of its own, its rows fill in the pet spells the owner's lacked.
local function AddPetSource(counted, totals)
    local guid = ns.petGUID
    if not guid then return end
    for id in pairs(counted) do
        if ns.SPELLS[id] and ns.SPELLS[id].pet and not totals[id] then
            for k, v in pairs(MeterTotals(guid) or {}) do
                if totals[k] == nil and k ~= "melee" then totals[k] = v end
            end
            return
        end
    end
end

local function ReadAfterFight(counted, seconds, tries)
    if InCombatLockdown() then return end -- a new pull came first; that fight is lost
    local totals, why = MeterTotals()
    if not totals and why == "wait" and tries > 0 then
        C_Timer.After(METER_RETRY, function() ReadAfterFight(counted, seconds, tries - 1) end)
        return
    end
    ns.lastMeter = totals and "read" or why
    if totals then
        AddPetSource(counted, totals)
        Learn(counted, totals, seconds)
    end
end

local function OnFightEnd()
    local counted = TakeCasts()
    local seconds = TakeAttackTime()
    if not next(counted) and seconds <= 0 then return end
    C_Timer.After(METER_RETRY, function() ReadAfterFight(counted, seconds, METER_TRIES) end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
-- No refresh on Shift: rebuilding a Blizzard tooltip from addon code (RefreshData) leaves
-- tainted state on it, and its next rebuild in combat errors on the secret line colours.
-- Action and bag buttons rebuild themselves every 0.2 s and pick Shift up; elsewhere the
-- Shift lines show on the next hover.
local function ClearShiftHint(tt) tt.meioShiftHint = nil end

local function HookTooltips()
    local post = TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
    if not post then
        Say("this client has no TooltipDataProcessor; tooltips stay unchanged")
        return
    end
    post(Enum.TooltipDataType.Spell, OnSpellTooltip)
    post(Enum.TooltipDataType.PetAction, OnSpellTooltip)
    post(Enum.TooltipDataType.Item, OnItemTooltip)
    -- the equipped weapons beside a weapon's tooltip get the line too
    for _, tt in ipairs({ GameTooltip, ItemRefTooltip, ShoppingTooltip1, ShoppingTooltip2 }) do
        itemTooltips[tt] = true
        tt:HookScript("OnTooltipCleared", ClearShiftHint)
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        f:UnregisterEvent("ADDON_LOADED")
        MeioDPSDB = MeioDPSDB or {}
        db = MeioDPSDB
        for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end
        MeioDPSCharDB = MeioDPSCharDB or {}
        charDB = MeioDPSCharDB
        charDB.measured = charDB.measured or {}
        HookTooltips()
        f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "pet")
        f:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player", "pet")
        f:RegisterEvent("PLAYER_REGEN_DISABLED")
        f:RegisterEvent("PLAYER_REGEN_ENABLED")
        f:RegisterEvent("PLAYER_ENTER_COMBAT")
        f:RegisterEvent("PLAYER_LEAVE_COMBAT")
        f:RegisterEvent("PLAYER_LOGIN")
        ns.db, ns.charDB = db, charDB
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        if arg1 == "pet" then
            local guid = UnitGUID("pet")
            if guid and canaccess(guid) then ns.petGUID = guid end
        end
        CountCast(arg3)
    elseif event == "PLAYER_ENTER_COMBAT" then
        attackFrom = attackFrom or GetTime()
    elseif event == "PLAYER_LEAVE_COMBAT" then
        if attackFrom then attackSeconds = attackSeconds + GetTime() - attackFrom end
        attackFrom = nil
    elseif event == "PLAYER_REGEN_DISABLED" then
        TrimToPull()
    elseif event == "PLAYER_REGEN_ENABLED" then
        OnFightEnd()
    elseif event == "PLAYER_LOGIN" then
        local ok, err = pcall(ns.RegisterSettings)
        if not ok then geterrorhandler()(err) end
    end
end)

---------------------------------------------------------------------------
-- /meiodps
---------------------------------------------------------------------------
-- key (also the chat command), what it does in help, its checkbox label in Settings.lua
ns.TOGGLES = {
    { key = "mana", what = "damage per mana, rage or energy",
        label = "Damage per cost" },
    { key = "heal", what = "what Drain Life, Siphon Life and Death Coil heal you",
        label = "Heals you" },
    { key = "shards", what = "Soul Shard cost and how many you have",
        label = "Soul Shard cost" },
    { key = "lifetap", what = "Life Tap mana per health and taps to full mana",
        label = "Life Tap" },
    { key = "ranks", what = "your ranks compared on Shift (per mana, per cast second)",
        label = "Rank comparison" },
    { key = "expected", what = "expected damage after hit and crit",
        label = "Expected damage" },
    { key = "measured", what = "measured damage per cast (damage meter)",
        label = "Measured damage" },
    { key = "auto", what = "damage and DPS on Attack, Auto Shot and Shoot",
        label = "Auto attacks" },
    { key = "weapon", what = "DPS with your attack power on weapon tooltips",
        label = "Weapon tooltips" },
}
local TOGGLE = {}
for _, t in ipairs(ns.TOGGLES) do TOGGLE[t.key] = t end

local CMD = "|cffffd100/meiodps%s|r"
local function Cmd(sub) return CMD:format(sub and " " .. sub or "") end
local function OnOff(v) return v and "|cff80ff80on|r" or "|cffff8080off|r" end

local function PrintStatus()
    local parts = {}
    for _, t in ipairs(ns.TOGGLES) do parts[#parts + 1] = t.key .. " " .. OnOff(db[t.key]) end
    Say(("tooltip lines %s (%s)"):format(OnOff(db.enabled), table.concat(parts, ", ")))
    local n = 0
    for _ in pairs(charDB.measured) do n = n + 1 end
    print(("  Measured: %d. Last damage meter read: %s"):format(n,
        ns.lastMeter or "none yet (after your first fight)"))
    print("  Hold Shift on a spell for the maths and your ranks side by side.")
end

local function PrintHelp()
    Say("damage, DPS and damage per mana on spell, ability and weapon tooltips")
    print(("  %s - open the settings"):format(Cmd()))
    print(("  %s - what's on, and the last damage meter read"):format(Cmd("status")))
    print(("  %s - all tooltip lines (now %s)"):format(Cmd("on||off"), OnOff(db.enabled)))
    for _, t in ipairs(ns.TOGGLES) do
        print(("  %s - %s (now %s)"):format(Cmd(t.key), t.what, OnOff(db[t.key])))
    end
    print(("  %s - measured damage per spell so far"):format(Cmd("casts")))
    print(("  %s - clear the measured damage"):format(Cmd("forget")))
    print(("  %s - print each fight's casts and meter totals (now %s)"):format(Cmd("debug"),
        OnOff(db.debug)))
    print(("  Settings: Esc > Options > AddOns > MeioDPS (%s)"):format(Cmd("settings")))
end

local function PrintCasts()
    local rows = {}
    for id, m in pairs(charDB.measured) do rows[#rows + 1] = { id = id, m = m } end
    if #rows == 0 then
        Say("nothing measured yet: fight something, then look again")
        return
    end
    table.sort(rows, function(x, y) return x.m.damage > y.m.damage end)
    Say("measured per cast (damage meter total / your casts)")
    for _, r in ipairs(rows) do
        if r.id == "melee" then
            print(("  Melee: %s DPS while attacking, %d s, %d fight(s)"):format(
                Fmt(r.m.damage / math.max(1, r.m.seconds)), r.m.seconds, r.m.fights))
        else
            local name = C_Spell.GetSpellName(r.id) or ("spell " .. r.id)
            local rank = C_Spell.GetSpellSubtext and C_Spell.GetSpellSubtext(r.id)
            if rank and canaccess(rank) and rank ~= "" then
                name = name .. " (" .. rank .. ")"
            end
            if ns.SPELLS[r.id] and ns.SPELLS[r.id].pet then name = name .. ", pet" end
            print(("  %s: %s per cast, %d casts, %d fight(s)"):format(name,
                Fmt(r.m.damage / r.m.casts), r.m.casts, r.m.fights or 0))
        end
    end
end

function ns.Forget()
    wipe(charDB.measured)
    Say("measured damage cleared")
end

local function OpenSettings()
    if not (ns.OpenSettings and ns.OpenSettings()) then PrintHelp() end
end

-- minimap addon compartment (.toc AddonCompartmentFunc)
function MeioDPS_OnAddonCompartmentClick() OpenSettings() end

SLASH_MEIODPS1 = "/meiodps"
SLASH_MEIODPS2 = "/spelldps"
SlashCmdList.MEIODPS = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "" or msg == "settings" or msg == "options" then
        OpenSettings()
    elseif msg == "help" or msg == "?" then
        PrintHelp()
    elseif msg == "status" then
        PrintStatus()
    elseif msg == "casts" then
        PrintCasts()
    elseif msg == "on" or msg == "off" then
        db.enabled = (msg == "on")
        Say("tooltip lines " .. OnOff(db.enabled))
    elseif TOGGLE[msg] then
        db[msg] = not db[msg]
        Say(TOGGLE[msg].what .. " " .. OnOff(db[msg]))
    elseif msg == "forget" then
        ns.Forget()
    elseif msg == "debug" then
        db.debug = not db.debug
        Say("debug " .. OnOff(db.debug))
    else
        Say(('unknown command "%s"'):format(msg))
        PrintHelp()
    end
end
