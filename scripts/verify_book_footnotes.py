#!/usr/bin/env python3
"""Download one WeRead chapter and validate the plugin's Lua footnote converter.

Credentials are read from a local KOReader ``settings/weread.lua``. The script
never prints credential values, request headers, or chapter text.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from typing import Any

from fetch_weread_epub import (
    WeReadClient,
    fetch_chapter,
    normalize_chapter_infos,
    read_reader_state,
    reader_url_for,
    write_epub,
)
from verify_progress_sync import SKILL_VERSION, load_settings


GATEWAY_URL = "https://i.weread.qq.com/api/agent/gateway"
EPUB_NS = "http://www.idpf.org/2007/ops"


def gateway(api_key: str, api_name: str, params: dict[str, Any] | None = None) -> Any:
    payload = {
        "api_name": api_name,
        "skill_version": SKILL_VERSION,
        **(params or {}),
    }
    request = urllib.request.Request(
        GATEWAY_URL,
        data=json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
        headers={
            "Accept": "application/json, text/plain, */*",
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json;charset=UTF-8",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8", "replace"))


def cookie_header(cookies: dict[str, str]) -> str:
    return "; ".join(f"{name}={value}" for name, value in cookies.items())


def find_shelf_book(payload: Any, wanted_title: str) -> dict[str, Any]:
    if isinstance(payload, dict) and isinstance(payload.get("data"), dict):
        payload = payload["data"]
    books = payload.get("books") if isinstance(payload, dict) else None
    if not isinstance(books, list):
        raise RuntimeError("Shelf response did not contain a books list")
    exact = [book for book in books if str(book.get("title") or "").strip() == wanted_title]
    matches = exact or [
        book for book in books if wanted_title in str(book.get("title") or "")
    ]
    if not matches:
        raise RuntimeError(f"Book not found on shelf: {wanted_title}")
    if len(matches) > 1:
        titles = ", ".join(str(book.get("title") or "") for book in matches[:5])
        raise RuntimeError(f"Multiple shelf books matched {wanted_title}: {titles}")
    return matches[0]


def find_chapter(chapters: list[dict[str, Any]], wanted_title: str) -> dict[str, Any]:
    readable = [
        chapter
        for chapter in chapters
        if int(chapter.get("wordCount") or 0) > 0
        and str(chapter.get("title") or "") != "封面"
    ]
    exact = [
        chapter
        for chapter in readable
        if str(chapter.get("title") or "").strip() == wanted_title
    ]
    matches = exact or [
        chapter
        for chapter in readable
        if wanted_title in str(chapter.get("title") or "")
    ]
    if not matches:
        raise RuntimeError(f"Chapter not found: {wanted_title}")
    if len(matches) > 1:
        titles = ", ".join(str(chapter.get("title") or "") for chapter in matches[:10])
        raise RuntimeError(f"Multiple chapters matched {wanted_title}: {titles}")
    return matches[0]


def lua_transform(
    repo: Path,
    source: str,
    chapter: dict[str, Any],
) -> tuple[str, str, dict[str, int]]:
    lua_program = r'''
package.path = "./?.lua;./?/init.lua;" .. package.path
local Footnotes = require("weread.lib.footnotes")
local function read_all(path)
    local file = assert(io.open(path, "rb"))
    local value = file:read("*a")
    file:close()
    return value
end
local function write_all(path, value)
    local file = assert(io.open(path, "wb"))
    file:write(value)
    file:close()
end
local source_path = assert(os.getenv("WR_FOOTNOTE_SOURCE"))
local output_path = assert(os.getenv("WR_FOOTNOTE_OUTPUT"))
local css_path = assert(os.getenv("WR_FOOTNOTE_CSS"))
local uid = assert(os.getenv("WR_FOOTNOTE_UID"))
local idx = tonumber(os.getenv("WR_FOOTNOTE_IDX")) or 0
local html = read_all(source_path)
local chapter = { chapterUid = uid, chapterIdx = idx }
local scan = Footnotes.scan_chapter(html, chapter)
local index = Footnotes.build_book_index({ [tostring(uid)] = scan }, { chapter })
local transformed, stats = Footnotes.transform_chapter(html, scan, index)
local valid, err = Footnotes.validate(transformed)
if not valid then error(err) end
write_all(output_path, transformed)
write_all(css_path, Footnotes.has_converted(stats) and Footnotes.FOOTNOTES_CSS or "")
print(string.format("candidates=%d converted=%d image_notes=%d backlinks=%d removed_note_blocks=%d unresolved=%d",
    stats.candidates or 0, stats.converted or 0,
    stats.image_notes or 0, stats.backlinks or 0,
    stats.removed_note_blocks or 0, stats.unresolved or 0))
'''
    with tempfile.TemporaryDirectory(prefix="weread-footnotes-") as temp_name:
        temp = Path(temp_name)
        source_path = temp / "source.xhtml"
        output_path = temp / "transformed.xhtml"
        css_path = temp / "footnotes.css"
        source_path.write_text(source, encoding="utf-8")
        environment = os.environ.copy()
        environment.update({
            "WR_FOOTNOTE_SOURCE": str(source_path),
            "WR_FOOTNOTE_OUTPUT": str(output_path),
            "WR_FOOTNOTE_CSS": str(css_path),
            "WR_FOOTNOTE_UID": str(chapter.get("chapterUid") or "chapter"),
            "WR_FOOTNOTE_IDX": str(chapter.get("chapterIdx") or 0),
        })
        try:
            completed = subprocess.run(
                ["luajit", "-e", lua_program],
                cwd=repo,
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
        except subprocess.CalledProcessError as exc:
            detail = (exc.stderr or exc.stdout or "unknown Lua error").strip()
            raise RuntimeError(f"Lua footnote conversion failed: {detail}") from exc
        transformed = output_path.read_text(encoding="utf-8")
        footnote_css = css_path.read_text(encoding="utf-8")
    values = {
        key: int(value)
        for key, value in re.findall(
            r"(candidates|converted|image_notes|backlinks|removed_note_blocks|unresolved)=(\d+)",
            completed.stdout,
        )
    }
    if len(values) != 6:
        raise RuntimeError("Lua footnote converter did not return complete statistics")
    return transformed, footnote_css, values


def inspect_epub(path: Path) -> dict[str, int | bool]:
    with zipfile.ZipFile(path) as archive:
        bad_member = archive.testzip()
        chapter_names = sorted(
            name for name in archive.namelist() if name.startswith("OEBPS/text/chapter_")
        )
        if len(chapter_names) != 1:
            raise RuntimeError(f"Expected one EPUB chapter, found {len(chapter_names)}")
        chapter_data = archive.read(chapter_names[0])
    root = ET.fromstring(chapter_data)
    ids = {
        element.attrib["id"]
        for element in root.iter()
        if element.attrib.get("id")
    }
    noterefs = []
    footnotes = []
    broken_targets = 0
    broken_backlinks = 0
    broken_local_links = 0
    original_note_blocks = 0
    for element in root.iter():
        classes = set(element.attrib.get("class", "").lower().split())
        if "note" in classes and "wr-book-footnote" not in classes:
            original_note_blocks += 1
        href = element.attrib.get("href", "")
        if href.startswith("#") and href[1:] not in ids:
            broken_local_links += 1
        epub_type = element.attrib.get(f"{{{EPUB_NS}}}type")
        if epub_type == "noteref":
            noterefs.append(element)
            if not href.startswith("#") or href[1:] not in ids:
                broken_targets += 1
        elif epub_type == "footnote":
            footnotes.append(element)
            for link in element.iter():
                href = link.attrib.get("href", "")
                if href.startswith("#") and href[1:] not in ids:
                    broken_backlinks += 1
    return {
        "zip_ok": bad_member is None,
        "xml_ok": True,
        "noterefs": len(noterefs),
        "footnotes": len(footnotes),
        "broken_targets": broken_targets,
        "broken_backlinks": broken_backlinks,
        "broken_local_links": broken_local_links,
        "original_note_blocks": original_note_blocks,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settings", type=Path, default=Path("settings/weread.lua"))
    parser.add_argument("--book-title", default="古文观止")
    parser.add_argument("--chapter-title", default="礼记")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("/tmp/weread-footnote-validation.epub"),
    )
    parser.add_argument("--sleep", type=float, default=0.15)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo = Path(__file__).resolve().parent.parent
    settings = load_settings(args.settings)
    shelf = gateway(settings["api_key"], "/shelf/sync")
    book = find_shelf_book(shelf, args.book_title)
    book_id = str(book.get("bookId") or "")
    if not book_id:
        raise RuntimeError("Matched shelf book did not contain bookId")

    client = WeReadClient(
        cookie_file=None,
        cookie_string=cookie_header(settings["cookies"]),
        save_cookies=None,
    )
    if not client.renew():
        raise RuntimeError("Cookie renewal failed")
    reader_url = reader_url_for(book_id)
    reader_state = read_reader_state(client.get_text(reader_url, referer=reader_url))
    catalog_payload = client.post_json(
        "https://weread.qq.com/web/book/chapterInfos",
        {"bookIds": [book_id]},
        referer=reader_url,
    )
    book_record, chapters = normalize_chapter_infos(catalog_payload, book_id)
    chapter = find_chapter(chapters, args.chapter_title)

    content_format = ["auto"]
    title, content, chapter_css, assets = fetch_chapter(
        client,
        book_id=book_id,
        chapter=chapter,
        sleep_seconds=args.sleep,
        content_format=content_format,
    )
    transformed, footnote_css, stats = lua_transform(repo, content, chapter)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    write_epub(
        args.output,
        title=str(book_record.get("book", {}).get("title") or book.get("title") or args.book_title),
        author=str(book_record.get("book", {}).get("author") or book.get("author") or ""),
        chapters=[(title, transformed, assets)],
        css=(chapter_css or "") + "\n" + footnote_css,
    )
    inspection = inspect_epub(args.output)
    ok = (
        inspection["zip_ok"]
        and inspection["xml_ok"]
        and inspection["broken_targets"] == 0
        and inspection["broken_backlinks"] == 0
        and inspection["broken_local_links"] == 0
        and inspection["original_note_blocks"] == 0
        and inspection["footnotes"] == inspection["noterefs"]
        and inspection["footnotes"] > 0
    )
    print(json.dumps({
        "ok": bool(ok),
        "book": str(book.get("title") or args.book_title),
        "chapter": title,
        "chapterUid": chapter.get("chapterUid"),
        "contentChars": len(content),
        "assets": len(assets),
        "lua": stats,
        "epub": inspection,
        "output": str(args.output),
        "bytes": args.output.stat().st_size,
    }, ensure_ascii=False, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
