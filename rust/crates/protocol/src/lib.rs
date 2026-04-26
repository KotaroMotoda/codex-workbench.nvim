use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Deserialize)]
pub struct BridgeRequest {
    pub id: Option<u64>,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Clone, Serialize)]
pub struct BridgeResponse {
    pub id: u64,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl BridgeResponse {
    pub fn ok(id: u64, result: impl Serialize) -> Self {
        Self {
            id,
            ok: true,
            result: Some(serde_json::to_value(result).unwrap_or(Value::Null)),
            error: None,
        }
    }

    pub fn err(id: u64, error: impl Into<String>) -> Self {
        Self {
            id,
            ok: false,
            result: None,
            error: Some(error.into()),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct BridgeEvent {
    pub event: String,
    #[serde(flatten)]
    pub payload: Value,
}

impl BridgeEvent {
    pub fn new(event: impl Into<String>, payload: impl Serialize) -> Self {
        Self {
            event: event.into(),
            payload: serde_json::to_value(payload).unwrap_or(Value::Null),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct InitializeParams {
    pub workspace: String,
    #[serde(default)]
    pub state_dir: Option<String>,
    #[serde(default = "default_shadow_root")]
    pub shadow_root: String,
    #[serde(default = "default_codex_cmd")]
    pub codex_cmd: String,
    #[serde(default = "default_max_untracked_file_bytes")]
    pub max_untracked_file_bytes: u64,
    #[serde(default = "default_max_untracked_total_bytes")]
    pub max_untracked_total_bytes: u64,
}

fn default_codex_cmd() -> String {
    "codex".to_string()
}

fn default_shadow_root() -> String {
    ".codex-workbench-shadows".to_string()
}

fn default_max_untracked_file_bytes() -> u64 {
    5 * 1024 * 1024
}

fn default_max_untracked_total_bytes() -> u64 {
    50 * 1024 * 1024
}

#[derive(Debug, Clone, Deserialize)]
pub struct AskParams {
    pub prompt: String,
    #[serde(default)]
    pub thread_id: Option<String>,
    #[serde(default)]
    pub new_thread: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ScopeParams {
    #[serde(default = "default_scope")]
    pub scope: String,
}

fn default_scope() -> String {
    "all".to_string()
}

#[derive(Debug, Clone, Deserialize)]
pub struct ApprovalResponseParams {
    pub approval_id: String,
    #[serde(default = "default_approval_decision")]
    pub decision: String,
}

fn default_approval_decision() -> String {
    "denied".to_string()
}
