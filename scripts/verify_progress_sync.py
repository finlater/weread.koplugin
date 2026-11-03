#!/usr/bin/env python3
"""Validate WeRead reading-progress pull and same-position upload.

The script reads credentials from KOReader's ``settings/weread.lua`` and never
prints API keys, cookie values, or Web Reader session tokens.

By default it performs read-only checks:

* pull progress through the official Agent Gateway;
* pull progress through the cookie-authenticated Web endpoint;
* load the Web Reader page and verify that upload-signing context is present.

Pass ``--offline-regressions`` to validate production request sequencing with
LuaJIT and synthetic protocol payloads, without loading credentials or sending
network requests. This does not verify real-server reading-time credit.

Pass ``--round-trip-write`` to reproduce the Web Reader's two-stage session
flow (enter-read handshake, then a report with ``rt=0``), upload the exact
position just pulled from the Gateway, and pull it again. If the response has
no acknowledgement, the script uses a reversible one-character offset probe.
"""

from __future__ import annotations

import argparse
import copy
import json
import math
import re
import sys
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Optional

from fetch_weread_epub import (
    USER_AGENT,
    WeReadClient,
    make_read_params,
    read_reader_state,
    reader_url_for,
    sorted_query,
    weread_e,
    weread_sign,
)


GATEWAY_URL = "https://i.weread.qq.com/api/agent/gateway"
WEB_PROGRESS_URL = "https://weread.qq.com/web/book/getProgress"
WEB_READ_URL = "https://weread.qq.com/web/book/read"
SKILL_VERSION = "1.0.5"
DEFAULT_READER_TOKEN = "3c5c8717f3daf09iop3423zafeqoi"
COOKIE_NAMES = ("wr_vid", "wr_skey", "wr_rt", "wr_ql", "wr_pf")


class ValidationError(RuntimeError):
    """A protocol or configuration check failed."""


def _decode_lua_string(value: str) -> str:
    replacements = {
        r"\\": "\\",
        r"\"": '"',
        r"\n": "\n",
        r"\r": "\r",
        r"\t": "\t",
    }
    return re.sub(
        r"\\(?:\\|\"|n|r|t)",
        lambda match: replacements.get(match.group(0), match.group(0)[1:]),
        value,
    )


def _find_table(source: str, key: str) -> str:
    match = re.search(
        rf'(?:\["{re.escape(key)}"\]|{re.escape(key)})\s*=\s*\{{',
        source,
    )
    if not match:
        return ""

    start = source.find("{", match.start())
    depth = 0
    quote: Optional[str] = None
    escaped = False
    for index in range(start, len(source)):
        char = source[index]
        if quote is not None:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in {'"', "'"}:
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start + 1 : index]
    raise ValidationError(f"Unterminated Lua table: {key}")


def _lua_string(source: str, key: str) -> str:
    match = re.search(
        rf'(?:\["{re.escape(key)}"\]|{re.escape(key)})\s*=\s*"((?:\\.|[^"\\])*)"',
        source,
    )
    return _decode_lua_string(match.group(1)) if match else ""


def load_settings(path: Path) -> dict[str, Any]:
    if str(path) == "-":
        source = sys.stdin.read()
    else:
        try:
            source = path.read_text(encoding="utf-8")
        except OSError as exc:
            raise ValidationError(f"Cannot read settings file: {path}") from exc

    api_key = _lua_string(source, "api_key")
    cookie_source = _find_table(source, "cookies")
    cookies = {
        name: _lua_string(cookie_source, name)
        for name in COOKIE_NAMES
        if _lua_string(cookie_source, name)
    }
    read_report = _find_table(source, "read_report")
    default_book_id = _lua_string(read_report, "book_id")

    if not api_key:
        raise ValidationError("settings/weread.lua does not contain api_key")
    if not cookies.get("wr_vid") or not cookies.get("wr_skey"):
        raise ValidationError(
            "settings/weread.lua must contain wr_vid and wr_skey cookies"
        )
    return {
        "api_key": api_key,
        "cookies": cookies,
        "default_book_id": default_book_id,
    }


def request_json(
    url: str,
    *,
    method: str = "GET",
    data: Optional[dict[str, Any]] = None,
    headers: Optional[dict[str, str]] = None,
) -> Any:
    body = None
    request_headers = {
        "Accept": "application/json, text/plain, */*",
        "User-Agent": USER_AGENT,
    }
    request_headers.update(headers or {})
    if data is not None:
        body = json.dumps(
            data, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")
        request_headers["Content-Type"] = "application/json;charset=UTF-8"
    request = urllib.request.Request(
        url,
        data=body,
        headers=request_headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        # Do not echo response headers or request data: they may contain auth.
        detail = exc.read().decode("utf-8", "replace")
        try:
            parsed = json.loads(detail)
            detail = json.dumps(
                {
                    key: parsed.get(key)
                    for key in ("errCode", "errMsg", "code", "message")
                    if key in parsed
                },
                ensure_ascii=False,
            )
        except json.JSONDecodeError:
            detail = "<non-JSON response>"
        raise ValidationError(f"HTTP {exc.code} from {url}: {detail}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise ValidationError(f"Request failed for {url}: {exc.reason}") from exc


def gateway_progress(api_key: str, book_id: str) -> Any:
    return request_json(
        GATEWAY_URL,
        method="POST",
        data={
            "api_name": "/book/getprogress",
            "skill_version": SKILL_VERSION,
            "bookId": str(book_id),
            "_t": int(time.time() * 1000),
        },
        headers={"Authorization": f"Bearer {api_key}"},
    )


def _walk_dicts(value: Any, depth: int = 0) -> list[dict[str, Any]]:
    if depth > 7:
        return []
    if isinstance(value, dict):
        result = [value]
        for child in value.values():
            if isinstance(child, (dict, list)):
                result.extend(_walk_dicts(child, depth + 1))
        return result
    if isinstance(value, list):
        result = []
        for child in value[:50]:
            result.extend(_walk_dicts(child, depth + 1))
        return result
    return []


def find_progress_node(value: Any, book_id: str) -> dict[str, Any]:
    candidates = []
    for node in _walk_dicts(value):
        if not any(
            key in node
            for key in ("progress", "readingProgress", "bookProgress")
        ):
            continue
        node_book_id = node.get("bookId") or node.get("book_id")
        if node_book_id is not None and str(node_book_id) != str(book_id):
            continue
        score = sum(
            key in node
            for key in (
                "bookId",
                "chapterUid",
                "chapterIdx",
                "chapterOffset",
                "updateTime",
            )
        )
        candidates.append((score, node))
    if not candidates:
        raise ValidationError("No reading-progress object found in response")
    candidates.sort(key=lambda item: item[0], reverse=True)
    return candidates[0][1]


def normalized_position(node: dict[str, Any]) -> dict[str, Any]:
    def first(*names: str) -> Any:
        for name in names:
            if node.get(name) is not None:
                return node[name]
        return None

    raw_progress = first("progress", "readingProgress", "bookProgress")
    try:
        progress = float(raw_progress)
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"Invalid progress value: {raw_progress!r}") from exc
    if not math.isfinite(progress) or progress < 0:
        raise ValidationError(f"Invalid progress value: {raw_progress!r}")

    return {
        "book_id": first("bookId", "book_id"),
        "progress": progress,
        "chapter_uid": first("chapterUid", "chapterId", "chapter_uid"),
        "chapter_idx": first("chapterIdx", "chapterIndex", "chapter_idx"),
        "chapter_offset": first(
            "chapterOffset", "chapterPos", "offset", "chapter_offset"
        ),
        "summary": first("summary", "chapterTitle") or "",
        "updated_at": first("updateTime", "updatedAt", "update_time"),
    }


def public_position(position: dict[str, Any]) -> dict[str, Any]:
    return {
        key: position.get(key)
        for key in (
            "book_id",
            "progress",
            "chapter_uid",
            "chapter_idx",
            "chapter_offset",
            "updated_at",
        )
    }


def cookie_progress(client: WeReadClient, book_id: str) -> Any:
    url = (
        f"{WEB_PROGRESS_URL}?bookId={urllib.parse.quote(str(book_id), safe='')}"
        f"&_={int(time.time() * 1000)}"
    )
    raw = client.request(
        url,
        referer=reader_url_for(book_id),
        accept="application/json, text/plain, */*",
    )
    return json.loads(raw.decode("utf-8", "replace"))


def load_reader_state(client: WeReadClient, book_id: str) -> tuple[str, Any]:
    referer = reader_url_for(book_id)
    for attempt in range(2):
        html = client.get_text(referer, referer=referer)
        try:
            state = read_reader_state(html)
        except (ValueError, json.JSONDecodeError):
            if attempt == 0 and client.renew():
                continue
            raise ValidationError(
                "Could not extract Web Reader session state after cookie renewal"
            )
        if str(state.book_id) != str(book_id):
            raise ValidationError(
                f"Reader page resolved to a different book: {state.book_id}"
            )
        if not state.psvts:
            if attempt == 0 and client.renew():
                continue
            raise ValidationError("Reader session does not contain psvts")
        return referer, state
    raise ValidationError("Could not load Web Reader session")


def deep_success(value: Any) -> bool:
    if value is True or value == 1 or value == "1":
        return True
    for node in _walk_dicts(value):
        succ = node.get("succ")
        if succ is True or succ == 1 or succ == "1":
            return True
        if node.get("synckey") is not None or node.get("syncKey") is not None:
            return True
    return False


def response_shape(value: Any) -> str:
    if isinstance(value, dict):
        return "object(" + ",".join(sorted(map(str, value.keys()))) + ")"
    if isinstance(value, list):
        child_types = sorted({type(child).__name__ for child in value})
        return f"array(len={len(value)},types={','.join(child_types)})"
    if isinstance(value, str):
        return f"string(len={len(value)})"
    return type(value).__name__


def make_enter_read_params(
    *,
    book_id: str,
    position: dict[str, Any],
    psvts: str,
    pclts: str,
) -> dict[str, Any]:
    """Build the payload used by FETCH_READER_ENTER_BOOK_READ.

    The current Web Reader signs this smaller payload before starting periodic
    reports. In particular, it intentionally omits rt/ts/rn/sg.
    """
    report = make_read_params(
        book_id=book_id,
        chapter_uid=position["chapter_uid"],
        chapter_idx=position["chapter_idx"],
        chapter_offset=position["chapter_offset"],
        progress=position["progress"],
        summary=position["summary"],
        psvts=psvts,
        pclts=pclts,
        token="",
        elapsed_seconds=0,
    )
    for key in ("rt", "ts", "rn", "sg"):
        report.pop(key, None)
    report["s"] = weread_sign(sorted_query(report))
    return report


def choose_upload_position(
    remote: dict[str, Any],
    reader_state: Any,
) -> dict[str, Any]:
    reader_progress = reader_state.progress or {}
    if isinstance(reader_progress.get("book"), dict):
        reader_progress = reader_progress["book"]
    current_chapter = reader_state.current_chapter or {}

    def value(remote_key: str, *fallback_keys: str) -> Any:
        if remote.get(remote_key) is not None:
            return remote[remote_key]
        for container in (reader_progress, current_chapter):
            for key in fallback_keys:
                if container.get(key) is not None:
                    return container[key]
        return None

    selected = {
        "progress": value("progress", "progress"),
        "chapter_uid": value("chapter_uid", "chapterUid", "chapterId"),
        "chapter_idx": value("chapter_idx", "chapterIdx", "chapterIndex"),
        "chapter_offset": value(
            "chapter_offset", "chapterOffset", "chapterPos", "offset"
        ),
        "summary": remote.get("summary")
        or reader_progress.get("summary")
        or current_chapter.get("title")
        or "",
    }
    if selected["chapter_uid"] is None:
        raise ValidationError("Remote/Reader state does not contain chapterUid")
    selected["chapter_idx"] = int(selected["chapter_idx"] or 0)
    selected["chapter_offset"] = int(selected["chapter_offset"] or 0)
    progress = float(selected["progress"] or 0)
    # Web Reader computes this with parseInt(100 * ratio). Preserve integer
    # JSON/signature encoding (`74`, not `74.0`) when the cloud value is whole.
    selected["progress"] = int(progress) if progress.is_integer() else progress
    return selected


def positions_match(before: dict[str, Any], after: dict[str, Any]) -> bool:
    return (
        math.isclose(
            float(before.get("progress") or 0),
            float(after.get("progress") or 0),
            rel_tol=0,
            abs_tol=1e-8,
        )
        and str(before.get("chapter_uid")) == str(after.get("chapter_uid"))
        and int(before.get("chapter_offset") or 0)
        == int(after.get("chapter_offset") or 0)
    )


def pull_current_position(
    client: WeReadClient,
    api_key: str,
    book_id: str,
) -> dict[str, Any]:
    """Prefer the uncached cookie endpoint for write-after-read verification."""
    try:
        return normalized_position(
            find_progress_node(cookie_progress(client, book_id), book_id)
        )
    except (ValidationError, RuntimeError, ValueError, json.JSONDecodeError):
        return normalized_position(
            find_progress_node(gateway_progress(api_key, book_id), book_id)
        )


def wait_for_position(
    client: WeReadClient,
    api_key: str,
    book_id: str,
    expected: dict[str, Any],
) -> tuple[bool, dict[str, Any]]:
    current = expected
    for attempt in range(4):
        current = pull_current_position(client, api_key, book_id)
        if positions_match(expected, current):
            return True, current
        if attempt < 3:
            time.sleep(1)
    return False, current


def offline_regressions() -> int:
    """Exercise production Lua request sequencing without credentials or writes."""
    root = Path(__file__).resolve().parent.parent
    position = {"chapter_uid": 2, "chapter_idx": 2, "chapter_offset": 10,
                "progress": 1, "summary": ""}
    enter = make_enter_read_params(book_id="test", position=position,
                                   psvts="test", pclts="test")
    report = make_read_params(book_id="test", chapter_uid=2, chapter_idx=2,
                             chapter_offset=10, progress=1, summary="",
                             psvts="test", pclts="test", token="test",
                             elapsed_seconds=0)
    if "rt" in enter or report.get("rt") != 0:
        raise ValidationError("Enter/report payload separation failed")
    if deep_success({"succ": 0, "errCode": -1}):
        raise ValidationError("Rejected enter was accepted")
    print("[offline protocol] enter omits rt; progress report preserves rt=0", flush=True)
    try:
        result = subprocess.run(["luajit", "spec/read_report_progress_spec.lua"],
                                cwd=root, check=False)
    except FileNotFoundError as exc:
        raise ValidationError("Install LuaJIT to run offline regressions") from exc
    if result.returncode:
        raise ValidationError("Production request-sequencing regressions failed")
    print("[offline sequencing] real progress POST and rejected-enter retries passed")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline-regressions", action="store_true",
                        help="Validate payloads and production sequencing without credentials")
    parser.add_argument(
        "--settings",
        type=Path,
        default=Path("settings/weread.lua"),
        help=(
            "KOReader WeRead settings file, or - for stdin "
            "(default: settings/weread.lua)"
        ),
    )
    parser.add_argument(
        "--book-id",
        help="Target book ID; defaults to read_report.book_id in settings",
    )
    parser.add_argument(
        "--round-trip-write",
        action="store_true",
        help="Run enter/read upload and a reversible pull-after-write check",
    )
    parser.add_argument(
        "--elapsed-seconds",
        type=int,
        default=0,
        help=(
            "Reading seconds included in report payloads during the write test "
            "(default: 0)"
        ),
    )
    parser.add_argument(
        "--probe-distance",
        type=int,
        default=1,
        help=(
            "Character distance for the reversible offset probe "
            "(default: 1)"
        ),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.offline_regressions:
        return offline_regressions()
    settings = load_settings(args.settings)
    book_id = str(args.book_id or settings["default_book_id"] or "")
    if not book_id:
        raise ValidationError(
            "No book ID supplied and read_report.book_id is empty"
        )

    cookie_header = "; ".join(
        f"{name}={value}" for name, value in settings["cookies"].items()
    )
    client = WeReadClient(
        cookie_file=None,
        cookie_string=cookie_header,
        save_cookies=None,
    )

    gateway_raw = gateway_progress(settings["api_key"], book_id)
    gateway_position = normalized_position(
        find_progress_node(gateway_raw, book_id)
    )
    print(
        "[gateway pull] ok:",
        json.dumps(public_position(gateway_position), ensure_ascii=False),
    )

    try:
        web_raw = cookie_progress(client, book_id)
        web_position = normalized_position(find_progress_node(web_raw, book_id))
        print(
            "[web pull] ok:",
            json.dumps(public_position(web_position), ensure_ascii=False),
        )
    except (ValidationError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(f"[web pull] unavailable: {exc}")

    referer, reader_state = load_reader_state(client, book_id)
    print(
        "[reader context] ok:",
        json.dumps(
            {
                "book_id": reader_state.book_id,
                "title": reader_state.book_title,
                "has_psvts": bool(reader_state.psvts),
                "has_pclts": bool(reader_state.pclts),
                "has_token": bool(reader_state.token),
            },
            ensure_ascii=False,
        ),
    )

    if not args.round_trip_write:
        print("Read-only validation passed. Add --round-trip-write to test upload.")
        return 0

    upload_position = choose_upload_position(gateway_position, reader_state)
    elapsed_seconds = max(0, int(args.elapsed_seconds))
    probe_distance = max(1, int(args.probe_distance))
    print(
        "[upload source]",
        f"summary_length={len(upload_position['summary'])}",
        f"elapsed_seconds={elapsed_seconds}",
    )
    # Web Reader commits UPDATE_READER_PAGE_CLIENT_TIMESTAMP once at page
    # initialization and reuses that encrypted value for both enter and report.
    page_client_timestamp = (
        reader_state.pclts or weread_e(int(time.time()))
    )

    enter_payload = make_enter_read_params(
        book_id=book_id,
        position=upload_position,
        psvts=reader_state.psvts,
        pclts=page_client_timestamp,
    )
    enter_result = client.post_json(
        WEB_READ_URL,
        enter_payload,
        referer=referer,
    )
    print("[enter-read handshake] HTTP response:", response_shape(enter_result))
    if not deep_success(enter_result):
        raise ValidationError("Enter was not acknowledged; do not claim an open session")

    def upload(
        position: dict[str, Any],
        report_seconds: int = 0,
    ) -> Any:
        payload = make_read_params(
            book_id=book_id,
            chapter_uid=position["chapter_uid"],
            chapter_idx=position["chapter_idx"],
            chapter_offset=position["chapter_offset"],
            progress=position["progress"],
            summary=position["summary"],
            psvts=reader_state.psvts,
            pclts=page_client_timestamp,
            token=reader_state.token or DEFAULT_READER_TOKEN,
            elapsed_seconds=report_seconds,
        )
        return client.post_json(WEB_READ_URL, payload, referer=referer)

    if elapsed_seconds:
        # Credit only time actually elapsed after the accepted enter.
        time.sleep(elapsed_seconds)
    result = upload(upload_position, elapsed_seconds)
    acknowledged = deep_success(result)
    print(
        "[same-position upload] HTTP response:",
        response_shape(result),
        "position:",
        json.dumps(public_position(gateway_position), ensure_ascii=False),
    )

    if not acknowledged:
        renewed = client.renew()
        print(f"[cookie renewal] succ=1: {renewed}")
        if renewed:
            referer, reader_state = load_reader_state(client, book_id)
            page_client_timestamp = (
                reader_state.pclts or weread_e(int(time.time()))
            )
            enter_payload = make_enter_read_params(
                book_id=book_id,
                position=upload_position,
                psvts=reader_state.psvts,
                pclts=page_client_timestamp,
            )
            enter_result = client.post_json(
                WEB_READ_URL,
                enter_payload,
                referer=referer,
            )
            print(
                "[post-renewal enter-read handshake] HTTP response:",
                response_shape(enter_result),
            )
            if not deep_success(enter_result):
                raise ValidationError("Renewed enter was not acknowledged")
            result = upload(upload_position)
            acknowledged = deep_success(result)
            print("[post-renewal upload] HTTP response:", response_shape(result))

    # Some currently deployed /web/book/read responses are HTTP 200 with an
    # empty JSON object. A same-position write cannot prove whether such a
    # response was accepted, so use a reversible one-character offset probe and
    # restore the original position in a finally block.
    if not acknowledged:
        print(
            "[write acknowledgement] absent; starting reversible "
            f"{probe_distance}-character offset probe"
        )
        probe = copy.deepcopy(upload_position)
        if probe["chapter_offset"] >= probe_distance:
            probe["chapter_offset"] -= probe_distance
        else:
            probe["chapter_offset"] += probe_distance
        probe_expected = copy.deepcopy(gateway_position)
        probe_expected["chapter_offset"] = probe["chapter_offset"]
        probe_observed = False
        restore_observed = False
        last_position = gateway_position
        try:
            upload(probe, elapsed_seconds)
            probe_observed, last_position = wait_for_position(
                client,
                settings["api_key"],
                book_id,
                probe_expected,
            )
        finally:
            upload(upload_position)
            restore_observed, last_position = wait_for_position(
                client,
                settings["api_key"],
                book_id,
                gateway_position,
            )
        if not restore_observed:
            raise ValidationError(
                "The reversible probe could not confirm restoration of the "
                "original cloud position"
            )
        if not probe_observed:
            raise ValidationError(
                "HTTP 200 was returned, but the reversible probe was not "
                "observable through either progress endpoint"
            )
        print("[reversible probe] observed and original position restored")

    unchanged, after_position = wait_for_position(
        client,
        settings["api_key"],
        book_id,
        gateway_position,
    )
    if not unchanged:
        raise ValidationError(
            "Post-upload position differs from the original position"
        )
    print(
        "[post-upload pull] unchanged:",
        json.dumps(public_position(after_position), ensure_ascii=False),
    )
    print("Round-trip progress-sync protocol validation passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as exc:
        print(f"Validation failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
