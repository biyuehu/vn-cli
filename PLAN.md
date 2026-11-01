# PLAN.md — SenaVN (sena-cli)

> 交接文档：项目背景、已定设计、当前状态、待办。改动前请先通读第 4、5 节（已定设计，不要推翻）。

## 1. 项目概述

- 终端版 gal 管理 + 游戏计时 + 云同步，**仅 Windows**，命令名 `sena`。
- 是已 archive 的 nano（react/tauri/rust/fluentui）的 2.0 重构：**数据结构和逻辑沿用**，换成纯 CLI。
- 刻意面向 coder：无 GUI、配置门槛不降（GitHub token 等）。
- 栈：Haskell（GHC 9.8.4 / cabal）主程序 + Rust `foo.exe` + SQLite（WAL）。
- 功能：VNDB 抓取元信息、游玩计时、GitHub 仓库云同步（同步尚未实现）。

## 2. 架构

两个独立二进制，**无 FFI**，通过文件通信，发布时放同一目录。

- `sena`（Haskell）：业务逻辑、CLI、数据库、输出。**不直接碰 Windows API**。
- `foo.exe`（Rust）：所有 Windows 底层脏活。
  - `foo --run --game-id <id> --game-name <n> --exe-path <p> --session <file>`：启动并监听一个游戏进程。一个 foo 对应一个游戏，可同时存在多个。
  - `foo --check-pid <pid>`：exit 0 = 存活，1 = 已死，2 = 参数错误。
- foo 不依赖 SQLite、不写 DB，只写 session 文件。

模块（src/SenaVN/）：Command（optparse 解析）、Handler（各命令逻辑）、Core（`Romi = ReaderT Env (ExceptT Text IO)`，`throwR`，`askConn`）、DB、Session、Api（VNDB）、Pretty（终端输出）、Types、Utils。Rust：src/main.rs、src/session.rs。

## 3. 数据模型

- DB：`~/.senavn/sena.db`，`journal_mode=WAL`，`foreign_keys=ON`，`initDB` 建表。
- 表：`games`、`local_paths`、`play_sessions`（已去掉 `game_aliases`/`game_tags`/`game_images`/`game_links` 这 4 个附属碎片表，收拢为 games 主表内的 JSON array 字段）。
- `play_sessions.id = <gameId>-<startTime>`，upsert 幂等；游玩记录为 `(start, end, duration)` 列表，**不存累加总时长**。
- 总时长 = DB 中 duration 之和 + 正在运行的 session 的 activeTime。
- Haskell 类型沿用 nano：`GameCore`、`LocalPath`、`GameWithLocal`、`PlayTimeline`、`FetchGameData`（VNDB 结果）。
- `Types.hs` 里的 `RootState`、`CloudData`、`AppConfig` 是旧模型，待同步/配置设计时重做。

## 4. Session 协议（已定）

- 路径：`<appdir>/sessions/<gameId>.session.json`，每个 foo 只写自己的文件，无竞争。
- 字段（camelCase，Aeson 与 serde 对齐）：`gameId, startUnix, lastHeartbeatUnix, activeSeconds, fooPid`。`startUnix` 启动时确定且不变；`lastHeartbeatUnix` 即 stop_time 的近似；foo 每 60s 原子写（写 .tmp 再 rename）。
- 判活：session 存在 + `foo --check-pid <fooPid>` 存活 = 正在玩；存在但已死 = 补录；不存在 = 没在玩。
- reconcile（sena 在 run/list/info/stat/tl 等命令前执行）：对每个已死的 session，`upsertPlaySession(gameId, startUnix, lastHeartbeatUnix, activeSeconds)`，`updateLastPlay`，再删 session 文件。幂等，不论 foo 正常退出还是崩溃都走同一路径。
- 取舍：不让 foo 最终写库，避免 foo 依赖 SQLite 与并发写；DB 单写者是 sena。
- DB 函数全部保持 `IO`，Handler 里 `liftIO`；只有 Handler 和 `openEditor` 在 `Romi`。

## 5. 命令语义（已定）

原则：**元信息 options 与 editor 互斥；参数 > editor > fetch**，无隐含潜规则。

add `<name> <id> [path]`：

- 带任意 meta option → 直接保存，不 fetch、不 editor（脚本用）。
- 默认 → fetch（`--order N`，默认 1）→ editor 确认；`--skip` 跳过 editor；`--no-fetch` 跳过 fetch；`--keep-name` 保留手输名称。

edit `<id>`：

- 带 meta option → 定点保存，不开 editor。
- 无参数 → editor（预填当前数据）；`--fetch` → 抓取后进 editor；`--fetch --apply` → 抓取后直接保存。

其它：

- `fetch <q> [--order N]`：纯展示。0 = 全部，N = 第 N 条详情；不改本地数据。
- `run <id> | --random | --recent | --last`：四选一。启动 foo 后 sena 立即退出（不常驻）。
- `status` 读 session 显示运行中游戏；`use <id> <exe> [--save --guide]`；`rm <id>`；`list/stat/tl/info`；`sync`、`config` 为桩。
- 编辑器：优先 `$VISUAL` → `$EDITOR` → PATH 中依次找 nvim/vim/nano/vi；**都没有就报错，不要用 notepad 兜底**。临时文件用 `encodePretty` 格式化的 JSON，必须 `waitForProcess` 退出后再读，解析失败给出明确错误。
- 破坏性操作（rm）用 haskeline 做 `[y/N]` 确认。

## 6. 工程约定与已踩过的坑

- 全面用 `Text`，`OverloadedStrings`，`OverloadedRecordDot`（已在 cabal `default-extensions`）；字段重名靠 dot 语法 + `DuplicateRecordFields`。
- `where` 里的局部函数写显式类型签名（否则触发 `HasField` 的 FlexibleContexts 报错）。
- sqlite-simple 的 `ToRow` 元组最多 10 个，更长用 `(a,..) :. (b,..)` 连接。
- 输出统一走 prettyprinter（Pretty.hs 的 `render`/`printXxx`），风格一致：dim 标签、cyan 标识、green 成功、`✓ ✗ ▶ ●` 状态符号。
- Windows 编码：`app/Main.hs` 用 CPP 条件编译，仅在 `mingw32_HOST_OS` 下 FFI 调 `SetConsoleOutputCP(65001)`，再 `hSetEncoding` 为 utf8。**不要让用户手动 chcp。**
- 构建：`cabal build` + `cargo build --release`，foo.exe 放在 sena.exe 同目录，Haskell 侧用 `getExecutablePath` 定位。

## 7. 当前状态

已完成：Command 解析与分支逻辑、DB schema 与 CRUD、Session 读写与 reconcile、VNDB 抓取、Pretty 输出、Romi/Env、foo 的 `--run` 与 `--check-pid`、Windows UTF-8。

未进仓库（Handler 仍为旧版）：editor 改造、`spawnFoo` 改造、rm 确认提示。

## 8. 待办

### P0（主链路 add → run → 退出 → list 目前跑不通）

1. [x] **`spawnFoo` 与 foo 参数不匹配**：Handler 没传 `--run`，foo 直接 usage 退出。改为 `spawnProcess`/`createProcess`，第一个参数 `--run`，用 `getExecutablePath` 同目录定位 foo.exe；`Session.getFooPath` 同样改（目前假定在 PATH）。Windows 下 detach（`detach_console = True`，必要时 `create_new_console`），使 foo 不随终端关闭。
2. [x] **SessionData 字段不一致**：Haskell 有 `exePath`，Rust 没有，Aeson 解析必败，且 `listSessions` 吞掉错误导致 status 永远为空、reconcile 不生效。决议：删除 Haskell 侧 `exePath`（foo 用不到）。
3. [x] **foo 正常退出会丢时长**：`run()` 结尾删了 session 但没人写库。改为 foo 退出时只写最终快照、**不删文件**，由 sena reconcile 入库后删除。`run` 启动前应拒绝“该游戏 session 已存在且 foo 存活”（防重复启动、防覆盖）。
4. [x] **`applyMeta` 的 vndbId**：`m.metaVndbId <> g.vndbId` 会把两个 `Just` 拼成 `"v2v1"`，改 `<|>`（`Control.Applicative`）。
5. [x] **VNDB 请求缺 `description`**：`Api.fetchFromVndb` 的 fields 补上，否则简介永远为空。
6. [x] **editor 实现**：按第 5 节落地（替换 `openEditor`）；编辑后**强制恢复原 `coreId`、`createDate`、`playTimelines`**，防止在 editor 里改坏主键/外键。
7. [x] **rm 确认**：haskeline `[y/N]`。

### P1（健壮性）

- [x] 错误出口：`Left err` 写 stderr 并 `exitFailure`；`Fetch` 的 `invalid --order` 也要非 0 退出；`main` 外层 `catch` SQL/HTTP/IO 异常，输出友好信息。
- [x] VNDB 数据：`parseDateToTimestamp` 现用 365/30 天估算且只认 `YYYY-MM-DD`，用 `Data.Time.parseTimeM` 多格式回退（`YYYY-MM`、`YYYY`、`TBA`→0）；`released` 改 `Maybe Text`；请求 `tags.spoiler` 并过滤剧透；捕获 `req` 的 HTTP 异常。
- [x] Session 读取：`eitherDecodeFileStrict` 外包 `try` / 安全重试（防止 foo rename 瞬间的文件锁竞争）。
- [x] foo：用 `Instant` 累加真实高精度间隔代替 `active_time += 1`，只刷新目标 pid；记录进程启动时间做 PID 复用防护。
- [x] Schema 精简：去掉附属表（aliases/tags/images/links），收拢为 games 表内的 array 字段。
- DB：`PRAGMA busy_timeout`；`PRAGMA user_version` 迁移机制（同步阶段要加墓碑表）。
- 非 TTY 输出（管道/重定向）用 `hSupportsANSI` 判断，退化为 `unAnnotate`。

### P2（功能）

- [x] 总时长合并运行中 session；`list`/`info` 动态展示当前正在玩的 session 时长与进度；`statusDot` 增加“正在玩”高亮。
- [x] `stat` 做真正统计（全库统计看板、通关率、Top 5 排行条形图、单游戏对比看板）。
- [x] `sena mv <old-id> <new-id>`：安全重命名主键，同步修改 local_paths, play_sessions 及 session 临时文件。
- [x] `run` 的短选项改为 `-R`=recent，支持 `--filter <dsl>` 与 shortcut。
- **Filter DSL**：独立设计，供 list/stat/tl/run 共用（当前所有 filter 参数为空操作）。
- **Config**：先定存储位置（独立配置文件还是 DB settings表）；token 不得进同步数据。
- **Sync**：基于 GitHub repo + API，对应 `CloudData`；需要删除墓碑表（`Remove --hard` 目前无意义，两种行为相同）。
- `sena import`：读取旧 `data.json`（旧 `RootState`），方便用真实数据自测。
- 交互式提问 wizard（haskeline）作为 add/edit 的可选模式（`--interactive`）。

### P3（以后）

- TUI（brick）：tree 形式，顶级节点为子命令，展开后为游戏；只做可选浏览层，不替代 CLI。
- [x] 清理：Cargo.toml 的 `roga` 未使用；`src/lib.rs`、`src/utils/*` 若为旧 tauri 代码则删除（否则 cargo 会尝试编译 lib target）；justfile 的 `build` 需同时跑 cargo 并复制 foo.exe；README TODO 同步更新。
- 测试：`applyMeta`、`applyFetch`、`pickResult`、日期解析、session JSON 往返、reconcile 都是纯函数/易隔离，优先补测。

## 9. 建议顺序

P0 全部（先通主链路并手动验证 add → run → 退出 → list → status）→ P1 → P2（先 Config 存储位置再 Sync）→ P3。
