// use roga::{transport::console::ConsoleTransport, *};
// use std::fs;

const DB_NAME: &'static str = "data";

// struct Database {
//     db: DB,
//     logger: Logger,
// }

// impl Database {
//     fn new(directory: &str) -> Result<Self, String> {
//         let directory = std::path::Path::new(&directory);
//         if !directory.exists() {
//             fs::create_dir_all(directory)
//                 .map_err(|e| format!("Failed to create directory: {}", e))?;
//         }

//         let logger = Logger::new()
//             .with_transport(ConsoleTransport {
//                 ..Default::default()
//             })
//             .with_level(LoggerLevel::Info)
//             .with_label("Database");
//         Ok(Database {
//             db: DB::open(directory.join(DB_NAME), Options::default()).map_err(|e| {
//                 let msg = format!("Failed to open database: {}", e);
//                 l_fatal!(&logger, &msg);
//                 msg
//             })?,
//             logger,
//         })
//     }

//     fn read_value(&mut self, key: &str) -> Result<String, String> {
//         Ok(match self.db.get(key.as_bytes()) {
//             Some(v) => String::from_utf8_lossy(&v).to_string(),
//             None => "".to_string(),
//         })
//     }

//     fn write_value(&mut self, key: &str, value: &str) -> Result<(), String> {
//         self.db.put(key.as_bytes(), value.as_bytes()).map_err(|e| {
//             let msg = format!("Failed to write value to database: {}", e);
//             l_error!(&self.logger, &msg);
//             msg
//         })?;
//         Ok(())
//     }
// }
