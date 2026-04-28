use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Result};
use codex_workbench_protocol::BridgeError;
use tempfile::NamedTempFile;

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

/// Tracks the progress of an in-flight `accept` operation so that a crash
/// mid-apply can be detected on the next `initialize` call.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApplyStage {
    /// `git apply` is about to run (or is running).
    Applying,
    /// `git apply` succeeded; state update in progress.
    Applied,
    /// Patch applied; shadow re-sync in progress.
    ShadowResyncing,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PendingApply {
    pub scope: String,
    /// SHA-256 hex of the patch bytes, for idempotent re-application.
    pub patch_sha256: String,
    pub started_at: u64,
    pub stage: ApplyStage,
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
    /// Set when an `accept` is in flight; cleared on completion or failure.
    /// A non-None value after restart means the previous run crashed mid-apply.
    #[serde(default)]
    pub pending_apply: Option<PendingApply>,
}

impl SessionState {
    /// Load state from `path`. On parse failure tries `path.bak`; if that also
    /// fails returns `Err(BridgeError::StateUnavailable)`.
    pub fn load(path: &Path) -> Result<Self> {
        if !path.exists() {
            return Ok(Self::default());
        }
        match Self::try_load(path) {
            Ok(state) => Ok(state),
            Err(primary) => {
                let bak = bak_path(path);
                if bak.exists() {
                    if let Ok(state) = Self::try_load(&bak) {
                        // Recovered from backup — log but don't fail.
                        eprintln!(
                            "[codex-workbench] state.json corrupt ({primary}); \
                             recovered from state.json.bak"
                        );
                        return Ok(state);
                    }
                }
                Err(anyhow!(BridgeError::StateUnavailable {
                    path: path.to_string_lossy().to_string(),
                    reason: primary.to_string(),
                }))
            }
        }
    }

    fn try_load(path: &Path) -> Result<Self> {
        let text = fs::read_to_string(path)?;
        Ok(serde_json::from_str(&text)?)
    }

    /// Atomically persist state.
    ///
    /// Copies the current on-disk file to `state.json.bak` (best-effort),
    /// then writes via a temp file in the same directory and renames it into
    /// place, so a crash mid-write cannot produce a truncated state.json.
    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        // Best-effort: keep previous version as a recovery backup.
        if path.exists() {
            let _ = fs::copy(path, bak_path(path));
        }
        // Atomic write: serialize into a NamedTempFile in the same directory,
        // then persist (rename) to the final path.
        let parent = path.parent().unwrap_or(Path::new("."));
        let mut tmp = NamedTempFile::new_in(parent)?;
        let json = serde_json::to_string_pretty(self)?;
        tmp.write_all(json.as_bytes())?;
        tmp.as_file().sync_all()?;
        tmp.persist(path)?;
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

fn bak_path(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    path.with_file_name(format!("{name}.bak"))
}

pub fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn save_is_atomic_and_load_recovers_from_bak() {
        let tmp = tempdir().unwrap();
        let path = tmp.path().join("state.json");

        // Save a valid state.
        let mut state = SessionState {
            workspace: "/test/workspace".to_string(),
            ..Default::default()
        };
        state.save(&path).unwrap();
        assert!(path.exists());
        assert!(!bak_path(&path).exists()); // no bak on first write

        // Save again — this time a .bak should appear.
        state.thread_id = Some("t1".into());
        state.save(&path).unwrap();
        assert!(bak_path(&path).exists());

        // Corrupt the main file.
        fs::write(&path, b"not json{{{").unwrap();

        // Load should recover from .bak.
        let loaded = SessionState::load(&path).unwrap();
        assert_eq!(loaded.workspace, "/test/workspace");
    }

    #[test]
    fn load_returns_state_unavailable_when_both_files_corrupt() {
        let tmp = tempdir().unwrap();
        let path = tmp.path().join("state.json");
        fs::write(&path, b"bad").unwrap();
        fs::write(bak_path(&path), b"also bad").unwrap();

        let err = SessionState::load(&path).unwrap_err();
        let bridge_err = err.downcast_ref::<BridgeError>();
        assert!(
            matches!(bridge_err, Some(BridgeError::StateUnavailable { .. })),
            "expected StateUnavailable, got {:?}",
            bridge_err
        );
    }
}
