--------------------------------------------------------------------------------
-- MidnightTimDebuggingTools: Utils.lua
-- Shared helpers. Loaded first. No WoW API calls at file scope.
-- Safe to load before ADDON_LOADED fires.
--------------------------------------------------------------------------------

MidnightTimDebug       = MidnightTimDebug       or {}
MidnightTimDebug.Utils = MidnightTimDebug.Utils or {}

local U = MidnightTimDebug.Utils

--------------------------------------------------------------------------------
-- Safe call wrapper
-- Wraps any WoW API call so a nil return or error never crashes the recorder.
-- Usage: local val = U.Safe(SomeAPI, arg1, arg2)
--------------------------------------------------------------------------------
function U.Safe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

-- Two-return variant for APIs like GetSpecialization() where you want both.
function U.Safe2(fn, ...)
    if type(fn) ~= "function" then return nil, nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil, nil
end

--------------------------------------------------------------------------------
-- Time helpers
--------------------------------------------------------------------------------
function U.Now()
    -- GetTime() is the reliable elapsed-seconds clock in WoW.
    -- time() gives wall clock but has 1-second resolution.
    -- We prefer GetTime() for relative timestamps inside a session,
    -- and time() only for wall-clock labels.
    return GetTime and GetTime() or 0
end

function U.WallClock()
    return time and time() or 0
end

function U.FormatDuration(seconds)
    seconds = seconds or 0
    local mins = math.floor(seconds / 60)
    local secs = math.floor(seconds % 60)
    if mins > 0 then
        return string.format("%dm%02ds", mins, secs)
    else
        return string.format("%.1fs", seconds)
    end
end

function U.FormatTimestamp(t)
    -- date() is a WoW global (wraps C strftime). Falls back gracefully.
    if date then
        return date("%Y-%m-%d %H:%M:%S", t)
    end
    return tostring(t)
end

--------------------------------------------------------------------------------
-- Shallow table copy (for snapshots)
--------------------------------------------------------------------------------
function U.ShallowCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

--------------------------------------------------------------------------------
-- Nil-safe, secret-safe string coerce
-- Midnight 12.0 marks some resource values as "secret" userdatas.
-- Calling tostring() on a secret value raises an error ("invalid value (secret)").
-- We pcall tostring to catch this and substitute a safe placeholder.
--------------------------------------------------------------------------------
function U.Str(v)
    if v == nil then return "nil" end
    local ok, result = pcall(tostring, v)
    if ok then return result end
    return "<secret>"
end

-- Returns true if the value can be safely serialized (not a secret userdata).
function U.IsSafe(v)
    if v == nil then return true end
    local ok = pcall(tostring, v)
    return ok
end

-- Sanitize a value for storage: replaces secret userdatas with nil
-- so they never end up in session tables or CSV output.
function U.Sanitize(v)
    if v == nil then return nil end
    local ok, result = pcall(tostring, v)
    if ok then return v end   -- original value is fine, return as-is
    return nil                -- secret -- drop it
end

--------------------------------------------------------------------------------
-- Table length that works on hash tables too
--------------------------------------------------------------------------------
function U.TableLen(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--------------------------------------------------------------------------------
-- Lightweight CSV escaping
-- Wraps the value in quotes if it contains commas, quotes, or newlines.
--------------------------------------------------------------------------------
function U.CSVEscape(val)
    local s = tostring(val or "")
    if s:find('[,"\n\r]') then
        s = '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

--------------------------------------------------------------------------------
-- Print to DEFAULT_CHAT_FRAME with a consistent prefix.
-- Only visible in-game; no-ops silently if the frame is nil (unit tests, etc.).
--------------------------------------------------------------------------------
local PREFIX = "|cff9966ff[MTDT]|r "

function U.Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. (msg or ""))
    end
end

function U.PrintWarn(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00[MTDT WARN]|r " .. (msg or ""))
    end
end

--------------------------------------------------------------------------------
-- Spell name lookup
-- Midnight 12.0 uses C_Spell.GetSpellInfo(id) which returns a table:
--   { name, iconID, castTime, minRange, maxRange, spellID, originalIconID }
-- The old GetSpellInfo(id) returns name as the first positional return.
-- We try the new API first, fall back to the old one.
--------------------------------------------------------------------------------
function U.GetSpellName(spellID)
    if not spellID or spellID == 0 then return nil end
    -- New API (Dragonflight / Midnight 12.0)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
        if ok and info and info.name and info.name ~= "" then
            return info.name
        end
    end
    -- Legacy API fallback
    if GetSpellInfo then
        local ok, name = pcall(GetSpellInfo, spellID)
        if ok and name and name ~= "" then return name end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Spellbook walker
-- Confirmed Midnight 12.0 API (from apicheck):
--   C_SpellBook.GetNumSpellBookSkillLines()  -> number (returns 5)
--   C_SpellBook.GetSpellBookSkillLineInfo(i) -> table
--   C_SpellBook.GetSpellBookItemInfo(slot, bank) -> table { spellID, ... }
--   C_SpellBook.GetSpellBookItemType(slot, bank) -> itemType string/enum
--   C_SpellBook.IsSpellBookItemPassive(slot, bank) -> bool
--   Enum.SpellBookSpellBank.Player confirmed present
-- Legacy GetNumSpellTabs / global GetSpellBookItemInfo confirmed NO.
--------------------------------------------------------------------------------
function U.SnapshotSpellbook()
    local seen = {}

    local numLines = 0
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
        local ok, n = pcall(C_SpellBook.GetNumSpellBookSkillLines)
        if ok and n then numLines = n end
    end

    if numLines == 0 then return seen end

    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player

    for i = 1, numLines do
        local lineInfo = U.Safe(C_SpellBook.GetSpellBookSkillLineInfo, i)
        if lineInfo then
            -- Field names confirmed from key list inspection
            local offset    = lineInfo.itemIndexOffset    or lineInfo.offset    or 0
            local numSpells = lineInfo.numSpellBookItems  or lineInfo.numSpells or 0
            for slot = offset + 1, offset + numSpells do
                -- GetSpellBookItemInfo returns a table with .spellID in Midnight 12.0
                local info = bank
                    and U.Safe(C_SpellBook.GetSpellBookItemInfo, slot, bank)
                    or  U.Safe(C_SpellBook.GetSpellBookItemInfo, slot)
                local spellID = info and info.spellID
                if spellID and spellID > 0 then
                    -- Skip passives (they don't cast)
                    local passive = bank
                        and U.Safe(C_SpellBook.IsSpellBookItemPassive, slot, bank)
                        or  U.Safe(C_SpellBook.IsSpellBookItemPassive, slot)
                    if not passive then
                        local name = U.GetSpellName(spellID)
                        seen[spellID] = name or true
                    end
                end
            end
        end
    end

    return seen
end

--------------------------------------------------------------------------------
-- Aura snapshot
-- Midnight 12.0 uses C_UnitAuras.GetAuraDataByIndex (Dragonflight+ API).
-- Old UnitBuff/UnitDebuff still exist as thin wrappers in some builds but
-- return protected/secret fields. We prefer the new API.
-- Returns table keyed by a stable key containing:
--   { spellID, name, stacks, duration, expirationTime, auraType }
--------------------------------------------------------------------------------
function U.SnapshotAuras(unit)
    unit = unit or "player"
    local auras = {}

    -- Preferred: C_UnitAuras (Midnight 12.0 / Dragonflight+)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
            local i = 1
            while true do
                local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
                if not ok or not data then break end
                local sid = U.Sanitize(data.spellId)
                if sid and sid > 0 then
                    local key = tostring(sid) .. (filter == "HARMFUL" and "_h" or "_b")
                    auras[key] = {
                        spellID        = sid,
                        name           = data.name or U.GetSpellName(sid),
                        stacks         = data.applications or 0,
                        duration       = U.Sanitize(data.duration),
                        expirationTime = U.Sanitize(data.expirationTime),
                        auraType       = filter,
                    }
                end
                i = i + 1
                if i > 60 then break end   -- safety cap
            end
        end
        return auras
    end

    -- Secondary: AuraUtil.ForEachAura (some Dragonflight builds)
    if AuraUtil and AuraUtil.ForEachAura then
        local function collect(data, auraType)
            if data and data.spellId then
                local key = tostring(data.spellId) .. (auraType == "HARMFUL" and "_h" or "_b")
                auras[key] = {
                    spellID        = data.spellId,
                    name           = data.name or U.GetSpellName(data.spellId),
                    stacks         = data.applications or 0,
                    duration       = U.Sanitize(data.duration),
                    expirationTime = U.Sanitize(data.expirationTime),
                    auraType       = auraType,
                }
            end
        end
        pcall(AuraUtil.ForEachAura, unit, "HELPFUL", nil, function(d) collect(d, "HELPFUL") end, true)
        pcall(AuraUtil.ForEachAura, unit, "HARMFUL", nil, function(d) collect(d, "HARMFUL") end, true)
        return auras
    end

    -- Legacy fallback: UnitBuff / UnitDebuff
    for i = 1, 60 do
        local name, _, count, _, duration, expiration, _, _, _, spellID =
            U.Safe(UnitBuff, unit, i)
        if not name then break end
        if spellID then
            auras[tostring(spellID) .. "_b"] = {
                spellID        = spellID,
                name           = name,
                stacks         = count or 0,
                duration       = U.Sanitize(duration),
                expirationTime = U.Sanitize(expiration),
                auraType       = "HELPFUL",
            }
        end
    end
    for i = 1, 60 do
        local name, _, count, _, duration, expiration, _, _, _, spellID =
            U.Safe(UnitDebuff, unit, i)
        if not name then break end
        if spellID then
            auras[tostring(spellID) .. "_h"] = {
                spellID        = spellID,
                name           = name,
                stacks         = count or 0,
                duration       = U.Sanitize(duration),
                expirationTime = U.Sanitize(expiration),
                auraType       = "HARMFUL",
            }
        end
    end

    return auras
end

--------------------------------------------------------------------------------
-- Aura diff
-- Returns { added = {}, removed = {}, changed = {} }
-- Compares two snapshots from SnapshotAuras.
--------------------------------------------------------------------------------
function U.DiffAuras(before, after)
    before = before or {}
    after  = after  or {}
    local added, removed, changed = {}, {}, {}

    for k, v in pairs(after) do
        if not before[k] then
            added[k] = v
        elseif before[k].stacks ~= v.stacks then
            changed[k] = { from = before[k].stacks, to = v.stacks, spell = v }
        end
    end
    for k, v in pairs(before) do
        if not after[k] then
            removed[k] = v
        end
    end

    return { added = added, removed = removed, changed = changed }
end

--------------------------------------------------------------------------------
-- Talent snapshot
-- Walks C_Traits (Midnight 12.0 talent system) and returns a list of active
-- talent nodes. Falls back to GetTalentInfo for older API shape.
-- Returns table of { nodeID, spellID, name, rank }
--------------------------------------------------------------------------------
function U.SnapshotTalents()
    local talents = {}

    -- C_Traits path (Midnight 12.0)
    if C_ClassTalents and C_ClassTalents.GetActiveConfigID then
        local configID = U.Safe(C_ClassTalents.GetActiveConfigID)
        if configID then
            local config = U.Safe(C_Traits.GetConfigInfo, configID)
            if config and config.treeIDs then
                for _, treeID in ipairs(config.treeIDs) do
                    local nodes = U.Safe(C_Traits.GetTreeNodes, treeID)
                    if nodes then
                        for _, nodeID in ipairs(nodes) do
                            local nodeInfo = U.Safe(C_Traits.GetNodeInfo, configID, nodeID)
                            if nodeInfo and nodeInfo.currentRank and nodeInfo.currentRank > 0 then
                                -- Try to get spell info for each rank entry
                                local spellID, spellName = nil, nil
                                if nodeInfo.activeEntry then
                                    local entryInfo = U.Safe(C_Traits.GetEntryInfo, configID, nodeInfo.activeEntry.entryID)
                                    if entryInfo and entryInfo.definitionID then
                                        local defInfo = U.Safe(C_Traits.GetDefinitionInfo, entryInfo.definitionID)
                                        if defInfo then
                                            spellID   = defInfo.spellID
                                            spellName = defInfo.overrideName or U.GetSpellName(defInfo.spellID)
                                        end
                                    end
                                end
                                table.insert(talents, {
                                    nodeID   = nodeID,
                                    spellID  = spellID,
                                    name     = spellName,
                                    rank     = nodeInfo.currentRank,
                                })
                            end -- spellID > 0 guard already handled above via defInfo path
                        end
                    end
                end
            end
            -- Strip any entries that ended up with no valid spellID
            local filtered = {}
            for _, t in ipairs(talents) do
                if t.spellID and t.spellID > 0 then
                    table.insert(filtered, t)
                end
            end
            return filtered
        end
    end

    -- Fallback: GetTalentInfo (older API, pre-dragonflight style)
    if GetTalentInfo then
        for tier = 1, 7 do
            for col = 1, 3 do
                local ok, name, _, _, _, selected, _, _, _, _, spellID = pcall(GetTalentInfo, tier, col, 1)
                if ok and selected then
                    table.insert(talents, { tier = tier, col = col, name = name, spellID = spellID, rank = 1 })
                end
            end
        end
    end

    return talents
end

--------------------------------------------------------------------------------
-- Spell usability snapshot
-- Confirmed Midnight 12.0 APIs:
--   C_Spell.IsSpellUsable(id)    -> bool (confirmed in key list)
--   C_Spell.GetSpellCooldown(id) -> { startTime, duration, isEnabled, modRate }
--   IsPlayerSpell(id)            -> bool (confirmed YES)
-- Removed: IsSpellUsable global, GetSpellCooldown global (both confirmed NO)
--------------------------------------------------------------------------------
function U.SnapshotSpellUsability(spellIDs)
    local out = {}
    for _, id in ipairs(spellIDs or {}) do
        local name = U.GetSpellName(id)

        -- Usability via C_Spell.IsSpellUsable (confirmed present)
        local usable
        if C_Spell and C_Spell.IsSpellUsable then
            local ok, v = pcall(C_Spell.IsSpellUsable, id)
            if ok then usable = U.Sanitize(v) end
        end

        -- Cooldown via C_Spell.GetSpellCooldown (confirmed present)
        local cdStart, cdDuration, cdEnabled
        if C_Spell and C_Spell.GetSpellCooldown then
            local ok, info = pcall(C_Spell.GetSpellCooldown, id)
            if ok and type(info) == "table" then
                cdStart    = U.Sanitize(info.startTime)
                cdDuration = U.Sanitize(info.duration)
                cdEnabled  = U.Sanitize(info.isEnabled)
            end
        end

        -- Known via IsPlayerSpell (confirmed YES)
        local known
        if IsPlayerSpell then
            local ok, k = pcall(IsPlayerSpell, id)
            if ok then known = U.Sanitize(k) end
        end

        out[id] = {
            name       = name,
            usable     = usable,
            cdStart    = cdStart,
            cdDuration = cdDuration,
            cdEnabled  = cdEnabled,
            known      = known,
        }
    end
    return out
end

--------------------------------------------------------------------------------
-- Resource snapshot
-- Returns primary and secondary resource values for the player.
--------------------------------------------------------------------------------
function U.SnapshotResources()
    local powerType = U.Safe(UnitPowerType, "player")
    local power     = U.Sanitize(U.Safe(UnitPower, "player", powerType))
    local powerMax  = U.Sanitize(U.Safe(UnitPowerMax, "player", powerType))
    local hp        = U.Sanitize(U.Safe(UnitHealth, "player"))
    local hpMax     = U.Sanitize(U.Safe(UnitHealthMax, "player"))

    -- Secondary resource (combo points, runes, etc.)
    local sec, secMax, secType = nil, nil, nil
    if UnitPower and UnitPowerMax then
        -- Fury (17) is DH primary. Soul Fragments aren't a real power type --
        -- they're tracked via charges/stacks on an internal buff.
        -- We snapshot what we can and let the raw data speak for itself.
        -- UnitPower for certain power types may return secret values in Midnight 12.0.
        -- U.Sanitize drops those silently rather than storing unserializable userdatas.
        for _, pt in ipairs({ 1, 2, 4, 6, 7, 9, 11, 12, 13, 17 }) do
            if pt ~= powerType then
                local raw = U.Safe(UnitPower, "player", pt)
                local val = U.Sanitize(raw)
                if val and val > 0 then
                    secType = pt
                    sec     = val
                    secMax  = U.Sanitize(U.Safe(UnitPowerMax, "player", pt))
                    break
                end
            end
        end
    end

    return {
        powerType = powerType,
        power     = power,
        powerMax  = powerMax,
        hp        = hp,
        hpMax     = hpMax,
        secType   = secType,
        sec       = sec,
        secMax    = secMax,
    }
end

--------------------------------------------------------------------------------
-- Zone snapshot
--------------------------------------------------------------------------------
function U.SnapshotZone()
    return {
        name          = U.Safe(GetZoneText),
        subZone       = U.Safe(GetSubZoneText),
        instanceName  = U.Safe(GetInstanceInfo),
        inInstance    = U.Safe(IsInInstance),
    }
end

--------------------------------------------------------------------------------
-- Class / spec info
--------------------------------------------------------------------------------
function U.SnapshotClassSpec()
    local className, classTag, classID = U.Safe(UnitClass, "player")
    local specIdx   = U.Safe(GetSpecialization)
    local specID, specName

    if GetSpecializationInfo and specIdx then
        specID, specName = U.Safe2(GetSpecializationInfo, specIdx)
    end

    return {
        className = className,
        classTag  = classTag,
        classID   = classID,
        specIdx   = specIdx,
        specID    = specID,
        specName  = specName,
        playerName = U.Safe(UnitName, "player"),
        realmName  = U.Safe(GetRealmName),
    }
end
