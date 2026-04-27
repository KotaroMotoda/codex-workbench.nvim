use std::ffi::{OsStr, OsString};
use std::fmt;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{anyhow, Context, Result};
use codex_workbench_protocol::BridgeError;
use sha2::{Digest, Sha256};

/// Error returned when a `git` invocation exits with a non-zero status. We
/// keep the full stderr in `stderr` so that callers can decide how to log it
/// and a separately truncated `stderr_tail` for promotion to user-facing
/// `BridgeError::GitFailed`.
#[derive(Debug, Clone)]
pub struct GitInvocationError {
    pub command: String,
    pub stderr: String,
    pub stderr_tail: String,
}

impl GitInvocationError {
    fn new(command: String, stderr: String) -> Self {
        let stderr_tail = truncate_for_display(&stderr, 800);
        Self {
            command,
            stderr,
            stderr_tail,
        }
    }
}

impl fmt::Display for GitInvocationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "git {} failed: {}", self.command, self.stderr_tail)
    }
}

impl std::error::Error for GitInvocationError {}

fn truncate_for_display(text: &str, max_chars: usize) -> String {
    let trimmed = text.trim();
    // Single pass: avoids the O(n) `chars().count()` pre-scan.
    let mut out = String::with_capacity(max_chars.min(trimmed.len()));
    for (idx, ch) in trimmed.chars().enumerate() {
        if idx >= max_chars {
            out.push('…');
            return out;
        }
        out.push(ch);
    }
    out
}

#[derive(Debug, Clone)]
pub struct GitRepo {
    pub root: PathBuf,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct UntrackedCopyWarning {
    pub path: String,
    pub reason: String,
}

impl GitRepo {
    pub fn discover(workspace: impl AsRef<Path>) -> Result<Self> {
        let workspace = workspace.as_ref();
        let output =
            git_output(["rev-parse", "--show-toplevel"], workspace, None).map_err(|error| {
                if error.downcast_ref::<GitInvocationError>().is_some() {
                    anyhow!(BridgeError::NotAGitRepository {
                        workspace: workspace.to_string_lossy().to_string(),
                    })
                } else {
                    error
                }
            })?;
        let root = PathBuf::from(output.trim());
        if root.as_os_str().is_empty() {
            return Err(anyhow!(BridgeError::NotAGitRepository {
                workspace: workspace.to_string_lossy().to_string(),
            }));
        }
        Ok(Self { root })
    }

    pub fn head(&self) -> Result<String> {
        git_output(["rev-parse", "HEAD"], &self.root, None).map(|s| s.trim().to_string())
    }

    pub fn diff_head(&self) -> Result<String> {
        git_output(
            ["diff", "HEAD", "--binary", "--full-index"],
            &self.root,
            None,
        )
    }

    pub fn status_z(&self) -> Result<Vec<u8>> {
        git_bytes(["status", "--porcelain=v1", "-z"], &self.root, None)
    }

    pub fn untracked_files(&self) -> Result<Vec<String>> {
        let bytes = git_bytes(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            &self.root,
            None,
        )?;
        Ok(bytes
            .split(|b| *b == 0)
            .filter(|chunk| !chunk.is_empty())
            .map(|chunk| String::from_utf8_lossy(chunk).to_string())
            .collect())
    }

    pub fn reset_hard(&self) -> Result<()> {
        git_success(["reset", "--hard", "HEAD"], &self.root, None)?;
        Ok(())
    }

    pub fn reset_hard_to(&self, rev: &str) -> Result<()> {
        git_success(["reset", "--hard", rev], &self.root, None)?;
        Ok(())
    }

    pub fn clean_untracked(&self) -> Result<()> {
        git_success(["clean", "-fd"], &self.root, None)?;
        Ok(())
    }

    pub fn apply_patch(&self, patch: &str) -> Result<()> {
        if patch.trim().is_empty() {
            return Ok(());
        }
        git_success(
            ["apply", "--3way", "--whitespace=nowarn"],
            &self.root,
            Some(patch.as_bytes()),
        )
    }

    pub fn apply_patch_without_index(&self, patch: &str) -> Result<()> {
        if patch.trim().is_empty() {
            return Ok(());
        }
        git_success(
            ["apply", "--whitespace=nowarn"],
            &self.root,
            Some(patch.as_bytes()),
        )
    }

    pub fn write_worktree_tree(&self) -> Result<String> {
        git_success(["add", "-A"], &self.root, None)?;
        let tree = git_output(["write-tree"], &self.root, None)?
            .trim()
            .to_string();
        git_success(["reset", "--mixed"], &self.root, None)?;
        Ok(tree)
    }

    pub fn diff_tree_to_worktree(&self, tree: &str) -> Result<String> {
        git_success(["add", "-A"], &self.root, None)?;
        let diff = git_output(
            ["diff", "--cached", tree, "--binary", "--full-index"],
            &self.root,
            None,
        );
        let reset = git_success(["reset", "--mixed"], &self.root, None);
        reset?;
        diff
    }

    pub fn fingerprint(&self, max_file_bytes: u64, max_total_bytes: u64) -> Result<String> {
        let mut hasher = Sha256::new();
        hasher.update(self.head()?.as_bytes());
        hasher.update(self.diff_head()?.as_bytes());
        hasher.update(self.status_z()?);

        let mut total = 0_u64;
        for rel in self.untracked_files()? {
            hasher.update(rel.as_bytes());
            let path = self.root.join(&rel);
            let meta = std::fs::symlink_metadata(&path)?;
            hasher.update(meta.len().to_le_bytes());
            if meta.file_type().is_file()
                && meta.len() <= max_file_bytes
                && total.saturating_add(meta.len()) <= max_total_bytes
            {
                total += meta.len();
                hasher.update(std::fs::read(&path)?);
            }
        }

        Ok(format!("{:x}", hasher.finalize()))
    }
}

pub fn repo_hash(path: &Path) -> String {
    let mut hasher = Sha256::new();
    hasher.update(path.to_string_lossy().as_bytes());
    format!("{:x}", hasher.finalize())[..16].to_string()
}

pub fn worktree_add_detached(repo_root: &Path, shadow_path: &Path) -> Result<()> {
    let args: Vec<OsString> = vec![
        "worktree".into(),
        "add".into(),
        "--detach".into(),
        path_arg(shadow_path),
        "HEAD".into(),
    ];
    git_success(args, repo_root, None)
}

pub fn git_output<I, S>(args: I, cwd: &Path, stdin: Option<&[u8]>) -> Result<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let bytes = git_bytes(args, cwd, stdin)?;
    String::from_utf8(bytes).context("git output was not valid UTF-8")
}

pub fn git_bytes<I, S>(args: I, cwd: &Path, stdin: Option<&[u8]>) -> Result<Vec<u8>>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    // Use Peekable to read the first argument (subcommand) for the error
    // descriptor without collecting the whole iterator into a Vec.
    let mut args = args.into_iter().peekable();
    let descriptor = args
        .peek()
        .map(|first| first.as_ref().to_string_lossy().into_owned())
        .unwrap_or_else(|| "unknown".to_string());
    let mut command = Command::new("git");
    command.args(args).current_dir(cwd);
    if stdin.is_some() {
        command.stdin(Stdio::piped());
    }
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command.spawn().context("failed to spawn git")?;
    if let Some(input) = stdin {
        child
            .stdin
            .as_mut()
            .context("git stdin was not available")?
            .write_all(input)?;
    }
    let output = child.wait_with_output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        return Err(GitInvocationError::new(descriptor, stderr).into());
    }
    Ok(output.stdout)
}

pub fn git_success<I, S>(args: I, cwd: &Path, stdin: Option<&[u8]>) -> Result<()>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    git_bytes(args, cwd, stdin).map(|_| ())
}

fn path_arg(path: &Path) -> std::ffi::OsString {
    path.as_os_str().to_os_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;
    use tempfile::tempdir;

    /// Create a git repo at `root` with the given files committed at HEAD.
    fn git_init_commit(root: &Path, files: &[(&str, &str)]) {
        for args in [
            &["init"][..],
            &["config", "user.email", "test@example.com"],
            &["config", "user.name", "Test"],
        ] {
            let out = Command::new("git")
                .args(args)
                .current_dir(root)
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "git {args:?}: {}",
                String::from_utf8_lossy(&out.stderr)
            );
        }
        for (name, content) in files {
            std::fs::write(root.join(name), content).unwrap();
        }
        for args in [&["add", "-A"][..], &["commit", "-m", "init"]] {
            let out = Command::new("git")
                .args(args)
                .current_dir(root)
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "git {args:?}: {}",
                String::from_utf8_lossy(&out.stderr)
            );
        }
    }

    /// Stage all changes in `root` and return the diff vs HEAD (binary, full-index).
    fn make_staged_patch(root: &Path) -> String {
        let out = Command::new("git")
            .args(["add", "-A"])
            .current_dir(root)
            .output()
            .unwrap();
        assert!(out.status.success());
        let out = Command::new("git")
            .args(["diff", "--cached", "HEAD", "--binary", "--full-index"])
            .current_dir(root)
            .output()
            .unwrap();
        assert!(out.status.success());
        String::from_utf8(out.stdout).unwrap()
    }

    /// Reset index and working tree back to HEAD (discards all staged/unstaged changes).
    fn reset_to_head(root: &Path) {
        for args in [
            &["reset", "HEAD", "--", "."][..],
            &["checkout", "--", "."],
            &["clean", "-fd"],
        ] {
            Command::new("git")
                .args(args)
                .current_dir(root)
                .output()
                .unwrap();
        }
    }

    #[test]
    fn apply_patch_empty_is_noop() {
        let tmp = tempdir().unwrap();
        git_init_commit(tmp.path(), &[("f.txt", "hello\n")]);
        let repo = GitRepo::discover(tmp.path()).unwrap();
        repo.apply_patch("").unwrap();
        repo.apply_patch("   \n  ").unwrap();
    }

    #[test]
    fn apply_patch_adds_new_file() {
        let tmp = tempdir().unwrap();
        git_init_commit(tmp.path(), &[("existing.txt", "base\n")]);
        std::fs::write(tmp.path().join("new.txt"), "brand new\n").unwrap();
        let patch = make_staged_patch(tmp.path());
        assert!(patch.contains("new.txt"));

        reset_to_head(tmp.path());
        assert!(!tmp.path().join("new.txt").exists());

        GitRepo::discover(tmp.path())
            .unwrap()
            .apply_patch(&patch)
            .unwrap();
        assert_eq!(
            std::fs::read_to_string(tmp.path().join("new.txt")).unwrap(),
            "brand new\n"
        );
    }

    #[test]
    fn apply_patch_modifies_existing_file() {
        let tmp = tempdir().unwrap();
        git_init_commit(tmp.path(), &[("f.txt", "original\n")]);
        std::fs::write(tmp.path().join("f.txt"), "modified\n").unwrap();
        let patch = make_staged_patch(tmp.path());

        reset_to_head(tmp.path());
        GitRepo::discover(tmp.path())
            .unwrap()
            .apply_patch(&patch)
            .unwrap();
        assert_eq!(
            std::fs::read_to_string(tmp.path().join("f.txt")).unwrap(),
            "modified\n"
        );
    }

    #[test]
    fn apply_patch_renames_file() {
        let tmp = tempdir().unwrap();
        git_init_commit(tmp.path(), &[("old.txt", "content\n")]);
        let out = Command::new("git")
            .args(["mv", "old.txt", "new.txt"])
            .current_dir(tmp.path())
            .output()
            .unwrap();
        assert!(out.status.success());
        let patch = make_staged_patch(tmp.path());

        reset_to_head(tmp.path());
        assert!(tmp.path().join("old.txt").exists());
        assert!(!tmp.path().join("new.txt").exists());

        GitRepo::discover(tmp.path())
            .unwrap()
            .apply_patch(&patch)
            .unwrap();
        assert!(!tmp.path().join("old.txt").exists());
        assert_eq!(
            std::fs::read_to_string(tmp.path().join("new.txt")).unwrap(),
            "content\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn apply_patch_changes_file_mode() {
        use std::os::unix::fs::PermissionsExt;

        let tmp = tempdir().unwrap();
        git_init_commit(tmp.path(), &[("script.sh", "#!/bin/sh\n")]);
        let path = tmp.path().join("script.sh");

        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms).unwrap();
        let patch = make_staged_patch(tmp.path());
        if patch.trim().is_empty() {
            // core.fileMode=false in this environment; skip rather than fail.
            return;
        }
        assert!(patch.contains("mode"), "patch should mention mode change");

        reset_to_head(tmp.path());
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o111,
            0,
            "file should not be executable before apply"
        );
        GitRepo::discover(tmp.path())
            .unwrap()
            .apply_patch(&patch)
            .unwrap();
        assert_ne!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o111,
            0,
            "file should be executable after apply"
        );
    }

    #[test]
    fn apply_patch_returns_error_when_context_does_not_match() {
        let tmp = tempdir().unwrap();
        git_init_commit(tmp.path(), &[("f.txt", "hello\n")]);
        // Patch whose context line ("no such line") doesn't exist in the file.
        let bad_patch = concat!(
            "diff --git a/f.txt b/f.txt\n",
            "--- a/f.txt\n",
            "+++ b/f.txt\n",
            "@@ -1 +1 @@\n",
            "-no such line\n",
            "+replacement\n",
        );
        let err = GitRepo::discover(tmp.path())
            .unwrap()
            .apply_patch(bad_patch)
            .unwrap_err();
        assert!(
            err.downcast_ref::<GitInvocationError>().is_some(),
            "expected GitInvocationError, got: {err}"
        );
    }
}
