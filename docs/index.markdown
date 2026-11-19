---
title: Home
---

# SenaVN | GalKeeper 2.0

A terminal-first Visual Novel library manager, gameplay tracker, and GitHub cloud synchronizer.

It is designed for programmers and geeks who play visual novel games, they prefer staying in the terminal without running bulky Electron or heavy GUI managers in the background.

Built with **Haskell (GHC 2021)** and a lightweight **Rust daemon (`sena-guard`)**.

---

## Why SenaVN?

- **Hardcore & Cool**: Pure terminal-first, keyboard-driven experience with sleek ANSI aesthetics, blazing-fast responsiveness and based functional programming Haskell!
- **Zero GUI Overhead**: Run `sena` for a full-featured interactive TUI, use concise CLI subcommands for shell scripting and aliases, and use terminal file picker without manually typing paths.
- **Seamless VNDB Integration**: Search visual novels directly by name or ID, interactively select search results, and review/edit metadata inside your preferred `$EDITOR` before saving.
- **3-Way Cloud Synchronization**: End-to-end sync with GitHub repositories based GitHub API. And decoupled local paths, only metadata is pure and cloud-synced.
- **Git-Log Style Timelines**: Visualize play history with ASCII graphs and summary statistics.
- **Native Windows Adaptation**: Automatic UTF-8 (`CP65001`) console output switching without needing manual `chcp`, with full support for ANSI styling and color themes.

---

## Quick Installation

Install SenaVN with a single command:

```powershell
irm https://raw.githubusercontent.com/biyuehu/vn-cli/main/install.ps1 | iex
```

This installs `sena.exe` and `sena-guard.exe` into `~/.senavn/bin` and adds it to your user `PATH`.

---

## About

`Sena` is named after **姬野星奏 (Himeno Sena)**, the heroine from the visual novel [*恋×シンアイ彼女 (Koi x Shin Ai Kanojo)*](https://vndb.org/v17516).
