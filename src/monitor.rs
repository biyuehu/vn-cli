use std::fs;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
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
  active_seconds: f64,
  pid: Pid,
  proc_start_time: u64,
}

impl Monitor {
  pub fn new(game_id: String, session_file: String, pid: u32) -> Self {
    let mut sys = System::new();
    let target = Pid::from_u32(pid);
    sys.refresh_processes(ProcessesToUpdate::Some(&[target]), true);
    let proc_start_time = sys.process(target).map(|p| p.start_time()).unwrap_or(0);

    Self {
      game_id,
      session_file,
      start_time: now_secs(),
      active_seconds: 0.0,
      pid: target,
      proc_start_time,
    }
  }

  pub fn write_session(&self) {
    let sd = SessionData {
      game_id: self.game_id.clone(),
      start_unix: self.start_time as i64,
      last_heartbeat_unix: now_secs() as i64,
      active_seconds: self.active_seconds.round() as i64,
      guard_pid: std::process::id() as i64,
    };
    let tmp = format!("{}.tmp", self.session_file);
    if let Ok(json) = serde_json::to_string(&sd) {
      let _ = fs::write(&tmp, json);
      let _ = fs::rename(&tmp, &self.session_file);
    }
  }

  pub fn run(&mut self) {
    let mut sys = System::new();
    let heartbeat_interval = 60u64;
    let mut last_heartbeat = now_secs();
    let mut last_tick = Instant::now();

    self.write_session();

    loop {
      sys.refresh_processes(ProcessesToUpdate::Some(&[self.pid]), true);

      let tick_now = Instant::now();
      let dt = tick_now.duration_since(last_tick).as_secs_f64();
      last_tick = tick_now;

      if let Some(proc) = sys.process(self.pid) {
        if self.proc_start_time > 0 && proc.start_time() != self.proc_start_time {
          eprintln!(
            "[sena-guard] PID {} reused by another process, exiting.",
            self.pid
          );
          break;
        }

        if is_window_active(self.pid.as_u32()) {
          self.active_seconds += dt;
        }

        let now = now_secs();
        if now - last_heartbeat >= heartbeat_interval {
          self.write_session();
          last_heartbeat = now;
        }

        thread::sleep(Duration::from_secs(1));
      } else {
        sys.refresh_processes(ProcessesToUpdate::All, true);
        if let Some((child_pid, child_start)) = self.find_child(&sys) {
          eprintln!(
            "[sena-guard] parent exited, following child pid={}",
            child_pid
          );
          self.pid = child_pid;
          self.proc_start_time = child_start;
          last_tick = Instant::now();
          thread::sleep(Duration::from_secs(1));
        } else {
          eprintln!(
            "[sena-guard] process exited. active={}s",
            self.active_seconds.round() as u64
          );
          break;
        }
      }
    }

    self.write_session();
  }

  fn find_child(&self, sys: &System) -> Option<(Pid, u64)> {
    for (pid, process) in sys.processes() {
      if process.parent() == Some(self.pid) {
        return Some((*pid, process.start_time()));
      }
    }
    None
  }
}
