#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

version="$(
    sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
        _meta.lua | head -n 1
)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: _meta.lua version must use X.Y.Z format (got: ${version:-missing})" >&2
    exit 1
fi

archive_path="${1:-dist/weread.koplugin-v${version}.zip}"
if [[ "$archive_path" != /* ]]; then
    archive_path="$repo_dir/$archive_path"
fi
mkdir -p "$(dirname "$archive_path")"

stage_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$stage_dir"
}
trap cleanup EXIT

plugin_dir="$stage_dir/weread.koplugin"
mkdir -p "$plugin_dir"
cp _meta.lua main.lua LICENSE NOTICE README.md "$plugin_dir/"
cp -R fonts icons integrations weread "$plugin_dir/"

rm -f "$archive_path"
(
    cd "$stage_dir"
    zip -qr "$archive_path" weread.koplugin
)
unzip -tq "$archive_path"

echo "version=$version"
echo "archive=$archive_path"
