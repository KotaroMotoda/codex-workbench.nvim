use std::collections::BTreeSet;

use anyhow::{anyhow, Result};
use codex_workbench_protocol::BridgeError;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ReviewFile {
    pub path: String,
    pub file_only: bool,
}

pub fn files_from_patch(patch: &str) -> Vec<ReviewFile> {
    let mut files = Vec::new();
    let mut current: Option<String> = None;
    let mut file_only = false;
    let mut seen = BTreeSet::new();

    for line in patch.lines() {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            if let Some(path) = current.take() {
                if seen.insert(path.clone()) {
                    files.push(ReviewFile { path, file_only });
                }
            }
            current = parse_diff_git_path(rest);
            file_only = false;
            continue;
        }

        if line.starts_with("GIT binary patch")
            || line.starts_with("Binary files ")
            || line.starts_with("old mode ")
            || line.starts_with("new mode ")
            || line.starts_with("new file mode ")
            || line.starts_with("deleted file mode ")
            || line.starts_with("rename from ")
            || line.starts_with("rename to ")
            || line.starts_with("similarity index ")
            || line.starts_with("Subproject commit ")
            || line.starts_with("new file mode 120000")
        {
            file_only = true;
        }
    }

    if let Some(path) = current.take() {
        if seen.insert(path.clone()) {
            files.push(ReviewFile { path, file_only });
        }
    }

    files
}

pub fn patch_for_scope(patch: &str, scope: &str) -> Result<String> {
    if scope == "all" || scope.trim().is_empty() {
        return Ok(patch.to_string());
    }

    if let Some(path) = scope.strip_prefix("file:") {
        return file_patch(patch, path).ok_or_else(|| {
            anyhow!(BridgeError::ScopeFileNotFound {
                path: path.to_string(),
            })
        });
    }

    if let Some(rest) = scope.strip_prefix("hunk:") {
        let (path, idx) = parse_hunk_scope(scope, rest)?;
        return hunk_patch(patch, path, idx).ok_or_else(|| {
            anyhow!(BridgeError::ScopeHunkNotFound {
                path: path.to_string(),
                index: idx,
            })
        });
    }

    Err(anyhow!(BridgeError::ScopeInvalid {
        scope: scope.to_string(),
        reason: "expected one of: all, file:<path>, hunk:<path>:<index>".to_string(),
    }))
}

pub fn remaining_after_scope(patch: &str, scope: &str) -> Result<String> {
    if scope == "all" || scope.trim().is_empty() {
        return Ok(String::new());
    }

    if let Some(path) = scope.strip_prefix("file:") {
        return Ok(remove_file_patch(patch, path));
    }

    if let Some(rest) = scope.strip_prefix("hunk:") {
        let (path, idx) = parse_hunk_scope(scope, rest)?;
        return remove_hunk_patch(patch, path, idx).ok_or_else(|| {
            anyhow!(BridgeError::ScopeHunkNotFound {
                path: path.to_string(),
                index: idx,
            })
        });
    }

    Err(anyhow!(BridgeError::ScopeInvalid {
        scope: scope.to_string(),
        reason: "expected one of: all, file:<path>, hunk:<path>:<index>".to_string(),
    }))
}

fn parse_hunk_scope<'a>(scope: &str, rest: &'a str) -> Result<(&'a str, usize)> {
    let (path, idx) = rest.rsplit_once(':').ok_or_else(|| {
        anyhow!(BridgeError::ScopeInvalid {
            scope: scope.to_string(),
            reason: "hunk scope must be hunk:<path>:<index>".to_string(),
        })
    })?;
    let idx = idx.parse::<usize>().map_err(|_| {
        anyhow!(BridgeError::ScopeInvalid {
            scope: scope.to_string(),
            reason: "hunk index must be a non-negative integer".to_string(),
        })
    })?;
    Ok((path, idx))
}

fn file_patch(patch: &str, path: &str) -> Option<String> {
    let mut out = Vec::new();
    let mut in_file = false;

    for line in patch.lines() {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            if in_file && !out.is_empty() {
                break;
            }
            in_file = parse_diff_git_path(rest).as_deref() == Some(path);
        }
        if in_file {
            out.push(line);
        }
    }

    (!out.is_empty()).then(|| format!("{}\n", out.join("\n")))
}

fn remove_file_patch(patch: &str, path: &str) -> String {
    let mut out = Vec::new();
    let mut in_file = false;

    for line in patch.lines() {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            in_file = parse_diff_git_path(rest).as_deref() == Some(path);
        }
        if !in_file {
            out.push(line);
        }
    }

    normalize_patch(out)
}

fn hunk_patch(patch: &str, path: &str, hunk_index: usize) -> Option<String> {
    let file_patch = file_patch(patch, path)?;
    let mut header = Vec::new();
    let mut hunks: Vec<Vec<&str>> = Vec::new();
    let mut current: Vec<&str> = Vec::new();
    let mut in_hunks = false;

    for line in file_patch.lines() {
        if line.starts_with("@@ ") {
            if !current.is_empty() {
                hunks.push(current);
                current = Vec::new();
            }
            in_hunks = true;
            current.push(line);
        } else if in_hunks {
            current.push(line);
        } else {
            header.push(line);
        }
    }

    if !current.is_empty() {
        hunks.push(current);
    }

    let selected = hunks.get(hunk_index)?;
    let mut out = header;
    out.extend(selected.iter().copied());
    Some(format!("{}\n", out.join("\n")))
}

fn remove_hunk_patch(patch: &str, path: &str, hunk_index: usize) -> Option<String> {
    let mut out = Vec::new();
    let mut in_target = false;
    let mut current_hunk: Option<usize> = None;
    let mut saw_target = false;

    for line in patch.lines() {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            in_target = parse_diff_git_path(rest).as_deref() == Some(path);
            current_hunk = None;
            out.push(line);
            continue;
        }

        if in_target && line.starts_with("@@ ") {
            let next = current_hunk.map_or(0, |idx| idx + 1);
            current_hunk = Some(next);
            if next == hunk_index {
                saw_target = true;
                continue;
            }
        }

        if in_target && current_hunk == Some(hunk_index) {
            continue;
        }

        out.push(line);
    }

    saw_target.then(|| normalize_patch(out))
}

fn normalize_patch(lines: Vec<&str>) -> String {
    if lines.is_empty() {
        String::new()
    } else {
        format!("{}\n", lines.join("\n"))
    }
}

fn parse_diff_git_path(rest: &str) -> Option<String> {
    let mut parts = rest.split_whitespace();
    let _a = parts.next()?;
    let b = parts.next()?;
    b.strip_prefix("b/").map(|s| s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const PATCH: &str = r#"diff --git a/a.txt b/a.txt
index 1111111..2222222 100644
--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,2 @@
-old
+new
 same
diff --git a/bin.dat b/bin.dat
index 1111111..2222222 100644
GIT binary patch
"#;

    const NEW_FILE_PATCH: &str = r#"diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..2222222
--- /dev/null
+++ b/new.txt
@@ -0,0 +1 @@
+hello
"#;

    #[test]
    fn parses_files_and_binary_fallback() {
        let files = files_from_patch(PATCH);
        assert_eq!(files[0].path, "a.txt");
        assert!(!files[0].file_only);
        assert_eq!(files[1].path, "bin.dat");
        assert!(files[1].file_only);
    }

    #[test]
    fn extracts_file_patch() {
        let patch = patch_for_scope(PATCH, "file:a.txt").unwrap();
        assert!(patch.contains("diff --git a/a.txt b/a.txt"));
        assert!(!patch.contains("bin.dat"));
    }

    #[test]
    fn extracts_hunk_patch() {
        let patch = patch_for_scope(PATCH, "hunk:a.txt:0").unwrap();
        assert!(patch.contains("@@ -1,2 +1,2 @@"));
        assert!(patch.contains("+new"));
    }

    #[test]
    fn removes_file_patch() {
        let patch = remaining_after_scope(PATCH, "file:a.txt").unwrap();
        assert!(!patch.contains("a.txt"));
        assert!(patch.contains("bin.dat"));
    }

    #[test]
    fn treats_new_files_as_file_only() {
        let files = files_from_patch(NEW_FILE_PATCH);
        assert_eq!(files[0].path, "new.txt");
        assert!(files[0].file_only);
    }
}
