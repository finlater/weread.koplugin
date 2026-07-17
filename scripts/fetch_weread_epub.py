#!/usr/bin/env python3
"""
Fetch readable WeRead EPUB-format chapter content and build a local EPUB.

This is a research/validation script for a KOReader plugin. It requires a
valid user-authenticated WeRead Web cookie jar or Cookie header string.
It does not print chapter text to stdout.
"""

from __future__ import annotations

import argparse
import base64
import http.cookiejar
import hashlib
import html
import io
import json
import os
import posixpath
import random
import re
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile
from dataclasses import dataclass
from http.cookies import SimpleCookie
from pathlib import Path
from typing import Any, Optional, Union


USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 "
    "Safari/537.36 Edg/135.0.0.0"
)


def md5_hex(value: Union[str, bytes]) -> str:
    if isinstance(value, str):
        value = value.encode("utf-8")
    return hashlib.md5(value).hexdigest()


def weread_e(value: Union[str, int]) -> str:
    s = str(value)
    h = md5_hex(s)
    result = h[:3]

    if re.fullmatch(r"\d+", s):
        chunks = [format(int(s[i : i + 9]), "x") for i in range(0, len(s), 9)]
        type_flag = "3"
    else:
        chunks = ["".join(format(ord(ch), "x") for ch in s)]
        type_flag = "4"

    result += type_flag
    result += "2" + h[-2:]

    for index, chunk in enumerate(chunks):
        result += format(len(chunk), "x").zfill(2) + chunk
        if index < len(chunks) - 1:
            result += "g"

    if len(result) < 20:
        result += h[: 20 - len(result)]

    result += md5_hex(result)[:3]
    return result


def weread_sign(query: str) -> str:
    a = 0x15051505
    b = a
    length = len(query)
    i = length - 1

    while i > 0:
        a = (a ^ (ord(query[i]) << ((length - i) % 30))) & 0x7FFFFFFF
        b = (b ^ (ord(query[i - 1]) << (i % 30))) & 0x7FFFFFFF
        i -= 2

    return format(a + b, "x").lower()


def sorted_query(params: dict[str, Any]) -> str:
    def js_string(value: Any) -> str:
        if value is True:
            return "true"
        if value is False:
            return "false"
        if value is None:
            return "null"
        return str(value)

    return "&".join(
        f"{key}={urllib.parse.quote(js_string(params[key]), safe='')}"
        for key in sorted(params.keys())
    )


def make_content_params(
    book_id: str,
    chapter_uid: Union[int, str],
    psvts: str,
    *,
    style: bool = False,
    sc: int = 1,
) -> dict[str, Any]:
    ct_value = int(time.time())
    ct = str(ct_value)
    if weread_e(ct) == psvts:
        ct_value += 1
        ct = str(ct_value)
    params: dict[str, Any] = {
        "b": weread_e(book_id),
        "c": weread_e(chapter_uid),
        "r": str(random.randint(0, 9999) ** 2),
        "ct": ct,
        "ps": psvts,
        "pc": weread_e(ct),
        "sc": sc,
        "prevChapter": False,
        "st": 1 if style else 0,
    }
    params["s"] = weread_sign(sorted_query(params))
    return params


def web_app_id(user_agent: str = USER_AGENT) -> str:
    prefix = "".join(str(len(part) % 10) for part in user_agent.split(" ")[:12])
    value = 0
    for char in user_agent:
        value = (0x83 * value + ord(char)) & 0x7FFFFFFF
    return f"wb{prefix}h{value}"


def make_read_params(
    *,
    book_id: str,
    chapter_uid: Union[int, str],
    chapter_idx: int,
    chapter_offset: int,
    progress: Union[int, float],
    summary: str,
    psvts: str,
    pclts: str,
    token: str,
    elapsed_seconds: int = 0,
) -> dict[str, Any]:
    ts = int(time.time() * 1000)
    rn = random.randint(0, 999)
    ct = int(ts / 1000)
    pc = pclts
    if pc is None or str(pc) in {"", "0"}:
        pc = weread_e(ct)
    params: dict[str, Any] = {
        "appId": web_app_id(),
        "b": weread_e(book_id),
        "c": weread_e(chapter_uid or 0),
        "ci": int(chapter_idx or 0),
        "co": int(chapter_offset or 0),
        "sm": (summary or "")[:20],
        "pr": progress,
        "rt": max(0, int(elapsed_seconds or 0)),
        "ts": ts,
        "rn": rn,
        "sg": hashlib.sha256(f"{ts}{rn}{token}".encode("utf-8")).hexdigest(),
        "ct": ct,
        "ps": psvts,
        "pc": pc,
    }
    params["s"] = weread_sign(sorted_query(params))
    return params


class WeReadClient:
    def __init__(
        self,
        *,
        cookie_file: Optional[Path],
        cookie_string: Optional[str],
        save_cookies: Optional[Path],
    ) -> None:
        self.cookie_jar = http.cookiejar.MozillaCookieJar()
        self.save_cookies = save_cookies or cookie_file

        if cookie_file and cookie_file.exists():
            self.cookie_jar.load(str(cookie_file), ignore_discard=True, ignore_expires=True)

        if cookie_string:
            self._load_cookie_string(cookie_string)

        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookie_jar)
        )

    def _load_cookie_string(self, cookie_string: str) -> None:
        simple = SimpleCookie()
        simple.load(cookie_string)
        for morsel in simple.values():
            cookie = http.cookiejar.Cookie(
                version=0,
                name=morsel.key,
                value=morsel.value,
                port=None,
                port_specified=False,
                domain=".weread.qq.com",
                domain_specified=True,
                domain_initial_dot=True,
                path="/",
                path_specified=True,
                secure=False,
                expires=None,
                discard=True,
                comment=None,
                comment_url=None,
                rest={},
                rfc2109=False,
            )
            self.cookie_jar.set_cookie(cookie)

    def persist_cookies(self) -> None:
        if not self.save_cookies:
            return
        self.save_cookies.parent.mkdir(parents=True, exist_ok=True)
        self.cookie_jar.save(str(self.save_cookies), ignore_discard=True, ignore_expires=True)

    def request(
        self,
        url: str,
        *,
        method: str = "GET",
        data: Optional[dict[str, Any]] = None,
        referer: str = "https://weread.qq.com/",
        accept: str = "application/json, text/plain, */*",
    ) -> bytes:
        body = None
        headers = {
            "accept": accept,
            "origin": "https://weread.qq.com",
            "referer": referer,
            "user-agent": USER_AGENT,
        }

        if data is not None:
            body = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            headers["content-type"] = "application/json;charset=UTF-8"

        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=30) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            payload = exc.read().decode("utf-8", "replace")
            raise RuntimeError(f"HTTP {exc.code} for {url}: {payload[:300]}") from exc

    def get_text(self, url: str, *, referer: str = "https://weread.qq.com/") -> str:
        return self.request(
            url,
            referer=referer,
            accept="text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ).decode("utf-8", "replace")

    def post_json(
        self,
        url: str,
        data: dict[str, Any],
        *,
        referer: str = "https://weread.qq.com/",
    ) -> Any:
        raw = self.request(url, method="POST", data=data, referer=referer)
        text = raw.decode("utf-8", "replace")
        return json.loads(text)

    def renew(self, rq: str = "%2Fweb%2Fbook%2Fread") -> bool:
        result = self.post_json(
            "https://weread.qq.com/web/login/renewal",
            {"rq": rq, "ql": False},
        )
        self.persist_cookies()
        return bool(result.get("succ"))


@dataclass
class ReaderState:
    book_id: str
    book_title: str
    author: str
    psvts: str
    pclts: str
    token: str
    current_chapter: dict[str, Any]
    progress: dict[str, Any]
    initial_state: dict[str, Any]


@dataclass
class EpubAsset:
    href: str
    media_type: str
    data: bytes


def extract_initial_state(reader_html: str) -> dict[str, Any]:
    match = re.search(
        r"window\.__INITIAL_STATE__\s*=\s*(\{.*?\})\s*;\s*\(function",
        reader_html,
        flags=re.S,
    )
    if not match:
        raise ValueError("Could not find window.__INITIAL_STATE__ in reader HTML")
    return json.loads(match.group(1))


def read_reader_state(reader_html: str) -> ReaderState:
    state = extract_initial_state(reader_html)
    reader = state.get("reader", {})
    book_info = reader.get("bookInfo", {})
    book_id = str(book_info.get("bookId") or "")
    if not book_id:
        raise ValueError("Could not find reader.bookInfo.bookId")

    return ReaderState(
        book_id=book_id,
        book_title=book_info.get("title") or book_id,
        author=book_info.get("author") or "",
        psvts=reader.get("psvts") or "",
        pclts=reader.get("pclts") or "",
        token=reader.get("token") or "",
        current_chapter=reader.get("currentChapter") or {},
        progress=reader.get("progress") or {},
        initial_state=state,
    )


def normalize_chapter_infos(payload: Any, book_id: str) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    candidates: list[Any]
    if isinstance(payload, list):
        candidates = payload
    elif isinstance(payload, dict):
        if isinstance(payload.get("data"), list):
            candidates = payload["data"]
        elif isinstance(payload.get("books"), list):
            candidates = payload["books"]
        else:
            candidates = [payload]
    else:
        raise ValueError("Unexpected chapterInfos response")

    for item in candidates:
        if not isinstance(item, dict):
            continue
        if str(item.get("bookId") or item.get("book", {}).get("bookId") or "") == book_id:
            chapters = item.get("updated") or item.get("chapterInfos") or item.get("chapters") or []
            return item, [ch for ch in chapters if isinstance(ch, dict) and ch.get("chapterUid")]

    raise ValueError(f"Could not find catalog for bookId={book_id}")


def checked_body(response_text: str) -> str:
    if len(response_text) <= 32:
        return ""
    expected = response_text[:32]
    body = response_text[32:]
    actual = md5_hex(body).upper()
    if actual != expected:
        raise ValueError(f"Shard MD5 mismatch: expected={expected}, actual={actual}")
    return body


def swap_positions(encoded: str) -> list[int]:
    length = len(encoded)
    if length < 4:
        return []
    if length < 11:
        return [0, 2]

    n = min(4, (length + 9) // 10)
    tmp = ""
    for i in range(length - 1, length - n - 1, -1):
        tmp += str(int(bin(ord(encoded[i]))[2:], 4))

    result: list[int] = []
    m = length - n - 2
    step = len(str(m))
    i = 0
    while len(result) < 10 and i + step < len(tmp):
        result.append(int(tmp[i : i + step]) % m)
        result.append(int(tmp[i + 1 : i + 1 + step]) % m)
        i += step
    return result


def reverse_swaps(encoded: str, positions: list[int]) -> str:
    chars = list(encoded)
    for i in range(len(positions) - 1, -1, -2):
        for k in (1, 0):
            left = positions[i] + k
            right = positions[i - 1] + k
            chars[left], chars[right] = chars[right], chars[left]
    return "".join(chars)


def repair_utf8(binary_text: str) -> str:
    out: list[str] = []
    i = 0
    while i < len(binary_text):
        b0 = ord(binary_text[i])
        if 0xC0 <= b0 <= 0xDF and i + 1 < len(binary_text):
            b1 = ord(binary_text[i + 1])
            if 0x80 <= b1 <= 0xBF:
                out.append(chr(((b0 & 0x1F) << 6) | (b1 & 0x3F)))
                i += 2
                continue
        if 0xE0 <= b0 <= 0xEF and i + 2 < len(binary_text):
            b1 = ord(binary_text[i + 1])
            b2 = ord(binary_text[i + 2])
            if 0x80 <= b1 <= 0xBF and 0x80 <= b2 <= 0xBF:
                out.append(chr(((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)))
                i += 3
                continue
        if 0xF0 <= b0 <= 0xF7 and i + 3 < len(binary_text):
            b1 = ord(binary_text[i + 1])
            b2 = ord(binary_text[i + 2])
            b3 = ord(binary_text[i + 3])
            if 0x80 <= b1 <= 0xBF and 0x80 <= b2 <= 0xBF and 0x80 <= b3 <= 0xBF:
                codepoint = (
                    ((b0 & 0x07) << 18)
                    | ((b1 & 0x3F) << 12)
                    | ((b2 & 0x3F) << 6)
                    | (b3 & 0x3F)
                )
                out.append(chr(codepoint))
                i += 4
                continue
        out.append(binary_text[i])
        i += 1
    return "".join(out)


def decode_encoded_payload(encoded_payload: str) -> str:
    if not encoded_payload:
        return ""
    encoded_payload = encoded_payload[1:]
    reordered = reverse_swaps(encoded_payload, swap_positions(encoded_payload))
    b64 = re.sub(r"[^A-Za-z0-9+/]", "", reordered.replace("-", "+").replace("_", "/"))
    padding = "=" * (-len(b64) % 4)
    binary = base64.b64decode(b64 + padding).decode("latin-1")
    return repair_utf8(binary)


def decode_content_shards(e0: str, e1: str, e3: str) -> str:
    payload = checked_body(e0) + checked_body(e1) + checked_body(e3)
    return decode_encoded_payload(payload)


def decode_style_shard(e2: str) -> str:
    return decode_encoded_payload(checked_body(e2))


def extract_body(source: str) -> str:
    match = re.search(r"<body[^>]*>(.*?)</body>", source, flags=re.I | re.S)
    if match:
        return match.group(1)
    escaped = html.escape(source).replace("\n", "<br/>")
    return f"<p>{escaped}</p>"


def make_chapter_xhtml(title: str, source: str, css_href: str = "../styles/weread.css") -> str:
    body = extract_body(source)
    return f'''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head>
  <meta charset="utf-8"/>
  <title>{html.escape(title)}</title>
  <link rel="stylesheet" type="text/css" href="{html.escape(css_href)}"/>
</head>
<body>
  <h1>{html.escape(title)}</h1>
  {body}
</body>
</html>
'''


def image_extension_and_type(data: bytes) -> tuple[str, str]:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png", "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return ".jpg", "image/jpeg"
    if data.startswith(b"GIF87a") or data.startswith(b"GIF89a"):
        return ".gif", "image/gif"
    if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return ".webp", "image/webp"
    return ".bin", "application/octet-stream"


def rewrite_image_sources(source: str, src_map: dict[str, str]) -> str:
    if not src_map:
        return source

    def replace_src(match: re.Match[str]) -> str:
        quote = match.group(1)
        src = html.unescape(match.group(2))
        key = posixpath.basename(urllib.parse.urlparse(src).path)
        href = src_map.get(key)
        if not href:
            return match.group(0)
        return f"src={quote}{href}{quote}"

    return re.sub(r"src=(['\"])(.*?)\1", replace_src, source)


def download_chapter_assets(
    client: WeReadClient,
    *,
    chapter: dict[str, Any],
    referer: str,
) -> tuple[list[EpubAsset], dict[str, str]]:
    tar_url = chapter.get("tar")
    if not tar_url:
        return [], {}

    raw = client.request(str(tar_url), referer=referer)
    assets: list[EpubAsset] = []
    src_map: dict[str, str] = {}

    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:*") as tf:
        for member in tf.getmembers():
            if not member.isfile():
                continue
            extracted = tf.extractfile(member)
            if extracted is None:
                continue
            data = extracted.read()
            ext, media_type = image_extension_and_type(data)
            if not media_type.startswith("image/"):
                continue
            stem = posixpath.basename(member.name)
            filename = stem if stem.endswith(ext) else stem + ext
            href = "images/" + filename
            epub_relative = "../" + href
            assets.append(EpubAsset(href=href, media_type=media_type, data=data))
            src_map[stem] = epub_relative
            src_map[filename] = epub_relative

    return assets, src_map


def xml_escape(value: str) -> str:
    return html.escape(value, quote=True)


def write_epub(
    output: Path,
    *,
    title: str,
    author: str,
    chapters: list[tuple[str, str, list[EpubAsset]]],
    css: str,
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    book_uuid = f"urn:uuid:{uuid.uuid4()}"

    nav_items = "\n".join(
        f'      <li><a href="text/chapter_{i:04d}.xhtml">{xml_escape(ch_title)}</a></li>'
        for i, (ch_title, _, _) in enumerate(chapters, start=1)
    )
    nav = f'''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
<head><meta charset="utf-8"/><title>Table of Contents</title></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>目录</h1>
    <ol>
{nav_items}
    </ol>
  </nav>
</body>
</html>
'''

    manifest_chapters = "\n".join(
        f'    <item id="chapter_{i:04d}" href="text/chapter_{i:04d}.xhtml" media-type="application/xhtml+xml"/>'
        for i in range(1, len(chapters) + 1)
    )
    all_assets: dict[str, EpubAsset] = {}
    for _, _, assets in chapters:
        for asset in assets:
            all_assets[asset.href] = asset
    manifest_assets = "\n".join(
        f'    <item id="asset_{i:04d}" href="{xml_escape(asset.href)}" media-type="{xml_escape(asset.media_type)}"/>'
        for i, asset in enumerate(all_assets.values(), start=1)
    )
    spine_chapters = "\n".join(
        f'    <itemref idref="chapter_{i:04d}"/>'
        for i in range(1, len(chapters) + 1)
    )
    opf = f'''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">{xml_escape(book_uuid)}</dc:identifier>
    <dc:title>{xml_escape(title)}</dc:title>
    <dc:creator>{xml_escape(author)}</dc:creator>
    <dc:language>zh-CN</dc:language>
    <meta property="dcterms:modified">{time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="style" href="styles/weread.css" media-type="text/css"/>
{manifest_chapters}
{manifest_assets}
  </manifest>
  <spine toc="toc">
{spine_chapters}
  </spine>
</package>
'''

    ncx_points = "\n".join(
        f'''    <navPoint id="navPoint-{i}" playOrder="{i}">
      <navLabel><text>{xml_escape(ch_title)}</text></navLabel>
      <content src="text/chapter_{i:04d}.xhtml"/>
    </navPoint>'''
        for i, (ch_title, _, _) in enumerate(chapters, start=1)
    )
    ncx = f'''<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="{xml_escape(book_uuid)}"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>{xml_escape(title)}</text></docTitle>
  <navMap>
{ncx_points}
  </navMap>
</ncx>
'''

    container = '''<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'''

    with zipfile.ZipFile(output, "w") as zf:
        zf.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        zf.writestr("META-INF/container.xml", container)
        zf.writestr("OEBPS/content.opf", opf)
        zf.writestr("OEBPS/toc.ncx", ncx)
        zf.writestr("OEBPS/nav.xhtml", nav)
        zf.writestr("OEBPS/styles/weread.css", css or "body { line-height: 1.6; }\n")
        for asset in all_assets.values():
            zf.writestr("OEBPS/" + asset.href, asset.data)
        for i, (ch_title, ch_source, _) in enumerate(chapters, start=1):
            zf.writestr(
                f"OEBPS/text/chapter_{i:04d}.xhtml",
                make_chapter_xhtml(ch_title, ch_source),
            )


def reader_url_for(book_id: str, chapter_uid: Optional[Union[int, str]] = None) -> str:
    base = f"https://weread.qq.com/web/reader/{weread_e(book_id)}"
    if chapter_uid is not None:
        base += "k" + weread_e(chapter_uid)
    return base


def txt_to_xhtml(text: str) -> str:
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    paragraphs = [f"<p>{html.escape(line.rstrip())}</p>" for line in lines if line.strip()]
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title></title></head>\n'
        "<body>\n" + "\n".join(paragraphs) + "\n</body></html>"
    )


def fetch_chapter(
    client: WeReadClient,
    *,
    book_id: str,
    chapter: dict[str, Any],
    sleep_seconds: float,
    content_format: list[str],
) -> tuple[str, str, str, list[EpubAsset]]:
    chapter_uid = chapter["chapterUid"]
    title = chapter.get("title") or f"Chapter {chapter_uid}"
    referer = reader_url_for(book_id, chapter_uid)
    reader_html = client.get_text(referer, referer=referer)
    psvts = read_reader_state(reader_html).psvts
    if not psvts:
        raise ValueError(f"Missing psvts for chapterUid={chapter_uid}")

    def post(endpoint: str, *, style: bool = False) -> str:
        params = make_content_params(book_id, chapter_uid, psvts, style=style, sc=1)
        result = client.request(
            "https://weread.qq.com" + endpoint,
            method="POST",
            data=params,
            referer=referer,
        ).decode("utf-8", "replace")
        if result == "{}":
            raise ValueError(f"{endpoint} returned empty object for chapterUid={chapter_uid}")
        if sleep_seconds:
            time.sleep(sleep_seconds)
        return result

    if content_format[0] == "txt":
        t0 = post("/web/book/chapter/t_0")
        t1_text = ""
        try:
            t1_text = post("/web/book/chapter/t_1")
        except ValueError:
            pass
        plain = decode_content_shards(t0, t1_text, "")
        return str(title), txt_to_xhtml(plain), "", []

    e0 = post("/web/book/chapter/e_0")
    if e0.startswith("{") and '"bookId"' in e0:
        content_format[0] = "txt"
        t0 = post("/web/book/chapter/t_0")
        t1_text = ""
        try:
            t1_text = post("/web/book/chapter/t_1")
        except ValueError:
            pass
        plain = decode_content_shards(t0, t1_text, "")
        return str(title), txt_to_xhtml(plain), "", []

    content_format[0] = "epub"
    e1 = post("/web/book/chapter/e_1")
    e3 = post("/web/book/chapter/e_3")
    content = decode_content_shards(e0, e1, e3)
    css = ""
    try:
        e2 = post("/web/book/chapter/e_2", style=True)
        css = decode_style_shard(e2)
    except ValueError:
        pass
    assets, src_map = download_chapter_assets(client, chapter=chapter, referer=referer)
    content = rewrite_image_sources(content, src_map)
    return str(title), content, css, assets


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reader-url", help="Any WeRead reader URL for the target book")
    parser.add_argument("--book-id", help="Formal WeRead bookId; skips bookId discovery")
    parser.add_argument("--cookie-file", type=Path, help="Netscape/Mozilla cookie jar path")
    parser.add_argument("--cookie-string", help="Raw Cookie header string")
    parser.add_argument("--save-cookies", type=Path, help="Where to persist renewed cookies")
    parser.add_argument("--output", type=Path, default=Path("out/weread.epub"))
    parser.add_argument("--limit", type=int, default=0, help="Fetch only the first N readable chapters")
    parser.add_argument("--skip", type=int, default=0, help="Skip the first N chapters")
    parser.add_argument("--sleep", type=float, default=0.2, help="Delay between shard requests")
    parser.add_argument("--no-renew", action="store_true", help="Skip /web/login/renewal")
    parser.add_argument("--dump-read-payload", action="store_true", help="Print /web/book/read payload and exit")
    parser.add_argument("--report-read", action="store_true", help="POST /web/book/read with the generated payload")
    parser.add_argument("--read-chapter-uid", help="chapterUid for --dump-read-payload/--report-read")
    parser.add_argument("--read-chapter-idx", type=int, help="chapterIdx for --dump-read-payload/--report-read")
    parser.add_argument("--read-offset", type=int, help="chapter offset for --dump-read-payload/--report-read")
    parser.add_argument("--read-progress", type=float, help="book progress for --dump-read-payload/--report-read")
    parser.add_argument("--read-summary", default="", help="summary text for --dump-read-payload/--report-read")
    parser.add_argument("--read-elapsed", type=int, default=0, help="elapsed active reading seconds")
    args = parser.parse_args(argv)

    if not args.cookie_file and not args.cookie_string:
        parser.error("Provide --cookie-file or --cookie-string")
    if not args.reader_url and not args.book_id:
        parser.error("Provide --reader-url or --book-id")

    client = WeReadClient(
        cookie_file=args.cookie_file,
        cookie_string=args.cookie_string,
        save_cookies=args.save_cookies,
    )

    if not args.no_renew:
        if not client.renew():
            raise RuntimeError("Cookie renewal failed")

    if args.reader_url:
        first_reader_url = args.reader_url
    else:
        first_reader_url = reader_url_for(args.book_id or "")

    reader_html = client.get_text(first_reader_url, referer=first_reader_url)
    reader_state = read_reader_state(reader_html)
    book_id = args.book_id or reader_state.book_id

    if args.dump_read_payload or args.report_read:
        progress_book = {}
        if isinstance(reader_state.progress, dict):
            progress_book = reader_state.progress.get("book") or {}
        current_chapter = reader_state.current_chapter or {}
        chapter_uid = (
            args.read_chapter_uid
            or current_chapter.get("chapterUid")
            or progress_book.get("chapterUid")
            or 0
        )
        chapter_idx = (
            args.read_chapter_idx
            if args.read_chapter_idx is not None
            else current_chapter.get("chapterIdx") or progress_book.get("chapterIdx") or 0
        )
        chapter_offset = (
            args.read_offset
            if args.read_offset is not None
            else current_chapter.get("chapterOffset") or progress_book.get("chapterOffset") or 0
        )
        progress = (
            args.read_progress
            if args.read_progress is not None
            else progress_book.get("progress") or 0
        )
        summary = args.read_summary or progress_book.get("summary") or ""
        payload = make_read_params(
            book_id=book_id,
            chapter_uid=chapter_uid,
            chapter_idx=int(chapter_idx or 0),
            chapter_offset=int(chapter_offset or 0),
            progress=progress,
            summary=summary,
            psvts=reader_state.psvts,
            pclts=reader_state.pclts,
            token=reader_state.token,
            elapsed_seconds=args.read_elapsed,
        )
        result: dict[str, Any] = {
            "ok": True,
            "bookId": book_id,
            "mode": "report-read" if args.report_read else "dump-read-payload",
            "payload": payload,
        }
        if args.report_read:
            result["response"] = client.post_json(
                "https://weread.qq.com/web/book/read",
                payload,
                referer=first_reader_url,
            )
            client.persist_cookies()
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0

    catalog_payload = client.post_json(
        "https://weread.qq.com/web/book/chapterInfos",
        {"bookIds": [book_id]},
        referer=first_reader_url,
    )
    book_record, chapters = normalize_chapter_infos(catalog_payload, book_id)
    chapters = [
        chapter
        for chapter in chapters
        if int(chapter.get("wordCount") or 0) > 0
        and str(chapter.get("title") or "") != "封面"
    ]
    if args.skip:
        chapters = chapters[args.skip :]
    if args.limit:
        chapters = chapters[: args.limit]
    if not chapters:
        raise RuntimeError("No chapters selected")

    book_title = (
        book_record.get("book", {}).get("title")
        or book_record.get("title")
        or reader_state.book_title
        or book_id
    )
    author = (
        book_record.get("book", {}).get("author")
        or book_record.get("author")
        or reader_state.author
        or ""
    )

    fetched: list[tuple[str, str, list[EpubAsset]]] = []
    css = ""
    content_format: list[str] = ["auto"]
    for index, chapter in enumerate(chapters, start=1):
        title, content, chapter_css, assets = fetch_chapter(
            client,
            book_id=book_id,
            chapter=chapter,
            sleep_seconds=args.sleep,
            content_format=content_format,
        )
        if chapter_css and not css:
            css = chapter_css
        fetched.append((title, content, assets))
        print(
            json.dumps(
                {
                    "chapter": index,
                    "chapterUid": chapter.get("chapterUid"),
                    "title": title,
                    "contentChars": len(content),
                    "cssChars": len(chapter_css),
                    "assets": len(assets),
                },
                ensure_ascii=False,
            ),
            flush=True,
        )

    write_epub(args.output, title=book_title, author=author, chapters=fetched, css=css)
    client.persist_cookies()
    print(
        json.dumps(
            {
                "ok": True,
                "bookId": book_id,
                "title": book_title,
                "chapters": len(fetched),
                "output": str(args.output),
                "bytes": args.output.stat().st_size,
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
