//! Conversion helpers between internal `anyhow::Error` and the public,
//! categorized `BridgeError` shipped to the Lua runtime.
//!
//! Internal code keeps using `anyhow::Result<T>` for ergonomic propagation;
//! we only classify errors at the boundary (`Manager::handle`) so that
//! Lua-facing responses always carry a stable `code` and a short, safe
//! message.

use codex_workbench_protocol::BridgeError;

use crate::git::GitInvocationError;

/// Reduce `anyhow::Error` to a typed `BridgeError`. Already-typed errors are
/// preserved; unknown errors collapse to `Internal { message }` with a short,
/// non-leaky description.
pub fn classify(error: anyhow::Error) -> BridgeError {
    if let Some(typed) = error.downcast_ref::<BridgeError>() {
        return typed.clone();
    }

    if let Some(git) = error.downcast_ref::<GitInvocationError>() {
        return BridgeError::GitFailed {
            command: git.command.clone(),
            stderr_tail: git.stderr_tail.clone(),
        };
    }

    if let Some(io) = error.downcast_ref::<std::io::Error>() {
        return BridgeError::Io {
            message: io.to_string(),
        };
    }

    BridgeError::Internal {
        message: short_chain(&error),
    }
}

/// Render an error and its causes without leaking large blobs. We keep the
/// chain short so that the message stays safe to display in a notification.
fn short_chain(error: &anyhow::Error) -> String {
    const MAX_CHARS: usize = 240;
    let mut out = String::new();
    for (idx, cause) in error.chain().enumerate() {
        if idx > 0 {
            out.push_str(": ");
        }
        out.push_str(&cause.to_string());
        if out.chars().count() >= MAX_CHARS {
            break;
        }
    }
    if out.chars().count() > MAX_CHARS {
        out = out.chars().take(MAX_CHARS).collect::<String>();
        out.push('…');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::anyhow;

    #[test]
    fn passes_through_typed_bridge_error() {
        let error = anyhow!(BridgeError::NoPendingReview);
        assert_eq!(classify(error).code(), "no_pending_review");
    }

    #[test]
    fn classifies_git_invocation_error() {
        let invocation = GitInvocationError {
            command: "apply".into(),
            stderr: "patch failed".into(),
            stderr_tail: "patch failed".into(),
        };
        let classified = classify(anyhow::Error::new(invocation));
        match classified {
            BridgeError::GitFailed { command, stderr_tail } => {
                assert_eq!(command, "apply");
                assert_eq!(stderr_tail, "patch failed");
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    #[test]
    fn unknown_errors_become_internal() {
        let classified = classify(anyhow!("oops"));
        assert_eq!(classified.code(), "internal_error");
    }

    #[test]
    fn short_chain_truncates_long_messages() {
        let huge = "x".repeat(1000);
        let classified = classify(anyhow!(huge));
        let payload = classified.details();
        let message = payload
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        assert!(message.chars().count() < 260);
    }
}
