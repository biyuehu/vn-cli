# set windows-shell := ["powershell.exe"]

default:
  @just --list

dev:
  bun x nodemon --exec 'cabal run' --ext .hs

build:
  cabal build