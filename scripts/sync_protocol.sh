#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema_dir="$repo_root/protocol/schema"
ts_dir="$repo_root/protocol/ts"

mkdir -p "$schema_dir" "$ts_dir"
codex app-server generate-json-schema --out "$schema_dir"
codex app-server generate-ts --out "$ts_dir"

