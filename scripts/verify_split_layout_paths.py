#!/usr/bin/env python3
"""Offline checks for flat EPUB + separate metadata layout path rules."""
from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTENT = (ROOT / "weread/lib/content.lua").read_text(encoding="utf-8")
BOOK_STORE = (ROOT / "weread/lib/book_store.lua").read_text(encoding="utf-8")
SETTINGS = (ROOT / "weread/lib/settings.lua").read_text(encoding="utf-8")
CACHE_UI = (ROOT / "weread/ui/cache.lua").read_text(encoding="utf-8")
MENU = (ROOT / "weread/ui/menu.lua").read_text(encoding="utf-8")

def must(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)

def main() -> int:
    checks = 0

    def ok(cond: bool, msg: str) -> None:
        nonlocal checks
        must(cond, msg)
        checks += 1

    fs = CONTENT.find("local function filename_safe")
    epub = CONTENT.find("function Content.book_content_epub_path")
    ok(fs != -1 and epub != -1 and fs < epub, "filename_safe must precede book_content_epub_path")

    for name in (
        "function Content.book_content_dir",
        "function Content.book_meta_dir",
        "function Content.ensure_book_meta_dir",
        "function Content.book_content_epub_path",
        "function Content.remove_book_files",
    ):
        ok(name in CONTENT, f"missing {name}")

    alias = "function Content.book_cache_dir(settings, book_id)" + chr(10) + "    return Content.book_meta_dir(settings, book_id)" + chr(10) + "end"
    ok(alias in CONTENT, "book_cache_dir must alias book_meta_dir")

    bad = "or looks_like_book_id_dir(pinned, book_id)"
    ok(bad not in CONTENT, "content resolved_dir must not trust bare bookId dirs")
    ok(bad not in BOOK_STORE, "book_store resolved_dir must not trust bare bookId dirs")
    ok("dir_has_sidecar(pinned)" in CONTENT and "dir_has_sidecar(pinned)" in BOOK_STORE, "resolved_dir must require sidecar markers")

    ok("Content.book_content_epub_path(settings, book, suffix or \"book\")" in CONTENT, "save_book_epub must use flat content path")
    ok("Content.ensure_book_meta_dir(settings, book_id, book)" in CONTENT, "EPUB save must ensure meta dir")
    ok("Content.remove_book_files" in CACHE_UI, "cache cleanup must use remove_book_files")

    ok('default_meta_dir = data_dir .. "/meta"' in SETTINGS, "default meta under data_dir/meta")
    ok("metadata directory must not be the same as the book directory" in SETTINGS, "set_meta_dir rejects equal paths")
    ok("if obj.meta_dir == obj.cache_dir then" in SETTINGS, "boot guard against equal dirs")

    ok("showMetaDirPicker" in CACHE_UI and "showDownloadDirPicker" in CACHE_UI, "cache UI must expose both directory pickers")
    ok("Metadata directory" in MENU and "Book directory" in MENU, "menu must expose book + metadata directory items")
    ok("offerMoveContentToNewDir" in CACHE_UI and "offerMoveMetaToNewDir" in CACHE_UI, "move helpers must split content vs metadata")
    ok("index.cached_file = book.cached_file" in BOOK_STORE, "BookStore.save must retain cached_file in index")

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        library = tmp_path / "Books"
        meta_root = tmp_path / "meta"
        library.mkdir()
        meta_root.mkdir()
        book_id = "123456"
        stale = library / "metadata" / book_id
        stale.mkdir(parents=True)
        legacy = library / book_id
        legacy.mkdir()
        (legacy / "catalog.json").write_text("{}", encoding="utf-8")
        (legacy / "book.epub").write_bytes(b"epub")
        flat = library / "santi.epub"
        flat.write_bytes(b"flat")

        def basename_safe(value: str) -> str:
            return re.sub(r"[^\w.\-]+", "_", value)

        def dir_has_sidecar(dir_path: Path) -> bool:
            return any((dir_path / name).is_file() for name in (
                "catalog.json", "thoughts.db", "metadata.json",
                "reading_state.json", "articles.json",
            ))

        def resolve(cache_dir, cached_file):
            canonical = meta_root / basename_safe(book_id)
            if cache_dir:
                pinned = Path(cache_dir)
                if pinned == canonical or dir_has_sidecar(pinned):
                    return pinned
            if cached_file:
                parent = Path(cached_file).parent
                if parent.name == basename_safe(book_id) and dir_has_sidecar(parent):
                    return parent
            return canonical

        got = resolve(str(stale), str(flat))
        ok(got == meta_root / book_id, f"stale empty leftover must fall back to meta, got {got}")
        got = resolve(str(legacy), str(legacy / "book.epub"))
        ok(got == legacy, f"legacy combined dir must win, got {got}")
        got = resolve(None, str(flat))
        ok(got == meta_root / book_id, f"flat parent must not become sidecar, got {got}")
        open_target = resolve(None, str(flat))
        ok(str(library) not in str(open_target), "open-book mkdir must not target library root child")
        ok(str(meta_root) in str(open_target), "open-book mkdir must target meta root")

    print(f"OK {checks} checks")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
