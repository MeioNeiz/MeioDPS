-- Options panel: Esc > Options > AddOns > MeioDPS, or /meiodps. Writes into MeioDPSDB.
local _, ns = ...

local category

local TIPS = {
    mana = "Per mana (rage, energy) line: damage for each point the spell or ability "
        .. "costs, to compare spells and ranks.",
    heal = "Heals you line on Drain Life, Siphon Life and Death Coil: health the spell "
        .. "gives back, and per point of mana.",
    shards = "Soul Shard line on Soul Fire, Shadowburn, summons and stones: shards the spell "
        .. "uses and how many you carry (red when you have too few).",
    lifetap = "Life Tap tooltip: mana for each point of health, and how many taps (and how "
        .. "much health) to fill your mana.",
    ranks = "Hold Shift on a spell to compare every rank you know: damage per mana and per "
        .. "second of casting. The best per mana is green, for downranking.",
    expected = "Expected line: damage and DPS after your chance to hit and crit, as shown "
        .. "in your character sheet.",
    measured = "Measured line: what the spell really did per cast in your fights, from "
        .. "Blizzard's damage meter, after 3 casts. Includes resists, crits and talents. "
        .. "Melee: per second your auto attack was on.",
    auto = "Damage and DPS per swing or shot on Attack, Auto Shot and Shoot (wand), from "
        .. "your character sheet.",
    weapon = "Weapon tooltips: the weapon's DPS with your attack power and buffs added, "
        .. "to compare weapons.",
}

local function Checkbox(key, name, tip)
    local setting = Settings.RegisterAddOnSetting(category, "MEIODPS_" .. key:upper(), key,
        ns.db, Settings.VarType.Boolean, name, key ~= "debug")
    Settings.CreateCheckbox(category, setting, tip)
    return setting
end

local function Header(layout, title, tip)
    if layout and CreateSettingsListSectionHeaderInitializer then
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(title, tip))
    end
end

function ns.RegisterSettings()
    if category or not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
    local layout
    category, layout = Settings.RegisterVerticalLayoutCategory("MeioDPS")
    Checkbox("enabled", "Tooltip lines", "Damage, DPS and the lines below on your spell, "
        .. "ability and weapon tooltips. Off: tooltips stay as Blizzard's. /meiodps on||off "
        .. "does the same.")
    Header(layout, "Tooltip lines", "Which lines tooltips show. Hold Shift on a spell or "
        .. "weapon for the maths and your ranks. /meiodps help lists the commands.")
    for _, t in ipairs(ns.TOGGLES) do Checkbox(t.key, t.label, TIPS[t.key]) end
    Header(layout, "Action buttons", "Numbers on your action bar buttons, for spells and "
        .. "macros that cast one. /meiodps buttons")
    local buttons = Checkbox("buttons", "Show on buttons", "Each damage spell's "
        .. "number in small text at the bottom of its button. /meiodps buttons does the "
        .. "same.")
    local show = Settings.RegisterAddOnSetting(category, "MEIODPS_BUTTONSHOW", "buttonShow",
        ns.db, Settings.VarType.String, "Buttons show", "expected")
    Settings.CreateDropdown(category, show, function()
        local c = Settings.CreateControlTextContainer()
        for _, m in ipairs(ns.BUTTON_MODES) do c:Add(m.key, m.label) end
        return c:GetData()
    end, "Expected: damage per cast after your chance to hit and crit. Measured: what it "
        .. "really did per cast in your fights (green), expected until 3 casts. DPS: "
        .. "expected damage per second. /meiodps buttons expected||measured||dps")
    for _, s in ipairs({ buttons, show }) do
        if s.SetValueChangedCallback then
            s:SetValueChangedCallback(function() ns.RefreshButtons() end)
        end
    end
    Header(layout, "Troubleshooting", "/meiodps debug, /meiodps forget")
    Checkbox("debug", "Print each fight", "After each fight, prints in chat the casts "
        .. "MeioDPS counted and the damage meter's totals.")
    if layout and CreateSettingsButtonInitializer then
        layout:AddInitializer(CreateSettingsButtonInitializer("Measured damage", "Forget",
            ns.Forget, "Clears what MeioDPS has measured for this character; it starts "
            .. "again from your next fight.", true))
    end
    Settings.RegisterAddOnCategory(category)
end

function ns.OpenSettings()
    if not category then return end
    Settings.OpenToCategory(category:GetID())
    return true
end
