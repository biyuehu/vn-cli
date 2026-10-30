use serde::{Deserialize, Serialize};

/// 和 Haskell Session.hs 的 SessionData 字段完全对齐
/// JSON key 用 camelCase 匹配 Aeson 默认派生
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionData {
  pub game_id: String,
  pub start_unix: i64,
  pub last_heartbeat_unix: i64,
  pub active_seconds: i64,
  pub foo_pid: i64,
}
