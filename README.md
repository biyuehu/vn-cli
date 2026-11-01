# SenaVN | GalKeeper v2.X

![GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue?style=flat-square) ![Haskell](https://img.shields.io/badge/Haskell-5D4F85?style=flat-square&logo=haskell&logoColor=white) ![Rust](https://img.shields.io/badge/Rust-000000?style=flat-square&logo=rust&logoColor=white) ![Windows](https://img.shields.io/badge/Windows-deepskyblue?style=flat-square&logo=linux&logoColor=white) ![Codeberg](https://img.shields.io/badge/Codeberg-2185D0?style=flat-square&logo=codeberg&logoColor=white)

A Visual Novel Management System In Terminal.

> This project is still in development.

## TODO

- [x] Improve `list` tui (more details, bar line)
- [x] 去掉 4 个附属碎片表（game_aliases/game_tags/game_images/game_links），收拢为 games 主表内的 array 字段
- [x] spawnFoo 加 DETACHED_PROCESS flag，让 foo.exe 和 sena 完全脱钩
- [x] openEditor 的 createProcess 改用 callProcess 阻塞等待退出后再读取
- [x] confirmation prompt（rm 确认提示）
- [x] sena mv <old-id> <new-id> 重命名游戏主键（级联更新本地配置、会话与历史记录）
- [ ] Config、Sync、filterDsl 这几个留着以后填
