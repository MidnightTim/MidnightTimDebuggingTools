# Commit -- MidnightTim Debugging Tools v1.0.1

**Date:** April 11, 2026  
**Author:** Midnight - Thrall (US)  
**Branch:** main  
**Tag:** v1.0.1

---

## Summary

Initial release. Polling-based spell research and profile generation tool for the Midnight 12.0 client. Built to support MidnightSensei spec database validation.

---

## Changed Files

- `MidnightTimDebuggingTools.toc` -- initial
- `Utils.lua` -- helpers, API wrappers, secret-number sanitization
- `Core.lua` -- recorder, session management, profile system, slash commands
- `UI.lua` -- panel, tabs, command buttons, export popup, reload prompt

---

## Commits

### feat(core): polling recorder with auto combat detection
OnUpdate ticker at 0.1s. Detects combat via UnitAffectingCombat. Auto-starts/stops sessions on combat state transitions. Manual start/stop via /mtdt start/stop. Sessions written to MidnightTimDebugDB.

### feat(core): spellbook/aura/cast/usability capture per tick
Every tick during recording: spellbook diff for new spell detection, C_UnitAuras aura diff, C_Spell.IsSpellUsable + GetSpellCooldown usability diff, UnitCastingInfo/UnitChannelInfo cast detection, cooldown-delta fallback for instant casts, resource snapshots every 5s.

### feat(core): profile auto-detection and generation
DetectProfile() reads classID + specIdx on login, matches against WATCH_PROFILES. BuildProfileFromDump() constructs a profile from a live spellbook scan and activates it immediately. Generated profiles persist to SavedVariables and auto-restore on reload.

### feat(core): buildprofile command (spells + talents in one pass)
/mtdt buildprofile scans the full spellbook and talent tree simultaneously, builds a watch profile, activates it, opens the UI, and shows a reload prompt. /mtdt dumpspells is an alias.

### feat(core): /mtdt bare opens UI, /mtdt help prints to chat
Bare /mtdt toggles the panel. /mtdt help prints the command list. Separated so the panel opens without flooding chat.

### feat(ui): five-tab panel with command buttons
Controls, Sessions, Snapshot, Info, Commands tabs. Commands tab renders every slash command as a clickable button -- no chat scrolling. Build Profile button in status bar. Start/Stop/Export/Reset in bottom bar. Snapshot tab live-refreshes every 0.5s.

### feat(ui): copy-paste export popup
All exports (sessions, spell list, talent list, API check) open in a scrollable EditBox. Ctrl+A / Ctrl+C to copy. Stored in SavedVariables as fallback.

### feat(ui): reload prompt after Build Profile
Modal dialog appears above the panel after buildprofile completes. Reload Now calls ReloadUI(). Not Now dismisses with a reminder -- profile is already active the current session.

### feat(utils): secret-number sanitization
U.Sanitize() probes numeric values with v+0 (arithmetic throws on Midnight 12.0 secret numbers; tostring does not). All aura fields, resource values, and spell IDs sanitized before storage or comparison. Prevents "attempt to compare secret number" poll errors.

### feat(utils): confirmed Midnight 12.0 API usage
C_SpellBook, C_Spell, C_UnitAuras, C_ClassTalents, C_Traits throughout. All legacy globals (GetSpellInfo, UnitBuff, etc.) confirmed absent via /mtdt apicheck and removed from all code paths.

### fix(utils): SnapshotClassSpec correctly captures classID
U.Safe() returns only the first pcall result. UnitClass() returns (name, tag, classID). Fixed with direct pcall to capture all three values. Was causing generated profile classID to store nil, preventing DetectProfile from ever matching.

### fix(core): forward declarations for BuildProfileFromDump/DetectProfile
local function Foo() creates a new local, not an assignment to a forward-declared upvalue. All three forward-declared functions changed to assignment form Foo = function() so the slash handler calls the real implementation.

### feat(profile): Devourer DH hand-authored profile
watchedSpells covering full Devourer rotation plus confirmed-absent Havoc abilities as negative checks. procTriggerAuras for Void Metamorphosis and Shattered Souls. Informed by live session export data.

---

## Testing Notes

- Confirmed working on Demonology Warlock and Devourer DH in Midnight 12.0
- Build Profile tested: 171 spells captured, profile activated, reload prompt shown
- Secret number fix eliminates recurring poll error on aura snapshots
- /mtdt apicheck confirmed all legacy API globals are absent; new APIs all present
- classID fix confirmed: profile now auto-detects and shows in status bar after reload
