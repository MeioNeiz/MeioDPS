-- Spell table (/meiodps spells): every damage spell you know side by side, the numbers the
-- tooltip shows (ns.Analyze), top rank by default or every rank. Click a column to sort;
-- the best in each column is green. Built on show and on events, never on a frame tick;
-- in a fight the rows stay as they were until it ends.
local _, ns = ...

-- not in help or Settings yet: only /meiodps spells opens it
ns.TABLE_LISTED = false

local WIDTH, HEIGHT, ROW, HEAD = 576, 432, 22, 22
local GREEN = { 0.45, 1, 0.45 }
local WHITE = { 1, 1, 1 }
local MUTED = "|cff999999"
local NONE = MUTED .. "-|r"
local SORT_ARROW = "Interface\\Buttons\\UI-SortArrow"

-- numeric columns, right to left from the row's right edge after the spell's name
local COLUMNS = {
    { key = "damage", title = "Damage", width = 70,
        tip = "Average damage per cast, as on the tooltip, before hit and crit. Area "
            .. "spells: per target." },
    { key = "dps", title = "Per cast sec", width = 92,
        tip = "Damage for each second you spend casting it: its cast time, channel or the "
            .. "1.5 s global cooldown. A DoT counts all its ticks, so it shows what is "
            .. "worth keeping up. On the tooltip it is the DPS (or Per cast second) line." },
    { key = "perMana", title = "Per mana", width = 70,
        tip = "Damage for each point of mana it costs. Tick Every rank to see which rank "
            .. "to downrank to when mana runs short." },
    { key = "measured", title = "Measured", width = 78,
        tip = "What it really did per cast in your fights, from Blizzard's damage meter, "
            .. "after 3 casts. Includes resists, misses, crits and talents." },
}
local NAME_TIP = "Your damage spells. Hover one for its tooltip."

local window, content, empty, status, ranksBox
local headers, rows = {}, {}
local entries = {}
local dirty

local canaccess = canaccessvalue or function() return true end

local function Tip(owner, title, text)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:SetText(title)
    GameTooltip:AddLine(text, 1, 1, 1, true)
    GameTooltip:Show()
end

local function Known(id)
    local ok, known = pcall(C_SpellBook.IsSpellKnown, id)
    return ok and known and true or false
end

local function Rank(id)
    local sub = C_Spell.GetSpellSubtext and C_Spell.GetSpellSubtext(id)
    if type(sub) ~= "string" or not canaccess(sub) then return 0 end
    return tonumber(sub:match("%d+")) or 0
end

-- one row's numbers, or nil for spells with nothing to compare (pets, shields)
local function Entry(id)
    local data = ns.SPELLS[id]
    if data and (data.pet or data.proc) then return nil end
    local ok, a = pcall(ns.Analyze, id)
    if not (ok and a and a.total > 0) then return nil end
    local name = C_Spell.GetSpellName(id)
    if not name then return nil end
    local m = ns.Measured(id)
    return { id = id, name = name, rank = Rank(id), aoe = a.p.aoe, damage = a.total,
        -- an on-next-swing attack has no rate of its own
        dps = not (a.weapon and a.weapon.swing) and a.dps or nil,
        perMana = a.cost and a.total / a.cost or nil, power = a.power,
        measured = m and m.damage / m.casts or nil }
end

local function Collect(allRanks)
    local list, top, seen = {}, {}, {}
    for _, src in ipairs({ ns.SPELLS, ns.WEAPON }) do
        for id in pairs(src) do
            if not seen[id] and Known(id) then
                seen[id] = true
                local e = Entry(id)
                if e and allRanks then
                    list[#list + 1] = e
                elseif e and (not top[e.name] or e.rank > top[e.name].rank) then
                    top[e.name] = e
                end
            end
        end
    end
    for _, e in pairs(top) do list[#list + 1] = e end
    return list
end

local function Sort(list)
    local key, up = ns.db.spellSort or "dps", ns.db.spellSortUp
    table.sort(list, function(x, y)
        if key ~= "name" then
            local a, b = x[key], y[key]
            if (a == nil) ~= (b == nil) then return a ~= nil end -- blanks last either way
            if a and a ~= b then
                if up then return a < b end
                return a > b
            end
        end
        if x.name ~= y.name then
            if key == "name" and up then return x.name > y.name end
            return x.name < y.name
        end
        return x.rank > y.rank
    end)
end

local function Best(list)
    local best = {}
    for _, c in ipairs(COLUMNS) do
        local n, top = 0, nil
        for _, e in ipairs(list) do
            local v = e[c.key]
            if v then
                n = n + 1
                if not top or v > top then top = v end
            end
        end
        best[c.key] = n > 1 and top or nil
    end
    return best
end

local function Text(key, v)
    if not v then return NONE end
    if key == "perMana" then return ("%.2f"):format(v) end
    return ns.Fmt(v)
end

local function Label(e)
    local sub = {}
    if e.rank > 0 then sub[#sub + 1] = "Rank " .. e.rank end
    if e.aoe then sub[#sub + 1] = "per target" end
    if #sub == 0 then return e.name end
    return ("%s  %s%s|r"):format(e.name, MUTED, table.concat(sub, ", "))
end

-- the cost column says mana, unless some spell costs rage, energy or focus
local function CostTitle(list)
    for _, e in ipairs(list) do
        if e.power and e.power ~= "mana" then return "Per cost" end
    end
    return "Per mana"
end

local function PlaceColumns(parent, cells)
    local right = -6
    for i = #COLUMNS, 1, -1 do
        local c = COLUMNS[i]
        cells[c.key]:ClearAllPoints()
        cells[c.key]:SetPoint("RIGHT", parent, "RIGHT", right, 0)
        cells[c.key]:SetWidth(c.width)
        right = right - c.width
    end
    return right
end

---@class MeioDPSTableRow: Button
---@field entry table the spell the row shows

local function Row(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, content) --[[@as MeioDPSTableRow]]
    r:SetHeight(ROW)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW)
    r:SetPoint("RIGHT")
    if i % 2 == 0 then
        local bg = r:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.04)
    end
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.08)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ROW - 4, ROW - 4)
    r.icon:SetPoint("LEFT", 4, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.cells = {}
    for _, c in ipairs(COLUMNS) do
        local fs = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        fs:SetJustifyH("RIGHT")
        r.cells[c.key] = fs
    end
    local left = PlaceColumns(r, r.cells)
    r.name = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.name:SetPoint("RIGHT", r, "RIGHT", left, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(r.entry.id)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", GameTooltip_Hide)
    rows[i] = r
    return r
end

local function ShowHeaders(costTitle)
    local key, up = ns.db.spellSort or "dps", ns.db.spellSortUp
    for k, h in pairs(headers) do
        h.label:SetText(k == "perMana" and costTitle or h.title)
        local on = k == key
        if on then h.label:SetTextColor(1, 1, 1) else h.label:SetTextColor(1, 0.82, 0) end
        h.arrow:SetShown(on)
        if on then
            -- the texture points down: highest first
            if up then h.arrow:SetTexCoord(0, 0.5625, 1, 0) else
                h.arrow:SetTexCoord(0, 0.5625, 0, 1) end
        end
    end
end

local function Draw()
    Sort(entries)
    local best = Best(entries)
    local costTitle = CostTitle(entries)
    ShowHeaders(costTitle)
    for i, e in ipairs(entries) do
        local r = Row(i)
        r.entry = e
        local ok, tex = pcall(C_Spell.GetSpellTexture, e.id)
        r.icon:SetTexture(ok and tex or 134400)
        r.name:SetText(Label(e))
        for _, c in ipairs(COLUMNS) do
            local v = e[c.key]
            local colour = v and v == best[c.key] and GREEN or WHITE
            r.cells[c.key]:SetText(Text(c.key, v))
            r.cells[c.key]:SetTextColor(colour[1], colour[2], colour[3])
        end
        r:Show()
    end
    for i = #entries + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(1, #entries * ROW))
    empty:SetShown(#entries == 0)
    local what = ns.db.spellRanks and "ranks" or "spells"
    status:SetText(#entries > 0 and ("%s%d %s. Best in each column in green.|r"):format(
        MUTED, #entries, #entries == 1 and what:sub(1, -2) or what) or "")
    if dirty then status:SetText(MUTED .. "In combat: numbers update when it ends.|r") end
end

-- force: read the spells even in a fight (the every rank tick asked for other rows)
local function Refresh(force)
    if not (window and window:IsShown()) then return end
    -- a fight can hide what spells do: keep the last rows until it ends
    if InCombatLockdown() and #entries > 0 and not force then
        dirty = true
    else
        dirty = nil
        entries = Collect(ns.db.spellRanks)
    end
    Draw()
end

local queued
local function QueueRefresh()
    if queued or not (window and window:IsShown()) then return end
    queued = true
    C_Timer.After(0.2, function()
        queued = nil
        Refresh()
    end)
end
function ns.RefreshTable() QueueRefresh() end

local EVENTS = { "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB", "SPELL_POWER_CHANGED",
    "PLAYER_EQUIPMENT_CHANGED", "PLAYER_DAMAGE_DONE_MODS", "SPELL_TEXT_UPDATE",
    "PLAYER_REGEN_ENABLED", "PLAYER_LEVEL_UP" }

local function SortBy(key)
    if (ns.db.spellSort or "dps") == key then
        ns.db.spellSortUp = not ns.db.spellSortUp
    else
        ns.db.spellSort, ns.db.spellSortUp = key, false
    end
    Draw()
end

local function Header(parent, key, title, tip)
    local h = CreateFrame("Button", nil, parent)
    h:SetHeight(HEAD)
    h.key, h.title = key, title
    h.label = h:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    h.arrow = h:CreateTexture(nil, "ARTWORK")
    h.arrow:SetTexture(SORT_ARROW)
    h.arrow:SetSize(9, 8)
    if key == "name" then
        h.label:SetPoint("LEFT", 2, 0)
        h.arrow:SetPoint("LEFT", h.label, "RIGHT", 3, 0)
    else
        h.label:SetPoint("RIGHT", 0, 0)
        h.arrow:SetPoint("RIGHT", h.label, "LEFT", -3, 0)
    end
    local hl = h:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)
    h:SetScript("OnClick", function() SortBy(key) end)
    h:SetScript("OnEnter", function(self)
        Tip(self, key == "perMana" and self.label:GetText() or title,
            tip .. "\n\n" .. MUTED .. "Click to sort, again to turn the order round.|r")
    end)
    h:SetScript("OnLeave", GameTooltip_Hide)
    headers[key] = h
    return h
end

local function Place()
    window:ClearAllPoints()
    local p = ns.db.spellPos
    if type(p) == "table" and p[1] then
        local point, rel = p[1] --[[@as FramePoint]], (p[2] or p[1]) --[[@as FramePoint]]
        window:SetPoint(point, UIParent, rel, p[3] or 0, p[4] or 0)
    else
        window:SetPoint("CENTER")
    end
end

local function Create()
    window = CreateFrame("Frame", "MeioDPSTable", UIParent, "ButtonFrameTemplate")
    if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(window) end
    if window.SetTitle then window:SetTitle("MeioDPS") end
    window:SetSize(WIDTH, HEIGHT)
    window:SetFrameStrata("DIALOG")
    window:SetToplevel(true)
    window:SetClampedToScreen(true)
    window:EnableMouse(true)
    window:SetMovable(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", function(self) self:StartMoving() end)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, rel, x, y = self:GetPoint()
        ns.db.spellPos = { point, rel, x, y }
    end)
    tinsert(UISpecialFrames, window:GetName())
    Place()

    local hint = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 14, -32)
    hint:SetPoint("RIGHT", -14, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("Your damage spells with your spell power and gear. Click a column to sort.")

    window.Inset:ClearAllPoints()
    window.Inset:SetPoint("TOPLEFT", 8, -52)
    window.Inset:SetPoint("BOTTOMRIGHT", -8, 34)

    local head = CreateFrame("Frame", nil, window.Inset)
    head:SetPoint("TOPLEFT", 4, -3)
    head:SetPoint("TOPRIGHT", -30, -3)
    head:SetHeight(HEAD)
    local line = head:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.25)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    local cells = {}
    for _, c in ipairs(COLUMNS) do cells[c.key] = Header(head, c.key, c.title, c.tip) end
    local left = PlaceColumns(head, cells)
    local name = Header(head, "name", "Spell", NAME_TIP)
    name:SetPoint("LEFT", 4, 0)
    name:SetPoint("RIGHT", head, "RIGHT", left - 8, 0)

    local scroll = CreateFrame("ScrollFrame", nil, window.Inset, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -2)
    scroll:SetPoint("BOTTOMRIGHT", -30, 4)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(WIDTH - 58, 1)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
    window.content = content

    empty = window.Inset:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    empty:SetPoint("CENTER")
    empty:SetText("No damage spells known yet.")

    ranksBox = CreateFrame("CheckButton", nil, window, "UICheckButtonTemplate")
    ranksBox:SetSize(26, 26)
    ranksBox:SetPoint("BOTTOMRIGHT", -96, 4)
    local label = ranksBox.Text or ranksBox:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:ClearAllPoints()
    label:SetPoint("LEFT", ranksBox, "RIGHT", 2, 1)
    label:SetText("Every rank")
    ranksBox:SetChecked(ns.db.spellRanks and true or false)
    ranksBox:SetScript("OnClick", function(self)
        ns.db.spellRanks = self:GetChecked() and true or false
        Refresh(true)
    end)
    ranksBox:SetScript("OnEnter", function(self)
        Tip(self, "Every rank", "Show each rank you know, not just the top one, to pick "
            .. "the rank to downrank to.")
    end)
    ranksBox:SetScript("OnLeave", GameTooltip_Hide)
    window.ranksBox = ranksBox

    status = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    status:SetPoint("BOTTOMLEFT", 14, 13)
    status:SetPoint("RIGHT", ranksBox, "LEFT", -8, 0)
    status:SetJustifyH("LEFT")
    window.status = status

    window:SetScript("OnShow", function(self)
        for _, e in ipairs(EVENTS) do pcall(self.RegisterEvent, self, e) end
        Refresh()
    end)
    window:SetScript("OnHide", function(self) self:UnregisterAllEvents() end)
    window:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_ENABLED" and not dirty then return end
        QueueRefresh()
    end)
    window:Hide()
end

function ns.ShowTable()
    if not window then Create() end
    window:Show()
end

function ns.ToggleTable()
    if window and window:IsShown() then window:Hide() else ns.ShowTable() end
end

function ns.ResetTable()
    ns.db.spellPos = nil
    if window then Place() end
end
