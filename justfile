set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

default:
  @just --list

dev:
  bun x nodemon --exec 'cabal run' --ext .hs

[windows]
build:
  cargo build --release
  cabal build
  $daemon = "sena-guard.exe"; \
  $senaDir = (Get-ChildItem -Path dist-newstyle -Recurse -Filter "SenaVN.exe" -ErrorAction SilentlyContinue | Select-Object -First 1).DirectoryName; \
  if ($senaDir -and (Test-Path "target/release/$daemon")) { \
    Copy-Item -Path "target/release/$daemon" -Destination $senaDir -Force; \
    Write-Host "[just] Synced $daemon to $senaDir" \
  }

[unix]
build:
  cargo build --release
  cabal build
  #!/usr/bin/env bash
  set -euo pipefail
  sena_dir=$(find dist-newstyle -type f -name SenaVN 2>/dev/null | head -n 1 | xargs -r dirname)
  if [ -n "$sena_dir" ] && [ -f "target/release/sena-guard" ]; then
    cp -f target/release/sena-guard "$sena_dir/"
    echo "[just] Synced sena-guard to $sena_dir"
  fi
