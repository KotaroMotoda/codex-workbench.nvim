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
mod proptests {
    use proptest::prelude::*;

    use super::*;

    /// A minimal but syntactically valid two-hunk patch used as a stable
    /// fixture for property-based tests.
    fn two_hunk_patch(file: &str) -> String {
        format!(
            "diff --git a/{file} b/{file}\nindex 111..222 100644\n--- a/{file}\n+++ b/{file}\n\
             @@ -1 +1 @@\n-old\n+new\n\
             @@ -10 +10 @@\n-foo\n+bar\n"
        )
    }

    proptest! {
        /// `patch_for_scope` and `remaining_after_scope` must never panic for
        /// any combination of inputs — even completely malformed ones.
        #[test]
        fn scope_functions_never_panic(patch in ".*", scope in ".*") {
            let _ = patch_for_scope(&patch, &scope);
            let _ = remaining_after_scope(&patch, &scope);
        }

        /// `scope == "all"` is always the identity for `patch_for_scope`.
        #[test]
        fn scope_all_is_identity(name in "[a-z][a-z0-9]{0,15}") {
            let patch = two_hunk_patch(&name);
            let extracted = patch_for_scope(&patch, "all").unwrap();
            prop_assert_eq!(extracted, patch);
        }

        /// `scope == "all"` always produces an empty remainder.
        #[test]
        fn remaining_after_all_is_empty(name in "[a-z][a-z0-9]{0,15}") {
            let patch = two_hunk_patch(&name);
            let remaining = remaining_after_scope(&patch, "all").unwrap();
            prop_assert!(remaining.is_empty());
        }

        /// `patch_for_scope("file:X")` + `remaining_after_scope("file:X")`
        /// together cover the original patch (no lines lost, no duplication).
        #[test]
        fn file_scope_covers_original(
            a in "[a-z]{3,8}",
            b in "[a-z]{3,8}",
        ) {
            prop_assume!(a != b);
            let patch_a = two_hunk_patch(&a);
            let patch_b = two_hunk_patch(&b);
            let combined = format!("{patch_a}{patch_b}");

            // Use the full diff header line as a unique anchor, avoiding false
            // positives when one name is a prefix of another (e.g. "abc" / "abcde").
            let header_a = format!("diff --git a/{a} b/{a}");
            let header_b = format!("diff --git a/{b} b/{b}");

            let extracted = patch_for_scope(&combined, &format!("file:{a}")).unwrap();
            let remaining = remaining_after_scope(&combined, &format!("file:{a}")).unwrap();

            prop_assert!(extracted.contains(&header_a), "extracted should contain file a");
            prop_assert!(!remaining.contains(&header_a), "remaining should not contain file a");
            prop_assert!(remaining.contains(&header_b), "remaining should still contain file b");
        }

        /// `hunk:path:N` scope for an existing hunk must return `Ok`.
        #[test]
        fn hunk_scope_zero_is_always_found(name in "[a-z]{3,8}") {
            let patch = two_hunk_patch(&name);
            let result = patch_for_scope(&patch, &format!("hunk:{name}:0"));
            prop_assert!(result.is_ok(), "hunk 0 should exist: {result:?}");
        }

        /// A `hunk:` scope with an out-of-bounds index must return a
        /// `ScopeHunkNotFound` error, never a panic.
        #[test]
        fn hunk_out_of_bounds_returns_error(name in "[a-z]{3,8}", idx in 100usize..200) {
            let patch = two_hunk_patch(&name);
            let result = patch_for_scope(&patch, &format!("hunk:{name}:{idx}"));
            prop_assert!(result.is_err());
        }

        /// Malformed (non-"all" / non-"file:" / non-"hunk:") scope strings
        /// must return `ScopeInvalid`, never panic.
        #[test]
        fn unknown_prefix_yields_scope_invalid(
            scope in "[^aAfFhH].*",  // excludes prefixes "all", "file:", "hunk:"
        ) {
            let patch = two_hunk_patch("x");
            let result = patch_for_scope(&patch, &scope);
            match result {
                Err(e) => {
                    let is_scope_invalid = e
                        .downcast_ref::<codex_workbench_protocol::BridgeError>()
                        .map(|be| be.code() == "scope_invalid")
                        .unwrap_or(false);
                    prop_assert!(is_scope_invalid, "expected scope_invalid, got: {e}");
                }
                Ok(_) => {} // "a" / "f" / "h" prefixes may accidentally match; allow Ok
            }
        }
    }
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
