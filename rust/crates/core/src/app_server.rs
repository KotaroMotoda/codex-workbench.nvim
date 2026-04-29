use std::path::Path;
use std::sync::mpsc::Receiver;

use anyhow::Result;
use codex_workbench_protocol::BridgeRequest;
use serde_json::Value;

use crate::manager::EventSink;

#[cfg(feature = "codex")]
use anyhow::{anyhow, Context};
#[cfg(feature = "codex")]
use codex_workbench_protocol::{ApprovalResponseParams, BridgeError, BridgeEvent, BridgeResponse};
#[cfg(feature = "codex")]
use serde_json::json;
#[cfg(feature = "codex")]
use std::collections::VecDeque;
#[cfg(feature = "codex")]
use std::io::{BufRead, BufReader, Write};
#[cfg(feature = "codex")]
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
#[cfg(feature = "codex")]
use std::sync::{Arc, Mutex};
#[cfg(feature = "codex")]
use std::thread;

/// Abstraction over the Codex app-server connection.
///
/// The trait exists primarily to enable dependency injection in tests:
/// integration tests can substitute a `MockAppServer` that records calls and
/// returns pre-configured results, eliminating the need for a live Codex binary.
pub trait AppServer {
    fn thread_id(&self) -> Option<&str>;
    fn set_thread_id(&mut self, thread_id: Option<String>);
    fn start_thread(&mut self, cwd: &Path) -> Result<String>;
    fn list_threads(&mut self, cwd: &[String]) -> Result<Value>;
    fn thread_messages(&mut self, thread_id: &str, limit: usize) -> Result<Value>;
    fn delete_thread(&mut self, thread_id: &str) -> Result<Value>;
    fn resume_thread(&mut self, thread_id: &str, cwd: &Path) -> Result<String>;
    fn fork_thread(&mut self, thread_id: &str, cwd: &Path) -> Result<String>;
    fn run_turn(
        &mut self,
        prompt: &str,
        cwd: &Path,
        bridge_rx: &Receiver<BridgeRequest>,
        sink: &mut dyn EventSink,
    ) -> Result<String>;
}

#[cfg(feature = "codex")]
pub struct AppServerClient {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    stderr_tail: Arc<Mutex<VecDeque<String>>>,
    next_id: u64,
    thread_id: Option<String>,
}

#[cfg(feature = "codex")]
impl AppServerClient {
    pub fn spawn(codex_cmd: &str) -> Result<Self> {
        let mut child = Command::new(codex_cmd)
            .args(["app-server", "--listen", "stdio://"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("failed to spawn `{codex_cmd} app-server`"))?;

        let stdin = child.stdin.take().context("app-server stdin unavailable")?;
        let stdout = child
            .stdout
            .take()
            .context("app-server stdout unavailable")?;
        let stderr_tail = Arc::new(Mutex::new(VecDeque::with_capacity(50)));
        if let Some(stderr) = child.stderr.take() {
            drain_stderr(stderr, Arc::clone(&stderr_tail));
        }
        let mut this = Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
            stderr_tail,
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

    pub fn list_threads(&mut self, cwd: &[String]) -> Result<Value> {
        self.request(
            "thread/list",
            json!({
                "cwd": cwd,
                "archived": false,
                "limit": 50,
                "sortKey": "updated_at",
                "sortDirection": "desc",
                "sourceKinds": ["cli", "vscode", "appServer", "unknown"],
            }),
        )
    }

    pub fn thread_messages(&mut self, thread_id: &str, limit: usize) -> Result<Value> {
        self.request(
            "thread/messages",
            json!({
                "threadId": thread_id,
                "limit": limit,
            }),
        )
    }

    pub fn delete_thread(&mut self, thread_id: &str) -> Result<Value> {
        self.request(
            "thread/delete",
            json!({
                "threadId": thread_id,
            }),
        )
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
                    json!({ "id": response_id, "summary": summarize_json(&message, 1200) }),
                ));
                continue;
            }

            if let Some(method) = message.get("method").and_then(Value::as_str) {
                self.emit_notification(method, &message, sink);

                if method == "turn/completed" {
                    let completed_turn = extract_turn_id(&message).unwrap_or_default();
                    if completed_turn.is_empty() || completed_turn == turn_id {
                        if let Some(error) = turn_error_message(&message) {
                            sink.emit(BridgeEvent::new(
                                "turn_error",
                                json!({ "turn_id": turn_id, "message": error }),
                            ));
                            return Err(anyhow!(BridgeError::TurnFailed {
                                turn_id: turn_id.clone(),
                                message: error,
                            }));
                        }
                        sink.emit(BridgeEvent::new(
                            "turn_completed",
                            json!({ "turn_id": turn_id }),
                        ));
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
            .map_err(|err| label_app_server_error(err, method))
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
            let stderr_tail = self.stderr_tail_text();
            return Err(anyhow!(BridgeError::AppServerCrashed { stderr_tail }));
        }
        serde_json::from_str(line.trim_end()).with_context(|| {
            format!(
                "app-server emitted invalid JSON: {}",
                truncate(line.trim_end(), 300)
            )
        })
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
                self.emit_notification(method, &message, sink);
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
                "summary": summarize_json(&params, 1200)
            }),
        ));

        let decision = wait_for_approval(bridge_rx, &approval_id, sink)?;
        self.write_message(&json!({
            "id": app_id,
            "result": { "decision": decision }
        }))
    }

    fn emit_notification(&self, method: &str, message: &Value, sink: &mut dyn EventSink) {
        sink.emit(BridgeEvent::new(
            "appserver_event",
            json!({ "method": method, "summary": summarize_notification(method, message) }),
        ));

        match method {
            "thread/started" => {
                if let Some(thread_id) = extract_thread_id(message) {
                    sink.emit(BridgeEvent::new(
                        "thread_started",
                        json!({ "thread_id": thread_id }),
                    ));
                }
            }
            "item/agentMessage/delta" => {
                if let Some(delta) = message.pointer("/params/delta").and_then(Value::as_str) {
                    sink.emit(BridgeEvent::new("output_delta", json!({ "text": delta })));
                }
            }
            "item/completed" => {
                if let Some(text) = agent_message_text(message) {
                    sink.emit(BridgeEvent::new(
                        "message_completed",
                        json!({ "text": text }),
                    ));
                }
            }
            "turn/diff/updated" => {
                if let Some(diff) = message.pointer("/params/diff").and_then(Value::as_str) {
                    sink.emit(BridgeEvent::new("diff_preview", json!({ "diff": diff })));
                }
            }
            _ => {}
        }
    }

    fn stderr_tail_text(&mut self) -> String {
        let status = self.child.try_wait().ok().flatten();
        let tail = self
            .stderr_tail
            .lock()
            .ok()
            .map(|tail| tail.iter().cloned().collect::<Vec<_>>().join("\n"))
            .unwrap_or_default();
        let trimmed = truncate(&tail, 800);
        match (status, trimmed.is_empty()) {
            (Some(status), false) => format!("status: {status}; stderr: {trimmed}"),
            (Some(status), true) => format!("status: {status}"),
            (None, false) => trimmed,
            (None, true) => String::new(),
        }
    }
}

#[cfg(feature = "codex")]
impl AppServer for AppServerClient {
    fn thread_id(&self) -> Option<&str> {
        AppServerClient::thread_id(self)
    }

    fn set_thread_id(&mut self, thread_id: Option<String>) {
        AppServerClient::set_thread_id(self, thread_id);
    }

    fn start_thread(&mut self, cwd: &Path) -> Result<String> {
        AppServerClient::start_thread(self, cwd)
    }

    fn list_threads(&mut self, cwd: &[String]) -> Result<Value> {
        AppServerClient::list_threads(self, cwd)
    }

    fn thread_messages(&mut self, thread_id: &str, limit: usize) -> Result<Value> {
        AppServerClient::thread_messages(self, thread_id, limit)
    }

    fn delete_thread(&mut self, thread_id: &str) -> Result<Value> {
        AppServerClient::delete_thread(self, thread_id)
    }

    fn resume_thread(&mut self, thread_id: &str, cwd: &Path) -> Result<String> {
        AppServerClient::resume_thread(self, thread_id, cwd)
    }

    fn fork_thread(&mut self, thread_id: &str, cwd: &Path) -> Result<String> {
        AppServerClient::fork_thread(self, thread_id, cwd)
    }

    fn run_turn(
        &mut self,
        prompt: &str,
        cwd: &Path,
        bridge_rx: &Receiver<BridgeRequest>,
        sink: &mut dyn EventSink,
    ) -> Result<String> {
        AppServerClient::run_turn(self, prompt, cwd, bridge_rx, sink)
    }
}

#[cfg(feature = "codex")]
impl Drop for AppServerClient {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

#[cfg(feature = "codex")]
fn wait_for_approval(
    rx: &Receiver<BridgeRequest>,
    approval_id: &str,
    sink: &mut dyn crate::manager::EventSink,
) -> Result<String> {
    loop {
        let request = rx.recv()?;
        if request.method == "approval_response" {
            let params: ApprovalResponseParams = serde_json::from_value(request.params)?;
            if params.approval_id == approval_id {
                let decision = match params.decision.as_str() {
                    "approved" | "approved_for_session" | "denied" | "abort" => params.decision,
                    "accept" => "approved".to_string(),
                    "decline" => "denied".to_string(),
                    _ => "denied".to_string(),
                };
                if let Some(id) = request.id {
                    sink.reply(BridgeResponse::ok(
                        id,
                        json!({ "approval_id": approval_id, "decision": decision }),
                    ));
                }
                return Ok(decision);
            }
            // 別のapproval_idへの応答は無視して待機継続。
            // ただし id 付き request には必ず応答して呼び出し側を待たせない。
            if let Some(id) = request.id {
                sink.reply(BridgeResponse::err(
                    id,
                    &BridgeError::Internal {
                        message: format!(
                            "approval_id mismatch: expected {}, got {}",
                            approval_id, params.approval_id
                        ),
                    },
                ));
            }
            continue;
        }
        // 承認待機中に届いた非approval_responseリクエストはエラーで返す
        if let Some(id) = request.id {
            sink.reply(BridgeResponse::err(
                id,
                &BridgeError::Internal {
                    message: "bridge is busy: waiting for approval".to_string(),
                },
            ));
        }
    }
}

#[cfg(feature = "codex")]
fn response_result(message: Value) -> Result<Value> {
    if let Some(error) = message.get("error") {
        let (code, message_text) = parse_remote_error(error);
        return Err(anyhow!(BridgeError::AppServerError {
            method: String::new(),
            code,
            message: message_text,
        }));
    }
    Ok(message.get("result").cloned().unwrap_or(Value::Null))
}

/// Extract a short, structured `(code, message)` pair from an app-server
/// error object. We intentionally avoid forwarding `data` or unknown nested
/// fields so that secrets and large blobs do not bleed into user-facing
/// notifications.
#[cfg(feature = "codex")]
fn parse_remote_error(error: &Value) -> (Option<i64>, String) {
    let code = error.get("code").and_then(Value::as_i64);
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .map(|s| truncate(s, 240))
        .unwrap_or_else(|| match error {
            Value::String(s) => truncate(s, 240),
            _ => "unknown app-server error".to_string(),
        });
    (code, message)
}

/// Replace the empty `method` placeholder set by `response_result` with the
/// real method name when we know it. Non-`AppServerError` causes pass through
/// unchanged so that crashes etc. retain their classification.
///
/// # Note on error-chain loss
/// When the method field is updated we construct a fresh `anyhow::Error`,
/// which intentionally discards the original cause chain. The chain is not
/// meaningful here — the bridge error payload is the only information we
/// forward — and preserving it would require boxing the original error as a
/// source, complicating `classify` at the outer boundary for no user benefit.
#[cfg(feature = "codex")]
fn label_app_server_error(err: anyhow::Error, method: &str) -> anyhow::Error {
    if let Some(BridgeError::AppServerError {
        method: existing,
        code,
        message,
    }) = err.downcast_ref::<BridgeError>()
    {
        if existing.is_empty() {
            return anyhow!(BridgeError::AppServerError {
                method: method.to_string(),
                code: *code,
                message: message.clone(),
            });
        }
    }
    err
}

#[cfg(feature = "codex")]
fn extract_thread_id(value: &Value) -> Option<String> {
    find_key(value, "thread")
        .and_then(|thread| find_string(thread, &["id", "threadId"]))
        .or_else(|| find_string(value, &["threadId"]))
}

#[cfg(feature = "codex")]
fn extract_turn_id(value: &Value) -> Option<String> {
    find_key(value, "turn")
        .and_then(|turn| find_string(turn, &["id", "turnId"]))
        .or_else(|| find_string(value, &["turnId"]))
}

#[cfg(feature = "codex")]
fn agent_message_text(value: &Value) -> Option<String> {
    let item = value.pointer("/params/item")?;
    let item_type = item.get("type").and_then(Value::as_str)?;
    if item_type != "agentMessage" {
        return None;
    }
    item.get("text")
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| find_string(item, &["text"]))
}

#[cfg(feature = "codex")]
fn turn_error_message(value: &Value) -> Option<String> {
    let turn = value
        .pointer("/params/turn")
        .or_else(|| value.get("turn"))?;
    let error = turn.get("error")?;
    if error.is_null() {
        return None;
    }
    let (_, message) = parse_remote_error(error);
    Some(message)
}

#[cfg(all(test, feature = "codex"))]
mod approval_tests {
    use super::*;
    use std::sync::mpsc;

    #[derive(Default)]
    struct RecordingSink {
        replies: Vec<BridgeResponse>,
    }

    impl EventSink for RecordingSink {
        fn emit(&mut self, _event: BridgeEvent) {}

        fn reply(&mut self, response: BridgeResponse) {
            self.replies.push(response);
        }
    }

    fn approval_request(id: u64, approval_id: &str, decision: &str) -> BridgeRequest {
        BridgeRequest {
            id: Some(id),
            method: "approval_response".to_string(),
            params: json!({
                "approval_id": approval_id,
                "decision": decision,
            }),
        }
    }

    #[test]
    fn wait_for_approval_replies_to_matching_id_request() {
        let (tx, rx) = mpsc::channel();
        tx.send(approval_request(7, "approval-1", "accept"))
            .unwrap();
        drop(tx);

        let mut sink = RecordingSink::default();
        let decision = wait_for_approval(&rx, "approval-1", &mut sink).unwrap();

        assert_eq!(decision, "approved");
        assert_eq!(sink.replies.len(), 1);
        assert_eq!(sink.replies[0].id, 7);
        assert!(sink.replies[0].ok);
    }

    #[test]
    fn wait_for_approval_replies_to_mismatched_id_request_and_keeps_waiting() {
        let (tx, rx) = mpsc::channel();
        tx.send(approval_request(7, "other", "approved")).unwrap();
        tx.send(approval_request(8, "approval-1", "approved"))
            .unwrap();
        drop(tx);

        let mut sink = RecordingSink::default();
        let decision = wait_for_approval(&rx, "approval-1", &mut sink).unwrap();

        assert_eq!(decision, "approved");
        assert_eq!(sink.replies.len(), 2);
        assert_eq!(sink.replies[0].id, 7);
        assert!(!sink.replies[0].ok);
        assert_eq!(
            sink.replies[0].error_code.as_deref(),
            Some("internal_error")
        );
        assert_eq!(sink.replies[1].id, 8);
        assert!(sink.replies[1].ok);
    }
}

#[cfg(feature = "codex")]
fn summarize_notification(method: &str, message: &Value) -> Value {
    let params = message.get("params").unwrap_or(&Value::Null);
    let thread_id = params.get("threadId").and_then(Value::as_str);
    let turn_id = params.get("turnId").and_then(Value::as_str);
    match method {
        "item/completed" | "item/started" => {
            let item = params.get("item").unwrap_or(&Value::Null);
            json!({
                "thread_id": thread_id,
                "turn_id": turn_id,
                "item_id": item.get("id").and_then(Value::as_str),
                "item_type": item.get("type").and_then(Value::as_str),
                "status": item.get("status").and_then(Value::as_str),
                "error": item.get("error").map(|error| summarize_json(error, 500)),
            })
        }
        "item/agentMessage/delta" => json!({
            "thread_id": thread_id,
            "turn_id": turn_id,
            "item_id": params.get("itemId").and_then(Value::as_str),
            "delta_bytes": params.get("delta").and_then(Value::as_str).map(str::len),
        }),
        "turn/diff/updated" => json!({
            "thread_id": thread_id,
            "turn_id": turn_id,
            "diff_bytes": params.get("diff").and_then(Value::as_str).map(str::len),
        }),
        "turn/completed" | "turn/started" => {
            let turn = params.get("turn").unwrap_or(&Value::Null);
            json!({
                "thread_id": thread_id,
                "turn_id": turn.get("id").and_then(Value::as_str).or(turn_id),
                "status": turn.get("status").and_then(Value::as_str),
                "error": turn.get("error").map(|error| summarize_json(error, 500)),
            })
        }
        "thread/started" => json!({
            "thread_id": extract_thread_id(message),
        }),
        _ => json!({
            "thread_id": thread_id,
            "turn_id": turn_id,
        }),
    }
}

#[cfg(feature = "codex")]
fn summarize_json(value: &Value, max_chars: usize) -> String {
    truncate(&value.to_string(), max_chars)
}

#[cfg(feature = "codex")]
fn truncate(text: &str, max_chars: usize) -> String {
    let mut out = String::with_capacity(max_chars.min(text.len()));
    for (idx, ch) in text.chars().enumerate() {
        if idx >= max_chars {
            out.push('…');
            return out;
        }
        out.push(ch);
    }
    out
}

#[cfg(feature = "codex")]
fn drain_stderr(stderr: std::process::ChildStderr, tail: Arc<Mutex<VecDeque<String>>>) {
    thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(|line| line.ok()) {
            if let Ok(mut tail) = tail.lock() {
                if tail.len() >= 50 {
                    tail.pop_front();
                }
                tail.push_back(line);
            }
        }
    });
}

#[cfg(feature = "codex")]
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

#[cfg(feature = "codex")]
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

#[cfg(feature = "codex")]
fn approval_id(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

#[cfg(all(test, feature = "codex"))]
mod tests {
    use super::*;

    #[test]
    fn notification_summary_does_not_leak_user_message_text() {
        let message = json!({
            "method": "item/completed",
            "params": {
                "threadId": "thread",
                "turnId": "turn",
                "item": {
                    "id": "item",
                    "type": "userMessage",
                    "text": "secret prompt text that must not be displayed"
                }
            }
        });

        let summary = summarize_notification("item/completed", &message).to_string();
        assert!(summary.contains("userMessage"));
        assert!(!summary.contains("secret prompt text"));
    }

    #[test]
    fn agent_message_text_only_accepts_agent_message_items() {
        let user = json!({
            "params": { "item": { "type": "userMessage", "text": "user text" } }
        });
        let agent = json!({
            "params": { "item": { "type": "agentMessage", "text": "agent text" } }
        });
        assert_eq!(agent_message_text(&user), None);
        assert_eq!(agent_message_text(&agent).as_deref(), Some("agent text"));
    }

    #[test]
    fn completed_turn_with_null_error_is_successful() {
        let message = json!({
            "method": "turn/completed",
            "params": {
                "turn": {
                    "id": "turn",
                    "status": "completed",
                    "error": null
                }
            }
        });

        assert_eq!(turn_error_message(&message), None);
    }
}
