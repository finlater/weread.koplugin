#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

lua_bin="${LUAJIT_BIN:-luajit}"
if ! command -v "$lua_bin" >/dev/null 2>&1 && [[ ! -x "$lua_bin" ]]; then
    echo "error: LuaJIT not found; install luajit or set LUAJIT_BIN" >&2
    exit 1
fi

spec_count=0
for spec_file in spec/*_spec.lua; do
    echo "==> $spec_file"
    "$lua_bin" "$spec_file"
    spec_count=$((spec_count + 1))
done

echo "All $spec_count Lua specs passed."
