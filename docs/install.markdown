---
title: Installation
---

# Installation Guide

## Quick Install (Windows One-Liner)

Install SenaVN directly via PowerShell without administrative privileges:

```powershell
irm https://raw.githubusercontent.com/biyuehu/vn-cli/main/install.ps1 | iex
```

### What this does

1. Queries GitHub Releases API for the latest release.
2. Downloads `sena-x86_64-windows.exe` and saves it as `~/.senavn/bin/sena.exe` (and `SenaVN.exe`).
3. Downloads `sena-guard-x86_64-windows.exe` and saves it as `~/.senavn/bin/sena-guard.exe`.
4. Appends `~/.senavn/bin` to the user's persistent `PATH` environment variable.
5. Refreshes current session `$env:PATH`.

---

## Manual Installation

1. Navigate to [GitHub Releases](https://github.com/biyuehu/vn-cli/releases).
2. Download:
   - `sena-x86_64-windows.exe` (rename to `sena.exe`)
   - `sena-guard-x86_64-windows.exe` (rename to `sena-guard.exe`)
   - `LICENSE`
3. Place both executables in the **same directory** (e.g. `C:\Tools\SenaVN` or `%USERPROFILE%\.senavn\bin`).
4. Add that directory to your system or user `PATH`.

---

## Building from Source

### Prerequisites

- **GHC 9.8.2** & **Cabal 3.10+** (via [GHCup](https://www.haskell.org/ghcup/))
- **Rust Stable** (via [rustup](https://rustup.rs/))
- **Just** task runner (optional: `cargo install just`)

### Build Commands

```sh
git clone https://github.com/biyuehu/vn-cli.git
cd vn-cli

# Compiles Rust daemon and Haskell CLI, then syncs sena-guard.exe to dist directory
just build
```

Run test suite:

```sh
cabal test
```
