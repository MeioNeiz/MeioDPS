-- MeioDPS.API: read-only numbers for other addons. Every function is nil-safe: it returns
-- nil when the game hides the value (secret in combat, nothing equipped), for spells
-- MeioDPS can't read, and on any error. Numbers are averages before hit and crit, with
-- your current spell power, attack power and buffs.
--
--   MeioDPS.API.SpellDamage(spellID) -> table or nil
--     { average = direct + dot, direct, dot, dotTicks, dotSeconds, expected (after hit
--       and crit), perTarget (true for area damage), comboPoints (finishers: read at) }
--     Spells and weapon abilities (Sinister Strike: weapon damage + bonus).
--   MeioDPS.API.AutoAttack(kind) -> average per hit, seconds per hit; or nil
--     kind "main", "off" (melee hands), "ranged" (bow, gun, crossbow, thrown or wand),
--     "wand" (only while a wand is equipped)
--   MeioDPS.API.Measured(spellID) -> average per cast, casts; or nil
--     What the damage meter showed per cast in your fights (from 3 casts on)

local _, ns = ...

local API = {}

local function Safe(fn)
    return function(...)
        local ok, a, b = pcall(fn, ...)
        if ok then return a, b end
    end
end

API.SpellDamage = Safe(function(spellID)
    if type(spellID) ~= "number" then return nil end
    if not (ns.SPELLS[spellID] or ns.WEAPON[spellID]) then return nil end
    local a = ns.Analyze(spellID)
    if not a then return nil end
    local p, data = a.p, ns.SPELLS[spellID]
    return { average = a.total, direct = p.direct, dot = p.dot,
        dotTicks = p.dot and data and data.t or nil, dotSeconds = p.dotTime,
        expected = a.expected, perTarget = p.aoe or false, comboPoints = p.points }
end)

API.AutoAttack = Safe(function(kind)
    local s
    if kind == "main" or kind == "off" then
        s = ns.Swing(kind)
    elseif kind == "ranged" or kind == "wand" and ns.HasWand() then
        s = ns.Swing("ranged")
    end
    if s then return s.avg, s.speed end
end)

API.Measured = Safe(function(spellID)
    if type(spellID) ~= "number" then return nil end
    local m = ns.Measured(spellID)
    if m then return m.damage / m.casts, m.casts end
end)

MeioDPS = MeioDPS or {}
MeioDPS.API = API
