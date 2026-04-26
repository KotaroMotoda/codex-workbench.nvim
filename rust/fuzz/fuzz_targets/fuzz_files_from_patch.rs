//! Fuzz `files_from_patch`: must never panic regardless of input.
//!
//! Run with:
//!   cargo fuzz run fuzz_files_from_patch -- -max_total_time=60
#![no_main]

use codex_workbench_core::review::files_from_patch;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Ok(text) = std::str::from_utf8(data) {
        let _ = files_from_patch(text);
    }
});
