#!/usr/bin/env bash
set -euo pipefail

readonly KOREADER_TESTED_COMMIT="1e2fa5f1239028ab4b37acae833cdc86a71e5258"
plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
koreader_dir="${KOREADER_DIR:-}"

if (( BASH_VERSINFO[0] < 4 )); then
    echo "error: KOReader integration tests require Bash >= 4 (got $BASH_VERSION)" >&2
    echo "On macOS, install Homebrew bash and run this script with that executable." >&2
    exit 1
fi

if [[ -z "$koreader_dir" ]]; then
    echo "error: set KOREADER_DIR to a KOReader checkout" >&2
    exit 1
fi
koreader_dir="$(cd "$koreader_dir" && pwd)"

if [[ ! -f "$koreader_dir/Makefile" || ! -d "$koreader_dir/plugins" ]]; then
    echo "error: KOREADER_DIR is not a KOReader source checkout" >&2
    exit 1
fi

actual_commit="$(git -C "$koreader_dir" rev-parse HEAD)"
if [[ "$actual_commit" != "$KOREADER_TESTED_COMMIT" ]]; then
    echo "error: expected KOReader $KOREADER_TESTED_COMMIT, got $actual_commit" >&2
    echo "Set KOREADER_DIR to the pinned checkout used by CI." >&2
    exit 1
fi

plugin_target="$koreader_dir/plugins/weread.koplugin"
spec_target="$koreader_dir/spec/unit/weread_plugin_spec.lua"
if [[ -e "$plugin_target" || -L "$plugin_target" ]]; then
    echo "error: integration target already exists: $plugin_target" >&2
    exit 1
fi
if [[ -e "$spec_target" ]]; then
    echo "error: integration spec target already exists: $spec_target" >&2
    exit 1
fi

cleanup() {
    rm -f "$spec_target"
    rm -f "$plugin_target"
}
trap cleanup EXIT

ln -s "$plugin_dir" "$plugin_target"
cp "$plugin_dir/spec/koreader/weread_plugin_spec.lua" "$spec_target"

if [[ "${KOREADER_SKIP_FETCH:-0}" != "1" ]]; then
    make -C "$koreader_dir" fetchthirdparty
fi

cd "$koreader_dir"
make base
./base/utils/fake_tty.py make --assume-old=base testfront \
    T="--busted -- spec/front/unit/weread_plugin_spec.lua"
