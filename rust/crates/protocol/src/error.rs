use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use thiserror::Error;

/// Public, classified error returned by the bridge.
///
/// Each variant has a stable `code` (snake_case discriminant) which the Lua
/// side maps to a localized, user-facing message. Free-form details such as a
/// captured `stderr` tail or a remote error payload are kept inside `details`
/// so that the human message stays short and predictable.
#[derive(Debug, Clone, Error)]
pub enum BridgeError {
    #[error("bridge is not initialized")]
    NotInitialized,

    #[error("invalid request: {message}")]
    InvalidRequest { message: String },

    #[error("unknown bridge method: {method}")]
    UnknownMethod { method: String },

    #[error("workspace is not a git repository")]
    NotAGitRepository { workspace: String },

    #[error("git command `{command}` failed")]
    GitFailed {
        command: String,
        stderr_tail: String,
    },

    #[error("failed to apply review patch")]
    PatchApplyFailed { scope: String, stderr_tail: String },

    #[error("review scope is invalid: {reason}")]
    ScopeInvalid { scope: String, reason: String },

    #[error("file is not present in review patch: {path}")]
    ScopeFileNotFound { path: String },

    #[error("hunk is not present in review patch: {path}:{index}")]
    ScopeHunkNotFound { path: String, index: usize },

    #[error("no pending review")]
    NoPendingReview,

    #[error("a pending review must be resolved before sending a new prompt")]
    ReviewPending,

    #[error("real workspace changed while review is pending")]
    RealWorkspaceChanged,

    #[error("Codex app-server is not reachable")]
    AppServerCrashed { stderr_tail: String },

    #[error("Codex app-server returned an error")]
    AppServerError {
        method: String,
        code: Option<i64>,
        message: String,
    },

    #[error("Codex turn failed")]
    TurnFailed { turn_id: String, message: String },

    #[error("no thread to {action}")]
    NoThread { action: String },

    #[error("I/O error")]
    Io { message: String },

    #[error("internal error")]
    Internal { message: String },

    // ── Phase 2: idempotency / crash-safety ──────────────────────────────────
    #[error("state file is unavailable: {path}")]
    StateUnavailable { path: String, reason: String },

    #[error("workspace is locked by another process")]
    WorkspaceLocked { holder_pid: Option<u32> },

    #[error("shadow worktree is unavailable")]
    ShadowUnavailable { reason: String },
}

impl BridgeError {
    /// Stable, snake_case identifier the Lua side uses for localization.
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotInitialized => "not_initialized",
            Self::InvalidRequest { .. } => "invalid_request",
            Self::UnknownMethod { .. } => "unknown_method",
            Self::NotAGitRepository { .. } => "not_a_git_repository",
            Self::GitFailed { .. } => "git_failed",
            Self::PatchApplyFailed { .. } => "patch_apply_failed",
            Self::ScopeInvalid { .. } => "scope_invalid",
            Self::ScopeFileNotFound { .. } => "scope_file_not_found",
            Self::ScopeHunkNotFound { .. } => "scope_hunk_not_found",
            Self::NoPendingReview => "no_pending_review",
            Self::ReviewPending => "review_pending",
            Self::RealWorkspaceChanged => "real_workspace_changed",
            Self::AppServerCrashed { .. } => "app_server_crashed",
            Self::AppServerError { .. } => "app_server_error",
            Self::TurnFailed { .. } => "turn_failed",
            Self::NoThread { .. } => "no_thread",
            Self::Io { .. } => "io_error",
            Self::Internal { .. } => "internal_error",
            Self::StateUnavailable { .. } => "state_unavailable",
            Self::WorkspaceLocked { .. } => "workspace_locked",
            Self::ShadowUnavailable { .. } => "shadow_unavailable",
        }
    }

    /// Structured payload for `details`. Omits secrets and large blobs.
    pub fn details(&self) -> Value {
        match self {
            Self::NotInitialized
            | Self::NoPendingReview
            | Self::ReviewPending
            | Self::RealWorkspaceChanged => Value::Null,
            Self::InvalidRequest { message } => json!({ "message": message }),
            Self::UnknownMethod { method } => json!({ "method": method }),
            Self::NotAGitRepository { workspace } => json!({ "workspace": workspace }),
            Self::GitFailed {
                command,
                stderr_tail,
            } => {
                json!({ "command": command, "stderr_tail": stderr_tail })
            }
            Self::PatchApplyFailed { scope, stderr_tail } => {
                json!({ "scope": scope, "stderr_tail": stderr_tail })
            }
            Self::ScopeInvalid { scope, reason } => {
                json!({ "scope": scope, "reason": reason })
            }
            Self::ScopeFileNotFound { path } => json!({ "path": path }),
            Self::ScopeHunkNotFound { path, index } => {
                json!({ "path": path, "index": index })
            }
            Self::AppServerCrashed { stderr_tail } => {
                json!({ "stderr_tail": stderr_tail })
            }
            Self::AppServerError {
                method,
                code,
                message,
            } => {
                json!({ "method": method, "code": code, "message": message })
            }
            Self::TurnFailed { turn_id, message } => {
                json!({ "turn_id": turn_id, "message": message })
            }
            Self::NoThread { action } => json!({ "action": action }),
            Self::Io { message } | Self::Internal { message } => {
                json!({ "message": message })
            }
            Self::StateUnavailable { path, reason } => {
                json!({ "path": path, "reason": reason })
            }
            Self::WorkspaceLocked { holder_pid } => {
                json!({ "holder_pid": holder_pid })
            }
            Self::ShadowUnavailable { reason } => {
                json!({ "reason": reason })
            }
        }
    }
}

impl From<std::io::Error> for BridgeError {
    fn from(value: std::io::Error) -> Self {
        BridgeError::Io {
            message: value.to_string(),
        }
    }
}

impl From<serde_json::Error> for BridgeError {
    fn from(value: serde_json::Error) -> Self {
        BridgeError::InvalidRequest {
            message: value.to_string(),
        }
    }
}

/// Wire format for an error response. Stable field set, designed to be
/// forward-compatible with new variants.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorPayload {
    /// snake_case discriminant. Lua maps this to a localized message.
    pub code: String,
    /// Short, human-readable summary. Lua falls back to this only if `code` is
    /// not in its translation table.
    pub message: String,
    /// Structured, optional payload. Should never include secrets or large
    /// blobs (truncate `stderr` tails before placing them here).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

impl ErrorPayload {
    pub fn from_bridge_error(error: &BridgeError) -> Self {
        let details = error.details();
        let details = if details.is_null() {
            None
        } else {
            Some(details)
        };
        Self {
            code: error.code().to_string(),
            message: error.to_string(),
            details,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn no_pending_review_has_no_details() {
        let payload = ErrorPayload::from_bridge_error(&BridgeError::NoPendingReview);
        assert_eq!(payload.code, "no_pending_review");
        assert!(payload.details.is_none());
        assert!(!payload.message.is_empty());
    }

    #[test]
    fn git_failed_carries_command_and_stderr_tail() {
        let error = BridgeError::GitFailed {
            command: "apply".into(),
            stderr_tail: "patch does not apply".into(),
        };
        let payload = ErrorPayload::from_bridge_error(&error);
        assert_eq!(payload.code, "git_failed");
        let details = payload.details.expect("details should be present");
        assert_eq!(details["command"], json!("apply"));
        assert_eq!(details["stderr_tail"], json!("patch does not apply"));
    }

    #[test]
    fn payload_round_trips_through_json() {
        let error = BridgeError::ScopeHunkNotFound {
            path: "src/lib.rs".into(),
            index: 3,
        };
        let payload = ErrorPayload::from_bridge_error(&error);
        let serialized = serde_json::to_string(&payload).unwrap();
        let parsed: ErrorPayload = serde_json::from_str(&serialized).unwrap();
        assert_eq!(parsed.code, "scope_hunk_not_found");
        assert_eq!(parsed.details.unwrap()["index"], json!(3));
    }

    #[test]
    fn every_variant_has_a_unique_code() {
        // Sanity: catches accidental copy-paste in code() if a new variant is
        // added in the future.
        let codes = [
            BridgeError::NotInitialized.code(),
            BridgeError::InvalidRequest {
                message: "x".into(),
            }
            .code(),
            BridgeError::UnknownMethod { method: "x".into() }.code(),
            BridgeError::NotAGitRepository {
                workspace: "x".into(),
            }
            .code(),
            BridgeError::GitFailed {
                command: "x".into(),
                stderr_tail: "".into(),
            }
            .code(),
            BridgeError::PatchApplyFailed {
                scope: "all".into(),
                stderr_tail: "".into(),
            }
            .code(),
            BridgeError::ScopeInvalid {
                scope: "x".into(),
                reason: "y".into(),
            }
            .code(),
            BridgeError::ScopeFileNotFound { path: "x".into() }.code(),
            BridgeError::ScopeHunkNotFound {
                path: "x".into(),
                index: 0,
            }
            .code(),
            BridgeError::NoPendingReview.code(),
            BridgeError::ReviewPending.code(),
            BridgeError::RealWorkspaceChanged.code(),
            BridgeError::AppServerCrashed {
                stderr_tail: "".into(),
            }
            .code(),
            BridgeError::AppServerError {
                method: "x".into(),
                code: None,
                message: "y".into(),
            }
            .code(),
            BridgeError::TurnFailed {
                turn_id: "t".into(),
                message: "m".into(),
            }
            .code(),
            BridgeError::NoThread { action: "x".into() }.code(),
            BridgeError::Io {
                message: "x".into(),
            }
            .code(),
            BridgeError::Internal {
                message: "x".into(),
            }
            .code(),
            BridgeError::StateUnavailable {
                path: "x".into(),
                reason: "y".into(),
            }
            .code(),
            BridgeError::WorkspaceLocked { holder_pid: None }.code(),
            BridgeError::ShadowUnavailable { reason: "x".into() }.code(),
        ];
        let mut sorted = codes.to_vec();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), codes.len(), "duplicate error code detected");
    }
}
