use std::path::PathBuf;
use std::process::Command;
use std::sync::mpsc::Receiver;

use anyhow::{anyhow, Context, Result};
use codex_workbench_protocol::{
    AskParams, BridgeEvent, BridgeRequest, InitializeParams, ScopeParams,
};
use serde_json::{json, Value};

use crate::app_server::AppServerClient;
use crate::git::GitRepo;
use crate::review::{files_from_patch, patch_for_scope, remaining_after_scope};
use crate::shadow::ShadowWorkspace;
use crate::state::{now_unix, state_file, ReviewItem, ReviewStatus, SessionState};

pub trait EventSink {
    fn emit(&mut self, event: BridgeEvent);
}

#[derive(Debug, Clone)]
struct RuntimeConfig {
    codex_cmd: String,
    max_untracked_file_bytes: u64,
    max_untracked_total_bytes: u64,
}

pub struct Manager {
    config: Option<RuntimeConfig>,
    real: Option<GitRepo>,
    shadow: Option<ShadowWorkspace>,
    state: SessionState,
    state_path: Option<PathBuf>,
    app_server: Option<AppServerClient>,
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
        }
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
            "status" => self.status(),
            "health" => self.health(),
            "approval_response" => Ok(json!({ "ignored": true })),
            other => Err(anyhow!("unknown bridge method: {other}")),
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
        let mut state = SessionState::load(&state_path)?;
        state.workspace = real.root.to_string_lossy().to_string();
        state.shadow_path = shadow.shadow_path.to_string_lossy().to_string();
        state.save(&state_path)?;

        self.config = Some(RuntimeConfig {
            codex_cmd: params.codex_cmd,
            max_untracked_file_bytes: params.max_untracked_file_bytes,
            max_untracked_total_bytes: params.max_untracked_total_bytes,
        });
        self.real = Some(real);
        self.shadow = Some(shadow);
        self.state = state;
        self.state_path = Some(state_path);

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

        if self.app_server.is_none() {
            self.app_server = Some(AppServerClient::spawn(&config.codex_cmd)?);
            if let Some(thread_id) = self.state.thread_id.clone() {
                let resumed = self
                    .app_server
                    .as_mut()
                    .unwrap()
                    .resume_thread(&thread_id, &shadow.shadow_path)?;
                self.state.thread_id = Some(resumed);
                self.save_state()?;
            }
        }

        let turn_id = self.app_server.as_mut().unwrap().run_turn(
            &params.prompt,
            &shadow.shadow_path,
            bridge_rx,
            sink,
        )?;

        if let Some(thread_id) = self
            .app_server
            .as_ref()
            .and_then(AppServerClient::thread_id)
        {
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

    fn accept(&mut self, scope: &str, sink: &mut dyn EventSink) -> Result<Value> {
        let config = self.config()?.clone();
        let real = self.real()?.clone();
        let shadow = self.shadow()?.clone();
        let selected_patch = {
            let review = self
                .state
                .pending_review()
                .ok_or_else(|| anyhow!("no pending review"))?;
            self.ensure_real_unchanged(review)?;
            patch_for_scope(&review.patch, scope)?
        };

        match real.apply_patch(&selected_patch) {
            Ok(()) => {
                self.update_pending_after_scope(scope, true, None)?;
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
                self.save_state()?;
                sink.emit(BridgeEvent::new("review_state", self.review()?));
                Ok(json!({ "accepted": scope }))
            }
            Err(error) => {
                if let Some(review) = self.state.pending_review_mut() {
                    review.status = ReviewStatus::ApplyFailed;
                    review.error = Some(error.to_string());
                }
                self.save_state()?;
                Err(anyhow!("failed to apply review patch: {error}"))
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
            .ok_or_else(|| anyhow!("no pending review"))?
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
            .ok_or_else(|| anyhow!("no thread id to resume"))?;
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
        let source = self
            .state
            .thread_id
            .clone()
            .ok_or_else(|| anyhow!("no thread id to fork"))?;
        let shadow_path = self.shadow()?.shadow_path.clone();
        let app = self.app_server()?;
        let forked = app.fork_thread(&source, &shadow_path)?;
        self.state.thread_id = Some(forked.clone());
        self.save_state()?;
        Ok(json!({ "thread_id": forked, "forked_from": source }))
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
            .ok_or_else(|| anyhow!("no pending review"))?;
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

    fn ensure_no_pending_review(&self) -> Result<()> {
        if let Some(review) = self.state.pending_review() {
            self.ensure_real_unchanged(review)?;
            return Err(anyhow!(
                "pending review exists; accept, reject, or fork before sending a new prompt"
            ));
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
            return Err(anyhow!(
                "real workspace changed while review is pending; accept/reject is blocked"
            ));
        }
        Ok(())
    }

    fn save_state(&self) -> Result<()> {
        self.state.save(
            self.state_path
                .as_ref()
                .context("manager is not initialized")?,
        )
    }

    fn app_server(&mut self) -> Result<&mut AppServerClient> {
        if self.app_server.is_none() {
            let codex_cmd = self.config()?.codex_cmd.clone();
            self.app_server = Some(AppServerClient::spawn(&codex_cmd)?);
        }
        Ok(self.app_server.as_mut().unwrap())
    }

    fn config(&self) -> Result<&RuntimeConfig> {
        self.config
            .as_ref()
            .ok_or_else(|| anyhow!("bridge is not initialized"))
    }

    fn real(&self) -> Result<&GitRepo> {
        self.real
            .as_ref()
            .ok_or_else(|| anyhow!("bridge is not initialized"))
    }

    fn shadow(&self) -> Result<&ShadowWorkspace> {
        self.shadow
            .as_ref()
            .ok_or_else(|| anyhow!("bridge is not initialized"))
    }
}
