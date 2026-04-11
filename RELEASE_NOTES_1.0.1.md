# MidnightTim Debugging Tools -- Release Notes v1.0.1

**Tagline:** Polling-Based Spell Research & Profile Generation for Midnight 12.0  
**Date:** April 2026  
**Author:** Midnight - Thrall (US)

---

## Overview

MidnightTim Debugging Tools (MTDT) is a standalone companion addon to MidnightSensei. It is a lightweight, polling-based debug recorder built specifically for the Midnight 12.0 client environment, where the standard WoW event API has significant drift and several common approaches simply do not work.

Its primary purpose is to capture raw evidence of what actually happens in combat -- which spells appear, when they appear, what auras fire, what the player casts -- so that MidnightSensei's spec database and tracking logic can be refined against real data rather than assumptions.

This is the initial release. It covers everything from first load through a complete profile generation workflow for any class and spec.

---

## Architecture

Three files loaded in order:

| File | Purpose |
|---|---|
| `Utils.lua` | Nil-safe and secret-safe helpers, API wrappers, snapshot functions |
| `Core.lua` | Polling recorder, session management, profile system, slash commands |
| `UI.lua` | Panel UI, tabs, command buttons, export and reload popups |

One `SavedVariables` block: `MidnightTimDebugDB` -- account-wide, stores sessions, profiles, spell dumps, and metadata.

No event registrations except a single `PLAYER_LOGIN` that immediately unregisters itself. Everything else is driven by a single `OnUpdate` ticker polling at 0.1s intervals.

---

## Key Features

### Polling-Based Combat Recorder

Sessions are started automatically when combat begins and stopped when it ends. Manual start/stop available via `/mtdt start` / `/mtdt stop`. Every session captures:

- Spellbook snapshot at session start
- Aura state at session start
- Spell usability and cooldown snapshot for all watched spells
- Combat enter/leave timestamps
- Aura adds/removes/stack changes every tick
- New spells that appear mid-session (spells not present at start)
- Spell usability transitions (spell becomes castable after a proc or buff)
- Cast detection via `UnitCastingInfo` / `UnitChannelInfo` + cooldown-delta fallback for instant casts
- Periodic resource snapshots (Fury/HP every 5s)
- Talent snapshot at session start

All data writes to `MidnightTimDebugDB.sessions` and survives reloads.

### Profile Auto-Detection and Generation

On login, MTDT reads `classID` and `specIdx` and matches against all defined watch profiles. If a generated profile exists for the current class/spec it activates automatically. Falls back to generic mode (full capture, no watch list) for unrecognised specs.

**Build Profile** -- one button in the status bar or `/mtdt buildprofile` -- performs a complete spellbook dump, talent snapshot, profile construction, and immediate activation. A reload prompt appears so data persists to SavedVariables. After reload, the profile auto-detects and activates on every future login.

Generated profiles are stored in `MidnightTimDebugDB.generatedProfiles` keyed by `GENERATED_<classID>_<specIdx>`.

### Midnight 12.0 API Compatibility

Confirmed working APIs used throughout:

- `C_SpellBook.GetSpellBookItemInfo` -- spellbook enumeration
- `C_Spell.GetSpellInfo` -- spell name lookup
- `C_Spell.GetSpellCooldown` -- cooldown state (returns table)
- `C_Spell.IsSpellUsable` -- usability
- `C_UnitAuras.GetAuraDataByIndex` -- aura enumeration
- `C_ClassTalents` / `C_Traits` -- talent tree walking
- `UnitCastingInfo` / `UnitChannelInfo` -- cast bar state

Legacy APIs confirmed absent and not used: `GetSpellInfo` global, `GetSpellCooldown` global, `IsSpellUsable` global, `UnitBuff`/`UnitDebuff`, `GetNumSpellTabs`.

All return values from WoW APIs are passed through `U.Sanitize()` before use. Midnight 12.0 marks some resource values and aura fields as secret-tainted numbers. The sanitizer probes numeric values with `v + 0` (arithmetic throws on secrets, `tostring` does not) and returns nil for secrets rather than propagating them into session data or CSV output.

### CSV Export

All sessions export to flat CSV via `/mtdt export` commands or the Export Recent button. The CSV opens in a scrollable copy-paste EditBox -- Ctrl+A / Ctrl+C to copy, paste into any text editor and save as `.csv`. The full CSV is also stored in `MidnightTimDebugDB.meta.lastExportCSV`.

### Spell and Talent Copy-Paste

- `/mtdt spelllist` -- opens the current spell dump as CSV in the copy-paste box
- `/mtdt talentlist` or `/mtdt talents` -- opens the current talent snapshot as CSV
- Both available as buttons on the Commands tab

### API Check

`/mtdt apicheck` probes every relevant API namespace and prints YES/NO for each, plus dumps all keys present on `C_SpellBook`, `C_Spell`, `C_UnitAuras`, `C_ClassTalents`, and `C_Traits`. Results open in the copy-paste box for easy sharing. Used to discover API drift during initial development.

---

## UI

The panel opens with `/mtdt` (bare command) or the `/mtdt ui` command. Five tabs:

| Tab | Content |
|---|---|
| Controls | Profile status, spell dump info, available profiles, export location |
| Sessions | Last 20 sessions with duration, event count, new spell count |
| Snapshot | Live spell usability table for watched profile + current player auras |
| Info | Character/spec info, full active talent list |
| Commands | Clickable buttons for every slash command -- no chat scrolling needed |

**Status bar** shows recording state, active profile name, and session count. **Build Profile** button sits on the right side of the status bar.

**Bottom bar** has Start/Stop, Export Recent, Copy Last, Reset (two-click confirm).

---

## Slash Commands

```
/mtdt                  open/close debug panel
/mtdt start            start recording (manual)
/mtdt stop             stop recording
/mtdt status           show recorder state in chat
/mtdt reset            discard session + clear all data
/mtdt sessions         list last 10 saved sessions
/mtdt export recent    export most recent session to CSV
/mtdt export last10    export last 10 sessions
/mtdt export all       export all sessions
/mtdt snapshot         live spell usability for active profile
/mtdt auras            print current player auras
/mtdt talents          open talent dump in copy-paste box
/mtdt spellinfo <id>   full debug info for one spell ID
/mtdt buildprofile     dump spells + talents, build profile, prompt reload
/mtdt dumpspells       alias for buildprofile
/mtdt spelllist        open spell dump in copy-paste box
/mtdt talentlist       open talent dump in copy-paste box
/mtdt profile auto     re-detect profile from current class/spec
/mtdt profile devourer force Devourer DH profile
/mtdt profile none     generic mode, no watch list
/mtdt profile clear    remove all generated profiles
/mtdt interval <sec>   set poll interval (0.05-1.0)
/mtdt apicheck         probe which APIs are available
/mtdt debug profile    show classID/specIdx and all profile keys
/mtdt help             print all commands to chat
```

---

## Devourer DH Watch Profile

The only hand-authored profile in this release. Includes a curated `watchedSpells` list covering the Devourer rotation and confirmed-absent Havoc abilities (negative checks), `watchedAuras` seeded from the same IDs, and `procTriggerAuras` that fire an instant snapshot when Void Metamorphosis or Shattered Souls appear.

Key finding from session data that informed MidnightSensei fixes:
- Collapsing Star castable spell ID is `1221150`, not `1221167` (the talent node)
- Collapsing Star appears ~23s into a Void Metamorphosis window, not at window open
- Void Metamorphosis window swap mechanics mapped: Reap/Consume/Voidblade swap out at window open, Cull/Devour/Pierce the Veil swap in

---

## Known Limitations

- Instant casts not detectable directly without events -- inferred via cooldown-delta on watched spells
- Sub-0.1s precision not achievable without events
- Enemy aura fields are secret/protected in Midnight 12.0 -- player self-auras only
- Talent snapshot may be incomplete at login if `C_Traits` data loads late
- Generated profiles that contain secret-tainted spell IDs from the spellbook dump may silently omit those spells from the watched list

---

*MidnightTim Debugging Tools is part of the MidnightSensei project.*  
*Standalone addon -- do NOT merge into MidnightSensei.*  
*Created by Midnight - Thrall (US)*
