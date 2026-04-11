PURPOSE
-------
A lightweight, polling-based debug recorder and profile generator for the
Midnight 12.0 client. Built to help validate MidnightSensei spec data by
capturing raw evidence of what actually happens in combat -- which spells
exist, when they appear, what auras fire, and what the player casts.

This addon exists because Midnight 12.0 has significant API drift from retail:
  - Some spells don't appear in the spellbook until combat begins
  - Some spells only appear after a proc or another spell is used
  - Enemy aura fields are secret/protected and unreadable
  - Several legacy global APIs are absent (UnitBuff, GetSpellInfo, etc.)
  - Some API return values are "secret-tainted" numbers that crash on comparison


QUICK START
-----------
1. Type /mtdt or click the minimap icon to open the panel
2. Click "Build Profile" in the status bar to scan your spells and talents
3. Click "Reload Now" when prompted to persist to SavedVariables
4. After reload, your profile auto-activates -- status bar shows your spec name
5. Enter combat to auto-start a recording session
6. After combat, click "Export Recent" to copy the session data


ARCHITECTURE
------------
Utils.lua   -- Nil-safe helpers, secret-number sanitization, API wrappers,
               spellbook/aura/talent/usability snapshot functions
Core.lua    -- Polling recorder, session management, profile system,
               slash command handler
UI.lua      -- Panel UI, five tabs, command buttons, export popup, reload prompt

SavedVariables: MidnightTimDebugDB (account-wide)
  .sessions[]          -- recorded combat sessions
  .generatedProfiles{} -- profiles built from Build Profile
  .spellDump[]         -- raw spellbook from last Build Profile
  .talentDump[]        -- raw talents from last Build Profile
  .spellDumpClass      -- class/spec info at dump time
  .meta{}              -- lastExportCSV, lastApiCheck


PROFILE SYSTEM
--------------
On login MTDT reads your classID and specIdx and auto-selects a matching
profile. If a generated profile exists for your spec, it activates. Otherwise
falls back to generic mode (full capture, no watched spell list).

PROFILES:
  Generated        Built from Build Profile for your exact class/spec.
                   Stored in SavedVariables, auto-restores after reload.
  Devourer DH      Hand-authored profile for Devourer Demon Hunter research.
  Generic          All specs with no defined profile. Captures everything --
                   spellbook, auras, casts, resources, talents -- without
                   a specific watched spell list.

BUILD PROFILE:
  Click "Build Profile" in the status bar or type /mtdt buildprofile.
  This scans your full spellbook and active talent tree, constructs a watch
  profile for your current spec, and activates it immediately. A reload prompt
  appears so the data persists to SavedVariables and survives future reloads.
  After reloading, the profile auto-detects on every login.

  /mtdt profile auto     -- re-detect after a spec change
  /mtdt profile clear    -- remove all generated profiles
  /mtdt profile none     -- switch to generic mode


UI TABS
-------
Controls    Active profile, spell dump info, available profiles, export path.
Sessions    Last 20 recorded sessions with duration, event count, new spells.
Snapshot    Live spell usability table + current player auras. Refreshes
            automatically every 0.5s when this tab is open.
Info        Character, class, spec, zone, and full active talent list.
Commands    Every slash command as a clickable button. Click to run.
            No need to type commands or scroll through chat output.


SLASH COMMANDS
--------------
/mtdt                  open/close debug panel
/mtdt start            start recording (manual)
/mtdt stop             stop recording
/mtdt status           show recorder state
/mtdt reset            discard session + clear all saved data
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
/mtdt interval <sec>   set poll interval (0.05 to 1.0)
/mtdt apicheck         probe which APIs are available (opens copy box)
/mtdt debug profile    show classID/specIdx and all profile keys in chat
/mtdt help             print all commands to chat


EXPORTING DATA
--------------
All exports open a scrollable copy-paste EditBox in the UI.
  1. Click inside the box
  2. Press Ctrl+A to select all
  3. Press Ctrl+C to copy
  4. Paste into Notepad or any text editor and save as .csv

The last export is also stored in MidnightTimDebugDB.meta.lastExportCSV
in the SavedVariables file (WTF/Account/<n>/SavedVariables/ after /reload).


API CHECK
---------
/mtdt apicheck probes every relevant Midnight 12.0 API and reports YES/NO
for each namespace and function. Also runs live probes (spell name lookup,
cooldown check, aura index read) and dumps all keys present on C_SpellBook,
C_Spell, C_UnitAuras, C_ClassTalents, and C_Traits. Results open in the
copy-paste box for sharing.


PERFORMANCE NOTES
-----------------
At 0.1s poll, the addon runs 10 polls per second.
The spellbook walk and aura scan are skipped entirely when not recording.
Usability snapshot only polls the watched spell list (N spells per profile).
Each poll is wrapped in pcall -- one crashed API can never kill future ticks.
Sessions shorter than 3s are discarded as trash-pull noise.
Maximum 50 sessions retained before oldest are pruned.

If you see hitching in heavy AoE: /mtdt interval 0.2


KNOWN LIMITATIONS
-----------------
- Instant casts are detected via cooldown-delta only (0.1s delay at most)
- Sub-0.1s precision not achievable without event registration
- Enemy aura fields are secret/protected in Midnight 12.0 -- player only
- Talent snapshot may be incomplete at login if C_Traits loads late
  (a 3-second deferred re-detect handles this automatically)
- Generated profiles seed watchedAuras from all spell IDs -- many won't
  produce auras. Session data will show which ones actually fire.


================================================================================
  MidnightTim Debugging Tools v1.0.0
  Created by Midnight - Thrall (US)
  Part of the MidnightSensei project
================================================================================
