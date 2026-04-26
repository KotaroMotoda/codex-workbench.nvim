//! Fuzz `errors::classify`: must never panic on arbitrary `anyhow::Error`
//! messages.
//!
//! Run with:
//!   cargo fuzz run fuzz_error_classify -- -max_total_time=60
#![no_main]

use anyhow::anyhow;
use codex_workbench_core::classify;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Ok(msg) = std::str::from_utf8(data) {
        let err = anyhow!("{}", msg);
        let _ = classify(err);
    }
});
