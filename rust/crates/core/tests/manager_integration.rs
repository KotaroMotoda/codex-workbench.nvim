//! Integration tests for [`Manager`].
//!
//! These tests stand up real temporary git repositories so that the full
//! initialize → ask → accept / reject pipeline can be exercised without
//! spawning a live Codex binary.  The [`MockAppServer`] implements the
//! [`AppServer`] trait and records every call made against it.

use std::path::Path;
use std::process::Command;
use std::sync::mpsc;
use std::sync::mpsc::Receiver;

use anyhow::Result;
use codex_workbench_core::app_server::AppServer;
use codex_workbench_core::manager::{EventSink, Manager};
use codex_workbench_protocol::{BridgeError, BridgeEvent, BridgeRequest};
use serde_json::{json, Value};
use tempfile::TempDir;

// ── EventSink ────────────────────────────────────────────────────────────────

/// EventSink that accumulates every event for later assertion.
struct RecordingSink {
    events: Vec<(String, Value)>,
}

impl RecordingSink {
    fn new() -> Self {
        Self { events: Vec::new() }
    }

    fn event_names(&self) -> Vec<&str> {
        self.events.iter().map(|(name, _)| name.as_str()).collect()
    }

    fn has_event(&self, name: &str) -> bool {
        self.events.iter().any(|(n, _)| n == name)
    }
}

impl EventSink for RecordingSink {
    fn emit(&mut self, event: BridgeEvent) {
        self.events
            .push((event.event.clone(), event.payload.clone()));
    }
}

// ── MockAppServer ─────────────────────────────────────────────────────────────

/// Configurable mock that records calls and returns canned responses.
struct MockAppServer {
    thread_id: Option<String>,
    delete_response: Value,
    /// If set, `run_turn` writes this (filename, content) pair into `cwd`
    /// so that a diff is produced and a review item is created.
    write_file_on_turn: Option<(String, String)>,
}

impl MockAppServer {
    fn new() -> Self {
        Self {
            thread_id: None,
            delete_response: json!({ "deleted": true }),
            write_file_on_turn: None,
        }
    }

    fn with_delete_response(mut self, response: Value) -> Self {
        self.delete_response = response;
        self
    }

    /// Configure the mock to write a file into the shadow repo on `run_turn`,
    /// causing a non-empty diff and therefore a review to be created.
    fn with_shadow_file(mut self, name: impl Into<String>, content: impl Into<String>) -> Self {
        self.write_file_on_turn = Some((name.into(), content.into()));
        self
    }
}

impl AppServer for MockAppServer {
    fn thread_id(&self) -> Option<&str> {
        self.thread_id.as_deref()
    }

    fn set_thread_id(&mut self, thread_id: Option<String>) {
        self.thread_id = thread_id;
    }

    fn start_thread(&mut self, _cwd: &Path) -> Result<String> {
        self.thread_id = Some("mock-thread-1".to_string());
        Ok("mock-thread-1".to_string())
    }

    fn list_threads(&mut self, _cwd: &[String]) -> Result<Value> {
        Ok(json!({
            "data": [{
                "id": "t1",
                "name": null,
                "preview": "mock thread",
                "cwd": "/mock",
                "status": { "type": "notLoaded" },
                "source": "cli",
                "updatedAt": 1_000_000_000u64,
                "createdAt": 1_000_000_000u64,
            }]
        }))
    }

    fn thread_messages(&mut self, thread_id: &str, _limit: usize) -> Result<Value> {
        Ok(json!({
            "messages": [
                { "role": "user", "text": format!("hello {thread_id}") },
                { "role": "assistant", "text": "hi" }
            ]
        }))
    }

    fn delete_thread(&mut self, thread_id: &str) -> Result<Value> {
        let deleted = self
            .delete_response
            .get("deleted")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        if deleted && self.thread_id.as_deref() == Some(thread_id) {
            self.thread_id = None;
        }
        Ok(self.delete_response.clone())
    }

    fn resume_thread(&mut self, thread_id: &str, _cwd: &Path) -> Result<String> {
        self.thread_id = Some(thread_id.to_string());
        Ok(thread_id.to_string())
    }

    fn fork_thread(&mut self, thread_id: &str, _cwd: &Path) -> Result<String> {
        let forked = format!("{thread_id}-fork");
        self.thread_id = Some(forked.clone());
        Ok(forked)
    }

    fn run_turn(
        &mut self,
        _prompt: &str,
        cwd: &Path,
        _bridge_rx: &Receiver<BridgeRequest>,
        _sink: &mut dyn EventSink,
    ) -> Result<String> {
        if self.thread_id.is_none() {
            self.start_thread(cwd)?;
        }
        if let Some((name, content)) = &self.write_file_on_turn {
            std::fs::write(cwd.join(name), content)?;
        }
        Ok("mock-turn-1".to_string())
    }
}

// ── git helpers ───────────────────────────────────────────────────────────────

fn git_init(path: &Path) {
    for args in [
        &["init"][..],
        &["config", "user.email", "test@example.com"],
        &["config", "user.name", "Test"],
    ] {
        let out = Command::new("git")
            .args(args)
            .current_dir(path)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    std::fs::write(path.join(".gitkeep"), "").unwrap();
    for args in [&["add", "."][..], &["commit", "-m", "init"]] {
        let out = Command::new("git")
            .args(args)
            .current_dir(path)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
}

/// Walk `state_root` (one level deep) and return the first `state.json` found.
///
/// `ShadowWorkspace::prepare` stores state in `state_root/<workspace_hash>/`,
/// so we cannot predict the exact subdirectory name without replicating the
/// hashing logic.
fn find_state_json(state_root: &Path) -> std::path::PathBuf {
    for entry in std::fs::read_dir(state_root).unwrap().flatten() {
        let candidate = entry.path().join("state.json");
        if candidate.exists() {
            return candidate;
        }
    }
    panic!("no state.json found under {}", state_root.display())
}

// ── test environment ──────────────────────────────────────────────────────────

/// Convenience wrapper: creates a git workspace, runs `initialize`, and
/// exposes helpers for subsequent requests.
struct TestEnv {
    _workspace: TempDir,
    _state_root: TempDir,
    _shadow_root: TempDir,
    manager: Manager,
    sink: RecordingSink,
}

impl TestEnv {
    fn setup() -> Self {
        let workspace = tempfile::tempdir().unwrap();
        let state_root = tempfile::tempdir().unwrap();
        let shadow_root = tempfile::tempdir().unwrap();

        git_init(workspace.path());

        let mut manager = Manager::new();
        let mut sink = RecordingSink::new();
        let (_tx, rx) = mpsc::channel::<BridgeRequest>();

        manager
            .handle(
                BridgeRequest {
                    id: Some(1),
                    method: "initialize".to_string(),
                    params: json!({
                        "workspace": workspace.path().to_string_lossy(),
                        "state_dir": state_root.path().to_string_lossy(),
                        "shadow_root": shadow_root.path().to_string_lossy(),
                        "codex_cmd": "codex",
                    }),
                },
                &rx,
                &mut sink,
            )
            .unwrap();

        Self {
            _workspace: workspace,
            _state_root: state_root,
            _shadow_root: shadow_root,
            manager,
            sink,
        }
    }

    /// Call `manager.handle` with a fresh channel (tests don't exercise the
    /// approval-response flow, so a new channel per call is fine).
    fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        let (_tx, rx) = mpsc::channel::<BridgeRequest>();
        self.manager.handle(
            BridgeRequest {
                id: Some(99),
                method: method.to_string(),
                params,
            },
            &rx,
            &mut self.sink,
        )
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[test]
fn initialize_emits_ready_event() {
    let env = TestEnv::setup();
    assert!(
        env.sink.has_event("ready"),
        "expected 'ready' event, got {:?}",
        env.sink.event_names()
    );
}

#[test]
fn status_reports_initialized_after_initialize() {
    let mut env = TestEnv::setup();
    let result = env.call("status", json!({})).unwrap();
    assert_eq!(result["initialized"], json!(true));
}

#[test]
fn review_is_empty_before_any_ask() {
    let mut env = TestEnv::setup();
    let result = env.call("review", json!({})).unwrap();
    assert_eq!(result["pending"], json!(null));
    assert_eq!(result["reviews"], json!([]));
}

#[test]
fn accept_fails_with_no_pending_review() {
    let mut env = TestEnv::setup();
    let err = env.call("accept", json!({ "scope": "all" })).unwrap_err();
    let code = err.downcast_ref::<BridgeError>().map(|e| e.code());
    assert_eq!(code, Some("no_pending_review"));
}

#[test]
fn reject_fails_with_no_pending_review() {
    let mut env = TestEnv::setup();
    let err = env.call("reject", json!({ "scope": "all" })).unwrap_err();
    let code = err.downcast_ref::<BridgeError>().map(|e| e.code());
    assert_eq!(code, Some("no_pending_review"));
}

#[test]
fn unknown_method_returns_error() {
    let mut env = TestEnv::setup();
    let err = env.call("nonexistent_method", json!({})).unwrap_err();
    let code = err.downcast_ref::<BridgeError>().map(|e| e.code());
    assert_eq!(code, Some("unknown_method"));
}

#[test]
fn health_returns_git_flag() {
    let mut env = TestEnv::setup();
    let result = env.call("health", json!({})).unwrap();
    assert_eq!(result["git"], json!(true));
}

#[test]
fn approval_response_is_silently_ignored() {
    let mut env = TestEnv::setup();
    let result = env
        .call(
            "approval_response",
            json!({ "approval_id": "x", "decision": "approved" }),
        )
        .unwrap();
    assert_eq!(result["ignored"], json!(true));
}

#[test]
fn ask_with_mock_no_diff_returns_no_review() {
    let mut env = TestEnv::setup();
    env.manager
        .inject_app_server(Box::new(MockAppServer::new()));

    let result = env
        .call("ask", json!({ "prompt": "hello", "new_thread": true }))
        .unwrap();

    assert_eq!(result["has_review"], json!(false));
    assert_eq!(result["turn_id"], json!("mock-turn-1"));
}

#[test]
fn ask_with_mock_saves_thread_id_to_state() {
    let mut env = TestEnv::setup();
    env.manager
        .inject_app_server(Box::new(MockAppServer::new()));

    env.call("ask", json!({ "prompt": "hello", "new_thread": true }))
        .unwrap();

    let status = env.call("status", json!({})).unwrap();
    assert_eq!(status["thread_id"], json!("mock-thread-1"));
}

#[test]
fn ask_can_skip_recent_prompt_persistence() {
    let mut env = TestEnv::setup();
    env.manager
        .inject_app_server(Box::new(MockAppServer::new()));

    env.call(
        "ask",
        json!({ "prompt": "secret @buffer", "new_thread": true, "persist_history": false }),
    )
    .unwrap();

    let result = env.call("recent_prompts", json!({ "limit": 10 })).unwrap();
    assert_eq!(result["prompts"], json!([]));
}

#[test]
fn ask_with_mock_creates_review_when_shadow_changes() {
    let mut env = TestEnv::setup();
    let mock = MockAppServer::new().with_shadow_file("codex_output.txt", "hello from codex\n");
    env.manager.inject_app_server(Box::new(mock));

    let result = env
        .call(
            "ask",
            json!({ "prompt": "write a file", "new_thread": true }),
        )
        .unwrap();

    assert_eq!(result["has_review"], json!(true));
    assert!(
        env.sink.has_event("review_created"),
        "expected review_created event"
    );

    let review_result = env.call("review", json!({})).unwrap();
    assert!(
        review_result["pending"].is_object(),
        "expected a pending review"
    );
}

#[test]
fn ask_with_new_thread_flag_starts_fresh_thread() {
    let mut env = TestEnv::setup();
    env.manager
        .inject_app_server(Box::new(MockAppServer::new()));

    env.call("ask", json!({ "prompt": "first", "new_thread": true }))
        .unwrap();
    let status = env.call("status", json!({})).unwrap();
    assert_eq!(status["thread_id"], json!("mock-thread-1"));

    // ask again with new_thread=true → mock starts_thread again
    env.call("ask", json!({ "prompt": "second", "new_thread": true }))
        .unwrap();
    let status2 = env.call("status", json!({})).unwrap();
    assert_eq!(status2["thread_id"], json!("mock-thread-1"));
}

#[test]
fn threads_uses_injected_mock() {
    let mut env = TestEnv::setup();
    env.manager
        .inject_app_server(Box::new(MockAppServer::new()));

    let result = env.call("threads", json!({})).unwrap();
    let threads = result["threads"].as_array().unwrap();
    assert_eq!(threads.len(), 1, "mock returns one thread");
    assert_eq!(threads[0]["id"], json!("t1"));
}

#[test]
fn thread_messages_uses_injected_mock() {
    let mut env = TestEnv::setup();
    env.manager
        .inject_app_server(Box::new(MockAppServer::new()));

    let result = env
        .call("thread/messages", json!({ "thread_id": "t1", "limit": 10 }))
        .unwrap();
    assert_eq!(result["thread_id"], json!("t1"));
    assert_eq!(result["messages"][0]["role"], json!("user"));
    assert_eq!(result["messages"][0]["text"], json!("hello t1"));
    assert_eq!(result["messages"][1]["role"], json!("assistant"));
}

#[test]
fn thread_delete_clears_current_thread_id() {
    let mut env = TestEnv::setup();
    env.manager
        .inject_app_server(Box::new(MockAppServer::new()));

    env.call("ask", json!({ "prompt": "p", "new_thread": true }))
        .unwrap();
    let result = env
        .call("thread/delete", json!({ "thread_id": "mock-thread-1" }))
        .unwrap();
    assert_eq!(result["deleted"], json!(true));

    let status = env.call("status", json!({})).unwrap();
    assert_eq!(status["thread_id"], json!(null));
}

#[test]
fn thread_delete_returns_app_server_deleted_flag() {
    let mut env = TestEnv::setup();
    env.manager.inject_app_server(Box::new(
        MockAppServer::new().with_delete_response(json!({ "deleted": false })),
    ));

    env.call("ask", json!({ "prompt": "p", "new_thread": true }))
        .unwrap();
    let result = env
        .call("thread/delete", json!({ "thread_id": "mock-thread-1" }))
        .unwrap();
    assert_eq!(result["deleted"], json!(false));

    let status = env.call("status", json!({})).unwrap();
    assert_eq!(status["thread_id"], json!("mock-thread-1"));
}

#[test]
fn resume_uses_injected_mock() {
    let mut env = TestEnv::setup();
    env.manager
        .inject_app_server(Box::new(MockAppServer::new()));

    // Seed a thread_id via ask.
    env.call("ask", json!({ "prompt": "p", "new_thread": true }))
        .unwrap();

    let result = env
        .call("resume", json!({ "thread_id": "mock-thread-1" }))
        .unwrap();
    assert_eq!(result["thread_id"], json!("mock-thread-1"));
}

#[test]
fn fork_uses_injected_mock() {
    let mut env = TestEnv::setup();
    env.manager
        .inject_app_server(Box::new(MockAppServer::new()));

    // Seed a thread_id.
    env.call("ask", json!({ "prompt": "p", "new_thread": true }))
        .unwrap();

    let result = env.call("fork", json!({})).unwrap();
    assert_eq!(result["forked_from"], json!("mock-thread-1"));
    assert_eq!(result["thread_id"], json!("mock-thread-1-fork"));
}

#[test]
fn second_initialize_on_same_workspace_fails_with_workspace_locked() {
    let workspace = tempfile::tempdir().unwrap();
    let state_root = tempfile::tempdir().unwrap();
    let shadow_root = tempfile::tempdir().unwrap();
    git_init(workspace.path());

    let make_params = || {
        json!({
            "workspace": workspace.path().to_string_lossy(),
            "state_dir": state_root.path().to_string_lossy(),
            "shadow_root": shadow_root.path().to_string_lossy(),
            "codex_cmd": "codex",
        })
    };

    let (_tx, rx) = mpsc::channel::<BridgeRequest>();
    let mut sink = RecordingSink::new();

    // First manager acquires the lock.
    let mut m1 = Manager::new();
    m1.handle(
        BridgeRequest {
            id: Some(1),
            method: "initialize".to_string(),
            params: make_params(),
        },
        &rx,
        &mut sink,
    )
    .unwrap();

    // Second manager on same workspace must fail.
    let mut m2 = Manager::new();
    let err = m2
        .handle(
            BridgeRequest {
                id: Some(2),
                method: "initialize".to_string(),
                params: make_params(),
            },
            &rx,
            &mut sink,
        )
        .unwrap_err();

    let code = err.downcast_ref::<BridgeError>().map(|e| e.code());
    assert_eq!(code, Some("workspace_locked"));
}

#[test]
fn recovery_needed_event_emitted_when_pending_apply_exists() {
    use codex_workbench_core::state::{ApplyStage, PendingApply, SessionState};

    let workspace = tempfile::tempdir().unwrap();
    let state_root = tempfile::tempdir().unwrap();
    let shadow_root = tempfile::tempdir().unwrap();
    git_init(workspace.path());

    let make_params = || {
        json!({
            "workspace": workspace.path().to_string_lossy(),
            "state_dir": state_root.path().to_string_lossy(),
            "shadow_root": shadow_root.path().to_string_lossy(),
            "codex_cmd": "codex",
        })
    };

    // First initialize: creates the shadow worktree and state.json.
    {
        let (_tx, rx) = mpsc::channel::<BridgeRequest>();
        let mut m = Manager::new();
        let mut sink = RecordingSink::new();
        m.handle(
            BridgeRequest {
                id: Some(1),
                method: "initialize".to_string(),
                params: make_params(),
            },
            &rx,
            &mut sink,
        )
        .unwrap();
        // m drops here → lock released.
    }

    // Inject a stale pending_apply into the state file.
    let state_path = find_state_json(state_root.path());
    let mut state = SessionState::load(&state_path).unwrap();
    state.pending_apply = Some(PendingApply {
        scope: "all".to_string(),
        patch_sha256: "aabbccddeeff".to_string(),
        started_at: 1_000_000,
        stage: ApplyStage::Applying,
    });
    state.save(&state_path).unwrap();

    // Second initialize should detect the stale apply and emit recovery_needed.
    let (_tx2, rx2) = mpsc::channel::<BridgeRequest>();
    let mut m2 = Manager::new();
    let mut sink2 = RecordingSink::new();
    m2.handle(
        BridgeRequest {
            id: Some(2),
            method: "initialize".to_string(),
            params: make_params(),
        },
        &rx2,
        &mut sink2,
    )
    .unwrap();

    assert!(
        sink2.has_event("recovery_needed"),
        "expected recovery_needed event, got {:?}",
        sink2.event_names()
    );

    // After clearing the stale apply the workspace must be usable again.
    let (_tx3, rx3) = mpsc::channel::<BridgeRequest>();
    let review_result = m2
        .handle(
            BridgeRequest {
                id: Some(3),
                method: "review".to_string(),
                params: json!({}),
            },
            &rx3,
            &mut sink2,
        )
        .unwrap();
    assert_eq!(review_result["pending"], json!(null));
}
