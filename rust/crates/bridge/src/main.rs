use std::io::{self, BufRead, Write};
use std::sync::mpsc::{self, Receiver};
use std::thread;

use anyhow::Result;
use codex_workbench_core::{classify, EventSink, Manager};
use codex_workbench_protocol::{BridgeError, BridgeEvent, BridgeRequest, BridgeResponse};
use serde_json::json;

struct StdoutSink;

impl EventSink for StdoutSink {
    fn emit(&mut self, event: BridgeEvent) {
        let _ = write_json(&event);
    }
}

fn main() -> Result<()> {
    let rx = spawn_stdin_reader();
    let mut manager = Manager::new();
    let mut sink = StdoutSink;

    while let Ok(request) = rx.recv() {
        let id = request.id;
        let response = match manager.handle(request, &rx, &mut sink) {
            Ok(result) => id.map(|id| BridgeResponse::ok(id, result)),
            Err(err) => {
                let bridge_error = classify(err);
                id.map(|id| BridgeResponse::err(id, &bridge_error))
            }
        };

        if let Some(response) = response {
            write_json(&response)?;
        }
    }

    Ok(())
}

fn spawn_stdin_reader() -> Receiver<BridgeRequest> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let stdin = io::stdin();
        for line in stdin.lock().lines() {
            let Ok(line) = line else {
                break;
            };
            if line.trim().is_empty() {
                continue;
            }
            match serde_json::from_str::<BridgeRequest>(&line) {
                Ok(request) => {
                    if tx.send(request).is_err() {
                        break;
                    }
                }
                Err(error) => {
                    let bridge_error = BridgeError::InvalidRequest {
                        message: error.to_string(),
                    };
                    let event = BridgeEvent::new(
                        "error",
                        json!({
                            "code": bridge_error.code(),
                            "message": bridge_error.to_string(),
                            "details": bridge_error.details(),
                        }),
                    );
                    let _ = write_json(&event);
                }
            }
        }
    });
    rx
}

fn write_json(value: &impl serde::Serialize) -> Result<()> {
    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, value)?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(())
}
