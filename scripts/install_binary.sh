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
mkdir -p "$data_dir"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$url" -o "$data_dir/codex-workbench-bridge"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$data_dir/codex-workbench-bridge" "$url"
else
  echo "curl or wget is required" >&2
  exit 1
fi

chmod +x "$data_dir/codex-workbench-bridge"
echo "$data_dir/codex-workbench-bridge"

