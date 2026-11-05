use sysinfo::{Pid, ProcessesToUpdate, System};

pub fn is_pid_alive(pid: u32) -> bool {
  let mut sys = System::new();
  let target = Pid::from_u32(pid);
  sys.refresh_processes(ProcessesToUpdate::Some(&[target]), true);
  sys.process(target).is_some()
}

#[cfg(windows)]
use winapi::um::winuser::{GetForegroundWindow, GetWindowThreadProcessId};

#[cfg(windows)]
pub fn is_window_active(pid: u32) -> bool {
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

#[cfg(not(windows))]
pub fn is_window_active(_pid: u32) -> bool {
  true
}
