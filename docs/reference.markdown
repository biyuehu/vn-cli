---
title: Reference
---

# Complete CLI & Configuration Reference

This page provides the comprehensive specification for all SenaVN command-line options, subcommands, flags, and persistent configuration keys.

---

## Command Line Interface (CLI)

### Syntax Overview

```bash
sena [SUBCOMMAND] [OPTIONS]
```

Running `sena` with no arguments launches the interactive Brick TUI browser.

---

### Commands Specification

#### `sena add`

Add a new visual novel to the local SQLite database.

```bash
sena add <NAME_OR_QUERY> <ID> [PATH] [OPTIONS]
```

| Argument / Flag | Description |
| :--- | :--- |
| `NAME_OR_QUERY` | VNDB search query string or game title |
| `ID` | Unique alphanumeric identifier for local database |
| `PATH` | Optional executable path. If omitted and `--skip` is absent, triggers the interactive file picker |
| `--vndb-id <ID>` | Direct VNDB ID (e.g. `v2002`) |
| `--developer <DEV>` | Override developer name |
| `--release-date <YYYYMMDD>` | Override release date integer |
| `--rating <SCORE>` | Override rating score (0.0 - 10.0) |
| `--description <TEXT>` | Override description |
| `--tag <TAG>` | Add custom tag (repeatable) |
| `--no-fetch` | Skip VNDB query; create local-only record |
| `-s, --skip` | Non-interactive mode: skip confirmation and file picker |
| `-o, --order <N>` | Auto-select Nth search result |
| `--keep-name` | Retain supplied `NAME` instead of VNDB title |

---

#### `sena use`

Associate executable, save folder, and guide file paths with a game.

```bash
sena use <ID> [PATH] [--save [PATH]] [--guide [PATH]]
```

| Argument / Flag | Description |
| :--- | :--- |
| `ID` | Game identifier |
| `[PATH]` | Executable path. Omit to launch interactive file picker |
| `--save [PATH]` | Save folder path. Omit `[PATH]` to launch interactive directory picker |
| `--guide [PATH]` | Walkthrough file path. Omit `[PATH]` to launch interactive file picker |

---

#### `sena run`

Launch game process and start background tracking daemon.

```bash
sena run [ID_OR_NAME] [OPTIONS]
```

| Flag | Description |
| :--- | :--- |
| `ID_OR_NAME` | Game ID or title query |
| `-s, --skip` | Exact ID match only, skip title fuzzy matching |
| `--random` | Select and launch a random game |
| `-R, --recent` | Launch the most recently played game |
| `-L, --last` | Launch the most recently added game |
| `-f, --filter <EXPR>` | Filter candidate pool by tag, title, or developer (useful with `--random`) |

---

#### `sena info`

Display game card or open associated resources.

```bash
sena info <ID> [-g] [-s]
```

| Flag | Description |
| :--- | :--- |
| `-g, --guide` | Open linked walkthrough file in `$EDITOR` |
| `-s, --save` | Open linked save folder in Windows File Explorer |

---

#### `sena edit`

Edit game metadata.

```bash
sena edit <ID> [--fetch] [--apply] [-o <N>] [--keep-name]
```

| Flag | Description |
| :--- | :--- |
| `--fetch` | Re-fetch metadata from VNDB and open in editor |
| `--apply` | Apply fetched VNDB metadata directly without opening editor |
| `-o, --order <N>` | Auto-select Nth VNDB search result |
| `--keep-name` | Keep existing local title during re-fetch |

---

#### `sena list`

List visual novels with formatting and sorting.

```bash
sena list [-s <FIELD>] [-r] [-d] [-f <EXPR>]
```

| Flag | Description |
| :--- | :--- |
| `-s, --sort <FIELD>` | Sort by: `title`, `lastPlay`, `createDate`, `releaseDate`, `rating`, `played` |
| `-r, --reverse` | Reverse sort order |
| `-d, --detail` | Show detailed multi-line cards with tags and paths |
| `-f, --filter <EXPR>` | Filter query expression |

---

#### `sena stat`

Display library aggregate statistics or specific game metrics.

```bash
sena stat [ID...] [-f <EXPR>]
```

---

#### `sena tl`

Display git-log style chronological gameplay timelines.

```bash
sena tl [ID...] [--today] [--oneline] [-n <NUM>] [-r] [--no-pager]
```

| Flag | Description |
| :--- | :--- |
| `--today` | Display sessions recorded today only |
| `--oneline` | Condensed single-line output per session |
| `-n, --max-count <N>` | Limit output to N sessions |
| `-r, --reverse` | Ascending chronological order |
| `--no-pager` | Disable terminal pager output |

---

#### `sena rm`

Remove a game from the library.

```bash
sena rm <ID> [-H, --hard]
```

| Flag | Description |
| :--- | :--- |
| (default) | Soft removal from local database. Retains cloud assets during sync |
| `-H, --hard` | Permanent deletion. Records atomic tombstone for cloud synchronization |

---

#### `sena mv`

Rename game identifier.

```bash
sena mv <OLD_ID> <NEW_ID>
```

Migrates sessions, local paths, and clears/records appropriate tombstones.

---

#### `sena sync`

Synchronize local library with GitHub repository.

```bash
sena sync [--dry-run]
```

| Flag | Description |
| :--- | :--- |
| `-n, --dry-run` | Simulate 3-way merge and report changes without modifying local DB or remote repo |

---

#### `sena config`

Manage persistent key-value configuration.

```bash
sena config [KEY] [VALUE] [-u <KEY>] [-e]
```

| Option | Description |
| :--- | :--- |
| `(no args)` | Print all active configuration values |
| `<KEY>` | Query specific configuration value |
| `<KEY> <VALUE>` | Set configuration value |
| `-u, --unset <KEY>` | Delete configuration key |
| `-e, --edit` | Open all configurations inside `$EDITOR` |

---

## Configuration Reference

SenaVN configuration is stored in SQLite table `configs`.

| Configuration Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `core.editor` | String | Fallback `$EDITOR` | Preferred editor command (e.g. `code --wait`, `nvim`, `notepad`). |
| `fetch.proxy` | String | `""` | HTTP/HTTPS proxy URL for VNDB queries and cloud sync (e.g. `http://127.0.0.1:7890`). |
| `sync.repo` | String | `""` | Target GitHub repository in `owner/repo` format. |
| `sync.token` | String | `""` | GitHub Personal Access Token (masked in CLI outputs). |
| `sync.branch` | String | `main` | Git branch storing library synchronization JSON. |
| `sync.path` | String | `data.json` | Path within repository storing library data. |
