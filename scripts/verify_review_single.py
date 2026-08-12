#!/usr/bin/env python3
"""
Verify WeRead GET /web/review/single (single review detail + comments).

Usage:
    python3 scripts/verify_review_single.py --cookie "wr_skey=XXX; wr_vid=XXX; ..."
    python3 scripts/verify_review_single.py --cookie "..." --review-id "REVIEW_ID"

Or set WEREAD_COOKIE env var. Provide --review-id from a thought that has comments,
for example from /book/readreviews pageReviews[].reviewId in browser DevTools.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/148.0.0.0 Safari/537.36"
)


def build_url(review_id, comments_count=20):
    params = {
        "reviewId": review_id,
        "commentsCount": comments_count,
        "commentsDirection": 0,
        "likesCount": 0,
        "synckey": 0,
    }
    query = urllib.parse.urlencode(params)
    return f"https://weread.qq.com/web/review/single?{query}"


def http_get(url, cookie):
    headers = {
        "Accept": "application/json, text/plain, */*",
        "Referer": "https://weread.qq.com/",
        "Cookie": cookie,
        "User-Agent": UA,
    }
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req) as resp:
        return resp.read().decode("utf-8", errors="replace"), resp.status


def redact(value, keep=4):
    text = str(value or "")
    if len(text) <= keep * 2:
        return "***"
    return f"{text[:keep]}...{text[-keep:]}"


def main():
    parser = argparse.ArgumentParser(description="Verify WeRead /web/review/single")
    parser.add_argument("--cookie", default=os.environ.get("WEREAD_COOKIE", ""))
    parser.add_argument(
        "--review-id",
        default="",
        help="reviewId from pageReviews[].reviewId (required for live test)",
    )
    parser.add_argument("--comments-count", type=int, default=20)
    args = parser.parse_args()

    if not args.cookie:
        print("ERROR: provide --cookie or set WEREAD_COOKIE", file=sys.stderr)
        sys.exit(1)

    print("=" * 60)
    print("Test 1: /web/review/single without reviewId")
    print("Expected: HTTP 4xx or empty/invalid payload")
    print("=" * 60)
    bad_url = build_url("")
    try:
        body, status = http_get(bad_url, args.cookie)
        print(f"  Status: {status}, body_bytes: {len(body)}")
        try:
            data = json.loads(body)
            print(f"  errCode: {data.get('errCode', 'none')}")
        except json.JSONDecodeError:
            print("  body is not JSON")
    except urllib.error.HTTPError as exc:
        print(f"  HTTPError: {exc.code}")
    print()

    if not args.review_id:
        print("Skipping Test 2: no --review-id provided")
        print("Provide a reviewId from readreviews pageReviews to verify comments.")
        return

    print("=" * 60)
    print("Test 2: /web/review/single with reviewId")
    print(f"  reviewId: {redact(args.review_id)}")
    print("=" * 60)
    url = build_url(args.review_id, args.comments_count)
    body, status = http_get(url, args.cookie)
    data = json.loads(body)
    review_id = data.get("reviewId", "")
    comments = data.get("comments") or []
    comments_count = data.get("commentsCount", len(comments))
    print(f"  Status: {status}")
    print(f"  reviewId present: {bool(review_id)}")
    print(f"  commentsCount: {comments_count}")
    print(f"  comments returned: {len(comments)}")
    if comments:
        sample = comments[0]
        author = (sample.get("author") or {}).get("name") or sample.get("author", "")
        content = str(sample.get("content", ""))[:40].replace("\n", " ")
        print(f"  first comment author: {redact(author)}")
        print(f"  first comment preview: {content!r}")
    if review_id:
        print("  PASS: endpoint returned review detail payload")
    else:
        print("  WARN: response missing reviewId; check cookie or reviewId")
        sys.exit(1)


if __name__ == "__main__":
    main()
