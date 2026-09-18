# SenaVN | GalKeeper v2.X

![GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue?style=flat-square) ![Haskell](https://img.shields.io/badge/Haskell-5D4F85?style=flat-square&logo=haskell&logoColor=white) ![Rust](https://img.shields.io/badge/Rust-000000?style=flat-square&logo=rust&logoColor=white) ![Windows](https://img.shields.io/badge/Windows-deepskyblue?style=flat-square&logo=linux&logoColor=white) ![Codeberg](https://img.shields.io/badge/Codeberg-2185D0?style=flat-square&logo=codeberg&logoColor=white)

A Visual Novel Management System In Terminal.

> This project is still in development.

## TODO

- [ ] Improve `list` tui (more details, bar line)

- [ ] getAppDir 换成 Windows %APPDATA%\sena（System.Win32 或读环境变量）
- [ ] spawnFoo 加 DETACHED_PROCESS flag，让 foo.exe 和 sena 完全脱钩
- [ ] openEditor 的 createProcess 需要等编辑器退出后再读文件，目前 createProcess 不等待，要改成 callProcess editor [path]
- [ ] Config、Sync、confirmation prompt、filterDsl 这几个留着以后填
