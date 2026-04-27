use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Result};
use codex_workbench_protocol::BridgeError;

use crate::git::{
    git_output, git_success, repo_hash, worktree_add_detached, GitRepo, UntrackedCopyWarning,
};

#[derive(Debug, Clone, serde::Serialize)]
pub struct ShadowWorkspace {
    pub workspace_hash: String,
    pub state_dir: PathBuf,
    pub shadow_path: PathBuf,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct SyncReport {
    pub warnings: Vec<UntrackedCopyWarning>,
}

impl ShadowWorkspace {
    pub fn prepare(repo: &GitRepo, state_root: &Path, shadow_root: &Path) -> Result<Self> {
        let workspace_hash = repo_hash(&repo.root);
        let state_dir = state_root.join(&workspace_hash);
        let shadow_path = shadow_root.join(&workspace_hash);
        fs::create_dir_all(&state_dir)?;
        fs::create_dir_all(shadow_root)?;

        if shadow_path.exists() {
            // Verify that the directory is still registered as an active git
            // worktree. If it was left behind by a previous crash (the worktree
            // entry was pruned but the directory was not removed), a plain
            // `exists()` check would incorrectly reuse a broken directory.
            if !is_registered_worktree(&repo.root, &shadow_path)? {
                // Prune stale entries, then re-add.
                let _ = git_success(["worktree", "prune"], &repo.root, None);
                worktree_add_detached(&repo.root, &shadow_path).map_err(|e| {
                    anyhow!(BridgeError::ShadowUnavailable {
                        reason: format!("failed to re-add shadow worktree: {e}"),
                    })
                })?;
            }
        } else {
            worktree_add_detached(&repo.root, &shadow_path).map_err(|e| {
                anyhow!(BridgeError::ShadowUnavailable {
                    reason: format!(
                        "failed to create shadow worktree at {}: {e}",
                        shadow_path.display()
                    ),
                })
            })?;
        }

        Ok(Self {
            workspace_hash,
            state_dir,
            shadow_path,
        })
    }

    pub fn shadow_repo(&self) -> GitRepo {
        GitRepo {
            root: self.shadow_path.clone(),
        }
    }

    pub fn sync_from_real(
        &self,
        real: &GitRepo,
        max_file_bytes: u64,
        max_total_bytes: u64,
    ) -> Result<SyncReport> {
        let shadow = self.shadow_repo();
        shadow.reset_hard_to(&real.head()?)?;
        shadow.clean_untracked()?;

        let diff = real.diff_head()?;
        shadow.apply_patch_without_index(&diff)?;

        let warnings = copy_untracked(real, &shadow.root, max_file_bytes, max_total_bytes)?;
        Ok(SyncReport { warnings })
    }
}

/// Return `true` when `target` appears in `git worktree list --porcelain`
/// output for `repo_root`. A missing entry means the directory is an orphan
/// (the worktree was pruned or never properly added).
fn is_registered_worktree(repo_root: &Path, target: &Path) -> Result<bool> {
    let output = git_output(["worktree", "list", "--porcelain"], repo_root, None)?;
    let target_canonical = target
        .canonicalize()
        .unwrap_or_else(|_| target.to_path_buf());
    for line in output.lines() {
        if let Some(path_str) = line.strip_prefix("worktree ") {
            let candidate = PathBuf::from(path_str);
            let candidate_canonical = candidate.canonicalize().unwrap_or(candidate);
            if candidate_canonical == target_canonical {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

fn copy_untracked(
    real: &GitRepo,
    shadow_root: &Path,
    max_file_bytes: u64,
    max_total_bytes: u64,
) -> Result<Vec<UntrackedCopyWarning>> {
    let mut warnings = Vec::new();
    let mut total = 0_u64;

    for rel in real.untracked_files()? {
        let src = real.root.join(&rel);
        let dst = shadow_root.join(&rel);
        let meta = fs::symlink_metadata(&src)?;

        if meta.len() > max_file_bytes {
            warnings.push(UntrackedCopyWarning {
                path: rel,
                reason: format!("untracked file exceeds {} bytes", max_file_bytes),
            });
            continue;
        }
        if total.saturating_add(meta.len()) > max_total_bytes {
            warnings.push(UntrackedCopyWarning {
                path: rel,
                reason: format!("untracked total exceeds {} bytes", max_total_bytes),
            });
            continue;
        }

        if let Some(parent) = dst.parent() {
            fs::create_dir_all(parent)?;
        }

        let file_type = meta.file_type();
        if file_type.is_file() {
            fs::copy(&src, &dst)?;
            total += meta.len();
        } else if file_type.is_symlink() {
            copy_symlink(&src, &dst)?;
        } else {
            warnings.push(UntrackedCopyWarning {
                path: rel,
                reason: "untracked path is not a regular file or symlink".to_string(),
            });
        }
    }

    Ok(warnings)
}

#[cfg(unix)]
fn copy_symlink(src: &Path, dst: &Path) -> Result<()> {
    let target = fs::read_link(src)?;
    std::os::unix::fs::symlink(target, dst)?;
    Ok(())
}

#[cfg(not(unix))]
fn copy_symlink(_src: &Path, _dst: &Path) -> Result<()> {
    Err(anyhow::anyhow!(
        "symlink copy is unsupported on this platform"
    ))
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn syncs_dirty_tracked_staged_and_untracked_without_ignored() {
        let tmp = tempdir().unwrap();
        let repo_dir = tmp.path().join("repo");
        fs::create_dir_all(&repo_dir).unwrap();
        run(&repo_dir, ["git", "init", "-b", "main"]);
        run(
            &repo_dir,
            ["git", "config", "user.email", "test@example.com"],
        );
        run(&repo_dir, ["git", "config", "user.name", "Test"]);
        fs::write(repo_dir.join(".gitignore"), "ignored.txt\n").unwrap();
        fs::write(repo_dir.join("tracked.txt"), "base\n").unwrap();
        run(&repo_dir, ["git", "add", "."]);
        run(&repo_dir, ["git", "commit", "-m", "init"]);

        fs::write(repo_dir.join("tracked.txt"), "changed\n").unwrap();
        run(&repo_dir, ["git", "add", "tracked.txt"]);
        fs::write(repo_dir.join("untracked.txt"), "copy me\n").unwrap();
        fs::write(repo_dir.join("ignored.txt"), "ignore me\n").unwrap();

        let real = GitRepo::discover(&repo_dir).unwrap();
        let state_root = tmp.path().join("state");
        let shadow_root = tmp.path().join("shadows");
        let shadow = ShadowWorkspace::prepare(&real, &state_root, &shadow_root).unwrap();
        let report = shadow.sync_from_real(&real, 1024, 1024).unwrap();

        assert!(report.warnings.is_empty());
        assert_eq!(
            fs::read_to_string(shadow.shadow_path.join("tracked.txt")).unwrap(),
            "changed\n"
        );
        assert_eq!(
            fs::read_to_string(shadow.shadow_path.join("untracked.txt")).unwrap(),
            "copy me\n"
        );
        assert!(!shadow.shadow_path.join("ignored.txt").exists());
    }

    #[test]
    fn final_diff_includes_untracked_shadow_files() {
        let tmp = tempdir().unwrap();
        let repo_dir = tmp.path().join("repo");
        fs::create_dir_all(&repo_dir).unwrap();
        run(&repo_dir, ["git", "init", "-b", "main"]);
        run(
            &repo_dir,
            ["git", "config", "user.email", "test@example.com"],
        );
        run(&repo_dir, ["git", "config", "user.name", "Test"]);
        fs::write(repo_dir.join("tracked.txt"), "base\n").unwrap();
        run(&repo_dir, ["git", "add", "."]);
        run(&repo_dir, ["git", "commit", "-m", "init"]);

        let real = GitRepo::discover(&repo_dir).unwrap();
        let state_root = tmp.path().join("state");
        let shadow_root = tmp.path().join("shadows");
        let shadow = ShadowWorkspace::prepare(&real, &state_root, &shadow_root).unwrap();
        shadow.sync_from_real(&real, 1024, 1024).unwrap();
        let shadow_repo = shadow.shadow_repo();
        let base_tree = shadow_repo.write_worktree_tree().unwrap();
        fs::write(shadow.shadow_path.join("new.txt"), "created\n").unwrap();

        let diff = shadow_repo.diff_tree_to_worktree(&base_tree).unwrap();
        assert!(diff.contains("diff --git a/new.txt b/new.txt"));
        assert!(diff.contains("+created"));
    }

    fn run<const N: usize>(cwd: &Path, args: [&str; N]) {
        let status = Command::new(args[0])
            .args(&args[1..])
            .current_dir(cwd)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "{args:?}");
    }
}
