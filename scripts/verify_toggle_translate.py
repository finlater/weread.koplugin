#!/usr/bin/env python3
"""
Verify WeRead POST /web/reader/toggleTranslate (per-book full-text translation).

This is the endpoint the plugin replays in Content.sync_translation() so that,
when the user opts into "download translation", a book's translation is
enabled/generated server-side before its chapters are downloaded.

Usage:
    python3 scripts/verify_toggle_translate.py --cookie "wr_skey=XXX; wr_vid=XXX; ..." --book-id "CB_XXXX"
    python3 scripts/verify_toggle_translate.py --book-id "CB_XXXX" --enabled false

Or set WEREAD_COOKIE env var. Get --book-id from the reader URL or from
/web/book/info?bookId=... in browser DevTools.

The script prints only redacted, non-identifying status. It never stores or
prints the cookie, tokens, or the full book id.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/148.0.0.0 Safari/537.36"
)

URL = "https://weread.qq.com/web/reader/toggleTranslate"


def http_post_json(payload, cookie):
    headers = {
        "Accept": "application/json, text/plain, */*",
        "Content-Type": "application/json;charset=UTF-8",
        "Origin": "https://weread.qq.com",
        "Referer": "https://weread.qq.com/",
        "Cookie": cookie,
        "User-Agent": UA,
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(URL, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.read().decode("utf-8", errors="replace"), resp.status
    except urllib.error.HTTPError as exc:
        return exc.read().decode("utf-8", errors="replace"), exc.code


def redact(value, keep=4):
    text = str(value or "")
    if len(text) <= keep * 2:
        return "***"
    return f"{text[:keep]}...{text[-keep:]}"


def toggle(book_id, enabled, cookie, label):
    print("=" * 60)
    print(f"{label}: toggleTranslate enabled={enabled}")
    print(f"  bookId: {redact(book_id)}")
    print("=" * 60)
    body, status = http_post_json({"bookId": book_id, "enabled": enabled}, cookie)
    print(f"  Status: {status}, body_bytes: {len(body)}")
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        print("  body is not JSON")
        return False
    succ = data.get("succ")
    print(f"  succ: {succ}")
    if status == 200 and succ == 1:
        print("  PASS: endpoint accepted the toggle")
        return True
    print(f"  WARN: unexpected response (errCode={data.get('errCode', 'none')})")
    return False


def main():
    parser = argparse.ArgumentParser(
        description="Verify WeRead /web/reader/toggleTranslate"
    )
    parser.add_argument("--cookie", default=os.environ.get("WEREAD_COOKIE", ""))
    parser.add_argument(
        "--book-id", default="", help="bookId such as CB_XXXX (required for live test)"
    )
    parser.add_argument(
        "--enabled",
        default="true",
        choices=["true", "false"],
        help="final translation display state to leave the book in (default true)",
    )
    args = parser.parse_args()

    if not args.cookie:
        print("ERROR: provide --cookie or set WEREAD_COOKIE", file=sys.stderr)
        sys.exit(1)
    if not args.book_id:
        print("ERROR: provide --book-id", file=sys.stderr)
        sys.exit(1)

    # Test 1: invalid input (empty bookId) should not report success.
    ok_bad = toggle("", True, args.cookie, "Test 1 (invalid bookId)")
    print()
    if ok_bad:
        print("WARN: empty bookId unexpectedly succeeded")

    # Test 2: enable translation, expect succ == 1.
    ok_on = toggle(args.book_id, True, args.cookie, "Test 2 (enable)")
    print()

    # Test 3: toggle off then back to the requested final state, showing the
    # endpoint works in both directions without leaving a surprise state.
    toggle(args.book_id, False, args.cookie, "Test 3 (disable)")
    print()
    final = args.enabled == "true"
    toggle(args.book_id, final, args.cookie, f"Restore (enabled={final})")

    if not ok_on:
        sys.exit(1)


if __name__ == "__main__":
    main()
