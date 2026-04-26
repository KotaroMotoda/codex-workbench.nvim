use std::ffi::{OsStr, OsString};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{anyhow, Context, Result};
use sha2::{Digest, Sha256};

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
        let output = git_output(["rev-parse", "--show-toplevel"], workspace.as_ref(), None)?;
        let root = PathBuf::from(output.trim());
        if root.as_os_str().is_empty() {
            return Err(anyhow!("Git repository is required"));
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
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow!("git failed: {stderr}"));
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
