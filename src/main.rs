use std::path::Path;
use std::process::Command;

mod guard;

use guard::cli::{parse_args, Mode};
use guard::monitor::Monitor;
use guard::win::is_pid_alive;

fn main() {
  match parse_args() {
    Err(e) => {
      eprintln!("error: {}", e);
      std::process::exit(2);
    }

    Ok(Mode::CheckPid { pid }) => {
      if is_pid_alive(pid) {
        std::process::exit(0);
      } else {
        std::process::exit(1);
      }
    }

    Ok(Mode::Run {
      game_id,
      game_name,
      exe_path,
      session_file,
    }) => {
      eprintln!("[sena-guard] launching: {} ({})", game_name, exe_path);

      let child = Command::new(&exe_path)
        .current_dir(
          Path::new(&exe_path)
            .parent()
            .unwrap_or_else(|| Path::new(".")),
        )
        .spawn();

      match child {
        Err(e) => {
          eprintln!("[sena-guard] failed to launch: {}", e);
          std::process::exit(1);
        }
        Ok(child) => {
          let pid = child.id();
          eprintln!("[sena-guard] pid={}", pid);
          let mut monitor = Monitor::new(game_id, session_file, pid);
          monitor.run();
        }
      }
    }
  }
}
