use std::fs;
use std::path::Path;
use std::process::Command;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use sysinfo::{Pid, ProcessesToUpdate, System};
use winapi::um::winuser::{GetForegroundWindow, GetWindowThreadProcessId};

mod session;
use session::SessionData;

// ────────────────────────────────────────────
// CLI args
// ────────────────────────────────────────────

#[derive(Debug)]
enum Mode {
    /// 启动并监听一个游戏进程
    Run {
        game_id: String,
        game_name: String,
        exe_path: String,
        session_file: String,
    },
    /// 检查一个 PID 是否存活（exit 0 = 存活，exit 1 = 死亡）
    CheckPid { pid: u32 },
}

fn parse_args() -> Result<Mode, String> {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(|s| s.as_str()) {
        Some("--check-pid") => {
            let pid = args
                .get(2)
                .ok_or("--check-pid requires a PID argument")?
                .parse::<u32>()
                .map_err(|_| "invalid PID")?;
            Ok(Mode::CheckPid { pid })
        }
        Some("--run") => {
            // --run --game-id <id> --game-name <name> --exe-path <path> --session <file>
            let get = |flag: &str| -> Result<String, String> {
                args.windows(2)
                    .find(|w| w[0] == flag)
                    .map(|w| w[1].clone())
                    .ok_or_else(|| format!("missing {}", flag))
            };
            Ok(Mode::Run {
                game_id: get("--game-id")?,
                game_name: get("--game-name")?,
                exe_path: get("--exe-path")?,
                session_file: get("--session")?,
            })
        }
        _ => Err("usage: foo.exe --run ... | foo.exe --check-pid <pid>".to_string()),
    }
}

// ────────────────────────────────────────────
// 时间工具
// ────────────────────────────────────────────

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

// ────────────────────────────────────────────
// PID 存活检查
// ────────────────────────────────────────────

fn is_pid_alive(pid: u32) -> bool {
    let mut sys = System::new();
    sys.refresh_processes(ProcessesToUpdate::All, true);
    sys.process(Pid::from_u32(pid)).is_some()
}

// ────────────────────────────────────────────
// 窗口是否在前台
// ────────────────────────────────────────────

fn is_window_active(pid: u32) -> bool {
    unsafe {
        let hwnd = GetForegroundWindow();
        if hwnd.is_null() {
            return false;
        }
        let mut foreground_pid: u32 = 0;
        GetWindowThreadProcessId(hwnd, &mut foreground_pid);
        foreground_pid == pid
    }
}

// ────────────────────────────────────────────
// 监听核心
// ────────────────────────────────────────────

struct Monitor {
    game_id: String,
    session_file: String,
    start_time: u64,
    active_time: u64,
    pid: Pid,
}

impl Monitor {
    fn new(game_id: String, session_file: String, pid: u32) -> Self {
        let start = now_secs();
        Self {
            game_id,
            session_file,
            start_time: start,
            active_time: 0,
            pid: Pid::from_u32(pid),
        }
    }

    /// 写 session 文件（原子写：先写 .tmp 再 rename）
    fn write_session(&self) {
        let sd = SessionData {
            game_id: self.game_id.clone(),
            start_time: self.start_time as i64,
            last_heartbeat: now_secs() as i64,
            active_time: self.active_time as i64,
            foo_pid: std::process::id() as i64,
        };
        let tmp = format!("{}.tmp", self.session_file);
        if let Ok(json) = serde_json::to_string(&sd) {
            let _ = fs::write(&tmp, json);
            let _ = fs::rename(&tmp, &self.session_file);
        }
    }

    /// 删 session 文件（foo 正常退出时调用）
    fn delete_session(&self) {
        let _ = fs::remove_file(&self.session_file);
    }

    /// 主监听循环
    fn run(&mut self) {
        let mut sys = System::new_all();
        let heartbeat_interval = 60u64; // 每 60 秒写一次 session
        let mut last_heartbeat = now_secs();

        // 先写一次，让 sena status 能立即看到
        self.write_session();

        loop {
            sys.refresh_processes(ProcessesToUpdate::All, true);

            if sys.process(self.pid).is_some() {
                // 进程还活着
                if is_window_active(self.pid.as_u32()) {
                    self.active_time += 1;
                }

                let now = now_secs();
                if now - last_heartbeat >= heartbeat_interval {
                    self.write_session();
                    last_heartbeat = now;
                }

                thread::sleep(Duration::from_secs(1));
            } else {
                // 目标进程退出，尝试找子进程（部分 gal 启动器会 spawn 子进程）
                sys.refresh_processes(ProcessesToUpdate::All, true);
                if let Some(child_pid) = self.find_child(&sys) {
                    eprintln!("[foo] parent exited, following child pid={}", child_pid);
                    self.pid = child_pid;
                    thread::sleep(Duration::from_secs(1));
                } else {
                    // 真正退出
                    eprintln!("[foo] process exited. active={}s", self.active_time);
                    break;
                }
            }
        }

        // 最终写一次完整数据，然后删 session 文件
        // sena 在 reconcile 时会读这次最终数据写入 DB
        // 但 foo 正常退出时直接自己写 DB 更干净 —— 这里先保留 session 删除
        // TODO：可选：在这里直接用 rusqlite 写入 DB，然后 delete_session
        self.write_session();
        self.delete_session();
    }

    fn find_child(&self, sys: &System) -> Option<Pid> {
        for (pid, process) in sys.processes() {
            if process.parent() == Some(self.pid) {
                return Some(*pid);
            }
        }
        None
    }
}

// ────────────────────────────────────────────
// main
// ────────────────────────────────────────────

fn main() {
    match parse_args() {
        Err(e) => {
            eprintln!("error: {}", e);
            std::process::exit(2);
        }

        Ok(Mode::CheckPid { pid }) => {
            if is_pid_alive(pid) {
                std::process::exit(0); // 存活
            } else {
                std::process::exit(1); // 死亡
            }
        }

        Ok(Mode::Run {
            game_id,
            game_name,
            exe_path,
            session_file,
        }) => {
            eprintln!("[foo] launching: {} ({})", game_name, exe_path);

            // 启动游戏进程
            let child = Command::new(&exe_path)
                .current_dir(
                    Path::new(&exe_path)
                        .parent()
                        .unwrap_or_else(|| Path::new(".")),
                )
                .spawn();

            match child {
                Err(e) => {
                    eprintln!("[foo] failed to launch: {}", e);
                    std::process::exit(1);
                }
                Ok(child) => {
                    let pid = child.id();
                    eprintln!("[foo] pid={}", pid);
                    let mut monitor = Monitor::new(game_id, session_file, pid);
                    monitor.run();
                }
            }
        }
    }
}
