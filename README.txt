================================================================================
  MidnightTim Debugging Tools — README
  Version 1.0.0
  Part of the MidnightSensei project. Standalone addon — do NOT merge into
  MidnightSensei itself.
================================================================================

PURPOSE
-------
A lightweight, polling-based debug recorder for the Midnight 12.0 client.

This addon exists because MidnightSensei's development revealed that the
Midnight 12.0 environment has significant API drift from retail WoW:
  - Some spells don't appear in the spellbook until combat begins
  - Some spells only appear after a proc fires or another ability is used
  - Enemy aura fields are secret/protected and unreadable
  - BNet APIs are broken
  - Some Blizzard APIs return nil where they shouldn't

This tool is built to capture raw evidence of what actually happens rather
than assume any API behaves as documented.


ARCHITECTURE
------------
Two files, loaded in order by the TOC:

  Utils.lua   — Nil-safe wrappers, snapshot helpers, CSV helpers. No state.
  Core.lua    — Polling recorder, session management, slash commands.

One hidden OnUpdate frame drives everything. PLAYER_LOGIN is registered once
(to know when SavedVariables are available) and then unregistered immediately.
No other event registrations exist.

Why polling instead of events?
  Midnight 12.0 has had issues with event registration, protected event
  tables, roster sync timing, and other weirdness. Polling is less elegant
  but far more predictable. The tradeoff is that instant-cast spells may not
  be detected mid-cast — we capture what we can via UnitCastingInfo /
  UnitChannelInfo state changes, and supplement with cooldown/usability diffs.

Poll interval: 0.1s by default.
Change via: /mtdt interval <0.05 - 1.0>


SAVEDVARIABLES
--------------
Everything goes to MidnightTimDebugDB. To inspect it:

  1. Log out (or /reload)
  2. Navigate to: World of Warcraft/_retail_/WTF/Account/<name>/SavedVariables/
  3. Open: MidnightTimDebuggingTools.lua
  4. The sessions array contains all captured data as plain Lua tables.
  5. meta.lastExportCSV contains the last export run.

Structure:
  MidnightTimDebugDB.sessions[]
    .sessionIndex
    .startWall, .endWall       (Unix timestamps for wall-clock labels)
    .startTime, .endTime       (GetTime() values for relative math)
    .durationSec
    .player                    (class/spec snapshot)
    .zone
    .profile                   (which watch profile was active)
    .talentsAtStart            (C_Traits snapshot)
    .spellbookAtStart          (all spell IDs visible at session open)
    .aurasAtStart              (all player auras at session open)
    .usabilityAtStart          (IsSpellUsable / GetSpellCooldown for watched spells)
    .resourcesAtStart          (Fury, HP, etc.)
    .events[]                  (timestamped event log)
    .newSpellsDiscovered{}     (spells that appeared during session but not at start)
    .summary                   (counts and highlights)

  MidnightTimDebugDB.meta
    .version
    .totalSessions
    .lastExportCSV             (flat CSV text of last export)
    .lastExportTime


SLASH COMMANDS
--------------
/mtdt help                     Print all commands

/mtdt start                    Start a manual recording session
/mtdt stop                     Stop the current session
/mtdt status                   Show recorder state

/mtdt reset                    Discard active session + clear ALL saved data
                                (use with caution)

/mtdt sessions                 List last 10 saved sessions with summary

/mtdt export                   Export most recent session to CSV
/mtdt export recent            Same as above
/mtdt export last10            Export last 10 sessions
/mtdt export all               Export all saved sessions

/mtdt snapshot                 Live usability table for all watched spells
                                (great for checking what's visible right now)
/mtdt auras                    Print all current player auras
/mtdt talents                  Print all active talents

/mtdt spellinfo <id>           Full debug print for one spell ID:
                                name, known, usable, casttime, cooldown,
                                player aura state

/mtdt profile devourer         Set active watch profile to Devourer DH
/mtdt profile none             Clear profile (generic recording)

/mtdt interval <sec>           Change poll interval (0.05 to 1.0)


WATCH PROFILES
--------------
A watch profile defines which spell IDs and aura IDs get extra attention
during recording. The primary profile is Devourer DH.

Profiles live in Core.lua under Core.WATCH_PROFILES.DEVOURER_DH.

Fields:
  watchedSpells[]      Polled every tick for usability/visibility changes
  watchedAuras[]       Flagged specifically in aura diff log entries
  procTriggerAuras[]   When these auras appear, a full spell+usability
                       snapshot is taken immediately (correlates proc
                       fires with spell availability changes)



PERFORMANCE NOTES
-----------------
At 0.1s poll interval, the addon runs 10 polls per second.
Each poll does:
  - UnitAffectingCombat check (trivial)
  - GetSpellBookItemInfo loop (only during recording — iterates all tabs)
  - UnitBuff/UnitDebuff or AuraUtil loop (only during recording)
  - IsSpellUsable x N watched spells (N = ~20 for Devourer profile)
  - UnitCastingInfo / UnitChannelInfo (2 calls)
  - Optionally UnitPower / UnitHealth (every 5s)

This is cheap. WoW addons routinely do far more per OnUpdate.
If you're in a 40-man raid doing heavy AoE, raise interval to 0.2s.

The spellbook walk and full aura snapshot are the most expensive operations.
Both are skipped entirely when not recording.


KNOWN LIMITATIONS
-----------------
1. Instant casts are not reliably captured.
   UnitCastingInfo only returns info during the cast animation.
   Instant casts have no cast bar. To capture instant casts you need
   UNIT_SPELLCAST_SUCCEEDED events, which this addon deliberately avoids.
   Workaround: watch for cooldown state changes on watched spells —
   if a spell's cooldown starts, it was cast.

2. Sub-0.1s precision is not achievable without events.
   This is fine for debugging spell availability and proc correlations.
   It is NOT fine for exact DPS rotation analysis (use MidnightSensei
   for that once the spell IDs are confirmed).

3. Spellbook scan may miss very late-loading abilities.
   Some abilities in Midnight 12.0 are not in the spellbook at login.
   This is exactly what we're here to document. combatGated spells
   (like Collapsing Star) are expected to be missing at session start.

4. Talent snapshot may be incomplete at login.
   C_Traits data can be delayed. The session stores whatever C_Traits
   returns at session start. If you suspect the talent snapshot is wrong,
   use /mtdt talents to check current state, then /mtdt start to capture
   a fresh session after the talent tree has loaded.

5. Enemy aura tracking is intentionally omitted.
   Midnight 12.0 marks enemy aura fields as secret/protected.
   Attempting to read them returns garbage. We only track player self-auras.


VERSION HISTORY
---------------
1.0.0  Initial release.
       Polling recorder, Devourer DH watch profile, CSV export.
       Spellbook/aura/usability/cast/talent/resource capture.
       /mtdt slash command suite.
================================================================================
