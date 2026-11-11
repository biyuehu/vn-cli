<!-- markdownlint-disable MD013 MD033 MD041 -->

<div align="center">

# SenaVN | GalKeeper 2.0

**A terminal-first Visual Novel library manager, gameplay tracker, and GitHub cloud synchronizer.**

Crafted for keyboard-driven players and programmers — pure terminal, zero GUI overhead, native Windows process tracking.

[![License](https://img.shields.io/badge/License-GPL--3.0-blue?style=flat-square)](LICENSE)
[![CI](https://github.com/biyuehu/vn-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/biyuehu/vn-cli/actions/workflows/ci.yml)
![Haskell](https://img.shields.io/badge/Haskell-GHC%209.8+-5D4F85?style=flat-square&logo=haskell&logoColor=white)
![Rust](https://img.shields.io/badge/Rust-2021-000000?style=flat-square&logo=rust&logoColor=white)
![Windows](https://img.shields.io/badge/Platform-Windows-0078D6?style=flat-square&logo=windows&logoColor=white)
![SQLite](https://img.shields.io/badge/Storage-SQLite%20WAL-003B57?style=flat-square&logo=sqlite&logoColor=white)
![Codeberg](https://img.shields.io/badge/Codeberg-2185D0?style=flat-square&logo=codeberg&logoColor=white)

</div>

---

## Architecture

SenaVN operates as two cooperative binaries without FFI complexity:

```mermaid
flowchart TD
    subgraph Host["User Terminal / CLI"]
        Sena["sena (Haskell GHC 2021)<br/>CLI Commands • Interactive TUI • DB Writer"]
    end

    subgraph Daemon["Background Guardian"]
        Guard["sena-guard.exe (Rust 2021)<br/>Windows API Process Watcher • Atomic Heartbeat"]
    end

    subgraph GameProc["Visual Novel Process"]
        Game["Game Executable (*.exe)"]
    end

    subgraph Storage["Local Persistence (~/.senavn/)"]
        DB[("SQLite Database<br/>sena.db (WAL Mode)")]
        Sessions["Session Files<br/>sessions/<id>.session.json"]
    end

    subgraph Remote["External Services"]
        VNDB["VNDB HTTPS API<br/>Metadata & Covers"]
        GitHub["GitHub REST API<br/>Encrypted Cloud Sync"]
    end

    Sena -- "Spawn & Detach" --> Guard
    Guard -- "Monitor PID" --> Game
    Guard -- "Atomic 60s Write" --> Sessions
    Sena -- "Reconcile Sessions" --> Sessions
    Sena -- "Single Writer" --> DB
    Sena -- "Fetch Query" --> VNDB
    Sena -- "3-Way Merge (data.json)" --> GitHub
```

- **`sena` (Haskell)**: CLI interface, interactive Brick TUI, SQLite operations, VNDB API queries, and 3-way cloud sync.
- **`sena-guard` (Rust)**: Standalone lightweight daemon for low-level Windows process polling. Completely independent from SQLite, ensuring zero database lock contention.

---

## Features

- **🎮 Dual Mode Interface**: Run `sena` without arguments to enter the full-screen interactive **TUI browser** (powered by Brick), or use rich CLI subcommands for instant shell scripting and automation.
- **🔍 Seamless VNDB Integration**: Search visual novels directly by name or ID, interactively select search results, and review/edit metadata inside your preferred `$EDITOR` before saving.
- **⏱️ Automated Gameplay Tracking**: Non-blocking game launch. `sena-guard` tracks process lifecycles in the background, continuously writing atomic heartbeats.
- **🛡️ Crash-Resilient Reconcile**: Unscheduled system reboots or game crashes are automatically reconciled and backfilled on the next CLI run — no lost play sessions.
- **☁️ 3-Way Cloud Synchronization**: Synchronize your library with a private GitHub repository. Includes Last-Write-Wins (LWW) conflict resolution, session deduplication, and resurrection of modified games.
- **⚰️ Two-Tier Deletion & Tombstone Tracking**:
  - `sena rm <id>`: Soft removal from local library without deleting remote cloud assets.
  - `sena rm <id> -H`: Permanent deletion recording an atomic tombstone in `deleted_games`, propagating cloud-wide on sync.
  - Reusing a previously deleted ID in `sena add` or `sena mv` safely clears historical tombstones with user confirmation.
- **📈 Git-Log Style Timelines & Statistics**: Visualize your visual novel journey with flowing session graphs, date grouping, total play duration calculations, and top-played rankings.
- **🪟 Native Windows Terminal Adaptation**: Automatic UTF-8 (`CP65001`) console output switching without needing manual `chcp`, with full support for ANSI styling and color themes.

---

## Tech Stack

| Component | Technologies |
| :--- | :--- |
| **CLI & TUI Engine** | Haskell (GHC 2021, Base 4.19), [Brick 2.12](https://github.com/jtdaugherty/brick), [Vty](https://github.com/jtdaugherty/vty), [optparse-applicative](https://github.com/pcapriotti/optparse-applicative) |
| **Process Guardian** | Rust 2021, `sysinfo`, `winapi` (Windows User32 / Kernel32) |
| **Database & Cache** | SQLite 3 (`sqlite-simple` with WAL journal mode, busy timeouts, and cascading foreign keys) |
| **Network & Sync** | [Req](https://github.com/mrkkrp/req) (HTTP/HTTPS client), Aeson (JSON serialization), RFC 4648 Base64 |
| **Testing & CI** | Self-contained zero-dependency Haskell test suite (51 test cases), GitHub Actions CI |

---

## CLI Reference

```sh
sena                                # Launch full-screen interactive TUI browser
sena add <name> <id> [path]         # Add a game from VNDB with interactive picker & editor
sena edit <id>                      # Edit game metadata in $EDITOR (or --fetch to refresh)
sena run <id>                       # Launch game and start background tracking
sena run --random                   # Pick a random game from library and launch
sena run --recent | --last          # Launch most recently played game
sena status                         # Display currently running games and active playtime
sena list [-s <field>] [-r] [-d]    # List games (sort by played/rating/release/date, detail mode)
sena stat [id...]                   # Library-wide aggregate statistics or per-game stats
sena tl [id...] [--today] [--oneline] # Git-log style gameplay session timeline
sena use <id> <exe> [--save <p>]    # Link local executable path, save directory, and walkthrough
sena info <id> [-g] [-s]            # View game card or quickly open guide file / save directory
sena mv <old-id> <new-id>           # Rename game ID (auto-migrates sessions and cloud tombstones)
sena rm <id> [-H, --hard]           # Remove game (soft local removal or -H permanent cloud deletion)
sena sync [--dry-run]               # Bidirectional 3-way cloud sync with GitHub repository
sena config [key] [val] [-u] [-e]   # View, set, unset, or edit configuration in $EDITOR
sena completion <shell>             # Generate completion script (bash, zsh, fish, powershell)
```

### Configuration Keys

Configure via `sena config <key> <val>` or `sena config -e`:

| Key | Description | Default |
| :--- | :--- | :--- |
| `core.editor` | Preferred editor command (e.g. `code --wait`, `nvim`, `notepad`) | Fallback to `$VISUAL` / `$EDITOR` |
| `fetch.proxy` | HTTP/HTTPS proxy for VNDB queries and GitHub sync | `""` |
| `sync.repo` | Target GitHub repository in `owner/repo` format | `""` |
| `sync.token` | GitHub Personal Access Token with repository scope | `""` (Masked in output) |
| `sync.branch` | Target branch for synchronization data | `main` |
| `sync.path` | File path in repository storing synchronized library data | `data.json` |

---

## Build & Development

### Prerequisites

- **GHC 9.8.2** & **Cabal 3.10+** (via [GHCup](https://www.haskell.org/ghcup/))
- **Rust Stable** (via [rustup](https://rustup.rs/))
- **Just** task runner (optional, recommended: `cargo install just`)

### Build Commands

```sh
# One-step build: compiles both Rust and Haskell, and syncs sena-guard.exe
just build

# Or manually:
cargo build --release
cabal build
copy target\release\sena-guard.exe (dist-newstyle\..\SenaVN.exe directory)

# Run full test suite (51 unit tests)
cabal test

# Check code formatting & compiler warnings
cargo clippy --all-targets -- -D warnings
cabal build --enable-tests --ghc-options="-Werror"
```

---

## About

`Sena` is named after **姬野星奏 (Himeno Sena)**, the heroine from the visual novel [*恋×シンアイ彼女 (Koi x Shin Ai Kanojo)*](https://vndb.org/v17516).

---

## License

This project is licensed under the **GNU General Public License v3.0** — see the [LICENSE](LICENSE) file for details.
