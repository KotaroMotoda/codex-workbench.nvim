//! Fuzz `patch_for_scope` and `remaining_after_scope`: must never panic.
//!
//! Run with:
//!   cargo fuzz run fuzz_patch_for_scope -- -max_total_time=60
#![no_main]

use codex_workbench_core::review::{patch_for_scope, remaining_after_scope};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // Split at the first NUL byte: everything before is the patch, after is
    // the scope string.  This gives the fuzzer independent control over both.
    let split = data.iter().position(|&b| b == 0).unwrap_or(data.len());
    let (patch_bytes, scope_bytes) = data.split_at(split);
    let scope_bytes = scope_bytes.strip_prefix(b"\0").unwrap_or(scope_bytes);

    if let (Ok(patch), Ok(scope)) = (
        std::str::from_utf8(patch_bytes),
        std::str::from_utf8(scope_bytes),
    ) {
        let _ = patch_for_scope(patch, scope);
        let _ = remaining_after_scope(patch, scope);
    }
});
