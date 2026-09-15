#!/usr/bin/env python3
"""Verify the query form used while polling a WeRead QR login session.

The script uses an anonymous, short-lived login session and never prints login
tokens or account data. Run it once with each form and scan the displayed URL:

    python3 scripts/verify_qr_login_otp.py --otp-form empty
    python3 scripts/verify_qr_login_otp.py --otp-form bare
"""

import argparse
import json
import urllib.error
import urllib.parse
import urllib.request


BASE_URL = "https://weread.qq.com"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 Chrome/148.0.0.0 Safari/537.36"
)


def request_json(url, timeout):
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json, text/plain, */*",
            "Referer": BASE_URL + "/r/weread-skills",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
            return response.status, json.loads(body)
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        return error.code, json.loads(body)


def redacted_summary(status, data):
    nested = data.get("data") if isinstance(data.get("data"), dict) else {}
    return {
        "http_status": status,
        "succeed": data.get("succeed"),
        "logicCode": data.get("logicCode"),
        "errcode": data.get("errcode", nested.get("errcode")),
        "errmsg": data.get("errmsg", nested.get("errmsg")),
        "has_access_token": bool(data.get("accessToken")),
        "has_web_login_vid": bool(data.get("webLoginVid")),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--otp-form",
        choices=("empty", "bare"),
        default="empty",
        help="Use otp= (empty) or otp (bare) in the polling query",
    )
    args = parser.parse_args()

    status, login_uid = request_json(BASE_URL + "/api/auth/getLoginUid", 20)
    uid = login_uid.get("uid", "")
    if status != 200 or not uid:
        raise SystemExit("Unable to create an anonymous QR login session")

    print("Open this short-lived confirmation URL and approve the login:")
    print(BASE_URL + "/web/confirm?uid=" + urllib.parse.quote(uid, safe=""))
    input("Press Enter immediately after approving the QR login...")

    query = "uid=" + urllib.parse.quote(uid, safe="") + "&otp"
    if args.otp_form == "empty":
        query += "="
    status, result = request_json(
        BASE_URL + "/api/auth/getLoginInfo?" + query,
        70,
    )
    print(json.dumps(redacted_summary(status, result), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
