<!-- markdownlint-disable MD013 MD033 MD041 -->

<div align="center">

# SenaVN | GalKeeper 2.0

**A terminal-first Visual Novel library manager, gameplay tracker, and GitHub cloud synchronizer.**

t is designed for programmers and geeks who play visual novel games. They prefer staying in the terminal without running bulky Electron or heavy GUI managers in the background.

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

- **Hardcore & Cool**: Pure terminal-first, keyboard-driven experience with sleek ANSI aesthetics, blazing-fast responsiveness and based functional programming Haskell!
- **Zero GUI Overhead**: Run `sena` for a full-featured interactive TUI, use concise CLI subcommands for shell scripting and aliases, and use terminal file picker without manually typing paths.
- **Seamless VNDB Integration**: Search visual novels directly by name or ID, interactively select search results, and review/edit metadata inside your preferred `$EDITOR` before saving.
- **3-Way Cloud Synchronization**: End-to-end sync with GitHub repositories based GitHub API. And decoupled local paths, only metadata is pure and cloud-synced.
- **Git-Log Style Timelines**: Visualize play history with ASCII graphs and summary statistics.
- **Native Windows Adaptation**: Automatic UTF-8 (`CP65001`) console output switching without needing manual `chcp`, with full support for ANSI styling and color themes.

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

## Usage

Please refer to [SenaVN Document](https://vn.himeno-sena.com/).

---

## Build & Development

- **GHC 9.8.2** & **Cabal 3.10+** (via [GHCup](https://www.haskell.org/ghcup/))
- **Rust Stable** (via [rustup](https://rustup.rs/))
- **Just** task runner (optional, recommended: `cargo install just`)

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
