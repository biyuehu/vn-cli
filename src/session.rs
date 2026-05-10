use serde::{Deserialize, Serialize};

/// 和 Haskell Session.hs 的 SessionData 字段完全对齐
/// JSON key 用 camelCase 匹配 Aeson 默认派生
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionData {
    pub game_id: String,
    pub start_time: i64,
    pub last_heartbeat: i64,
    pub active_time: i64, // 秒，窗口在前台的累计时间
    pub foo_pid: i64,
}
