---
title: Start
---

# Start

This guide walks you through the daily workflow of SenaVN: adding games, linking local paths, managing metadata, launching games, and using the interactive TUI.

---

## 1. Adding Games to Your Library

Add games from VNDB using `sena add`. Provide a title query and a short unique ID for your local library:

```sh
# Search VNDB by title and assign a short ID
sena add "gamename" gamename

# Or add using a specific VNDB ID directly
sena add "Steins;Gate" sg --vndb-id v2002
```

### Interactive VNDB Picker

If multiple games match your query, an interactive selection menu appears:

```text
  [1] FORTUNE×WORLD ~Bokura ga Game o Tsukuru Riyuu~ - GLOVETY (Rating: 8.6)
  [2] Itsuka, Todoku, Ano Sora ni. - Lump of Sugar (Rating: 8.4)
Select result [1-2, default 1, q to cancel]
```

Select the appropriate number or press Enter for the top result.

### Metadata Review & File Picker

Unless `--skip` is passed:

1. SenaVN opens the fetched metadata in your `$EDITOR` for manual adjustments.
2. If no path was provided on the command line, SenaVN opens the **interactive terminal file picker** to link your game executable immediately.

---

## 2. Linking Executable, Save Folder, and Walkthrough

Use `sena use` to associate local filesystem paths with a game ID. Omit path arguments to trigger interactive terminal browsers starting at your system drive roots:

```sh
# Interactively pick executable file (starts at drives root)
sena use gamename

# Interactively pick save folder
sena use gamename --save

# Interactively pick walkthrough / guide file
sena use gamename --guide

# Or pass paths directly
sena use gamename "D:\Games\gamename\gamename.exe" --save "D:\Games\gamename\savedata"
```

### File Picker Controls

- `Up` / `Down` or `k` / `j`: Move selection up/down.
- `PgUp` / `PgDn`: Scroll list by 10 items.
- `Enter`: Descend into directory or confirm file selection.
- `Space`: Confirm current directory (in save folder mode).
- `Backspace` / `Left` / `h`: Ascend to parent folder (returns to `This PC (Drives)` at root).
- `/`: Enter real-time filter search.
- `Esc` / `q`: Cancel.

---

## 3. Launching and Tracking Games

Launch your visual novel with automated background playtime tracking:

```sh
# Launch by ID or title query
sena run gamename

# Launch the game you played most recently
sena run --recent

# Launch the most recently added game
sena run --last

# Pick and launch a random game
sena run --random
```

### Live Status & Crash Protection

SenaVN detaches `sena-guard.exe` to poll the game process PID in the background without holding database locks:

```sh
# View currently running games and elapsed session time
sena status
```

If your game crashes or Windows reboots unexpectedly, the heartbeat file persists. SenaVN automatically reconciles and backfills the session duration on your next CLI command.

---

## 4. Viewing & Editing Metadata

```sh
# View formatted game info card in terminal
sena info gamename

# Open walkthrough file in your editor
sena info gamename -g

# Open save folder in Windows Explorer
sena info gamename -s

# Edit game metadata in $EDITOR
sena edit gamename

# Refresh metadata from VNDB
sena edit gamename --fetch
```

---

## 5. Using the Interactive TUI

Run `sena` with no arguments to launch the fullscreen Brick browser:

```sh
sena
```

### TUI Controls

- **Navigation**: Use `Up`/`Down` or `j`/`k` to browse games in the left navigation tree.
- **Run Game**: Press `r` on any selected game to launch it and attach the daemon.
- **Edit Game**: Press `e` to open metadata in your `$EDITOR`.
- **Open Save**: Press `s` to open the save directory in File Explorer.
- **Open Guide**: Press `g` to open the walkthrough file.
- **Filter**: Press `/` to start searching games by title, alias, ID, or tags.
- **Exit**: Press `q` or `Esc`.
