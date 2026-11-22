-- Damage from a spell's description text. No game calls, so it can be tested anywhere.
-- On WoW Forever the numbers in the text already include your spell power and the talents
-- the game applies to the tooltip (checked: Shadow Bolt rank 3, 22 spell power, reads
-- 62 + 22 x 0.857 = 81), so they are used as they are.

local _, ns = ...
ns = ns or {}

-- Damage words to the school whose crit chance applies. Forever adds mixed schools (Chaos
-- Bolt, Shadowflame, Frostfire Bolt); "N damage" with no word is physical.
local SCHOOLS = {
    physical = 1, holy = 2, fire = 3, nature = 4, frost = 5, shadow = 6, arcane = 7,
    chaos = 3, shadowflame = 6, frostfire = 5, spellfire = 3, spellfrost = 5,
    shadowfrost = 6, chimeric = 7,
}
ns.SCHOOLS = SCHOOLS

-- damage dealt to each enemy in an area, so "per target"
local AREA = {
    "nearby enemies", "all enemies", "all targets", "all enemy targets", "in the area",
    "enter the area", "enemies within", "targets within", "target area", "enemies near",
    "in a cone",
}

-- Does the (lower case) text deal its damage to each of several targets? Chain Lightning's
-- number is the first target's; each jump does less.
function ns.IsArea(t)
    if type(t) ~= "string" or t:find("jump", 1, true) then return false end
    for _, phrase in ipairs(AREA) do
        if t:find(phrase, 1, true) then return true end
    end
    -- Multi-Shot "hitting 3 targets", Whirlwind "up to 4 enemies"
    return t:find("hitting %d+ targets") ~= nil or t:find("up to %d+ enemies") ~= nil
end

local function Seconds(n, unit)
    n = tonumber(n)
    if not n then return nil end
    if unit and unit:sub(1, 3) == "min" then return n * 60 end
    return n
end

local NUM = "(%d+%.?%d*)"
-- range forms first: on the same start they win
local FORMS = {
    { NUM .. " to " .. NUM .. " (%a+) damage", range = true, word = true },
    { NUM .. " to " .. NUM .. " damage", range = true },
    { NUM .. "%-" .. NUM .. " damage", range = true },
    { NUM .. " (%a+) damage", word = true },
    { NUM .. " damage" },
}

-- First match of one form from pos whose damage word is a school ("0.7 additional damage"
-- isn't): start, end, low, high, school
local function FindForm(t, form, pos)
    while true do
        local s, e, a, b, c = t:find(form[1], pos)
        if not s then return nil end
        local lo, hi, word
        if form.range then lo, hi, word = a, b, c else lo, hi, word = a, a, b end
        word = form.word and word or "physical"
        if SCHOOLS[word] then return s, e, tonumber(lo), tonumber(hi), word end
        pos = s + 1
    end
end

-- The next "N [school] damage" or "N to M [school] damage" from pos
local function NextDamage(t, pos)
    local best
    for _, form in ipairs(FORMS) do
        local m = { FindForm(t, form, pos) }
        if m[1] and (not best or m[1] < best[1]) then best = m end
    end
    if best then return best[1], best[2], best[3], best[4], best[5] end
end

-- What a description says the spell does, or nil when it names no damage:
-- { direct, lo, hi, dot, dotTime, school, aoe, points, ap }. direct is the average of the
-- range; dot is the whole periodic part; dotTime the seconds it takes; points the combo
-- points it was read at; ap the share of attack power added to direct; apUnknown: attack
-- power adds more by an amount the text doesn't give.
function ns.ParseDescription(text)
    if type(text) ~= "string" or text == "" then return nil end
    local t = text:lower():gsub("(%d),(%d)", "%1%2"):gsub("%s+", " ")
    local r = { apUnknown = t:find("attack power", 1, true) ~= nil }
    -- finishing moves list damage per combo point: read the most points
    local at, points
    for s, n in t:gmatch("()(%d) points?%s*:") do at, points = s, tonumber(n) end
    if at and points > 1 then
        r.points = points
        t = t:sub(tonumber(at) or 1)
    end
    -- Bloodthirst: "damage equal to 45% of your attack power plus 30"
    local apPct, plus = t:match("damage equal to (%d+)%% of your attack power plus (%d+)")
    if apPct then
        r.direct, r.lo, r.hi, r.school = tonumber(plus), tonumber(plus), tonumber(plus), "physical"
        r.ap, r.apUnknown = tonumber(apPct) / 100, false
    end
    local pos = 1
    while true do
        local s, e, lo, hi, school = NextDamage(t, pos)
        if not s then break end
        pos = e + 1
        if SCHOOLS[school] then
            local sentence = t:sub(e + 1):match("^[^.]*") or ""
            local over, overUnit = sentence:match("^ over (%d+) (%a+)")
            local after, afterUnit = sentence:match("^ after (%d+) (%a+)")
            local eachFor = sentence:match("^ each second for (%d+) sec")
            local every = tonumber(sentence:match("every " .. NUM .. " sec"))
            local who = sentence:match("^ to (%a+)")
            if who == "himself" or who == "herself" or who == "you" then
                -- Hellfire burning you
            elseif over or after then
                if not r.dot then
                    r.dot, r.dotTime = (lo + hi) / 2, Seconds(over or after, overUnit or afterUnit)
                    r.school = r.school or school
                end
            elseif eachFor then
                if not r.dot then
                    r.dot, r.dotTime = (lo + hi) / 2 * tonumber(eachFor), tonumber(eachFor)
                    r.school = r.school or school
                end
            elseif every then
                -- "every 1 sec for 6 sec", "Lasts 15 sec.", Wrack's "for 6 sec, inflicting"
                local n, unit = sentence:match("every %S+ %a+ for (%d+) (%a+)")
                if not n then n, unit = t:match("lasts (%d+) (%a+)") end
                if not n then n, unit = t:match("for (%d+) (sec)") end
                local dur = Seconds(n, unit)
                if dur and not r.dot and every > 0 then
                    r.dot, r.dotTime = (lo + hi) / 2 * dur / every, dur
                    r.school = r.school or school
                end
            elseif not r.direct then
                r.direct, r.lo, r.hi = (lo + hi) / 2, lo, hi
                r.school = school
            end
        end
    end
    -- Shadow Cleave: "dealing 3 to 6 to each", no damage word
    if not (r.direct or r.dot) then
        local lo, hi = t:match("dealing " .. NUM .. " to " .. NUM .. " to each")
        lo, hi = tonumber(lo), tonumber(hi)
        if lo and hi then r.direct, r.lo, r.hi = (lo + hi) / 2, lo, hi end
    end
    -- Drain Life, Siphon Life: "transfers 14 health every 1 second from the target ... lasts 5 sec"
    if not r.dot and t:find("from the target") then
        local per = tonumber(t:match("transfers (%d+) health"))
        local every = tonumber(t:match("every (%d+) sec")) or (t:find("every sec") and 1)
        local lasts, unit = t:match("lasts (%d+) (%a+)")
        local dur = Seconds(lasts, unit)
        if per and every and dur and every > 0 then
            r.dot, r.dotTime = per * dur / every, dur
            r.school = r.school or "shadow"
        end
    end
    if not (r.direct or r.dot) then return nil end
    -- what it heals you: a drain heals what it deals; Death Coil "the caster gains 100% of
    -- the damage caused in health"
    if t:find("transfers %d+ health") then
        r.heal = (r.direct or 0) + (r.dot or 0)
    else
        local pct = tonumber(t:match("gains (%d+)%% of the damage caused in health"))
        if pct then r.heal = ((r.direct or 0) + (r.dot or 0)) * pct / 100 end
    end
    r.aoe = ns.IsArea(t)
    r.schoolIndex = SCHOOLS[r.school]
    return r
end

-- Life Tap: "Converts 140 Health into 140 Mana": health, mana; nil when unreadable
function ns.ParseLifeTap(text)
    if type(text) ~= "string" then return nil end
    local t = text:lower():gsub("(%d),(%d)", "%1%2")
    local health, mana = t:match("converts (%d+) health into (%d+) mana")
    health, mana = tonumber(health), tonumber(mana)
    if health and mana and health > 0 then return health, mana end
end

return ns
