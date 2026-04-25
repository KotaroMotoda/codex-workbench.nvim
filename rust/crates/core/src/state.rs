use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;

use crate::review::ReviewFile;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ReviewItem {
    pub id: String,
    pub turn_id: String,
    pub base_head: String,
    pub real_head: String,
    pub shadow_head: String,
    pub base_tree: String,
    pub real_fingerprint: String,
    pub patch: String,
    pub files: Vec<ReviewFile>,
    pub created_at: u64,
    pub status: ReviewStatus,
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewStatus {
    Pending,
    Accepted,
    Rejected,
    ApplyFailed,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct SessionState {
    #[serde(default)]
    pub workspace: String,
    #[serde(default)]
    pub shadow_path: String,
    #[serde(default)]
    pub thread_id: Option<String>,
    #[serde(default)]
    pub reviews: Vec<ReviewItem>,
}

impl SessionState {
    pub fn load(path: &Path) -> Result<Self> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let text = fs::read_to_string(path)?;
        Ok(serde_json::from_str(&text)?)
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let text = serde_json::to_string_pretty(self)?;
        fs::write(path, text)?;
        Ok(())
    }

    pub fn pending_review(&self) -> Option<&ReviewItem> {
        self.reviews
            .iter()
            .rev()
            .find(|review| review.status == ReviewStatus::Pending)
    }

    pub fn pending_review_mut(&mut self) -> Option<&mut ReviewItem> {
        self.reviews
            .iter_mut()
            .rev()
            .find(|review| review.status == ReviewStatus::Pending)
    }
}

pub fn state_file(state_dir: &Path) -> PathBuf {
    state_dir.join("state.json")
}

pub fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
