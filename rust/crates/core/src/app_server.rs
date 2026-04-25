use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::mpsc::Receiver;

use anyhow::{anyhow, Context, Result};
use codex_workbench_protocol::{ApprovalResponseParams, BridgeEvent, BridgeRequest};
use serde_json::{json, Value};

use crate::manager::EventSink;

pub struct AppServerClient {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_id: u64,
    thread_id: Option<String>,
}

impl AppServerClient {
    pub fn spawn(codex_cmd: &str) -> Result<Self> {
        let mut child = Command::new(codex_cmd)
            .args(["app-server", "--listen", "stdio://"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .with_context(|| format!("failed to spawn `{codex_cmd} app-server`"))?;

        let stdin = child.stdin.take().context("app-server stdin unavailable")?;
        let stdout = child
            .stdout
            .take()
            .context("app-server stdout unavailable")?;
        let mut this = Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
            next_id: 1,
            thread_id: None,
        };
        this.initialize()?;
        Ok(this)
    }

    pub fn set_thread_id(&mut self, thread_id: Option<String>) {
        self.thread_id = thread_id;
    }

    pub fn thread_id(&self) -> Option<&str> {
        self.thread_id.as_deref()
    }

    pub fn start_thread(&mut self, cwd: &Path) -> Result<String> {
        let result = self.request(
            "thread/start",
            json!({
                "cwd": cwd.to_string_lossy(),
            }),
        )?;
        let thread_id = extract_thread_id(&result)
            .ok_or_else(|| anyhow!("thread/start response did not include a thread id"))?;
        self.thread_id = Some(thread_id.clone());
        Ok(thread_id)
    }

    pub fn resume_thread(&mut self, thread_id: &str, cwd: &Path) -> Result<String> {
        let result = self.request(
            "thread/resume",
            json!({
                "threadId": thread_id,
                "cwd": cwd.to_string_lossy(),
            }),
        )?;
        let resumed = extract_thread_id(&result).unwrap_or_else(|| thread_id.to_string());
        self.thread_id = Some(resumed.clone());
        Ok(resumed)
    }

    pub fn fork_thread(&mut self, thread_id: &str, cwd: &Path) -> Result<String> {
        let result = self.request(
            "thread/fork",
            json!({
                "threadId": thread_id,
                "cwd": cwd.to_string_lossy(),
                "ephemeral": false,
            }),
        )?;
        let forked = extract_thread_id(&result)
            .ok_or_else(|| anyhow!("thread/fork response did not include a thread id"))?;
        self.thread_id = Some(forked.clone());
        Ok(forked)
    }

    pub fn run_turn(
        &mut self,
        prompt: &str,
        cwd: &Path,
        bridge_rx: &Receiver<BridgeRequest>,
        sink: &mut dyn EventSink,
    ) -> Result<String> {
        let thread_id = match self.thread_id.clone() {
            Some(thread_id) => thread_id,
            None => self.start_thread(cwd)?,
        };

        let request_id = self.send_request(
            "turn/start",
            json!({
                "threadId": thread_id,
                "cwd": cwd.to_string_lossy(),
                "input": [
                    {
                        "type": "text",
                        "text": prompt,
                        "text_elements": []
                    }
                ]
            }),
        )?;

        let start_result = self.read_until_response(request_id, bridge_rx, sink)?;
        let turn_id = extract_turn_id(&start_result).unwrap_or_else(|| "unknown".to_string());
        sink.emit(BridgeEvent::new(
            "turn_started",
            json!({ "thread_id": thread_id, "turn_id": turn_id }),
        ));

        loop {
            let message = self.read_message()?;
            if let Some(response_id) = message.get("id") {
                if message.get("method").is_some() {
                    self.handle_server_request(&message, bridge_rx, sink)?;
                    continue;
                }
                sink.emit(BridgeEvent::new(
                    "appserver_response",
                    json!({ "id": response_id, "message": message }),
                ));
                continue;
            }

            if let Some(method) = message.get("method").and_then(Value::as_str) {
                let params = message.get("params").cloned().unwrap_or(Value::Null);
                sink.emit(BridgeEvent::new(
                    "appserver_event",
                    json!({ "method": method, "params": params }),
                ));

                if method == "item/agentMessage/delta" {
                    if let Some(delta) = find_string(&message, &["delta", "text"]) {
                        sink.emit(BridgeEvent::new("output_delta", json!({ "text": delta })));
                    }
                }

                if method == "turn/diff/updated" {
                    if let Some(diff) = find_string(&message, &["diff"]) {
                        sink.emit(BridgeEvent::new("diff_preview", json!({ "diff": diff })));
                    }
                }

                if method == "turn/completed" {
                    let completed_turn = extract_turn_id(&message).unwrap_or_default();
                    if completed_turn.is_empty() || completed_turn == turn_id {
                        return Ok(turn_id);
                    }
                }
            }
        }
    }

    fn initialize(&mut self) -> Result<()> {
        let id = self.send_request(
            "initialize",
            json!({
                "clientInfo": {
                    "name": "codex_workbench_nvim",
                    "title": "codex-workbench.nvim",
                    "version": env!("CARGO_PKG_VERSION")
                }
            }),
        )?;
        self.read_until_response_no_approval(id)?;
        self.write_message(&json!({ "method": "initialized" }))?;
        Ok(())
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value> {
        let id = self.send_request(method, params)?;
        self.read_until_response_no_approval(id)
    }

    fn send_request(&mut self, method: &str, params: Value) -> Result<u64> {
        let id = self.next_id;
        self.next_id += 1;
        let message = json!({
            "id": id,
            "method": method,
            "params": params,
        });
        self.write_message(&message)?;
        Ok(id)
    }

    fn write_message(&mut self, message: &Value) -> Result<()> {
        serde_json::to_writer(&mut self.stdin, message)?;
        self.stdin.write_all(b"\n")?;
        self.stdin.flush()?;
        Ok(())
    }

    fn read_message(&mut self) -> Result<Value> {
        let mut line = String::new();
        let read = self.stdout.read_line(&mut line)?;
        if read == 0 {
            return Err(anyhow!("app-server closed stdout"));
        }
        Ok(serde_json::from_str(line.trim_end())?)
    }

    fn read_until_response_no_approval(&mut self, id: u64) -> Result<Value> {
        loop {
            let message = self.read_message()?;
            if message.get("id").and_then(Value::as_u64) == Some(id) {
                return response_result(message);
            }
        }
    }

    fn read_until_response(
        &mut self,
        id: u64,
        bridge_rx: &Receiver<BridgeRequest>,
        sink: &mut dyn EventSink,
    ) -> Result<Value> {
        loop {
            let message = self.read_message()?;
            if message.get("id").and_then(Value::as_u64) == Some(id)
                && message.get("method").is_none()
            {
                return response_result(message);
            }
            if message.get("id").is_some() && message.get("method").is_some() {
                self.handle_server_request(&message, bridge_rx, sink)?;
                continue;
            }
            if let Some(method) = message.get("method").and_then(Value::as_str) {
                sink.emit(BridgeEvent::new(
                    "appserver_event",
                    json!({ "method": method, "params": message.get("params").cloned().unwrap_or(Value::Null) }),
                ));
            }
        }
    }

    fn handle_server_request(
        &mut self,
        message: &Value,
        bridge_rx: &Receiver<BridgeRequest>,
        sink: &mut dyn EventSink,
    ) -> Result<()> {
        let app_id = message
            .get("id")
            .cloned()
            .ok_or_else(|| anyhow!("server request missing id"))?;
        let method = message
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();
        let approval_id = approval_id(&app_id);
        let params = message.get("params").cloned().unwrap_or(Value::Null);

        sink.emit(BridgeEvent::new(
            "approval_request",
            json!({
                "approval_id": approval_id,
                "method": method,
                "params": params
            }),
        ));

        let decision = wait_for_approval(bridge_rx, &approval_id)?;
        self.write_message(&json!({
            "id": app_id,
            "result": { "decision": decision }
        }))
    }
}

impl Drop for AppServerClient {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

fn wait_for_approval(rx: &Receiver<BridgeRequest>, approval_id: &str) -> Result<String> {
    loop {
        let request = rx.recv()?;
        if request.method != "approval_response" {
            continue;
        }
        let params: ApprovalResponseParams = serde_json::from_value(request.params)?;
        if params.approval_id == approval_id {
            return Ok(match params.decision.as_str() {
                "approved" | "approved_for_session" | "denied" | "abort" => params.decision,
                "accept" => "approved".to_string(),
                "decline" => "denied".to_string(),
                _ => "denied".to_string(),
            });
        }
    }
}

fn response_result(message: Value) -> Result<Value> {
    if let Some(error) = message.get("error") {
        return Err(anyhow!("app-server error: {error}"));
    }
    Ok(message.get("result").cloned().unwrap_or(Value::Null))
}

fn extract_thread_id(value: &Value) -> Option<String> {
    find_key(value, "thread")
        .and_then(|thread| find_string(thread, &["id", "threadId"]))
        .or_else(|| find_string(value, &["threadId"]))
}

fn extract_turn_id(value: &Value) -> Option<String> {
    find_key(value, "turn")
        .and_then(|turn| find_string(turn, &["id", "turnId"]))
        .or_else(|| find_string(value, &["turnId"]))
}

fn find_key<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    match value {
        Value::Object(map) => {
            if let Some(value) = map.get(key) {
                return Some(value);
            }
            map.values().find_map(|value| find_key(value, key))
        }
        Value::Array(items) => items.iter().find_map(|value| find_key(value, key)),
        _ => None,
    }
}

fn find_string(value: &Value, keys: &[&str]) -> Option<String> {
    match value {
        Value::Object(map) => {
            for key in keys {
                if let Some(text) = map.get(*key).and_then(Value::as_str) {
                    return Some(text.to_string());
                }
            }
            map.values().find_map(|value| find_string(value, keys))
        }
        Value::Array(items) => items.iter().find_map(|value| find_string(value, keys)),
        _ => None,
    }
}

fn approval_id(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}
