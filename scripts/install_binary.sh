#!/usr/bin/env bash
set -euo pipefail

version="${CODEX_WORKBENCH_VERSION:-0.1.0}"
repo="${CODEX_WORKBENCH_REPO:-KotaroMotoda/codex-workbench.nvim}"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/codex-workbench/bin/$version"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) arch="x86_64" ;;
  arm64|aarch64) arch="aarch64" ;;
  *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac

case "$os" in
  darwin) platform="macos" ;;
  linux) platform="linux" ;;
  *) echo "unsupported os: $os" >&2; exit 1 ;;
esac

asset="codex-workbench-bridge-${platform}-${arch}"
url="https://github.com/${repo}/releases/download/v${version}/${asset}"
sha256_url="${url}.sha256"

mkdir -p "$data_dir"

partial="${data_dir}/${asset}.partial"
sha256_file="${data_dir}/${asset}.sha256"
final="${data_dir}/codex-workbench-bridge"

# Download binary to a partial file and its checksum alongside.
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$url"        -o "$partial"
  curl -fsSL "$sha256_url" -o "$sha256_file"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$partial"      "$url"
  wget -qO "$sha256_file"  "$sha256_url"
else
  echo "curl or wget is required" >&2
  exit 1
fi

# Verify SHA-256 checksum before installing.
# The .sha256 file contains "<hash>  <filename>" (shasum -a 256 format).
expected_hash="$(awk '{print $1}' "$sha256_file")"
actual_hash="$(shasum -a 256 "$partial" | awk '{print $1}')"

if [ "$expected_hash" != "$actual_hash" ]; then
  rm -f "$partial" "$sha256_file"
  echo "checksum mismatch for $asset (expected $expected_hash, got $actual_hash)" >&2
  exit 1
fi

# Atomic install: move the verified partial into the final path, then chmod.
mv "$partial" "$final"
chmod +x "$final"
rm -f "$sha256_file"

echo "$final"
