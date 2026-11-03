# Agent Guidelines & Operational Rules

本文件为所有在此代码库工作的 AI Agent 必须无条件遵守的最高行为准则与技术红线。

---

## 1. 依赖与工具链约束 (Dependencies & Toolchain)

- **严禁私自引入未授权依赖**：优先使用标准库（Haskell `base`、Rust `std`）实现功能。严禁擅自在 `.cabal`、`Cargo.toml` 中增加未经用户明确许可的第三方包。
- **严禁擅自清除构建缓存**：严禁随意执行 `cabal clean`、`cargo clean` 等破坏本地增量编译产物（`dist-newstyle`、`.hi`/`.hie`）的命令。
- **禁止暴力打断工具链进程**：后台编译与 LSP 初始化为异步长任务，严禁频繁执行 `kill` / `Stop-Process` 重启 HLS 或 Cabal，杜绝人为制造重启死锁。
- **锁定 HLS 单组件模式**：本项目核心模块均集中于 `lib:SenaVN`，VS Code 中必须严格锁定 `haskell.sessionLoading: singleComponent` 与 `haskell.componentsLoading: single`，禁止启用会导致两次全量重复编译的多组件推导。
- **禁止私自创建 Cradle 配置**：严禁擅自新增或随意篡改 `hie.yaml`、`cabal.project` 等全局构建映射文件。

---

## 2. 工作区与版本控制边界 (Workspace & Git Boundaries)

- **严禁干预用户工作区状态**：
  - 严禁擅自执行 `git checkout -- <file>` 或 `git restore <file>` 还原工作区改动（包括用户主动删除的文件）。
  - 用户未暂存的修改一律视为用户意图，未经明确许可绝不私自覆盖或回滚。
- **禁止生成临时垃圾文件**：严禁在工作区根目录或代码树中随意创建 `test_*.hs` 等一次性调试脚本。
- **禁止重复执行自动化工作流**：项目已配置 Git 钩子（如 `lefthook`），在执行 `git commit` 前严禁画蛇添足手动全量执行 hook 脚本。
- **未经许可严禁提交**：严禁私自执行 `git commit` 或 `git push`，所有提交必须经由用户明示。

---

## 3. 代码质量与编译规范 (Code Quality & Constraints)

- **零编译器警告**：代码必须始终满足 `-Wall` 与 `-Werror`，零编译错误，零 HLint 警告。
- **原生终端兼容原则**：终端与控制台适配一律基于标准库（如 `System.IO.hIsTerminalDevice`、读取 `COLUMNS` 环境变量与合法 clamp 范围），禁止强依赖外部控制台包。

---

## 4. 沟通与交互准则 (Communication & Execution)

- **喊停立即彻底停手**：当用户给出“停手”、“别动”、“闭嘴”等指令时，必须立刻中断所有工具调用和终端命令，严禁任何偷跑探测的侥幸心理。
- **听懂核心诉求，杜绝答非所问**：
  - 用户指出是历史改动导致的问题，必须直接溯源提交历史与环境污染点，严禁拿当前未暂存的 diff 敷衍搪塞。
  - 绝不把体验劣化（如分钟级卡顿）美化为“正常现象”或“固定开销”，必须客观以日志时间戳与事实说话。
- **实事求是，禁止主观脑补**：不清楚的事项直接请示用户，严禁将自己的臆测作为既定事实采取行动。
