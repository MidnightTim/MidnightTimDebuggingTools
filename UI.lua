--------------------------------------------------------------------------------
-- MidnightTimDebuggingTools: UI.lua
-- Minimal debug panel. Same patterns as MidnightSensei UI.lua.
-- Rules carried over:
--   - Always MakeFont() / never SetNormalFontObject (blocky font)
--   - FRIZQT__.TTF only -- no Unicode outside basic Latin
--   - ApplyBackdrop() for all frames
--   - No UI polish goals -- stability and clarity only
--------------------------------------------------------------------------------

MidnightTimDebug    = MidnightTimDebug    or {}
MidnightTimDebug.UI = MidnightTimDebug.UI or {}

-- Lazy getters -- same fix as Core.lua, avoids nil capture at file scope
local function U()    return MidnightTimDebug.Utils end
local function Core() return MidnightTimDebug.Core  end
local UI = MidnightTimDebug.UI   -- UI table is created on this file's own line 12, always valid

--------------------------------------------------------------------------------
-- Colour palette -- same family as MidnightSensei, purple accent for MTDT
--------------------------------------------------------------------------------
local C = {
    BG          = {0.04, 0.04, 0.07, 0.94},
    BG_LIGHT    = {0.08, 0.08, 0.13, 0.94},
    BORDER      = {0.25, 0.25, 0.35, 0.70},
    BORDER_ACC  = {0.60, 0.30, 1.00, 0.90},   -- purple accent border
    TITLE_BG    = {0.10, 0.08, 0.18, 0.98},
    TITLE       = {0.80, 0.55, 1.00, 1.00},   -- purple title text
    ACCENT      = {0.60, 0.30, 1.00, 1.00},
    TEXT        = {0.92, 0.90, 0.88, 1.00},
    TEXT_DIM    = {0.55, 0.53, 0.50, 1.00},
    ROW_EVEN    = {0.07, 0.07, 0.11, 0.55},
    ROW_ODD     = {0.04, 0.04, 0.07, 0.30},
    ROW_HOVER   = {0.18, 0.12, 0.28, 0.80},
    SEP         = {0.25, 0.25, 0.35, 0.50},
    GREEN       = {0.20, 0.90, 0.20, 1.00},
    RED         = {1.00, 0.30, 0.30, 1.00},
    YELLOW      = {1.00, 0.85, 0.20, 1.00},
    ORANGE      = {1.00, 0.55, 0.10, 1.00},
}

--------------------------------------------------------------------------------
-- Shared frame helpers (mirrors MidnightSensei patterns exactly)
--------------------------------------------------------------------------------
local function ApplyBackdrop(f, bg, border)
    if not f.SetBackdrop then Mixin(f, BackdropTemplateMixin) end
    f:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    local b = bg or C.BG ; local e = border or C.BORDER
    f:SetBackdropColor(b[1], b[2], b[3], b[4] or 1)
    f:SetBackdropBorderColor(e[1], e[2], e[3], e[4] or 1)
end

-- ALWAYS use this -- never SetNormalFontObject
local function MakeFont(parent, size, justify, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFont("Fonts/FRIZQT__.TTF", size or 11, "")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetTextColor(C.TEXT[1], C.TEXT[2], C.TEXT[3], 1)
    return fs
end

local function MakeButton(parent, w, h, label, accent)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(w, h)
    local border = accent and C.BORDER_ACC or C.BORDER
    ApplyBackdrop(btn, C.BG_LIGHT, border)
    local fs = MakeFont(btn, 10, "CENTER")
    fs:SetPoint("CENTER")
    fs:SetText(label or "")
    btn.label = fs
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.ROW_HOVER[1], C.ROW_HOVER[2], C.ROW_HOVER[3], C.ROW_HOVER[4])
        GameTooltip:Hide()
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.BG_LIGHT[1], C.BG_LIGHT[2], C.BG_LIGHT[3], C.BG_LIGHT[4] or 1)
    end)
    return btn
end

local function MakeCloseBtn(parent, onClick)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(18, 18)
    ApplyBackdrop(btn, {0.15, 0.05, 0.05, 0.90}, C.BORDER_ACC)
    local fs = MakeFont(btn, 11, "CENTER")
    fs:SetPoint("CENTER")
    fs:SetText("X")
    fs:SetTextColor(1, 0.4, 0.4, 1)
    btn:SetScript("OnEnter", function() fs:SetTextColor(1, 0.7, 0.7, 1) ; GameTooltip:Hide() end)
    btn:SetScript("OnLeave", function() fs:SetTextColor(1, 0.4, 0.4, 1) end)
    btn:SetScript("OnClick", onClick)
    return btn
end

local function MakeTitleBar(parent, titleStr)
    local tBar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    tBar:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, 0)
    tBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    tBar:SetHeight(26)
    ApplyBackdrop(tBar, C.TITLE_BG, C.BORDER_ACC)
    tBar:EnableMouse(true)
    tBar:RegisterForDrag("LeftButton")
    tBar:SetScript("OnDragStart", function() parent:StartMoving() end)
    tBar:SetScript("OnDragStop",  function() parent:StopMovingOrSizing() end)

    local title = MakeFont(tBar, 12, "CENTER")
    title:SetPoint("CENTER")
    title:SetTextColor(C.TITLE[1], C.TITLE[2], C.TITLE[3], 1)
    title:SetText(titleStr)

    local xBtn = MakeCloseBtn(tBar, function() parent:Hide() end)
    xBtn:SetPoint("RIGHT", tBar, "RIGHT", -4, 0)
    return tBar
end

local function MakeSeparator(parent, yOffset, anchorFrame)
    local sep = parent:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT",  anchorFrame or parent, "BOTTOMLEFT",  4, yOffset or -4)
    sep:SetPoint("TOPRIGHT", anchorFrame or parent, "BOTTOMRIGHT", -4, yOffset or -4)
    sep:SetColorTexture(C.SEP[1], C.SEP[2], C.SEP[3], C.SEP[4])
    return sep
end

--------------------------------------------------------------------------------
-- Main panel
-- Layout:
--   Title bar (draggable)
--   Status row (recording state + live timer)
--   Tab row: Controls | Sessions | Snapshot | Info
--   Content area (scrollable)
--   Bottom bar: version label
--------------------------------------------------------------------------------
local panel         = nil
local statusLabel   = nil
local contentScroll = nil
local contentFrame  = nil
local contentText   = nil
local activeTab     = "controls"
local statusTimer   = 0   -- used by OnUpdate to refresh the live timer

local PANEL_W = 380
local PANEL_H = 480
local TAB_H   = 26
local CONTENT_TOP_OFFSET = 26 + 28 + TAB_H + 6   -- titlebar + status + tabs + padding

--------------------------------------------------------------------------------
-- Helpers for content rendering
--------------------------------------------------------------------------------
local function SetContent(text)
    if contentText then
        contentText:SetText(text or "")
        -- Resize scroll child to fit text
        local th = contentText:GetStringHeight()
        if contentFrame then
            contentFrame:SetHeight(math.max(th + 12, contentScroll:GetHeight()))
        end
        if contentScroll then
            contentScroll:SetVerticalScroll(0)
        end
    end
end

local function Clr(hex, text)
    return string.format("|cff%s%s|r", hex, text)
end

--------------------------------------------------------------------------------
-- Status bar refresh
-- Called on tab open and on timer tick when Controls tab is active.
--------------------------------------------------------------------------------
local function RefreshStatus()
    if not statusLabel then return end

    local isRec = Core()._IsRecording and Core()._IsRecording() or false
    local sess  = Core()._GetActiveSession and Core()._GetActiveSession() or nil

    if isRec and sess then
        local elapsed = (GetTime and GetTime() or 0) - (sess.startTime or 0)
        local dur     = U().FormatDuration(elapsed)
        local events  = sess.events and #sess.events or 0
        local inCombat = (UnitAffectingCombat and UnitAffectingCombat("player")) or false
        local combatStr = inCombat and Clr("22dd22", "IN COMBAT") or Clr("888888", "out of combat")
        statusLabel:SetText(
            Clr("ff4444", "REC") .. "  " ..
            Clr("dddddd", dur) .. "  " ..
            Clr("888888", events .. " events") .. "  " ..
            combatStr
        )
    else
        local db = MidnightTimDebugDB
        local n  = db and db.sessions and #db.sessions or 0
        local profile = Core().activeProfile and Core().activeProfile.name or "generic"
        statusLabel:SetText(
            Clr("888888", "IDLE") .. "  " ..
            Clr("9966ff", profile) .. "  " ..
            Clr("888888", n .. " sessions saved")
        )
    end
end

--------------------------------------------------------------------------------
-- Tab: Controls
--------------------------------------------------------------------------------
local function RenderControls()
    local isRec = Core()._IsRecording and Core()._IsRecording() or false
    local db    = MidnightTimDebugDB
    local n     = db and db.sessions and #db.sessions or 0
    local profile = Core().activeProfile and Core().activeProfile.name or "generic"

    local lines = {
        Clr("9966ff", "RECORD"),
        "",
        "Profile: " .. Clr("dddddd", profile),
        "Sessions saved: " .. Clr("dddddd", tostring(n)),
        "Poll interval: " .. Clr("dddddd", string.format("%.2fs", Core().POLL_INTERVAL or 0.1)),
        "",
        Clr("9966ff", "EXPORT"),
        "",
        Clr("888888", "Exports write to:"),
        Clr("aaaaaa", "MidnightTimDebugDB.meta.lastExportCSV"),
        Clr("888888", "Open SavedVariables file after /reload"),
        "",
        Clr("9966ff", "PROFILES"),
        "",
        "  devourer  -  Devourer DH (primary target)",
        "  none      -  Generic (all spells/auras)",
    }
    SetContent(table.concat(lines, "\n"))
end

--------------------------------------------------------------------------------
-- Tab: Sessions
--------------------------------------------------------------------------------
local function RenderSessions()
    local db = MidnightTimDebugDB
    local sessions = db and db.sessions or {}

    if #sessions == 0 then
        SetContent(Clr("888888", "No sessions saved yet.\n\nEnter combat or use /mtdt start to record."))
        return
    end

    local lines = {
        Clr("9966ff", string.format("SESSIONS  (%d saved)", #sessions)),
        "",
    }

    -- Show last 20, newest first
    local start = math.max(1, #sessions - 19)
    for i = #sessions, start, -1 do
        local s   = sessions[i]
        local sum = s.summary or {}
        local dur = sum.durationFmt or U().FormatDuration(s.durationSec or 0)
        local evts = sum.eventCount or 0
        local ns   = sum.newSpellCount or 0
        local wall = s.startWall and date("%m/%d %H:%M", s.startWall) or "?"
        local prof = s.profile or "generic"
        local spec = s.player and s.player.specName or "?"

        table.insert(lines, string.format(
            "%s#%d%s  %s  %s  %s",
            "|cff9966ff", s.sessionIndex or i, "|r",
            Clr("dddddd", wall),
            Clr("aaaaaa", dur),
            Clr("888888", spec)
        ))
        table.insert(lines, string.format(
            "   %s events  %s new spells  %s",
            Clr("dddddd", tostring(evts)),
            ns > 0 and Clr("22dd22", tostring(ns)) or Clr("888888", "0"),
            Clr("888888", prof)
        ))
        table.insert(lines, "")
    end

    SetContent(table.concat(lines, "\n"))
end

--------------------------------------------------------------------------------
-- Tab: Snapshot
-- Calls the same logic as /mtdt snapshot + /mtdt auras but renders to the panel.
--------------------------------------------------------------------------------
local function RenderSnapshot()
    local lines = {
        Clr("9966ff", "LIVE SPELL SNAPSHOT"),
        "",
    }

    local profile = Core().activeProfile
    if not profile then
        table.insert(lines, Clr("888888", "No profile active. Use /mtdt profile devourer"))
    else
        table.insert(lines, "Profile: " .. Clr("dddddd", profile.name))
        table.insert(lines, "")

        local usability = U().SnapshotSpellUsability(profile.watchedSpells or {})
        for _, id in ipairs(profile.watchedSpells or {}) do
            local s = usability[id]
            if s then
                local nameStr = (s.name or ("ID:" .. id)):sub(1, 28)
                local knownClr  = s.known  and "22dd22" or "888888"
                local usableClr = s.usable and "22dd22" or (s.noMana and "ffaa00" or "dd4444")
                local cdStr = ""
                if s.cdStart and s.cdStart > 0 and s.cdDuration and s.cdDuration > 0 then
                    local remain = (s.cdStart + s.cdDuration) - (GetTime and GetTime() or 0)
                    if remain > 0 then
                        cdStr = "  CD: " .. Clr("ffaa00", string.format("%.0fs", remain))
                    end
                end
                table.insert(lines, string.format(
                    "%s%-28s%s  known:%s  usable:%s%s",
                    "|cffaaaaaa", nameStr, "|r",
                    Clr(knownClr,  s.known  and "Y" or "N"),
                    Clr(usableClr, s.usable and "Y" or (s.noMana and "OOM" or "N")),
                    cdStr
                ))
            end
        end
    end

    table.insert(lines, "")
    table.insert(lines, Clr("9966ff", "PLAYER AURAS"))
    table.insert(lines, "")

    local auras = U().SnapshotAuras("player")
    local count = 0
    for _, a in pairs(auras) do
        count = count + 1
        local nameStr = (a.name or ("ID:" .. (a.spellID or "?"))):sub(1, 28)
        local stackStr = (a.stacks and a.stacks > 0) and ("  x" .. a.stacks) or ""
        local typeClr  = a.auraType == "HARMFUL" and "dd4444" or "44aadd"
        table.insert(lines, string.format(
            "%s%-28s%s  %s%s  id:%s",
            "|cffaaaaaa", nameStr, "|r",
            Clr(typeClr, a.auraType == "HARMFUL" and "debuff" or "buff"),
            stackStr,
            Clr("888888", tostring(a.spellID or "?"))
        ))
    end
    if count == 0 then
        table.insert(lines, Clr("888888", "(no auras)"))
    end

    SetContent(table.concat(lines, "\n"))
end

--------------------------------------------------------------------------------
-- Tab: Info
-- Talents + class/spec info
--------------------------------------------------------------------------------
local function RenderInfo()
    local lines = {
        Clr("9966ff", "CHARACTER"),
        "",
    }

    local cs = U().SnapshotClassSpec()
    table.insert(lines, "Name:   " .. Clr("dddddd", (cs.playerName or "?") .. "-" .. (cs.realmName or "?")))
    table.insert(lines, "Class:  " .. Clr("dddddd", cs.className or "?"))
    table.insert(lines, "Spec:   " .. Clr("dddddd", (cs.specName or "?") .. " (specIdx " .. tostring(cs.specIdx or "?") .. ")"))
    table.insert(lines, "Zone:   " .. Clr("dddddd", U().SnapshotZone().name or "?"))
    table.insert(lines, "")
    table.insert(lines, Clr("9966ff", "ACTIVE TALENTS"))
    table.insert(lines, "")

    local talents = U().SnapshotTalents()
    if #talents == 0 then
        table.insert(lines, Clr("888888", "(none found -- talent tree may not be loaded yet)"))
    else
        for _, t in ipairs(talents) do
            local nameStr = (t.name or "unknown"):sub(1, 30)
            local idStr   = tostring(t.spellID or 0)
            local rankStr = t.rank and t.rank > 1 and (" r" .. t.rank) or ""
            table.insert(lines, string.format(
                "  %s  %s%s",
                Clr("888888", string.format("%-8s", idStr)),
                Clr("dddddd", nameStr),
                Clr("888888", rankStr)
            ))
        end
    end

    SetContent(table.concat(lines, "\n"))
end

--------------------------------------------------------------------------------
-- Tab dispatcher
--------------------------------------------------------------------------------
local tabRenders = {
    controls = RenderControls,
    sessions = RenderSessions,
    snapshot = RenderSnapshot,
    info     = RenderInfo,
}

local tabButtons = {}

local function SwitchTab(name)
    activeTab = name
    for k, btn in pairs(tabButtons) do
        if k == name then
            btn:SetBackdropColor(C.ROW_HOVER[1], C.ROW_HOVER[2], C.ROW_HOVER[3], 0.90)
            btn.label:SetTextColor(C.TITLE[1], C.TITLE[2], C.TITLE[3], 1)
        else
            btn:SetBackdropColor(C.BG_LIGHT[1], C.BG_LIGHT[2], C.BG_LIGHT[3], C.BG_LIGHT[4] or 1)
            btn.label:SetTextColor(C.TEXT[1], C.TEXT[2], C.TEXT[3], 1)
        end
    end
    RefreshStatus()
    local fn = tabRenders[name]
    if fn then fn() end
end

--------------------------------------------------------------------------------
-- Build the panel (lazy -- built once on first show)
--------------------------------------------------------------------------------
local function BuildPanel()
    panel = CreateFrame("Frame", "MidnightTimDebugPanel", UIParent, "BackdropTemplate")
    panel:SetSize(PANEL_W, PANEL_H)
    panel:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    ApplyBackdrop(panel, C.BG, C.BORDER_ACC)

    -- Title bar
    MakeTitleBar(panel, "MidnightTim Debug Tools  v" .. (Core().VERSION or "1.0.0"))

    -- Status row
    local statusRow = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    statusRow:SetPoint("TOPLEFT",  panel, "TOPLEFT",  0, -26)
    statusRow:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -26)
    statusRow:SetHeight(28)
    ApplyBackdrop(statusRow, {0.06, 0.06, 0.10, 0.95}, C.BORDER)

    statusLabel = MakeFont(statusRow, 10, "LEFT")
    statusLabel:SetPoint("LEFT",  statusRow, "LEFT",  8, 0)
    statusLabel:SetPoint("RIGHT", statusRow, "RIGHT", -8, 0)
    statusLabel:SetText("Initializing...")

    -- Tab row
    local tabRow = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    tabRow:SetPoint("TOPLEFT",  panel, "TOPLEFT",  0, -54)
    tabRow:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -54)
    tabRow:SetHeight(TAB_H)
    ApplyBackdrop(tabRow, {0.06, 0.06, 0.10, 0.90}, C.BORDER)

    local tabDefs = {
        { key = "controls", label = "Controls" },
        { key = "sessions", label = "Sessions" },
        { key = "snapshot", label = "Snapshot" },
        { key = "info",     label = "Info"     },
    }
    local tabW = math.floor(PANEL_W / #tabDefs)
    for i, td in ipairs(tabDefs) do
        local btn = MakeButton(tabRow, tabW - 2, TAB_H - 4, td.label)
        btn:SetPoint("LEFT", tabRow, "LEFT", (i - 1) * tabW + 1, 0)
        btn:SetScript("OnClick", function() SwitchTab(td.key) end)
        tabButtons[td.key] = btn
    end

    -- Scroll content area
    contentScroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    contentScroll:SetPoint("TOPLEFT",     panel, "TOPLEFT",   8,  -(26 + 28 + TAB_H + 6))
    contentScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 34)

    contentFrame = CreateFrame("Frame", nil, contentScroll)
    contentFrame:SetWidth(contentScroll:GetWidth())
    contentFrame:SetHeight(10)
    contentScroll:SetScrollChild(contentFrame)

    contentText = MakeFont(contentFrame, 10, "LEFT")
    contentText:SetPoint("TOPLEFT",  contentFrame, "TOPLEFT",  4, -4)
    contentText:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", -4, -4)
    contentText:SetWordWrap(true)
    contentText:SetSpacing(3)

    -- Bottom bar with action buttons
    local botBar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    botBar:SetPoint("BOTTOMLEFT",  panel, "BOTTOMLEFT",  0, 0)
    botBar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    botBar:SetHeight(32)
    ApplyBackdrop(botBar, {0.06, 0.06, 0.10, 0.96}, C.BORDER_ACC)

    -- Action buttons in bottom bar
    -- Start / Stop (recording toggle)
    local btnStartStop = MakeButton(botBar, 74, 22, "Start", true)
    btnStartStop:SetPoint("LEFT", botBar, "LEFT", 6, 0)
    btnStartStop:SetScript("OnClick", function()
        local isRec = Core()._IsRecording and Core()._IsRecording() or false
        if isRec then
            Core().StopSession()
        else
            Core().StartSession(true)
        end
        RefreshStatus()
        if tabRenders[activeTab] then tabRenders[activeTab]() end
    end)
    panel.btnStartStop = btnStartStop

    -- Export recent -- runs export AND opens the copy popup
    local btnExport = MakeButton(botBar, 84, 22, "Export Recent")
    btnExport:SetPoint("LEFT", btnStartStop, "RIGHT", 4, 0)
    btnExport:SetScript("OnClick", function()
        local db = MidnightTimDebugDB
        local all = db and db.sessions or {}
        if #all > 0 then
            SlashCmdList["MIDNIGHTTIMDEBUGGINGTOOLS"]("export recent")
        else
            U().Print("No sessions to export.")
        end
    end)

    -- Copy Last -- re-opens the popup for the last export without re-running it
    local btnCopy = MakeButton(botBar, 72, 22, "Copy Last")
    btnCopy:SetPoint("LEFT", btnExport, "RIGHT", 4, 0)
    btnCopy:SetScript("OnClick", function()
        local db  = MidnightTimDebugDB
        local csv = db and db.meta and db.meta.lastExportCSV
        if csv and #csv > 0 then
            UI.ShowExport(csv)
        else
            U().Print("No export found. Run Export Recent first.")
        end
    end)

    -- Reset (with confirm step)
    local btnReset = MakeButton(botBar, 56, 22, "Reset")
    btnReset:SetPoint("RIGHT", botBar, "RIGHT", -6, 0)
    btnReset._confirming = false
    btnReset:SetScript("OnClick", function(self)
        if not self._confirming then
            self._confirming = true
            self.label:SetText("Confirm?")
            self.label:SetTextColor(C.RED[1], C.RED[2], C.RED[3], 1)
            -- Auto-cancel confirm after 3s
            C_Timer.After(3, function()
                if self._confirming then
                    self._confirming = false
                    self.label:SetText("Reset")
                    self.label:SetTextColor(C.TEXT[1], C.TEXT[2], C.TEXT[3], 1)
                end
            end)
        else
            self._confirming = false
            self.label:SetText("Reset")
            self.label:SetTextColor(C.TEXT[1], C.TEXT[2], C.TEXT[3], 1)
            SlashCmdList["MIDNIGHTTIMDEBUGGINGTOOLS"]("reset")
            RefreshStatus()
            if tabRenders[activeTab] then tabRenders[activeTab]() end
        end
    end)

    -- OnUpdate: refresh status label and Start/Stop button label on every frame
    -- when the panel is visible. Lightweight -- just string updates.
    panel:SetScript("OnUpdate", function(self, elapsed)
        statusTimer = statusTimer + elapsed
        if statusTimer < 0.5 then return end
        statusTimer = 0

        -- Refresh status label
        RefreshStatus()

        -- Update Start/Stop button label
        local isRec = Core()._IsRecording and Core()._IsRecording() or false
        if panel.btnStartStop then
            if isRec then
                panel.btnStartStop.label:SetText("Stop")
                panel.btnStartStop.label:SetTextColor(C.RED[1], C.RED[2], C.RED[3], 1)
            else
                panel.btnStartStop.label:SetText("Start")
                panel.btnStartStop.label:SetTextColor(C.GREEN[1], C.GREEN[2], C.GREEN[3], 1)
            end
        end

        -- Live-refresh snapshot tab if it's open
        if activeTab == "snapshot" then
            RenderSnapshot()
        end
    end)

    panel:Hide()
end

--------------------------------------------------------------------------------
-- Export popup
-- A resizable scrollable EditBox pre-filled with the CSV text.
-- The player can Ctrl+A / Ctrl+C to copy it, then paste into any text editor
-- and save as .csv themselves. This is the only way WoW addons can "export"
-- data -- the client has no file-write API.
--------------------------------------------------------------------------------
local exportPopup = nil

local function BuildExportPopup()
    exportPopup = CreateFrame("Frame", "MidnightTimDebugExport", UIParent, "BackdropTemplate")
    exportPopup:SetSize(520, 420)
    exportPopup:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    exportPopup:SetFrameStrata("DIALOG")
    exportPopup:SetMovable(true)
    exportPopup:SetClampedToScreen(true)
    exportPopup:EnableMouse(true)
    ApplyBackdrop(exportPopup, C.BG, C.BORDER_ACC)

    MakeTitleBar(exportPopup, "MTDT Export -- Select All (Ctrl+A) then Copy (Ctrl+C)")

    -- Instruction label
    local hint = MakeFont(exportPopup, 10, "CENTER")
    hint:SetPoint("TOPLEFT",  exportPopup, "TOPLEFT",  10, -32)
    hint:SetPoint("TOPRIGHT", exportPopup, "TOPRIGHT", -10, -32)
    hint:SetTextColor(C.TEXT_DIM[1], C.TEXT_DIM[2], C.TEXT_DIM[3], 1)
    hint:SetText("Click inside the box, press Ctrl+A to select all, then Ctrl+C to copy. Paste into Notepad and Save As .csv")

    -- ScrollFrame containing an EditBox
    local sf = CreateFrame("ScrollFrame", "MidnightTimDebugExportScroll", exportPopup, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     exportPopup, "TOPLEFT",   8, -52)
    sf:SetPoint("BOTTOMRIGHT", exportPopup, "BOTTOMRIGHT", -26, 36)

    local eb = CreateFrame("EditBox", "MidnightTimDebugExportBox", sf)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject("ChatFontNormal")
    eb:SetWidth(sf:GetWidth())
    eb:SetScript("OnEscapePressed", function() exportPopup:Hide() end)
    -- Allow the editbox to resize its scroll parent
    eb:SetScript("OnTextChanged", function(self)
        self:SetWidth(sf:GetWidth())
    end)
    sf:SetScrollChild(eb)
    exportPopup.editBox = eb

    -- Bottom bar
    local botBar = CreateFrame("Frame", nil, exportPopup, "BackdropTemplate")
    botBar:SetPoint("BOTTOMLEFT",  exportPopup, "BOTTOMLEFT",  0, 0)
    botBar:SetPoint("BOTTOMRIGHT", exportPopup, "BOTTOMRIGHT", 0, 0)
    botBar:SetHeight(32)
    ApplyBackdrop(botBar, {0.06, 0.06, 0.10, 0.96}, C.BORDER_ACC)

    local btnClose = MakeButton(botBar, 70, 22, "Close")
    btnClose:SetPoint("RIGHT", botBar, "RIGHT", -8, 0)
    btnClose:SetScript("OnClick", function() exportPopup:Hide() end)

    local sizeLabel = MakeFont(botBar, 10, "LEFT")
    sizeLabel:SetPoint("LEFT", botBar, "LEFT", 10, 0)
    sizeLabel:SetTextColor(C.TEXT_DIM[1], C.TEXT_DIM[2], C.TEXT_DIM[3], 1)
    exportPopup.sizeLabel = sizeLabel

    exportPopup:Hide()
end

function UI.ShowExport(csvText)
    if not exportPopup then BuildExportPopup() end
    csvText = csvText or ""
    exportPopup.editBox:SetText(csvText)
    exportPopup.editBox:HighlightText()
    exportPopup.sizeLabel:SetText(string.format("%d chars / ~%d lines", #csvText, select(2, csvText:gsub("\n", "\n")) + 1))
    exportPopup:Show()
    exportPopup.editBox:SetFocus()
end

--------------------------------------------------------------------------------
-- Public: toggle the panel
--------------------------------------------------------------------------------
function UI.Toggle()
    if not panel then BuildPanel() end
    if panel:IsShown() then
        panel:Hide()
    else
        RefreshStatus()
        SwitchTab(activeTab)
        panel:Show()
    end
end

function UI.Show()
    if not panel then BuildPanel() end
    RefreshStatus()
    SwitchTab(activeTab)
    panel:Show()
end

function UI.Hide()
    if panel then panel:Hide() end
end

--------------------------------------------------------------------------------
-- Expose internal state for UI reads
-- Core.lua doesn't expose isRecording/activeSession publicly -- add thin
-- accessors here rather than touching Core internals.
-- We read the upvalue indirectly by checking isRecording state.
-- The cleanest approach: add two read-only accessors to Core at the bottom
-- of Core.lua init. Since we can't edit Core.lua from here, we instead
-- piggyback on the observable state: if Core().StartSession was called but
-- Core().StopSession hasn't been called, a session is active.
-- We detect this by checking if MidnightTimDebugDB.activeSessionFlag exists.
-- Core.lua sets/clears this flag around StartSession/StopSession.
--
-- Simpler path: just expose the accessors directly in Core.lua.
-- See the two stubs added at the bottom of Core.lua.
--------------------------------------------------------------------------------

-- (Accessors Core()._IsRecording and Core()._GetActiveSession are defined
--  at the bottom of Core.lua and used here.)
-- ui/toggle/show/hide slash commands are handled directly in Core.lua's
-- HandleSlash, which calls MidnightTimDebug.UI.Toggle/Show/Hide.
-- No hook or wrapper needed here.
