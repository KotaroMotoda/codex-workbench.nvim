use std::fs::{File, OpenOptions};
use std::io::Write as _;
use std::path::PathBuf;
use std::process::Command;
use std::sync::mpsc::Receiver;

use anyhow::{anyhow, Result};
use codex_workbench_protocol::{
    AskParams, BridgeError, BridgeEvent, BridgeRequest, InitializeParams, RecentPromptsParams,
    ScopeParams, StageBeginParams, StageFinalizeParams, ThreadIdParams, ThreadMessagesParams,
};
use fs2::FileExt as _;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::app_server::AppServer;
#[cfg(feature = "codex")]
use crate::app_server::AppServerClient;
use crate::git::{GitInvocationError, GitRepo};
use crate::review::{files_from_patch, patch_for_scope, remaining_after_scope};
use crate::shadow::ShadowWorkspace;
use crate::state::{
    now_unix, state_file, ApplyStage, PendingApply, ReviewItem, ReviewStatus, SessionState,
};

pub trait EventSink {
    fn emit(&mut self, event: BridgeEvent);
    /// Write a response to a specific request id. Used to reply with an error
    /// when a non-approval request arrives while the bridge is waiting for
    /// approval. Default is a no-op (e.g. in test sinks).
    fn reply(&mut self, _response: codex_workbench_protocol::BridgeResponse) {}
}

#[derive(Debug, Clone)]
struct RuntimeConfig {
    codex_cmd: String,
    max_untracked_file_bytes: u64,
    max_untracked_total_bytes: u64,
    max_recent_prompts: usize,
}

pub struct Manager {
    config: Option<RuntimeConfig>,
    real: Option<GitRepo>,
    shadow: Option<ShadowWorkspace>,
    state: SessionState,
    state_path: Option<PathBuf>,
    app_server: Option<Box<dyn AppServer>>,
    /// Active external stage tracked between `stage_begin` and `stage_finalize`.
    ///
    /// Not persisted to disk — if the bridge restarts mid-stage, the caller
    /// must restart the stage. This trades crash-safety for simplicity, which
    /// is acceptable because external stages are short-lived (one tool call).
    active_stage: Option<ExternalStage>,
    /// Exclusive lock file held for the lifetime of this Manager instance.
    /// Dropping the Manager automatically releases the lock.
    _lock: Option<File>,
}

/// In-flight external write transaction (issue #44 / P0).
#[derive(Debug, Clone)]
struct ExternalStage {
    stage_id: String,
    base_tree: String,
    base_head: String,
    real_fingerprint: String,
}

impl Default for Manager {
    fn default() -> Self {
        Self::new()
    }
}

impl Manager {
    pub fn new() -> Self {
        Self {
            config: None,
            real: None,
            shadow: None,
            state: SessionState::default(),
            state_path: None,
            app_server: None,
            active_stage: None,
            _lock: None,
        }
    }

    /// Inject a custom [`AppServer`] implementation before the first `ask` /
    /// `threads` call. Used in integration tests to avoid spawning a real Codex
    /// process; also useful for diagnostics in production.
    pub fn inject_app_server(&mut self, app: Box<dyn AppServer>) {
        debug_assert!(
            self.app_server.is_none(),
            "inject_app_server must be called before the first ask/threads call"
        );
        self.app_server = Some(app);
    }

    pub fn handle(
        &mut self,
        request: BridgeRequest,
        bridge_rx: &Receiver<BridgeRequest>,
        sink: &mut dyn EventSink,
    ) -> Result<Value> {
        match request.method.as_str() {
            "initialize" => {
                let params: InitializeParams = serde_json::from_value(request.params)?;
                self.initialize(params, sink)
            }
            "ask" => {
                let params: AskParams = serde_json::from_value(request.params)?;
                self.ask(params, bridge_rx, sink)
            }
            "review" => self.review(),
            "recent_prompts" => {
                let params: RecentPromptsParams = serde_json::from_value(request.params)?;
                self.recent_prompts(params)
            }
            "threads" => self.threads(),
            "thread/messages" => {
                let params: ThreadMessagesParams = serde_json::from_value(request.params)?;
                self.thread_messages(params)
            }
            "thread/delete" => {
                let params: ThreadIdParams = serde_json::from_value(request.params)?;
                self.delete_thread(params)
            }
            "accept" => {
                let params: ScopeParams = serde_json::from_value(request.params)?;
                self.accept(&params.scope, sink)
            }
            "reject" => {
                let params: ScopeParams = serde_json::from_value(request.params)?;
                self.reject(&params.scope, sink)
            }
            "resume" => self.resume(request.params),
            "fork" => self.fork(),
            "abandon_review" => self.abandon_review(sink),
            "stage_begin" => {
                let params: StageBeginParams =
                    serde_json::from_value(request.params).unwrap_or_default();
                self.stage_begin(params)
            }
            "stage_finalize" => {
                let params: StageFinalizeParams =
                    serde_json::from_value(request.params).unwrap_or_default();
                self.stage_finalize(params, sink)
            }
            "status" => self.status(),
            "health" => self.health(),
            "approval_response" => Ok(json!({ "ignored": true })),
            other => Err(anyhow!(BridgeError::UnknownMethod {
                method: other.to_string(),
            })),
        }
    }

    fn initialize(&mut self, params: InitializeParams, sink: &mut dyn EventSink) -> Result<Value> {
        let real = GitRepo::discover(&params.workspace)?;
        let state_root = params
            .state_dir
            .as_ref()
            .map(PathBuf::from)
            .unwrap_or_else(|| real.root.join(".codex-workbench"));
        let shadow_root = PathBuf::from(&params.shadow_root);
        let shadow = ShadowWorkspace::prepare(&real, &state_root, &shadow_root)?;
        let state_path = state_file(&shadow.state_dir);

        // Acquire an exclusive workspace lock before loading state so that
        // two Neovim instances cannot operate on the same workspace simultaneously.
        let lock = acquire_workspace_lock(&shadow.state_dir.join(".lock"))?;

        let mut state = SessionState::load(&state_path)?;
        state.workspace = real.root.to_string_lossy().to_string();
        state.shadow_path = shadow.shadow_path.to_string_lossy().to_string();

        // Detect an incomplete apply from a previous crash and warn the user.
        if let Some(pa) = &state.pending_apply {
            sink.emit(BridgeEvent::new(
                "recovery_needed",
                json!({
                    "stage": pa.stage,
                    "scope": pa.scope,
                    "started_at": pa.started_at,
                }),
            ));
            // Clear the stale pending_apply so the workspace is usable again.
            state.pending_apply = None;
        }

        state.save(&state_path)?;

        self.config = Some(RuntimeConfig {
            codex_cmd: params.codex_cmd,
            max_untracked_file_bytes: params.max_untracked_file_bytes,
            max_untracked_total_bytes: params.max_untracked_total_bytes,
            max_recent_prompts: params.max_recent_prompts,
        });
        self.real = Some(real);
        self.shadow = Some(shadow);
        self.state = state;
        self.state_path = Some(state_path);
        self._lock = Some(lock);

        sink.emit(BridgeEvent::new(
            "ready",
            json!({
                "workspace": self.real()?.root.to_string_lossy().to_string(),
                "shadow_path": self.shadow()?.shadow_path.to_string_lossy().to_string(),
                "state": &self.state,
            }),
        ));

        self.status()
    }

    fn ask(
        &mut self,
        params: AskParams,
        bridge_rx: &Receiver<BridgeRequest>,
        sink: &mut dyn EventSink,
    ) -> Result<Value> {
        self.ensure_no_pending_review()?;
        let config = self.config()?.clone();
        if params.persist_history {
            self.state
                .push_recent_prompt_with_limit(params.prompt.clone(), config.max_recent_prompts);
            self.save_state()?;
        }
        let real = self.real()?.clone();
        let shadow = self.shadow()?.clone();

        let sync = shadow.sync_from_real(
            &real,
            config.max_untracked_file_bytes,
            config.max_untracked_total_bytes,
        )?;
        for warning in &sync.warnings {
            sink.emit(BridgeEvent::new("shadow_warning", warning));
        }

        let shadow_repo = shadow.shadow_repo();
        let base_tree = shadow_repo.write_worktree_tree()?;
        let base_head = real.head()?;
        let real_fingerprint = real.fingerprint(
            config.max_untracked_file_bytes,
            config.max_untracked_total_bytes,
        )?;

        self.ensure_app_server()?;
        if params.new_thread {
            self.state.thread_id = None;
            self.app_server.as_deref_mut().unwrap().set_thread_id(None);
        } else if let Some(thread_id) = params.thread_id.as_deref().filter(|id| !id.is_empty()) {
            let resumed = self
                .app_server
                .as_deref_mut()
                .unwrap()
                .resume_thread(thread_id, &shadow.shadow_path)?;
            self.state.thread_id = Some(resumed);
            self.save_state()?;
        } else if let Some(thread_id) = self.state.thread_id.clone() {
            let resumed = self
                .app_server
                .as_deref_mut()
                .unwrap()
                .resume_thread(&thread_id, &shadow.shadow_path)?;
            self.state.thread_id = Some(resumed);
            self.save_state()?;
        }

        let turn_id = self.app_server.as_deref_mut().unwrap().run_turn(
            &params.prompt,
            &shadow.shadow_path,
            bridge_rx,
            sink,
        )?;

        if let Some(thread_id) = self.app_server.as_deref().and_then(|app| app.thread_id()) {
            self.state.thread_id = Some(thread_id.to_string());
        }

        let patch = shadow_repo.diff_tree_to_worktree(&base_tree)?;
        let has_review = !patch.trim().is_empty();
        if has_review {
            let review = ReviewItem {
                id: format!("{turn_id}-{}", now_unix()),
                turn_id: turn_id.clone(),
                base_head,
                real_head: real.head()?,
                shadow_head: shadow_repo.head()?,
                base_tree,
                real_fingerprint,
                files: files_from_patch(&patch),
                patch,
                created_at: now_unix(),
                status: ReviewStatus::Pending,
                error: None,
            };
            self.state.reviews.push(review.clone());
            self.save_state()?;
            sink.emit(BridgeEvent::new(
                "review_created",
                json!({ "item": review }),
            ));
        } else {
            self.save_state()?;
        }

        Ok(json!({ "turn_id": turn_id, "has_review": has_review }))
    }

    fn review(&self) -> Result<Value> {
        Ok(json!({
            "pending": self.state.pending_review(),
            "reviews": &self.state.reviews,
        }))
    }

    fn recent_prompts(&self, params: RecentPromptsParams) -> Result<Value> {
        self.config()?;
        Ok(json!({
            "prompts": self.state.recent_prompts(params.limit as usize),
        }))
    }

    fn threads(&mut self) -> Result<Value> {
        self.ensure_app_server()?;
        let real_root = self.real()?.root.to_string_lossy().to_string();
        let shadow_path = self.shadow()?.shadow_path.to_string_lossy().to_string();
        let result = self
            .app_server
            .as_mut()
            .unwrap()
            .list_threads(&[real_root.clone(), shadow_path.clone()])?;
        let threads = result
            .get("data")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .map(|thread| {
                        json!({
                            "id": thread.get("id").and_then(Value::as_str),
                            "name": thread.get("name").and_then(Value::as_str),
                            "preview": thread.get("preview").and_then(Value::as_str).map(trim_preview),
                            "cwd": thread.get("cwd").and_then(Value::as_str),
                            "status": thread.get("status").and_then(status_label),
                            "source": thread.get("source").and_then(source_label),
                            "updated_at": thread.get("updatedAt"),
                            "created_at": thread.get("createdAt"),
                        })
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();

        Ok(json!({
            "project": {
                "workspace": real_root,
                "shadow_path": shadow_path,
                "current_thread_id": &self.state.thread_id,
            },
            "threads": threads,
        }))
    }

    fn thread_messages(&mut self, params: ThreadMessagesParams) -> Result<Value> {
        self.ensure_app_server()?;
        let result = self
            .app_server
            .as_mut()
            .unwrap()
            .thread_messages(&params.thread_id, params.limit)?;
        let raw = result
            .get("messages")
            .or_else(|| result.get("data"))
            .or_else(|| result.get("items"))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let start = raw.len().saturating_sub(params.limit);
        let messages = raw
            .into_iter()
            .skip(start)
            .map(|message| {
                json!({
                    "role": message.get("role")
                        .or_else(|| message.get("type"))
                        .or_else(|| message.get("author"))
                        .and_then(Value::as_str)
                        .unwrap_or("message"),
                    "text": message_text(&message),
                })
            })
            .collect::<Vec<_>>();
        Ok(json!({
            "thread_id": params.thread_id,
            "messages": messages,
        }))
    }

    fn delete_thread(&mut self, params: ThreadIdParams) -> Result<Value> {
        self.ensure_app_server()?;
        let result = self
            .app_server
            .as_mut()
            .unwrap()
            .delete_thread(&params.thread_id)?;
        let deleted = result
            .get("deleted")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        if deleted && self.state.thread_id.as_deref() == Some(params.thread_id.as_str()) {
            self.state.thread_id = None;
            self.save_state()?;
        }
        Ok(json!({
            "thread_id": params.thread_id,
            "deleted": deleted,
            "raw": result,
        }))
    }

    /// Accept a review scope, applying the patch to the real workspace.
    ///
    /// The operation is staged so that a crash can be detected on restart:
    ///
    /// 1. `pending_apply.stage = Applying`  — saved before `git apply`
    /// 2. `pending_apply.stage = Applied`   — saved after `git apply` succeeds
    /// 3. `pending_apply.stage = ShadowResyncing` — saved before shadow sync
    /// 4. `pending_apply` cleared            — saved after full completion
    ///
    /// On the next `initialize`, a leftover `pending_apply` triggers a
    /// `recovery_needed` event so the user can inspect and remediate.
    fn accept(&mut self, scope: &str, sink: &mut dyn EventSink) -> Result<Value> {
        let config = self.config()?.clone();
        let real = self.real()?.clone();
        let shadow = self.shadow()?.clone();
        let selected_patch = {
            let review = self
                .state
                .pending_review()
                .ok_or_else(|| anyhow!(BridgeError::NoPendingReview))?;
            self.ensure_real_unchanged(review)?;
            patch_for_scope(&review.patch, scope)?
        };

        // Stage 1: record intent before touching the real workspace.
        let patch_sha256 = sha256_hex(&selected_patch);
        self.state.pending_apply = Some(PendingApply {
            scope: scope.to_string(),
            patch_sha256,
            started_at: now_unix(),
            stage: ApplyStage::Applying,
        });
        self.save_state()?;

        match real.apply_patch(&selected_patch) {
            Ok(()) => {
                // Stage 2: patch applied to real workspace.
                if let Some(pa) = self.state.pending_apply.as_mut() {
                    pa.stage = ApplyStage::Applied;
                }
                self.update_pending_after_scope(scope, true, None)?;
                self.save_state()?;

                // Stage 3: shadow re-sync in progress.
                if let Some(pa) = self.state.pending_apply.as_mut() {
                    pa.stage = ApplyStage::ShadowResyncing;
                }
                self.save_state()?;

                shadow.sync_from_real(
                    &real,
                    config.max_untracked_file_bytes,
                    config.max_untracked_total_bytes,
                )?;
                let next_fingerprint = real.fingerprint(
                    config.max_untracked_file_bytes,
                    config.max_untracked_total_bytes,
                )?;
                if let Some(review) = self.state.pending_review_mut() {
                    review.real_fingerprint = next_fingerprint;
                }

                // Done: clear the transactional marker.
                self.state.pending_apply = None;
                self.save_state()?;
                sink.emit(BridgeEvent::new("review_state", self.review()?));
                Ok(json!({ "accepted": scope }))
            }
            Err(error) => {
                let stderr_tail = error
                    .downcast_ref::<GitInvocationError>()
                    .map(|git| git.stderr_tail.clone())
                    .unwrap_or_else(|| error.to_string());
                if let Some(review) = self.state.pending_review_mut() {
                    review.status = ReviewStatus::ApplyFailed;
                    review.error = Some(stderr_tail.clone());
                }
                // Clear pending_apply on failure — no partial state to recover.
                self.state.pending_apply = None;
                self.save_state()?;
                Err(anyhow!(BridgeError::PatchApplyFailed {
                    scope: scope.to_string(),
                    stderr_tail,
                }))
            }
        }
    }

    fn reject(&mut self, scope: &str, sink: &mut dyn EventSink) -> Result<Value> {
        let config = self.config()?.clone();
        let real = self.real()?.clone();
        let shadow = self.shadow()?.clone();
        let review = self
            .state
            .pending_review()
            .ok_or_else(|| anyhow!(BridgeError::NoPendingReview))?
            .clone();
        self.ensure_real_unchanged(&review)?;
        self.update_pending_after_scope(scope, false, None)?;
        shadow.sync_from_real(
            &real,
            config.max_untracked_file_bytes,
            config.max_untracked_total_bytes,
        )?;
        self.save_state()?;
        sink.emit(BridgeEvent::new("review_state", self.review()?));
        Ok(json!({ "rejected": scope }))
    }

    fn resume(&mut self, params: Value) -> Result<Value> {
        let thread_id = params
            .get("thread_id")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| self.state.thread_id.clone())
            .ok_or_else(|| {
                anyhow!(BridgeError::NoThread {
                    action: "resume".into()
                })
            })?;
        let shadow_path = self.shadow()?.shadow_path.clone();
        let app = self.app_server()?;
        let resumed = if app.thread_id() == Some(thread_id.as_str()) {
            thread_id
        } else {
            app.resume_thread(&thread_id, &shadow_path)?
        };
        self.state.thread_id = Some(resumed.clone());
        self.save_state()?;
        Ok(json!({ "thread_id": resumed }))
    }

    fn fork(&mut self) -> Result<Value> {
        let source = self.state.thread_id.clone().ok_or_else(|| {
            anyhow!(BridgeError::NoThread {
                action: "fork".into()
            })
        })?;
        if self.state.pending_review().is_some() {
            self.abandon_pending_review()?;
        }
        let shadow_path = self.shadow()?.shadow_path.clone();
        let app = self.app_server()?;
        let forked = app.fork_thread(&source, &shadow_path)?;
        self.state.thread_id = Some(forked.clone());
        self.save_state()?;
        Ok(json!({ "thread_id": forked, "forked_from": source }))
    }

    fn abandon_review(&mut self, sink: &mut dyn EventSink) -> Result<Value> {
        self.abandon_pending_review()?;
        self.save_state()?;
        sink.emit(BridgeEvent::new("review_state", self.review()?));
        Ok(json!({ "abandoned": true }))
    }

    /// Begin a backend-neutral external write stage (issue #44 / P0).
    ///
    /// Mirrors the prep half of [`Self::ask`] without invoking the AppServer:
    /// syncs the shadow worktree from the real workspace, captures a base tree
    /// and fingerprint, and records an [`ExternalStage`]. The caller (typically
    /// a codecompanion extension) is then expected to write file edits into
    /// `shadow_path` and finally invoke `stage_finalize` to materialize the
    /// resulting diff as a `ReviewItem`.
    fn stage_begin(&mut self, params: StageBeginParams) -> Result<Value> {
        self.ensure_no_pending_review()?;
        if self.active_stage.is_some() {
            return Err(anyhow!(BridgeError::ReviewPending));
        }
        let config = self.config()?.clone();
        let real = self.real()?.clone();
        let shadow = self.shadow()?.clone();

        let sync = shadow.sync_from_real(
            &real,
            config.max_untracked_file_bytes,
            config.max_untracked_total_bytes,
        )?;
        let warnings = sync.warnings;

        let shadow_repo = shadow.shadow_repo();
        let base_tree = shadow_repo.write_worktree_tree()?;
        let base_head = real.head()?;
        let real_fingerprint = real.fingerprint(
            config.max_untracked_file_bytes,
            config.max_untracked_total_bytes,
        )?;
        let label = params.label.as_deref().unwrap_or("external");
        let stage_id = format!("{label}-{}", now_unix());
        self.active_stage = Some(ExternalStage {
            stage_id: stage_id.clone(),
            base_tree,
            base_head,
            real_fingerprint,
        });
        Ok(json!({
            "stage_id": stage_id,
            "shadow_path": shadow.shadow_path.to_string_lossy().to_string(),
            "warnings": warnings,
        }))
    }

    /// Finalize the in-flight external stage by diffing the shadow worktree
    /// against the captured base tree. When the diff is non-empty, a
    /// [`ReviewItem`] is created and a `review_created` event is emitted —
    /// from this point onward the existing accept/reject flow takes over.
    fn stage_finalize(
        &mut self,
        params: StageFinalizeParams,
        sink: &mut dyn EventSink,
    ) -> Result<Value> {
        let stage = self
            .active_stage
            .take()
            .ok_or_else(|| anyhow!(BridgeError::NoActiveStage))?;
        if let Some(expected) = params.stage_id.as_deref() {
            if expected != stage.stage_id {
                // Restore so callers can recover by retrying with the right id.
                self.active_stage = Some(stage);
                return Err(anyhow!(BridgeError::NoActiveStage));
            }
        }

        let real = self.real()?.clone();
        let shadow = self.shadow()?.clone();
        let shadow_repo = shadow.shadow_repo();
        let patch = shadow_repo.diff_tree_to_worktree(&stage.base_tree)?;
        let has_review = !patch.trim().is_empty();
        if has_review {
            let review = ReviewItem {
                id: format!("{}-{}", stage.stage_id, now_unix()),
                turn_id: stage.stage_id.clone(),
                base_head: stage.base_head,
                real_head: real.head()?,
                shadow_head: shadow_repo.head()?,
                base_tree: stage.base_tree,
                real_fingerprint: stage.real_fingerprint,
                files: files_from_patch(&patch),
                patch,
                created_at: now_unix(),
                status: ReviewStatus::Pending,
                error: None,
            };
            self.state.reviews.push(review.clone());
            self.save_state()?;
            sink.emit(BridgeEvent::new(
                "review_created",
                json!({ "item": review }),
            ));
        }
        Ok(json!({
            "stage_id": stage.stage_id,
            "has_review": has_review,
        }))
    }

    fn status(&self) -> Result<Value> {
        Ok(json!({
            "initialized": self.real.is_some(),
            "workspace": self.real.as_ref().map(|r| r.root.to_string_lossy().to_string()),
            "shadow_path": self.shadow.as_ref().map(|s| s.shadow_path.to_string_lossy().to_string()),
            "thread_id": &self.state.thread_id,
            "pending_review": self.state.pending_review(),
        }))
    }

    fn health(&self) -> Result<Value> {
        let codex_cmd = self
            .config
            .as_ref()
            .map(|config| config.codex_cmd.as_str())
            .unwrap_or("codex");
        let git_ok = Command::new("git").arg("--version").output().is_ok();
        let codex_version = Command::new(codex_cmd).arg("--version").output();
        Ok(json!({
            "git": git_ok,
            "codex": codex_version.as_ref().ok().and_then(|o| String::from_utf8(o.stdout.clone()).ok()).map(|s| s.trim().to_string()),
            "bridge": env!("CARGO_PKG_VERSION"),
            "workspace": self.real.as_ref().map(|r| r.root.to_string_lossy().to_string()),
            "shadow_path": self.shadow.as_ref().map(|s| s.shadow_path.to_string_lossy().to_string()),
        }))
    }

    fn update_pending_after_scope(
        &mut self,
        scope: &str,
        accepted: bool,
        error: Option<String>,
    ) -> Result<()> {
        let review = self
            .state
            .pending_review_mut()
            .ok_or_else(|| anyhow!(BridgeError::NoPendingReview))?;
        let remaining = remaining_after_scope(&review.patch, scope)?;
        if remaining.trim().is_empty() {
            review.status = if accepted {
                ReviewStatus::Accepted
            } else {
                ReviewStatus::Rejected
            };
        }
        review.patch = remaining;
        review.files = files_from_patch(&review.patch);
        review.error = error;
        Ok(())
    }

    fn abandon_pending_review(&mut self) -> Result<()> {
        let config = self.config()?.clone();
        let real = self.real()?.clone();
        let shadow = self.shadow()?.clone();
        if let Some(review) = self.state.pending_review_mut() {
            review.status = ReviewStatus::Rejected;
            review.patch.clear();
            review.files.clear();
        }
        shadow.sync_from_real(
            &real,
            config.max_untracked_file_bytes,
            config.max_untracked_total_bytes,
        )?;
        Ok(())
    }

    fn ensure_no_pending_review(&self) -> Result<()> {
        if let Some(review) = self.state.pending_review() {
            self.ensure_real_unchanged(review)?;
            return Err(anyhow!(BridgeError::ReviewPending));
        }
        Ok(())
    }

    fn ensure_real_unchanged(&self, review: &ReviewItem) -> Result<()> {
        let config = self.config()?;
        let fingerprint = self.real()?.fingerprint(
            config.max_untracked_file_bytes,
            config.max_untracked_total_bytes,
        )?;
        if fingerprint != review.real_fingerprint {
            return Err(anyhow!(BridgeError::RealWorkspaceChanged));
        }
        Ok(())
    }

    fn save_state(&self) -> Result<()> {
        let path = self
            .state_path
            .as_ref()
            .ok_or_else(|| anyhow!(BridgeError::NotInitialized))?;
        self.state.save(path)
    }

    fn app_server(&mut self) -> Result<&mut dyn AppServer> {
        self.ensure_app_server()?;
        Ok(self.app_server.as_deref_mut().unwrap())
    }

    #[cfg(feature = "codex")]
    fn ensure_app_server(&mut self) -> Result<()> {
        if self.app_server.is_none() {
            let codex_cmd = self.config()?.codex_cmd.clone();
            self.app_server = Some(Box::new(AppServerClient::spawn(&codex_cmd)?));
        }
        Ok(())
    }

    /// Without the `codex` feature, the bridge has no built-in way to spawn an
    /// AppServer. Tests and external integrations must inject one via
    /// [`Manager::inject_app_server`] before calling Codex-flavored methods.
    #[cfg(not(feature = "codex"))]
    fn ensure_app_server(&mut self) -> Result<()> {
        if self.app_server.is_none() {
            return Err(anyhow!(BridgeError::CodexBackendDisabled));
        }
        Ok(())
    }

    fn config(&self) -> Result<&RuntimeConfig> {
        self.config
            .as_ref()
            .ok_or_else(|| anyhow!(BridgeError::NotInitialized))
    }

    fn real(&self) -> Result<&GitRepo> {
        self.real
            .as_ref()
            .ok_or_else(|| anyhow!(BridgeError::NotInitialized))
    }

    fn shadow(&self) -> Result<&ShadowWorkspace> {
        self.shadow
            .as_ref()
            .ok_or_else(|| anyhow!(BridgeError::NotInitialized))
    }
}

/// Acquire an exclusive lock on `lock_path`. Writes the current PID into the
/// lock file so that holder identity is visible on lock contention.
///
/// The returned `File` must be kept alive for as long as the lock should be
/// held — dropping it releases the lock automatically (fs2 uses POSIX advisory
/// locking on Unix, which is tied to the file descriptor lifetime).
fn acquire_workspace_lock(lock_path: &std::path::Path) -> Result<File> {
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(lock_path)?;

    if file.try_lock_exclusive().is_ok() {
        // We hold the lock — record our PID for diagnostics.
        file.set_len(0)?;
        writeln!(file, "{}", std::process::id())?;
        return Ok(file);
    }

    // Read the holder PID from the lock file (best-effort).
    let holder_pid = std::fs::read_to_string(lock_path)
        .ok()
        .and_then(|s| s.trim().parse::<u32>().ok());
    Err(anyhow!(BridgeError::WorkspaceLocked { holder_pid }))
}

fn sha256_hex(data: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data.as_bytes());
    format!("{:x}", hasher.finalize())
}

fn trim_preview(text: &str) -> String {
    let flattened = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut out = String::new();
    for (idx, ch) in flattened.chars().enumerate() {
        if idx >= 120 {
            out.push('…');
            return out;
        }
        out.push(ch);
    }
    out
}

fn status_label(value: &Value) -> Option<&str> {
    value
        .get("type")
        .and_then(Value::as_str)
        .or_else(|| value.as_str())
}

fn source_label(value: &Value) -> Option<&str> {
    value.as_str().or_else(|| {
        value
            .get("custom")
            .and_then(Value::as_str)
            .or_else(|| value.get("subAgent").map(|_| "subAgent"))
    })
}

fn message_text(value: &Value) -> String {
    if let Some(text) = value
        .get("text")
        .or_else(|| value.get("content"))
        .or_else(|| value.get("message"))
        .and_then(Value::as_str)
    {
        return text.to_string();
    }
    if let Some(items) = value
        .get("content")
        .or_else(|| value.get("items"))
        .and_then(Value::as_array)
    {
        let parts = items
            .iter()
            .filter_map(|item| {
                item.get("text")
                    .or_else(|| item.get("content"))
                    .and_then(Value::as_str)
            })
            .collect::<Vec<_>>();
        if !parts.is_empty() {
            return parts.join("\n");
        }
    }
    String::new()
}
