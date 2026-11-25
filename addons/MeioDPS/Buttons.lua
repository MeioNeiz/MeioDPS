-- Damage on action buttons: each spell's expected damage per cast (or measured, or DPS) in
-- small text at the bottom of the button. The tooltip's own numbers (ns.Analyze), cached
-- per spell until stats, gear or spells change. Event driven, no OnUpdate.
local _, ns = ...

local BARS = { "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
    "MultiBarRightButton", "MultiBarLeftButton", "MultiBar5Button", "MultiBar6Button",
    "MultiBar7Button" }
-- Bartender4 and ElvUI (its own copy) make LibActionButton buttons; Dominos makes
-- ActionBarButtonTemplate ones and reuses some of Blizzard's. All are made at their
-- addon's login, which can come after ours.
local LABS = { "LibActionButton-1.0", "LibActionButton-1.0-ElvUI" }
local NAMED = { "BT4Button%d", "DominosActionButton%d" }
local BAR_ADDONS = { Bartender4 = true, Dominos = true, ElvUI = true }
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

local buttons, known, labButtons, labels, cache = {}, {}, {}, {}, {}
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

local function HasText(fs)
    if not (fs and fs:IsShown()) then return false end
    local text = fs:GetText()
    return isSecret(text) or text ~= nil and text ~= ""
end

-- the number and the count side by side would touch (1234 beside 28)
local function Crowded(fs, b, count)
    local ok, crowded = pcall(function()
        return fs:GetStringWidth() + count:GetStringWidth() + 9 > b:GetWidth()
    end)
    return ok and crowded
end

-- bottom centre; above a macro's name, left of a reagent count (above it if too wide)
local function Place(fs, b)
    fs:ClearAllPoints()
    local name, count = b.Name, b.Count
    if HasText(name) then
        fs:SetPoint("BOTTOM", b, "BOTTOM", 0, 13)
    elseif HasText(count) and Crowded(fs, b, count) then
        fs:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 5, 19)
    elseif HasText(count) then
        fs:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 5, 5)
    else
        fs:SetPoint("BOTTOM", b, "BOTTOM", 0, 5)
    end
end

-- on the button's text layer, above the cooldown swipe like the hotkey
local function Label(b)
    local fs = labels[b]
    if not fs then
        local layer = b.TextOverlayContainer or b.HotKey and b.HotKey:GetParent() or b
        fs = layer:CreateFontString(nil, "OVERLAY",
            "GameFontHighlightSmallOutline")
        labels[b] = fs
    end
    return fs
end

local function Slot(v)
    return type(v) == "number" and not isSecret(v) and v > 0 and v
end

-- LibActionButton reads its slot from the paging state; it can also hold a spell, an item
-- or a macro of its own (custom bars): spells only
local function LabSpell(b)
    local ok, kind, value = pcall(b.GetAction, b)
    if not ok then kind, value = b._state_type, b._state_action end
    if isSecret(kind) then return nil end
    if kind == "action" then
        value = Slot(value)
        return value and SlotSpell(value)
    end
    if kind == "spell" and not isSecret(value) then return value end
end

local function ButtonSpell(b)
    if labButtons[b] or b._state_type ~= nil then return LabSpell(b) end
    -- Dominos' buttons have ID 0 and their slot in the "action" attribute
    local slot = Slot(b.action) or b.GetAttribute and Slot(b:GetAttribute("action"))
    return slot and SlotSpell(slot)
end

local function Update(b)
    local id = ButtonSpell(b)
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

local function Add(b, lab)
    if type(b) ~= "table" then return end
    if lab then labButtons[b] = true end
    if known[b] then return end
    known[b] = true
    buttons[#buttons + 1] = b
    -- a reagent count can change after our refresh for the bag change (Soul Fire going
    -- to 1 shard hides it): move the number with it
    if type(b.UpdateCount) == "function" then
        hooksecurefunc(b, "UpdateCount", function()
            local fs = labels[b]
            if fs and fs:IsShown() then pcall(Place, fs, b) end
        end)
    end
end

local function Moved() ns.RefreshButtons() end
local hookedLabs = {}

local function Discover()
    for _, prefix in ipairs(BARS) do
        for i = 1, 12 do Add(_G[prefix .. i]) end
    end
    for _, major in ipairs(LABS) do
        local lib = LibStub and LibStub(major, true)
        if lib and not hookedLabs[lib] and lib.RegisterCallback then
            hookedLabs[lib] = true
            local function On(name, fn) pcall(lib.RegisterCallback, "MeioDPS", name, fn) end
            On("OnButtonCreated", function(_, b)
                Add(b, true)
                ns.RefreshButtons()
            end)
            On("OnButtonUpdate", Moved)
            On("OnButtonContentsChanged", Moved)
        end
        if lib and type(lib.buttonRegistry) == "table" then
            for b in pairs(lib.buttonRegistry) do Add(b, true) end
        end
    end
    for i = 1, 180 do
        for _, name in ipairs(NAMED) do Add(_G[name:format(i)]) end
    end
    for bar = 1, 15 do
        for i = 1, 12 do Add(_G[("ElvUI_Bar%dButton%d"):format(bar, i)]) end
    end
end

local function Register(event, unit)
    -- an event this client lacks errors on register
    if unit then
        pcall(f.RegisterUnitEvent, f, event, unit)
    else
        pcall(f.RegisterEvent, f, event)
    end
end

function ns.InitButtons()
    Discover()
    for _, e in ipairs(STALE) do
        stale[e] = true
        Register(e)
    end
    for _, e in ipairs(MOVED) do Register(e) end
    Register("UNIT_STATS", "player")
    stale.UNIT_STATS = true
    Register("PLAYER_ENTERING_WORLD")
    Register("PLAYER_REGEN_ENABLED")
    Register("ADDON_LOADED")
    f:SetScript("OnEvent", function(_, event, name)
        if event == "ADDON_LOADED" then
            if not BAR_ADDONS[name] then return end
            Discover()
            return ns.RefreshButtons()
        end
        if event == "PLAYER_REGEN_ENABLED" then
            if not staleAfterFight then return end
            staleAfterFight = nil
            return ns.RefreshButtons(true)
        end
        if event == "PLAYER_ENTERING_WORLD" then
            Discover()
            -- descriptions can still be loading at login
            C_Timer.After(3, function() ns.RefreshButtons(true) end)
        end
        ns.RefreshButtons(stale[event])
    end)
    -- paging and stance swaps change a button's slot; a bar addon's button can be new
    if EventRegistry and EventRegistry.RegisterCallback then
        pcall(EventRegistry.RegisterCallback, EventRegistry, "ActionButton.OnActionChanged",
            function(_, b)
                Add(b)
                ns.RefreshButtons()
            end, f)
    end
    ns.RefreshButtons(true)
end
