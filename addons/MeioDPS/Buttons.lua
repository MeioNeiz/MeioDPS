-- Damage on action buttons: each spell's expected damage per cast (or measured, or DPS) in
-- small text at the bottom of the button. The tooltip's own numbers (ns.Analyze), cached
-- per spell until stats, gear or spells change. Event driven, no OnUpdate.
local _, ns = ...

-- Blizzard's bars; Bartender, Dominos and ElvUI buttons are their own frames
local BARS = { "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
    "MultiBarRightButton", "MultiBarLeftButton", "MultiBar5Button", "MultiBar6Button",
    "MultiBar7Button" }
local THROTTLE = 0.2
local WHITE = { 1, 1, 1 }
local MEASURED = { 0.45, 1, 0.45 }

-- key (chat word and saved value), Settings label, help words
ns.BUTTON_MODES = {
    { key = "expected", label = "Expected damage", what = "expected damage per cast" },
    { key = "measured", label = "Measured damage",
        what = "measured damage per cast (green), else expected" },
    { key = "dps", label = "DPS", what = "expected DPS" },
}

local isSecret = issecretvalue or function() return false end

local buttons, labels, cache = {}, {}, {}
local pending

local function Short(v)
    if v >= 100000 then return ("%dk"):format(math.floor(v / 1000 + 0.5)) end
    if v >= 10000 then return (("%.1fk"):format(v / 1000):gsub("%.0k$", "k")) end
    if v >= 10 then return tostring(math.floor(v + 0.5)) end
    return (("%.1f"):format(v):gsub("%.0$", ""))
end

-- expected damage per cast and per second, or false when there's nothing to show
local function Compute(id)
    local data = ns.SPELLS[id]
    if not (data or ns.WEAPON[id]) or data and (data.pet or data.proc) then return false end
    local a = ns.Analyze(id)
    if not (a and a.expected and a.expected > 0) then return false end
    return { expected = a.expected, dps = a.expected / a.rateTime }
end

-- text and colour for the chosen mode; measured is read live, it changes after fights
local function Value(id)
    local v = cache[id]
    if v == nil then
        local ok, r = pcall(Compute, id)
        v = ok and r or false
        -- a fight can hide what a spell does: try again after it
        if v or not InCombatLockdown() then cache[id] = v end
    end
    if not v then return nil end
    local mode = ns.db.buttonShow
    if mode == "dps" then return Short(v.dps), WHITE end
    local m = mode == "measured" and ns.Measured(id)
    if m then return Short(m.damage / m.casts), MEASURED end
    return Short(v.expected), WHITE
end

-- the spell a slot casts: a spell, or a macro showing one
local function SlotSpell(slot)
    local kind, id, sub = GetActionInfo(slot)
    if isSecret(kind) or isSecret(id) then return nil end
    if kind == "spell" then return id end
    if kind == "macro" then
        if sub == "spell" then return id end
        return GetMacroSpell and GetMacroSpell(id)
    end
end

-- bottom centre; above a macro's name, left of a reagent count
local function Place(fs, b)
    fs:ClearAllPoints()
    local name, count = b.Name, b.Count
    if name and name:IsShown() and (name:GetText() or "") ~= "" then
        fs:SetPoint("BOTTOM", b, "BOTTOM", 0, 13)
    elseif count and count:IsShown() and (count:GetText() or "") ~= "" then
        fs:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 5, 5)
    else
        fs:SetPoint("BOTTOM", b, "BOTTOM", 0, 5)
    end
end

-- on the button's text layer, above the cooldown swipe like the hotkey
local function Label(b)
    local fs = labels[b]
    if not fs then
        fs = (b.TextOverlayContainer or b):CreateFontString(nil, "OVERLAY",
            "GameFontHighlightSmallOutline")
        labels[b] = fs
    end
    return fs
end

local function Update(b)
    local slot = b.action
    local id = type(slot) == "number" and not isSecret(slot) and SlotSpell(slot)
    local text, colour
    if type(id) == "number" and not isSecret(id) then text, colour = Value(id) end
    if text then
        local fs = Label(b)
        fs:SetText(text)
        fs:SetTextColor(colour[1], colour[2], colour[3])
        Place(fs, b)
        fs:Show()
    elseif labels[b] then
        labels[b]:Hide()
    end
end

local function Refresh()
    pending = nil
    local on = ns.db and ns.db.buttons
    for _, b in ipairs(buttons) do
        if on then
            local ok, err = pcall(Update, b)
            if not ok and ns.db.debug then ns.Say("button: " .. tostring(err)) end
        elseif labels[b] then
            labels[b]:Hide()
        end
    end
end

-- stale: numbers changed (stats, gear, spells), not just what's on the bars.
-- In a fight crit and descriptions can turn secret and read as 0 or old: the numbers
-- stay as they were until it ends.
local staleAfterFight
function ns.RefreshButtons(stale)
    if stale and InCombatLockdown() then
        staleAfterFight = true
    elseif stale then
        wipe(cache)
    end
    if pending or #buttons == 0 then return end
    pending = true
    C_Timer.After(THROTTLE, Refresh)
end

local STALE = { "SPELL_POWER_CHANGED", "PLAYER_DAMAGE_DONE_MODS", "COMBAT_RATING_UPDATE",
    "PLAYER_EQUIPMENT_CHANGED", "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB",
    "LEARNED_SPELL_IN_SKILL_LINE", "SPELL_TEXT_UPDATE", "PLAYER_LEVEL_UP" }
local MOVED = { "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED",
    "UPDATE_BONUS_ACTIONBAR", "UPDATE_SHAPESHIFT_FORM", "UPDATE_MACROS", "BAG_UPDATE_DELAYED" }

local f = CreateFrame("Frame")
local stale = {}

local function Register(event, unit)
    -- an event this client lacks errors on register
    if unit then
        pcall(f.RegisterUnitEvent, f, event, unit)
    else
        pcall(f.RegisterEvent, f, event)
    end
end

function ns.InitButtons()
    for _, prefix in ipairs(BARS) do
        for i = 1, 12 do
            local b = _G[prefix .. i]
            if b then buttons[#buttons + 1] = b end
        end
    end
    for _, e in ipairs(STALE) do
        stale[e] = true
        Register(e)
    end
    for _, e in ipairs(MOVED) do Register(e) end
    Register("UNIT_STATS", "player")
    stale.UNIT_STATS = true
    Register("PLAYER_ENTERING_WORLD")
    Register("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_ENABLED" then
            if not staleAfterFight then return end
            staleAfterFight = nil
            return ns.RefreshButtons(true)
        end
        if event == "PLAYER_ENTERING_WORLD" then
            -- descriptions can still be loading at login
            C_Timer.After(3, function() ns.RefreshButtons(true) end)
        end
        ns.RefreshButtons(stale[event])
    end)
    -- paging and stance swaps change a button's slot
    if EventRegistry and EventRegistry.RegisterCallback then
        pcall(EventRegistry.RegisterCallback, EventRegistry, "ActionButton.OnActionChanged",
            function() ns.RefreshButtons() end, f)
    end
    ns.RefreshButtons(true)
end
