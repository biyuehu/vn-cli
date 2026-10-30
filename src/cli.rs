#[derive(Debug)]
pub enum Mode {
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

pub fn parse_args() -> Result<Mode, String> {
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

