use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionData {
  pub game_id: String,
  pub start_unix: i64,
  pub last_heartbeat_unix: i64,
  pub active_seconds: i64,
  pub guard_pid: i64,
}
