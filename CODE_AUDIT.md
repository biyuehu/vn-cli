<!--
  ====================================================================================
  [WARNING / 警告] FOR AI AGENTS:
  DO NOT READ, REFERENCE, PARSE, OR UTILIZE ANY CONTENTS OF THIS FILE WITHOUT EXPLICIT
  AND DIRECT PERMISSION FROM THE USER.
  严禁任何 AI 助手在未经用户显式授权的情况下，私自读取、引用、反思或依据本文件中的任何内容！
  ====================================================================================
-->

# SenaVN 源码深度审计与缺陷分析报告

> 本文档记录了对当前代码库源码（`src/`、`app/`、`justfile`、`.github/`）的纯代码层实际缺陷、未竟逻辑与性能隐患分析。

---

## 一、 业务执行层（`Handler.hs` & `Command.hs`）

1. **参数虚设丢弃（`Handler.hs:533, 556, 568`）**
   - `handle List`、`handle Stats`、`handle Timeline` 均在形参中以通配符形式忽略了参数：`listFilter = _`、`statsFilter = _`、`tlFilter = _`。
   - 命令行在定义中接收了 `-f / --filter`，但在 Handler 逻辑中被彻底丢弃，条件过滤功能当前为零实现。

2. **未实现空桩（`Handler.hs:638, 641`）**
   - `handle Sync` 仅有一行 `throwR "sync not yet implemented"`。
   - `handle Config` 仅有一行 `throwR "config not yet implemented"`。

3. **未完成逻辑残留（`Handler.hs:398`）**
   - `handle Remove` 中，`removeHard` 参数仅在输出提示后拼接了一句 `(TODO: cloud remove)`，底层调用均为同一套数据库删除，硬删除与普通删除没有任何实际行为区分。

4. **CLI 参数解析缺陷与不对称（`Command.hs:89, 372`）**
   - `cfgParser` 强制要求同时输入两个参数（`Config <$> argument str <*> argument str`），无法支持无参列出全部已有配置，也无法支持单参查询某个指定配置的值。
   - `run` 命令支持 `--random`，但在参数定义层缺少 `--filter` 选项，无法实现“在符合特定条件的游戏中随机挑选运行”。

---

## 二、 数据访问层（`DB.hs`）

1. **严重 I/O 放大与 N+1 查询链（`DB.hs:205-215`）**
   - `getAllGamesWithLocal` 先全表查询 `games`。
   - 随后进入循环，为每款游戏单独发起一次 SQL 查询 `play_sessions`（拼接入 `GameCore`）。
   - 再发起一次独立 SQL 查询 `local_paths`（获取本地路径）。
   - 若库内有 50 款游戏，执行一次查看列表或全库统计将触发 `1 + 50 + 50 = 101` 次独立 SQL 往返。应通过 `LEFT JOIN` 与批量查询在内存中映射来消除 I/O 放大。

2. **缺少配置存储介质**
   - `sena.db` 目前仅有 `games`、`local_paths`、`play_sessions` 三张表，未设计任何用于持久化本地配置/凭据的表结构。

3. **缺少连接超时保护（`DB.hs:51`）**
   - `withDB` 仅配置了 `PRAGMA journal_mode=WAL` 和 `PRAGMA foreign_keys=ON`，未设置 `PRAGMA busy_timeout`。在同机多进程并发读写时，极易直接抛出 SQLite 锁库异常。

4. **未被消费的死代码（`DB.hs:295`）**
   - `deleteLocalPath :: Connection -> Text -> IO ()` 定义并导出，但全工程从未被调用（`local_paths` 表已依赖外键 `ON DELETE CASCADE` 自动级联清理）。

---

## 三、 网络与外部接口层（`Api.hs`）

1. **主图字段抓取后被丢弃（`Api.hs:29, 84`）**
   - VNDB 请求的 `fields` 中声明了 `image.url` 与 `screenshots.url`。
   - 但在 `VNRawItem` 映射及 `transformVNData` 组装中，`imgList` 仅提取了 `screens`（截图列表），导致封面主图（`image.url`）抓取后从未被写入数据库。

2. **异常穿透与无超时约束（`Api.hs:72`）**
   - `fetchFromVndb` 直接调用 `runReq defaultHttpConfig`，缺少网络连接与读取超时限制。
   - 断网、DNS 故障或触发 VNDB 限流（429）时，直接向顶层抛出裸的 `HttpException` 崩溃报错，缺乏业务层语义包装。

---

## 四、 跨进程协调（`Session.hs` & `foo.exe`）

1. **多终端并发下的 Session 文件竞争（`Session.hs:141`）**
   - `reconcileSessions` 在所有关键命令执行前均会触发。
   - 若用户同时在两个终端运行 `sena`，会同时触发扫描 `.session.json`。虽有 `readSafe` 的文件锁读取重试，但写 DB 与删文件之间存在竞争窗口，会导致冗余重复写入。

2. **开发调试态下的 `foo.exe` 寻址缺陷（`Session.hs:126`）**
   - `getFooPath` 优先查找 `selfExe` 同目录下的 `foo.exe`，否则回退到系统 `PATH`。
   - 使用 `cabal run` 调试时，二进制位于 `dist-newstyle\build\...\SenaVN.exe`，该目录下默认不存在 `foo.exe`。若用户环境变量未配置 `foo.exe`，启动游戏将直接报错退出。

---

## 五、 类型定义层（`Types.hs`）

1. **废弃死代码残留（`Types.hs:62-81`）**
   - 存在 20 行已被注释的历史遗留结构体（`CloudData`、`AppConfig`、`RootState`），未彻底清理。

2. **职责边界混乱（`Types.hs:83-108`）**
   - `VNRawItem`、`VNTitle`、`VNScreenshot`、`VNTag`、`VNDeveloper`、`VNExtLink`、`VNResponse` 等仅用于 `Api.hs` 反序列化的底层网络协议私有类型，全部堆放在核心领域模型定义文件 `Types.hs` 中，污染了纯净的领域层。

---

## 六、 构建与持续集成（`justfile` & `ci.yml`）

1. **双语言构建链断裂（`justfile`）**
   - `just build` 仅包含 `cabal build`，未串联 Rust 侧的 `cargo build --release`，也未将 `foo.exe` 产物搬运至 `sena.exe` 同级目录。

2. **CI 测试目标空跑（`.github/workflows/ci.yml:59`）**
   - CI 配置了 `cabal build --enable-tests --ghc-options="-Werror"`。
   - 但 `SenaVN.cabal` 中目前完全没有定义 `test-suite` 区块，导致测试流水线为空跑状态，核心纯逻辑缺乏自动化回归保障。
