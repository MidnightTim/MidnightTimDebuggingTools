--------------------------------------------------------------------------------
-- MidnightTimDebuggingTools: Core.lua
-- Polling-based combat debug recorder for Midnight 12.0.
-- NO RegisterEvent calls -- pure polling via an OnUpdate ticker.
-- Everything is written to SavedVariables for offline inspection.
--
-- Architecture note:
--   We drive all state detection through a single ticker registered on a
--   hidden frame's OnUpdate handler. This avoids all event registration
--   issues observed in Midnight 12.0 (protected event tables, delayed
--   roster sync, etc.). The tradeoff is that sub-frame-rate precision is
--   not achievable, but for debugging purposes 0.1s resolution is fine.
--
-- SavedVariables: MidnightTimDebugDB
--   .sessions[]         -- array of completed session records
--   .activeSession      -- session in progress (nil when idle)
--   .meta               -- { version, lastExportCSV, totalSessions }
--------------------------------------------------------------------------------

MidnightTimDebug      = MidnightTimDebug      or {}
MidnightTimDebug.Core = MidnightTimDebug.Core or {}

-- U is resolved lazily via a local getter rather than captured at file scope.
-- In some Midnight 12.0 load sequences MidnightTimDebug.Utils is not yet
-- assigned when this file's top-level code runs, so a direct
-- "local U = MidnightTimDebug.Utils" captures nil permanently.
-- The getter re-reads the table reference on every call, which is always safe.
local function U()
    return MidnightTimDebug.Utils
end

local Core = MidnightTimDebug.Core

Core.VERSION     = "1.0.0"
Core.ADDON_NAME  = "MidnightTimDebuggingTools"
Core.DISPLAY     = "MidnightTim Debug Tools"

-- Maximum sessions retained in SavedVariables before oldest are pruned.
-- Each session can be several KB depending on combat length and aura churn.
Core.MAX_SESSIONS = 50

-- Polling interval in seconds.
-- 0.1s is a reasonable balance: fine enough to catch proc windows and
-- aura transitions, cheap enough not to matter on any modern machine.
-- Raise to 0.2 if you see any hitching during heavy combat.
Core.POLL_INTERVAL = 0.1

-- Minimum fight length in seconds before a session is considered worth keeping.
-- Trash pulls shorter than this are discarded on session end to reduce noise.
Core.MIN_SESSION_SECONDS = 3

--------------------------------------------------------------------------------
-- Devourer DH Watch Profile
-- This is the primary research target for v1.
-- Fill in verified spell IDs and aura IDs as you discover them in-game.
-- Anything marked VERIFY needs in-game confirmation via /mtdt spellinfo <id>
--
-- IMPORTANT: IDs sourced from MidnightSensei's Core.lua validSpells whitelist
-- for Devourer (classID 12, specIdx 3). Some may still need verification.
-- Flag unconfirmed entries with -- VERIFY comment.
--------------------------------------------------------------------------------
Core.WATCH_PROFILES = {

    DEVOURER_DH = {
        name    = "Devourer DH",
        classID = 12,
        specIdx = 3,

        -- Spells to watch for usability/visibility/cooldown changes.
        -- These will be polled every tick during a session.
        watchedSpells = {
            -- Core rotation
            1217605,  -- Void Metamorphosis
            1226019,  -- Reap
            1221167,  -- Collapsing Star    (combatGated in MidnightSensei -- may not appear at load)
            1234195,  -- Void Nova
            473728,   -- Void Ray
            1245412,  -- Voidblade
            -- Shared DH class abilities
            185123,   -- Throw Glaive
            183752,   -- Disrupt
            278326,   -- Consume Magic
            196718,   -- Darkness
            207684,   -- Sigil of Misery
            255260,   -- Chaos Brand
            -- Defensive
            198589,   -- Blur
            -- Things we explicitly DON'T expect but want to confirm are absent:
            191427,   -- Metamorphosis (Havoc)  -- SHOULD NOT APPEAR
            198013,   -- Eye Beam (Havoc)        -- SHOULD NOT APPEAR
            370965,   -- The Hunt (Havoc)        -- SHOULD NOT APPEAR
            258920,   -- Immolation Aura (Havoc) -- SHOULD NOT APPEAR
        },

        -- Auras to specifically watch for appearance/disappearance.
        -- These get diff-checked every tick rather than only at snapshot points.
        watchedAuras = {
            1217605,  -- Void Metamorphosis buff (if it applies a self-buff)  VERIFY
            1221167,  -- Collapsing Star channel buff                         VERIFY
            1226019,  -- Reap buff if any                                     VERIFY
            1238855,  -- Mastery: Monster Within                              VERIFY
            1227619,  -- Shattered Souls tracking buff                       VERIFY
        },

        -- Auras that, when they appear, should trigger a note in the log
        -- about what spells became newly available on that same tick.
        -- This helps correlate "proc fires -> spell appears" relationships.
        procTriggerAuras = {
            1217605,  -- Void Metamorphosis     VERIFY
            1227619,  -- Shattered Souls        VERIFY
        },
    },

}

-- Active profile used during recording. Nil = record everything generically.
-- Auto-selected on login by DetectProfile(). Can be overridden with /mtdt profile.
-- Starts nil so any class that doesn't match a profile gets generic recording.
Core.activeProfile = nil

-- Forward declaration: DetectProfile is defined near OnLogin below but called
-- from the slash handler which is defined earlier in the file.
local DetectProfile

-- Forward declarations for profile build/restore functions defined near OnLogin.
local BuildProfileFromDump
local RestoreGeneratedProfiles

--------------------------------------------------------------------------------
-- Internal state -- never persisted directly, rebuilt each session
--------------------------------------------------------------------------------
local ticker         = nil    -- the OnUpdate frame
local tickAccum      = 0      -- accumulated time since last poll
local isRecording    = false  -- true when a session is actively recording
local wasInCombat    = false  -- combat state on the previous tick
local activeSession  = nil    -- the current in-progress session table

-- Spell visibility from the previous tick (for new-spell detection)
local prevSpellbook  = {}
-- Aura state from the previous tick (for aura diff)
local prevAuras      = {}
-- Spell usability from the previous tick (for usability transitions)
local prevUsability  = {}

--------------------------------------------------------------------------------
-- DB Helpers
--------------------------------------------------------------------------------
local function EnsureDB()
    MidnightTimDebugDB = MidnightTimDebugDB or {}
    local db = MidnightTimDebugDB
    db.sessions  = db.sessions  or {}
    db.meta      = db.meta      or { version = Core.VERSION, totalSessions = 0 }
    db.meta.version = Core.VERSION
    return db
end

local function GetDB()
    return MidnightTimDebugDB or EnsureDB()
end

--------------------------------------------------------------------------------
-- Session record builder
-- Returns a fresh, empty session table.
--------------------------------------------------------------------------------
local function NewSession()
    local now = U().Now()
    return {
        sessionIndex  = (GetDB().meta.totalSessions or 0) + 1,
        startTime     = now,
        startWall     = U().WallClock(),
        endTime       = nil,
        endWall       = nil,
        durationSec   = nil,
        manualStart   = false,   -- true if /mtdt start was used
        combatStart   = nil,     -- GetTime() when we detected combat begin
        combatEnd     = nil,     -- GetTime() when we detected combat end
        player        = U().SnapshotClassSpec(),
        zone          = U().SnapshotZone(),
        profile       = Core.activeProfile and Core.activeProfile.name or "generic",

        -- Snapshots taken at session open
        talentsAtStart    = U().SnapshotTalents(),
        spellbookAtStart  = U().SnapshotSpellbook(),
        aurasAtStart      = U().SnapshotAuras("player"),
        usabilityAtStart  = Core.activeProfile
                                and U().SnapshotSpellUsability(Core.activeProfile.watchedSpells)
                                or  {},
        resourcesAtStart  = U().SnapshotResources(),

        -- Event log -- array of { t, event, data }
        -- t is relative seconds from session startTime for easy reading.
        events = {},

        -- Spells that were NOT in the spellbook at session start but appeared later.
        newSpellsDiscovered = {},

        -- Summary filled in at session close
        summary = {},
    }
end

--------------------------------------------------------------------------------
-- Event logger
-- Appends a record to the active session's event log.
-- t is always relative to session start for clarity in export.
--------------------------------------------------------------------------------
local function LogEvent(eventType, data)
    if not activeSession then return end
    local t = U().Now() - activeSession.startTime
    table.insert(activeSession.events, {
        t     = math.floor(t * 100) / 100,   -- 2 decimal precision
        event = eventType,
        data  = data,
    })
end

--------------------------------------------------------------------------------
-- New spell detection
-- Compares current spellbook against the session's at-start snapshot and
-- also against prevSpellbook to catch spells that appeared THIS tick.
-- Called every poll tick during recording.
--------------------------------------------------------------------------------
local function CheckForNewSpells(currentBook)
    if not activeSession then return end
    for spellID, name in pairs(currentBook) do
        -- Not in spellbook at session start?
        if not activeSession.spellbookAtStart[spellID] then
            -- Not already noted?
            if not activeSession.newSpellsDiscovered[spellID] then
                local t = U().Now() - activeSession.startTime
                activeSession.newSpellsDiscovered[spellID] = {
                    spellID      = spellID,
                    name         = name,
                    discoveredAt = math.floor(t * 100) / 100,
                    inCombat     = UnitAffectingCombat and UnitAffectingCombat("player") or false,
                }
                LogEvent("NEW_SPELL_APPEARED", {
                    spellID = spellID,
                    name    = name,
                })
            end
        end
        -- Also log if it appeared this tick (wasn't in prevSpellbook at all)
        if not prevSpellbook[spellID] and not activeSession.spellbookAtStart[spellID] then
            LogEvent("SPELL_THIS_TICK_NEW", {
                spellID = spellID,
                name    = name,
            })
        end
    end

    -- Also check if any spell that WAS in prevSpellbook is now gone.
    -- This is unusual but worth capturing (ability removed mid-combat).
    for spellID, name in pairs(prevSpellbook) do
        if not currentBook[spellID] then
            LogEvent("SPELL_DISAPPEARED", {
                spellID = spellID,
                name    = name,
            })
        end
    end
end

--------------------------------------------------------------------------------
-- Aura diff logging
-- Every tick, compares current auras against prev.
-- If profile has watchedAuras, we also specifically flag those.
--------------------------------------------------------------------------------
local function CheckAuras(currentAuras)
    if not activeSession then return end
    local diff = U().DiffAuras(prevAuras, currentAuras)

    -- Log all adds
    for _, aura in pairs(diff.added) do
        LogEvent("AURA_ADDED", {
            spellID  = aura.spellID,
            name     = aura.name,
            stacks   = aura.stacks,
            auraType = aura.auraType,
            watched  = Core.activeProfile and Core.IsWatchedAura(aura.spellID) or false,
        })
        -- If this is a proc-trigger aura, snapshot spells now to see what changed.
        if Core.activeProfile and Core.IsProcTrigger(aura.spellID) then
            local currentBook = U().SnapshotSpellbook()
            local currentUsability = Core.activeProfile
                and U().SnapshotSpellUsability(Core.activeProfile.watchedSpells)
                or {}
            LogEvent("PROC_TRIGGER_SNAPSHOT", {
                triggerAura     = aura.spellID,
                triggerName     = aura.name,
                spellbook       = currentBook,
                usability       = currentUsability,
                resources       = U().SnapshotResources(),
            })
        end
    end

    -- Log all removes
    for _, aura in pairs(diff.removed) do
        LogEvent("AURA_REMOVED", {
            spellID  = aura.spellID,
            name     = aura.name,
            auraType = aura.auraType,
            watched  = Core.activeProfile and Core.IsWatchedAura(aura.spellID) or false,
        })
    end

    -- Log stack changes for watched auras
    for _, change in pairs(diff.changed) do
        if Core.activeProfile and Core.IsWatchedAura(change.spell.spellID) then
            LogEvent("AURA_STACKS_CHANGED", {
                spellID  = change.spell.spellID,
                name     = change.spell.name,
                fromStacks = change.from,
                toStacks   = change.to,
            })
        end
    end
end

--------------------------------------------------------------------------------
-- Spell usability diff
-- For watched spells, logs when usability or cooldown state changes.
-- This is the key signal for "spell became castable after proc/buff".
--------------------------------------------------------------------------------
local function CheckUsability(currentUsability)
    if not activeSession then return end
    for spellID, cur in pairs(currentUsability) do
        local prev = prevUsability[spellID]
        if prev then
            -- Usability transition
            if prev.usable ~= cur.usable then
                LogEvent("SPELL_USABILITY_CHANGED", {
                    spellID  = spellID,
                    name     = cur.name,
                    from     = prev.usable,
                    to       = cur.usable,
                    noMana   = cur.noMana,
                })
            end
            -- Known/visible transition (IsPlayerSpell changed)
            if prev.known ~= cur.known then
                LogEvent("SPELL_KNOWN_CHANGED", {
                    spellID = spellID,
                    name    = cur.name,
                    from    = prev.known,
                    to      = cur.known,
                })
            end
        else
            -- First time we've seen data for this spell
            LogEvent("SPELL_USABILITY_INITIAL", {
                spellID  = spellID,
                name     = cur.name,
                usable   = cur.usable,
                known    = cur.known,
                noMana   = cur.noMana,
            })
        end
    end
end

--------------------------------------------------------------------------------
-- Cast detection
-- Confirmed Midnight 12.0 (apicheck):
--   UnitCastingInfo  YES -- returns table { name, text, texture, startTime,
--                            endTime, isTradeSkill, castID, notInterruptible, spellID }
--   UnitChannelInfo  YES -- same shape
--   C_Spell.GetCurrentSpellCastingInfo  NO
-- We key on castID which is unique per cast event.
-- Cooldown-delta on watched spells provides fallback for instant casts
-- that complete faster than one poll interval.
--------------------------------------------------------------------------------
local lastCastID    = nil
local lastChannelID = nil
local lastCooldownState = {}

local function GetCastInfoTable(unit, fn)
    if not fn then return nil end
    local ok, result = pcall(fn, unit)
    if not ok or not result then return nil end
    -- Table-shape (Midnight 12.0)
    if type(result) == "table" then
        return {
            name    = U().Sanitize(result.name) or U().GetSpellName(result.spellID),
            spellID = U().Sanitize(result.spellID),
            castID  = U().Sanitize(result.castID),
        }
    end
    -- Legacy positional shape (name, _, _, startTime, endTime, _, castID, _, spellID)
    if type(result) == "string" then
        local ok2, a, _, _, _, _, _, g, _, i2 = pcall(fn, unit)
        if ok2 and type(a) == "string" then
            return {
                name    = U().Sanitize(a),
                spellID = U().Sanitize(i2),
                castID  = U().Sanitize(g),
            }
        end
    end
    return nil
end

local function CheckCasts()
    if not activeSession then return end

    -- Cast bar detection via UnitCastingInfo (confirmed YES)
    local cast = GetCastInfoTable("player", UnitCastingInfo)
    local castID = cast and cast.castID
    if castID and castID ~= lastCastID then
        lastCastID = castID
        LogEvent("CAST_STARTED", {
            name    = cast.name,
            spellID = cast.spellID,
            castID  = castID,
        })
    elseif not castID and lastCastID then
        LogEvent("CAST_FINISHED", { castID = lastCastID })
        lastCastID = nil
    end

    -- Channel detection via UnitChannelInfo (confirmed YES)
    local chan = GetCastInfoTable("player", UnitChannelInfo)
    local chanID = chan and chan.castID
    if chanID and chanID ~= lastChannelID then
        lastChannelID = chanID
        LogEvent("CHANNEL_STARTED", {
            name    = chan.name,
            spellID = chan.spellID,
            castID  = chanID,
        })
    elseif not chanID and lastChannelID then
        LogEvent("CHANNEL_FINISHED", { castID = lastChannelID })
        lastChannelID = nil
    end

    -- Cooldown-delta for instant casts on watched spells
    local profile = Core.activeProfile
    if not profile or not profile.watchedSpells then return end
    for _, id in ipairs(profile.watchedSpells) do
        local cdStart, cdDuration
        if C_Spell and C_Spell.GetSpellCooldown then
            local ok, info = pcall(C_Spell.GetSpellCooldown, id)
            if ok and type(info) == "table" then
                cdStart    = U().Sanitize(info.startTime)
                cdDuration = U().Sanitize(info.duration)
            end
        end
        local prev      = lastCooldownState[id]
        local prevStart = prev and prev.cdStart or 0
        if cdStart and cdStart > 0 and (not prevStart or prevStart == 0) then
            LogEvent("SPELL_CAST_DETECTED", {
                spellID    = id,
                name       = U().GetSpellName(id),
                cdDuration = cdDuration,
            })
        end
        lastCooldownState[id] = { cdStart = cdStart, cdDuration = cdDuration }
    end
end

--------------------------------------------------------------------------------
-- Combat state change handling
--------------------------------------------------------------------------------
local function OnCombatEntered()
    LogEvent("COMBAT_ENTERED", {
        spellbook  = U().SnapshotSpellbook(),
        auras      = U().SnapshotAuras("player"),
        usability  = Core.activeProfile
                        and U().SnapshotSpellUsability(Core.activeProfile.watchedSpells)
                        or {},
        resources  = U().SnapshotResources(),
        talents    = U().SnapshotTalents(),
    })
    if activeSession then
        activeSession.combatStart = U().Now()
    end
end

local function OnCombatLeft()
    LogEvent("COMBAT_LEFT", {
        spellbook  = U().SnapshotSpellbook(),
        auras      = U().SnapshotAuras("player"),
        usability  = Core.activeProfile
                        and U().SnapshotSpellUsability(Core.activeProfile.watchedSpells)
                        or {},
        resources  = U().SnapshotResources(),
    })
    if activeSession then
        activeSession.combatEnd = U().Now()
    end
end

--------------------------------------------------------------------------------
-- Periodic resource snapshot (every ~5s during combat)
-- Lightweight breadcrumb trail of Fury/HP over the fight.
--------------------------------------------------------------------------------
local lastResourceSnap = 0
local RESOURCE_INTERVAL = 5.0

local function CheckResources(now)
    if not activeSession then return end
    if now - lastResourceSnap < RESOURCE_INTERVAL then return end
    lastResourceSnap = now
    LogEvent("RESOURCE_SNAPSHOT", U().SnapshotResources())
end

--------------------------------------------------------------------------------
-- Main poll tick
-- Called every POLL_INTERVAL seconds from the OnUpdate handler.
-- Order: combat state -> spellbook -> auras -> usability -> casts -> resources
--------------------------------------------------------------------------------
local function OnPollTick(now)
    local inCombat = (UnitAffectingCombat and UnitAffectingCombat("player")) or false

    -- Combat state transitions
    if inCombat and not wasInCombat then
        wasInCombat = true
        if not isRecording then
            -- Auto-start a session when combat begins
            Core.StartSession(false)
        end
        OnCombatEntered()
    elseif not inCombat and wasInCombat then
        wasInCombat = false
        OnCombatLeft()
        -- Auto-stop the session when combat ends (only if it was auto-started)
        if isRecording and activeSession and not activeSession.manualStart then
            Core.StopSession()
        end
    end

    if not isRecording then return end

    -- Spellbook diff
    local currentBook = U().SnapshotSpellbook()
    CheckForNewSpells(currentBook)
    prevSpellbook = currentBook

    -- Aura diff
    local currentAuras = U().SnapshotAuras("player")
    CheckAuras(currentAuras)
    prevAuras = currentAuras

    -- Spell usability diff (watched spells only)
    local currentUsability = Core.activeProfile
        and U().SnapshotSpellUsability(Core.activeProfile.watchedSpells)
        or {}
    CheckUsability(currentUsability)
    prevUsability = currentUsability

    -- Cast detection
    CheckCasts()

    -- Periodic resource snapshots
    CheckResources(now)
end

--------------------------------------------------------------------------------
-- Public: start a recording session
-- manualOverride = true when triggered by /mtdt start
--------------------------------------------------------------------------------
function Core.StartSession(manualOverride)
    if isRecording then
        U().Print("Session already in progress. Use /mtdt stop to end it first.")
        return
    end

    EnsureDB()
    activeSession              = NewSession()
    activeSession.manualStart  = manualOverride or false
    isRecording                = true

    -- Seed previous-state caches from current state
    prevSpellbook  = U().ShallowCopy(activeSession.spellbookAtStart)
    prevAuras      = U().ShallowCopy(activeSession.aurasAtStart)
    prevUsability  = U().ShallowCopy(activeSession.usabilityAtStart)
    lastCastGUID   = nil
    lastChannelGUID = nil
    lastResourceSnap = U().Now()

    local trigger = manualOverride and "manual" or "auto (combat)"
    U().Print(string.format("Recording started [%s] -- session #%d | Profile: %s",
        trigger,
        activeSession.sessionIndex,
        activeSession.profile))
end

--------------------------------------------------------------------------------
-- Public: stop the current session and commit to DB
--------------------------------------------------------------------------------
function Core.StopSession()
    if not isRecording then
        U().Print("No session in progress.")
        return
    end

    local now        = U().Now()
    local wallNow    = U().WallClock()
    local duration   = now - activeSession.startTime
    activeSession.endTime    = now
    activeSession.endWall    = wallNow
    activeSession.durationSec = duration

    -- Final snapshots
    LogEvent("SESSION_END_SNAPSHOT", {
        spellbook  = U().SnapshotSpellbook(),
        auras      = U().SnapshotAuras("player"),
        usability  = Core.activeProfile
                        and U().SnapshotSpellUsability(Core.activeProfile.watchedSpells)
                        or {},
        resources  = U().SnapshotResources(),
    })

    -- Build summary
    local eventCounts = {}
    for _, e in ipairs(activeSession.events) do
        eventCounts[e.event] = (eventCounts[e.event] or 0) + 1
    end

    local newSpellCount = U().TableLen(activeSession.newSpellsDiscovered)

    activeSession.summary = {
        durationFmt     = U().FormatDuration(duration),
        eventCount      = #activeSession.events,
        eventCounts     = eventCounts,
        newSpellCount   = newSpellCount,
        newSpells       = activeSession.newSpellsDiscovered,
        combatDuration  = (activeSession.combatStart and activeSession.combatEnd)
                            and (activeSession.combatEnd - activeSession.combatStart)
                            or nil,
    }

    isRecording   = false

    -- Discard very short sessions (trash noise)
    if duration < Core.MIN_SESSION_SECONDS then
        U().Print(string.format("Session discarded (%.1fs < %ds minimum).", duration, Core.MIN_SESSION_SECONDS))
        activeSession = nil
        return
    end

    -- Commit to DB
    local db = GetDB()
    table.insert(db.sessions, activeSession)
    db.meta.totalSessions = (db.meta.totalSessions or 0) + 1

    -- Prune oldest if over cap
    while #db.sessions > Core.MAX_SESSIONS do
        table.remove(db.sessions, 1)
    end

    local idx = activeSession.sessionIndex
    U().Print(string.format("Session #%d saved | %s | %d events | %d new spells discovered",
        idx,
        activeSession.summary.durationFmt,
        activeSession.summary.eventCount,
        newSpellCount))

    activeSession = nil
end

--------------------------------------------------------------------------------
-- Profile helpers
--------------------------------------------------------------------------------
function Core.IsWatchedAura(spellID)
    if not Core.activeProfile or not Core.activeProfile.watchedAuras then return false end
    for _, id in ipairs(Core.activeProfile.watchedAuras) do
        if id == spellID then return true end
    end
    return false
end

function Core.IsProcTrigger(spellID)
    if not Core.activeProfile or not Core.activeProfile.procTriggerAuras then return false end
    for _, id in ipairs(Core.activeProfile.procTriggerAuras) do
        if id == spellID then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Export functions
-- All exports flatten to CSV-ish text and store in DB for later retrieval.
-- Format: sessionIndex, time, event, key, value
-- One row per event field to keep it simple and grep-able.
--------------------------------------------------------------------------------
local function SessionToCSV(session)
    local lines = {}
    local idx = session.sessionIndex or 0

    -- Header rows for the session itself
    local function H(k, v)
        table.insert(lines, string.format("%d,META,%s,%s",
            idx, U().CSVEscape(k), U().CSVEscape(v)))
    end

    H("startWall",     U().FormatTimestamp(session.startWall or 0))
    H("duration",      session.summary and session.summary.durationFmt or "?")
    H("player",        (session.player and session.player.playerName) or "?")
    H("class",         (session.player and session.player.className)  or "?")
    H("spec",          (session.player and session.player.specName)   or "?")
    H("zone",          (session.zone and session.zone.name)           or "?")
    H("profile",       session.profile or "generic")
    H("eventCount",    tostring(session.summary and session.summary.eventCount or 0))
    H("newSpells",     tostring(session.summary and session.summary.newSpellCount or 0))

    -- Talent summary
    for i, t in ipairs(session.talentsAtStart or {}) do
        table.insert(lines, string.format("%d,TALENT,%d,%s,%s",
            idx,
            t.spellID or 0,
            U().CSVEscape(t.name or "unknown"),
            tostring(t.rank or 1)))
    end

    -- New spells discovered
    for spellID, info in pairs(session.newSpellsDiscovered or {}) do
        table.insert(lines, string.format("%d,NEW_SPELL,%d,%s,%.2f",
            idx,
            spellID,
            U().CSVEscape(info.name or "unknown"),
            info.discoveredAt or 0))
    end

    -- Event log
    for _, e in ipairs(session.events or {}) do
        local dataStr = ""
        if type(e.data) == "table" then
            -- Flatten first-level data keys, skip large nested tables (spellbook snapshots).
            -- Midnight 12.0 may return secret userdatas for resource values even after
            -- SnapshotResources sanitization (e.g. values stored in events before the fix).
            -- pcall the entire key=value concat so a secret on either side of .. cannot
            -- produce a nil hole in parts[] that would crash table.concat.
            local parts = {}
            for k, v in pairs(e.data) do
                if type(v) ~= "table" then
                    local ok, entry = pcall(function()
                        return tostring(k) .. "=" .. U().Str(v)
                    end)
                    if ok and entry then
                        table.insert(parts, entry)
                    else
                        table.insert(parts, tostring(k) .. "=<secret>")
                    end
                end
            end
            dataStr = table.concat(parts, "|")
        end
        table.insert(lines, string.format("%d,EVENT,%.2f,%s,%s",
            idx,
            e.t or 0,
            U().CSVEscape(e.event),
            U().CSVEscape(dataStr)))
    end

    return table.concat(lines, "\n")
end

local function RunExport(sessions)
    if not sessions or #sessions == 0 then
        U().Print("No sessions to export.")
        return
    end

    local allParts = {}
    table.insert(allParts, "sessionIndex,type,key_or_time,field,value")
    for _, s in ipairs(sessions) do
        table.insert(allParts, SessionToCSV(s))
    end

    local csv = table.concat(allParts, "\n")
    local db  = GetDB()
    db.meta.lastExportCSV     = csv
    db.meta.lastExportSession = #sessions
    db.meta.lastExportTime    = U().WallClock()

    U().Print(string.format("Exported %d session(s) -- %d chars. Use Ctrl+A / Ctrl+C in the popup to copy.",
        #sessions, #csv))

    -- Open the copy popup if UI is loaded
    local ui = MidnightTimDebug and MidnightTimDebug.UI
    if ui and ui.ShowExport then
        ui.ShowExport(csv)
    else
        -- UI not loaded -- remind where to find it
        U().Print("SavedVariables: MidnightTimDebugDB.meta.lastExportCSV")
    end
end

--------------------------------------------------------------------------------
-- Slash command handler
-- /mtdt <command> [args]
--------------------------------------------------------------------------------
local function HandleSlash(msg)
    msg = msg and msg:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
    local cmd, args = msg:match("^(%S+)%s*(.*)")
    cmd = cmd or msg

    ----------------------------------------------------------------------------
    if cmd == "start" then
        Core.StartSession(true)

    ----------------------------------------------------------------------------
    elseif cmd == "stop" then
        Core.StopSession()

    ----------------------------------------------------------------------------
    elseif cmd == "status" then
        if isRecording and activeSession then
            local elapsed = U().Now() - activeSession.startTime
            local events  = #activeSession.events
            local inCombat = (UnitAffectingCombat and UnitAffectingCombat("player")) or false
            U().Print(string.format("RECORDING | Session #%d | %s elapsed | %d events | In combat: %s | Profile: %s",
                activeSession.sessionIndex,
                U().FormatDuration(elapsed),
                events,
                tostring(inCombat),
                activeSession.profile))
        else
            local db = GetDB()
            local n  = #(db.sessions or {})
            U().Print(string.format("IDLE | %d sessions saved | Poll interval: %.2fs | Profile: %s",
                n, Core.POLL_INTERVAL,
                Core.activeProfile and Core.activeProfile.name or "generic"))
        end

    ----------------------------------------------------------------------------
    elseif cmd == "reset" then
        if isRecording then
            isRecording   = false
            activeSession = nil
            U().Print("Active session discarded.")
        end
        local db = GetDB()
        db.sessions           = {}
        db.meta.totalSessions = 0
        db.meta.lastExportCSV = nil
        U().Print("All sessions cleared from SavedVariables.")

    ----------------------------------------------------------------------------
    elseif cmd == "export" then
        local sub = args and args:lower() or ""
        local db  = GetDB()
        if sub == "recent" or sub == "" then
            local all = db.sessions or {}
            if #all > 0 then
                RunExport({ all[#all] })
            else
                U().Print("No sessions saved.")
            end
        elseif sub == "last10" then
            local all = db.sessions or {}
            local slice = {}
            local start = math.max(1, #all - 9)
            for i = start, #all do table.insert(slice, all[i]) end
            RunExport(slice)
        elseif sub == "all" then
            RunExport(db.sessions or {})
        else
            U().Print("Usage: /mtdt export | /mtdt export recent | /mtdt export last10 | /mtdt export all")
        end

    ----------------------------------------------------------------------------
    elseif cmd == "sessions" then
        local db = GetDB()
        local sessions = db.sessions or {}
        if #sessions == 0 then
            U().Print("No sessions saved.")
            return
        end
        U().Print(string.format("-- %d session(s) saved --", #sessions))
        local start = math.max(1, #sessions - 9)
        for i = start, #sessions do
            local s = sessions[i]
            local dur  = s.summary and s.summary.durationFmt or "?"
            local evts = s.summary and s.summary.eventCount or 0
            local ns   = s.summary and s.summary.newSpellCount or 0
            local wall = s.startWall and U().FormatTimestamp(s.startWall) or "?"
            U().Print(string.format("  #%d | %s | %s | %d events | %d new spells | %s",
                s.sessionIndex or i, wall, dur, evts, ns,
                s.profile or "generic"))
        end

    ----------------------------------------------------------------------------
    elseif cmd == "spellinfo" then
        -- Utility: print everything knowable about a spell ID right now.
        -- Usage: /mtdt spellinfo 1221167
        local id = tonumber(args)
        if not id then
            U().Print("Usage: /mtdt spellinfo <spellID>")
            return
        end
        local name, rank, icon, cost, isFunnel, powerType, castTime, minRange, maxRange =
            U().Safe(GetSpellInfo, id)
        local usable, noMana = U().Safe(IsSpellUsable, id)
        local known          = U().Safe(IsPlayerSpell, id)
        local cdStart, cdDur = U().Safe2(GetSpellCooldown, id)

        U().Print(string.format("SpellInfo: %d", id))
        U().Print(string.format("  Name:      %s", tostring(name)))
        U().Print(string.format("  Known:     %s", tostring(known)))
        U().Print(string.format("  Usable:    %s  (noMana: %s)", tostring(usable), tostring(noMana)))
        U().Print(string.format("  CastTime:  %s ms", tostring(castTime)))
        U().Print(string.format("  CD:        start=%s dur=%s", tostring(cdStart), tostring(cdDur)))
        U().Print(string.format("  Icon:      %s", tostring(icon)))

        -- Check aura on player
        if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
            local aura = U().Safe(C_UnitAuras.GetPlayerAuraBySpellID, id)
            if aura then
                U().Print(string.format("  PlayerAura: stacks=%d dur=%.1f",
                    aura.applications or 0, aura.duration or 0))
            else
                U().Print("  PlayerAura: none")
            end
        end

    ----------------------------------------------------------------------------
    elseif cmd == "snapshot" then
        -- Print a live snapshot of all watched spells for the active profile.
        local profile = Core.activeProfile
        if not profile then
            U().Print("No active profile.")
            return
        end
        U().Print(string.format("-- Snapshot: %s --", profile.name))
        local usability = U().SnapshotSpellUsability(profile.watchedSpells)
        for _, id in ipairs(profile.watchedSpells) do
            local s = usability[id]
            if s then
                U().Print(string.format("  %d %-30s known=%-5s usable=%-5s",
                    id,
                    (s.name or "?"):sub(1, 30),
                    tostring(s.known),
                    tostring(s.usable)))
            end
        end

    ----------------------------------------------------------------------------
    elseif cmd == "auras" then
        -- Print current player auras
        local auras = U().SnapshotAuras("player")
        local count = 0
        U().Print("-- Current Player Auras --")
        for _, a in pairs(auras) do
            count = count + 1
            U().Print(string.format("  %d %-30s stacks=%-3d type=%s",
                a.spellID or 0,
                (a.name or "?"):sub(1, 30),
                a.stacks or 0,
                a.auraType or "?"))
        end
        if count == 0 then U().Print("  (none)") end

    ----------------------------------------------------------------------------
    elseif cmd == "talents" then
        local talents = U().SnapshotTalents()
        if #talents == 0 then
            U().Print("No talents found -- talent tree may not be loaded yet.")
        else
            local lines = { "spellID,name,rank,nodeID" }
            for _, t in ipairs(talents) do
                table.insert(lines, string.format("%d,%s,%d,%s",
                    t.spellID or 0,
                    U().Str(t.name or "unknown"),
                    t.rank or 1,
                    U().Str(t.nodeID)))
            end
            local text = table.concat(lines, "\n")
            local ui2 = MidnightTimDebug and MidnightTimDebug.UI
            if ui2 and ui2.ShowExport then
                ui2.ShowExport(text)
            else
                U().Print(string.format("Talents (%d) -- open UI to copy", #talents))
            end
        end

    ----------------------------------------------------------------------------
    elseif cmd == "profile" then
        local p = args and args:upper() or ""
        if p == "DEVOURER" or p == "DEVOURER_DH" then
            Core.activeProfile = Core.WATCH_PROFILES.DEVOURER_DH
            U().Print("Active profile set to: Devourer DH")
        elseif p == "NONE" or p == "GENERIC" then
            Core.activeProfile = nil
            U().Print("Active profile cleared (generic recording).")
        elseif p == "CLEAR" then
            -- Remove all generated profiles from memory and SavedVariables
            local db = GetDB()
            db.generatedProfiles = {}
            for key in pairs(Core.WATCH_PROFILES) do
                if key:find("^GENERATED_") then
                    Core.WATCH_PROFILES[key] = nil
                end
            end
            Core.activeProfile = nil
            U().Print("All generated profiles cleared. Using generic recording.")
        elseif p == "AUTO" or p == "" then
            local detected = DetectProfile()
            if detected then
                U().Print("Auto-detected profile: " .. detected.name)
            else
                U().Print("No profile matched your class/spec -- using generic recording.")
            end
        else
            U().Print("Usage: /mtdt profile auto | devourer | none")
            if Core.activeProfile then
                U().Print("Current: " .. Core.activeProfile.name)
            else
                U().Print("Current: generic (all spells/auras captured, no watch list)")
            end
        end

    ----------------------------------------------------------------------------
    elseif cmd == "interval" then
        local v = tonumber(args)
        if v and v >= 0.05 and v <= 1.0 then
            Core.POLL_INTERVAL = v
            U().Print(string.format("Poll interval set to %.2fs.", v))
        else
            U().Print("Usage: /mtdt interval <0.05 - 1.0>")
            U().Print(string.format("Current: %.2fs", Core.POLL_INTERVAL))
        end

    ----------------------------------------------------------------------------
    elseif cmd == "ui" or cmd == "toggle" then
        local ui = MidnightTimDebug and MidnightTimDebug.UI
        if ui and ui.Toggle then
            ui.Toggle()
        else
            U().Print("UI module not loaded.")
        end

    elseif cmd == "show" then
        local ui = MidnightTimDebug and MidnightTimDebug.UI
        if ui and ui.Show then ui.Show() end

    elseif cmd == "hide" then
        local ui = MidnightTimDebug and MidnightTimDebug.UI
        if ui and ui.Hide then ui.Hide() end

    ----------------------------------------------------------------------------
    elseif cmd == "dumpspells" or cmd == "buildprofile" then
        -- "buildprofile" is the primary user-facing command (spell dump + talents + profile build).
        -- "dumpspells" remains as an alias for backwards compatibility.
        local out = {}
        local i   = 1
        local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
        while true do
            local ok, info = pcall(C_SpellBook.GetSpellBookItemInfo, i, bank)
            if not ok or not info then break end
            local name    = U().Sanitize(info.name)
            local spellID = U().Sanitize(info.actionID or info.spellID)
            if name and spellID then
                table.insert(out, {
                    index     = i,
                    name      = name,
                    subName   = U().Sanitize(info.subName) or "",
                    spellType = tostring(info.itemType or ""),
                    spellID   = spellID,
                })
            end
            i = i + 1
            if i > 1024 then break end
        end
        table.sort(out, function(a, b)
            if a.name == b.name then return a.spellID < b.spellID end
            return a.name < b.name
        end)

        -- Capture class/spec
        local cs        = U().SnapshotClassSpec()
        local classID   = cs.classID
        local specIdx   = cs.specIdx
        local className = cs.className or "Unknown"
        local specName  = cs.specName  or "Unknown"

        -- Capture talents at the same time
        local talents = U().SnapshotTalents()

        -- Store everything
        local db = GetDB()
        db.spellDump      = out
        db.spellDumpTime  = U().WallClock()
        db.talentDump     = talents
        db.spellDumpClass = {
            classID   = classID,  specIdx   = specIdx,
            className = className, specName  = specName,
        }

        U().Print(string.format(
            "Build Profile: %d spells + %d talents captured for %s %s.",
            #out, #talents, specName, className))

        -- Build profile and activate
        local profile = BuildProfileFromDump(out, classID, specIdx, className, specName)

        if profile then
            -- Open UI then show reload prompt
            local ui2 = MidnightTimDebug and MidnightTimDebug.UI
            if ui2 then
                if ui2.Show then ui2.Show() end
                C_Timer.After(0.1, function()
                    if ui2.ShowReloadPrompt then ui2.ShowReloadPrompt() end
                end)
            end
        else
            U().Print("Profile build failed -- check class/spec detection.")
        end

    ----------------------------------------------------------------------------
    elseif cmd == "spelllist" then
        -- Show raw spell dump in the copy-paste export box for independent troubleshooting.
        local db = GetDB()
        local dump = db.spellDump
        if not dump or #dump == 0 then
            U().Print("No spell dump found. Run /mtdt buildprofile first.")
        else
            local lines = { "spellID,name,subName,spellType" }
            for _, e in ipairs(dump) do
                table.insert(lines, string.format("%d,%s,%s,%s",
                    e.spellID or 0,
                    U().Str(e.name),
                    U().Str(e.subName),
                    U().Str(e.spellType)))
            end
            local text = table.concat(lines, "\n")
            local ui2 = MidnightTimDebug and MidnightTimDebug.UI
            if ui2 and ui2.ShowExport then
                ui2.ShowExport(text)
            else
                U().Print("Spell list: " .. #dump .. " spells (open UI to copy)")
            end
        end

    ----------------------------------------------------------------------------
    elseif cmd == "talentlist" then
        -- Show raw talent dump in the copy-paste export box for independent troubleshooting.
        local db = GetDB()
        local dump = db.talentDump or U().SnapshotTalents()
        if not dump or #dump == 0 then
            U().Print("No talent data found. Run /mtdt buildprofile first.")
        else
            local lines = { "spellID,name,rank,nodeID" }
            for _, t in ipairs(dump) do
                table.insert(lines, string.format("%d,%s,%d,%s",
                    t.spellID or 0,
                    U().Str(t.name),
                    t.rank or 1,
                    U().Str(t.nodeID)))
            end
            local text = table.concat(lines, "\n")
            local ui2 = MidnightTimDebug and MidnightTimDebug.UI
            if ui2 and ui2.ShowExport then
                ui2.ShowExport(text)
            else
                U().Print("Talent list: " .. #dump .. " talents (open UI to copy)")
            end
        end

    ----------------------------------------------------------------------------
    elseif cmd == "debug" and args == "profile" then
        -- Show exactly what classID/specIdx are being read and what profiles exist
        local classID = U().Safe(function()
            local _, _, id = UnitClass("player") ; return id
        end)
        local specIdx = U().Safe(GetSpecialization)
        local cs      = U().SnapshotClassSpec()
        U().Print(string.format("classID=%s  specIdx=%s  className=%s  specName=%s",
            tostring(classID), tostring(specIdx),
            tostring(cs.className), tostring(cs.specName)))
        U().Print("WATCH_PROFILES keys:")
        for k, p in pairs(Core.WATCH_PROFILES) do
            U().Print(string.format("  %s  classID=%s  specIdx=%s",
                k, tostring(p.classID), tostring(p.specIdx)))
        end
        local db = GetDB()
        U().Print("generatedProfiles keys:")
        for k, p in pairs(db.generatedProfiles or {}) do
            U().Print(string.format("  %s  classID=%s  specIdx=%s",
                k, tostring(p.classID), tostring(p.specIdx)))
        end
        U().Print("activeProfile: " .. (Core.activeProfile and Core.activeProfile.name or "nil"))

    ----------------------------------------------------------------------------
    elseif cmd == "apicheck" then
        -- Probe which APIs are available. Output goes to the copy popup AND chat.
        local lines = {}
        local function out(s)
            -- Strip color codes for the plain-text copy buffer
            local plain = (s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            table.insert(lines, plain)
            U().Print(s)
        end
        local function chk(label, val)
            local yn = (val ~= nil) and "YES" or "NO "
            local clr = (val ~= nil) and "|cff22dd22YES|r" or "|cffdd4444NO |r"
            U().Print(string.format("  %s  %s", clr, label))
            table.insert(lines, string.format("  %s  %s", yn, label))
        end
        -- Probe all keys present on a namespace table, print them
        local function probeKeys(label, tbl)
            if type(tbl) ~= "table" then
                out(string.format("  [%s] -- nil or not a table", label))
                return
            end
            local keys = {}
            for k in pairs(tbl) do table.insert(keys, tostring(k)) end
            table.sort(keys)
            out(string.format("  [%s] keys: %s", label, table.concat(keys, ", ")))
        end

        out("=== MTDT API CHECK ===")
        out("  SPELLBOOK:")
        chk("C_SpellBook",                                  C_SpellBook)
        if C_SpellBook then probeKeys("C_SpellBook", C_SpellBook) end
        chk("Enum.SpellBookSpellBank",                      Enum and Enum.SpellBookSpellBank)
        chk("GetNumSpellTabs (legacy)",                     GetNumSpellTabs)
        chk("GetSpellBookItemInfo (legacy)",                GetSpellBookItemInfo)

        out("  SPELL INFO:")
        chk("C_Spell",                                      C_Spell)
        if C_Spell then probeKeys("C_Spell", C_Spell) end
        chk("IsPlayerSpell",                                IsPlayerSpell)
        chk("IsSpellUsable (legacy)",                       IsSpellUsable)
        chk("GetSpellInfo (legacy)",                        GetSpellInfo)
        chk("GetSpellCooldown (legacy)",                    GetSpellCooldown)

        out("  AURAS:")
        chk("C_UnitAuras",                                  C_UnitAuras)
        if C_UnitAuras then probeKeys("C_UnitAuras", C_UnitAuras) end
        chk("AuraUtil.ForEachAura",                         AuraUtil and AuraUtil.ForEachAura)
        chk("UnitBuff (legacy)",                            UnitBuff)

        out("  CAST:")
        chk("C_Spell.GetCurrentSpellCastingInfo (NO in 12.0)", C_Spell and C_Spell.GetCurrentSpellCastingInfo)
        chk("UnitCastingInfo",                              UnitCastingInfo)
        chk("UnitChannelInfo",                              UnitChannelInfo)

        out("  TALENTS:")
        chk("C_ClassTalents",                               C_ClassTalents)
        if C_ClassTalents then probeKeys("C_ClassTalents", C_ClassTalents) end
        chk("C_Traits",                                     C_Traits)
        if C_Traits then probeKeys("C_Traits", C_Traits) end

        out("  UNIT:")
        chk("UnitAffectingCombat",                          UnitAffectingCombat)
        chk("UnitPower",                                    UnitPower)
        chk("UnitHealth",                                   UnitHealth)

        out("  LIVE PROBES:")
        -- Spellbook line count
        if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
            local ok, n = pcall(C_SpellBook.GetNumSpellBookSkillLines)
            out(string.format("  C_SpellBook.GetNumSpellBookSkillLines() = %s", ok and tostring(n) or "ERROR"))
        end
        -- Cooldown on Throw Glaive (185123) - confirmed working
        if C_Spell and C_Spell.GetSpellCooldown then
            local ok, info = pcall(C_Spell.GetSpellCooldown, 185123)
            if ok and type(info) == "table" then
                out(string.format("  C_Spell.GetSpellCooldown(185123/ThrowGlaive) = {startTime=%s, duration=%s, isEnabled=%s}",
                    tostring(info.startTime), tostring(info.duration), tostring(info.isEnabled)))
            else
                out(string.format("  C_Spell.GetSpellCooldown(185123) = ok=%s type=%s", tostring(ok), type(info)))
            end
        end
        -- Spell name on Throw Glaive
        local n = U().GetSpellName(185123)
        out(string.format("  GetSpellName(185123) = %s", tostring(n)))
        -- Aura index probe
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local ok, d = pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, "HELPFUL")
            out(string.format("  C_UnitAuras.GetAuraDataByIndex(player,1,HELPFUL) = ok=%s type=%s", tostring(ok), type(d)))
            if ok and type(d) == "table" then
                out(string.format("    .name=%s .spellId=%s", tostring(d.name), tostring(d.spellId)))
            end
        end

        out("=== END API CHECK ===")

        -- Push to copy popup
        local csvText = table.concat(lines, "\n")
        local db = GetDB()
        db.meta.lastApiCheck = csvText
        local ui = MidnightTimDebug and MidnightTimDebug.UI
        if ui and ui.ShowExport then
            ui.ShowExport(csvText)
        else
            U().Print("(UI not loaded -- results saved to MidnightTimDebugDB.meta.lastApiCheck)")
        end

    ----------------------------------------------------------------------------
    elseif cmd == "help" then
        U().Print("--- " .. Core.DISPLAY .. " v" .. Core.VERSION .. " ---")
        U().Print("/mtdt                  -- open/close debug panel")
        U().Print("/mtdt start            -- start recording (manual)")
        U().Print("/mtdt stop             -- stop recording")
        U().Print("/mtdt status           -- show recorder state")
        U().Print("/mtdt reset            -- discard session + clear all data")
        U().Print("/mtdt sessions         -- list last 10 saved sessions")
        U().Print("/mtdt export recent    -- export most recent session to CSV")
        U().Print("/mtdt export last10    -- export last 10 sessions")
        U().Print("/mtdt export all       -- export all sessions")
        U().Print("/mtdt snapshot         -- live spell usability")
        U().Print("/mtdt auras            -- print current player auras")
        U().Print("/mtdt talents          -- print active talents")
        U().Print("/mtdt spellinfo <id>   -- full debug info for one spell ID")
        U().Print("/mtdt profile auto     -- re-detect profile from class/spec")
        U().Print("/mtdt profile devourer -- force Devourer DH profile")
        U().Print("/mtdt profile none     -- generic mode (no watch list)")
        U().Print("/mtdt interval <sec>   -- set poll interval (0.05-1.0)")
        U().Print("/mtdt apicheck         -- probe which APIs are available")
        U().Print("/mtdt buildprofile     -- dump spells + talents, build profile, prompt reload")
        U().Print("/mtdt dumpspells       -- alias for buildprofile")

    ----------------------------------------------------------------------------
    elseif cmd == "" then
        -- Bare /mtdt opens the UI
        local ui = MidnightTimDebug and MidnightTimDebug.UI
        if ui and ui.Toggle then ui.Toggle() end

    else
        U().Print("Unknown command: " .. tostring(cmd) .. ". Try /mtdt help")
    end
end

--------------------------------------------------------------------------------
-- Ticker frame + OnUpdate
-- This is the ONLY frame in the addon. No RegisterEvent calls.
-- We use an OnUpdate ticker to drive everything.
--------------------------------------------------------------------------------
local function InitTicker()
    ticker = CreateFrame("Frame", "MidnightTimDebugTicker", UIParent)
    ticker:SetScript("OnUpdate", function(self, elapsed)
        tickAccum = tickAccum + elapsed
        if tickAccum < Core.POLL_INTERVAL then return end
        tickAccum = 0

        -- Wrap the entire tick in pcall so a Lua error in polling
        -- never prevents future ticks from firing.
        local ok, err = pcall(OnPollTick, U().Now())
        if not ok then
            -- Only print once per error string to avoid chat spam
            if err ~= ticker._lastErr then
                ticker._lastErr = err
                U().PrintWarn("Poll error: " .. tostring(err))
            end
        else
            ticker._lastErr = nil
        end
    end)
end

--------------------------------------------------------------------------------
-- Addon load
-- We use a minimal "wait for PLAYER_LOGIN" approach.
-- PLAYER_LOGIN is reliable and fires after SavedVariables are loaded.
-- We register it via the ticker's script instead of SetScript("OnEvent") to
-- keep event registration to the absolute minimum.
--
-- NOTE: We DO register PLAYER_LOGIN on the ticker frame once because
-- SavedVariables are not populated at file-load time -- they become available
-- after PLAYER_LOGIN. If this event is problematic in Midnight 12.0, the
-- workaround is to call EnsureDB() lazily on first command or first tick.
-- We check for both paths defensively.
--------------------------------------------------------------------------------
local initDone = false

--------------------------------------------------------------------------------
-- Generated profile persistence
-- Profiles built from spell dumps are stored in SavedVariables so they survive
-- reloads. On login they are re-injected into Core.WATCH_PROFILES before
-- DetectProfile() runs, so auto-detect picks them up immediately.
--------------------------------------------------------------------------------
BuildProfileFromDump = function(spellList, classID, specIdx, className, specName)
    if not spellList or #spellList == 0 then
        U().Print("No spells in dump -- run /mtdt dumpspells first.")
        return nil
    end

    local profileKey  = string.format("GENERATED_%d_%d", classID or 0, specIdx or 0)
    local profileName = string.format("%s %s (generated)", specName or "?", className or "?")

    -- watchedSpells: all castable spells from the dump (exclude passives)
    local watchedSpells  = {}
    local watchedAuras   = {}
    local seenIDs        = {}

    for _, entry in ipairs(spellList) do
        local id = entry.spellID
        if id and id > 0 and not seenIDs[id] then
            seenIDs[id] = true
            -- itemType "SPELL" or nil = castable; "PASSIVE" = skip for watched
            local t = tostring(entry.spellType or "")
            if not t:find("PASSIVE") and not t:find("passive") then
                table.insert(watchedSpells, id)
            end
            -- Seed watchedAuras with same IDs -- aura spellIDs often match castable IDs
            -- The session will tell us which ones actually produce auras
            table.insert(watchedAuras, id)
        end
    end

    local profile = {
        name             = profileName,
        classID          = classID,
        specIdx          = specIdx,
        watchedSpells    = watchedSpells,
        watchedAuras     = watchedAuras,
        procTriggerAuras = {},    -- populated manually after analysing session data
        generated        = true,  -- flag: built from dump, not hand-authored
        generatedAt      = U().WallClock(),
    }

    -- Inject into live WATCH_PROFILES table
    Core.WATCH_PROFILES[profileKey] = profile

    -- Persist to SavedVariables so it survives reloads
    local db = GetDB()
    db.generatedProfiles = db.generatedProfiles or {}
    db.generatedProfiles[profileKey] = {
        name             = profile.name,
        classID          = classID,
        specIdx          = specIdx,
        watchedSpells    = watchedSpells,
        watchedAuras     = watchedAuras,
        procTriggerAuras = {},
        generated        = true,
        generatedAt      = profile.generatedAt,
    }

    U().Print(string.format(
        "Profile '%s' built: %d watched spells. Activating now.",
        profileName, #watchedSpells))

    -- Activate immediately
    Core.activeProfile = profile
    return profile
end

-- Called from OnLogin after EnsureDB() -- re-injects any previously generated
-- profiles from SavedVariables back into Core.WATCH_PROFILES so DetectProfile()
-- can find them.
RestoreGeneratedProfiles = function()
    local db = GetDB()
    if not db.generatedProfiles then return end
    local count = 0
    for key, p in pairs(db.generatedProfiles) do
        -- Always overwrite -- ensures only one entry per key even if
        -- BuildProfileFromDump already injected a live version this session
        Core.WATCH_PROFILES[key] = p
        count = count + 1
    end
    if count > 0 then
        U().Print(string.format("[Profile] Restored %d generated profile(s).", count))
    end
end
-- Reads classID and specIdx from the WoW API and matches against all defined
-- watch profiles. Falls back to nil (generic) if no profile matches.
-- Generic mode still captures everything: spellbook changes, auras, casts,
-- usability, resources, talents -- just without a watched spell list.
-- Can be called again after a spec change via /mtdt profile auto.
--------------------------------------------------------------------------------
DetectProfile = function()
    local classID = U().Safe(function()
        local _, _, id = UnitClass("player") ; return id
    end)
    local specIdx = U().Safe(GetSpecialization)

    if not classID then
        Core.activeProfile = nil
        return nil
    end

    -- Exact match: classID + specIdx
    for _, profile in pairs(Core.WATCH_PROFILES) do
        if profile.classID == classID and profile.specIdx == specIdx then
            Core.activeProfile = profile
            return profile
        end
    end

    -- specIdx nil fallback: API not ready yet at login
    if specIdx == nil then
        for _, profile in pairs(Core.WATCH_PROFILES) do
            if profile.classID == classID then
                Core.activeProfile = profile
                return profile
            end
        end
    end

    -- No match -- generic mode
    Core.activeProfile = nil
    return nil
end

local function OnLogin()
    if initDone then return end
    initDone = true

    EnsureDB()

    -- Seed combat state so we don't fire a spurious COMBAT_ENTERED on first tick
    wasInCombat = (UnitAffectingCombat and UnitAffectingCombat("player")) or false

    -- Re-inject any previously generated profiles from SavedVariables
    RestoreGeneratedProfiles()

    -- Auto-select profile based on current class/spec
    DetectProfile()

    -- GetSpecialization() sometimes returns nil at PLAYER_LOGIN.
    -- Re-run detection after 3s to catch the common case where spec loads late.
    C_Timer.After(3, function()
        if not Core.activeProfile then
            local p = DetectProfile()
            if p then
                U().Print("Profile detected (late load): " .. p.name)
            end
        end
    end)

    local profileName = Core.activeProfile and Core.activeProfile.name or "generic"
    U().Print(string.format("v%s loaded. Profile: %s | Type /mtdt help for commands.",
        Core.VERSION, profileName))
end

-- Initialization entry point
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        OnLogin()
        InitTicker()
    end
end)

-- Also guard against SavedVariables being available immediately
-- (some addon environments initialize them before PLAYER_LOGIN)
if MidnightTimDebugDB then
    EnsureDB()
end

-- Register slash commands
SLASH_MIDNIGHTTIMDEBUGGINGTOOLS1 = "/mtdt"
SlashCmdList["MIDNIGHTTIMDEBUGGINGTOOLS"] = HandleSlash

--------------------------------------------------------------------------------
-- Read-only accessors for UI.lua
-- UI.lua loads after Core.lua and needs the local upvalues isRecording and
-- activeSession without coupling to Core internals.
--------------------------------------------------------------------------------
function Core._IsRecording()
    return isRecording
end

function Core._GetActiveSession()
    return activeSession
end
