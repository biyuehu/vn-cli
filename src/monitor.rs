use std::fs;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use sysinfo::{Pid, ProcessesToUpdate, System};

use crate::session::SessionData;
use crate::win::is_window_active;

pub fn now_secs() -> u64 {
  SystemTime::now()
    .duration_since(UNIX_EPOCH)
    .unwrap_or_default()
    .as_secs()
}

pub struct Monitor {
  game_id: String,
  session_file: String,
  start_time: u64,
  active_time: u64,
  pid: Pid,
}

impl Monitor {
  pub fn new(game_id: String, session_file: String, pid: u32) -> Self {
    Self {
      game_id,
      session_file,
      start_time: now_secs(),
      active_time: 0,
      pid: Pid::from_u32(pid),
    }
  }

  /// 写 session 文件（原子写：先写 .tmp 再 rename）
  pub fn write_session(&self) {
    let sd = SessionData {
      game_id: self.game_id.clone(),
      start_unix: self.start_time as i64,
      last_heartbeat_unix: now_secs() as i64,
      active_seconds: self.active_time as i64,
      foo_pid: std::process::id() as i64,
    };
    let tmp = format!("{}.tmp", self.session_file);
    if let Ok(json) = serde_json::to_string(&sd) {
      let _ = fs::write(&tmp, json);
      let _ = fs::rename(&tmp, &self.session_file);
    }
  }

  /// 主监听循环
  pub fn run(&mut self) {
    let mut sys = System::new();
    let heartbeat_interval = 60u64; // 每 60 秒写一次 session
    let mut last_heartbeat = now_secs();

    // 先写一次，让 sena status 能立即看到
    self.write_session();

    loop {
      // 99.9% 正常游玩时间：只定向刷新当前游戏这一个 PID，CPU 占用为 0
      sys.refresh_processes(ProcessesToUpdate::Some(&[self.pid]), true);

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
        // 目标进程退出，全量刷新一次尝试找子进程（部分 gal 启动器会 spawn 子进程）
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

    // 最终写一次完整数据快照，保留给 sena reconcile 入库后删除，foo 自身绝不删 session
    self.write_session();
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
