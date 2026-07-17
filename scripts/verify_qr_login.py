#!/usr/bin/env python3
"""Verify WeRead's QR-login protocol without persisting credentials.

The script mirrors the login flow used by the maintained fork:

1. Establish a temporary session on /r/weread-skills.
2. Request a QR login UID from /api/auth/getLoginUid.
3. Wait for confirmation through /api/auth/getLoginInfo.
4. Handle the optional four-digit OTP.
5. Verify the returned credentials against userInfo and apikeyGet.

No cookies, access tokens, refresh tokens, or API keys are printed or saved.
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
import webbrowser
from pathlib import Path
from typing import Any
from urllib.parse import quote

import requests


BASE_URL = "https://weread.qq.com"
SKILLS_PAGE_URL = f"{BASE_URL}/r/weread-skills"
LOGIN_UID_URL = f"{BASE_URL}/api/auth/getLoginUid"
LOGIN_INFO_URL = f"{BASE_URL}/api/auth/getLoginInfo"
USER_INFO_URL = f"{BASE_URL}/api/userInfo"
API_KEY_URL = f"{BASE_URL}/api/skills/apikeyGet?only_show=1"
RENEWAL_URL = f"{BASE_URL}/web/login/renewal"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0"
)


class ProtocolError(RuntimeError):
    """Raised when WeRead returns an unexpected login response."""


def describe_shape(value: Any, depth: int = 0) -> Any:
    """Return JSON structure metadata without exposing credential values."""
    if depth >= 3:
        return type(value).__name__
    if isinstance(value, dict):
        return {
            str(key): describe_shape(item, depth + 1)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return {
            "type": "list",
            "length": len(value),
            "item": describe_shape(value[0], depth + 1) if value else None,
        }
    if isinstance(value, str):
        return {"type": "str", "length": len(value)}
    return type(value).__name__


def request_json(
    session: requests.Session,
    url: str,
    *,
    timeout: int,
    headers: dict[str, str] | None = None,
    stage: str,
) -> dict[str, Any]:
    response = session.get(url, headers=headers, timeout=timeout)
    print(
        f"[{stage}] HTTP {response.status_code}; "
        f"content-type={response.headers.get('content-type', 'unknown')}; "
        f"Set-Cookie={bool(response.headers.get('Set-Cookie'))}",
        flush=True,
    )
    try:
        data = response.json()
    except ValueError:
        data = None
    if not response.ok:
        shape = describe_shape(data) if data is not None else "non-JSON body"
        raise ProtocolError(
            f"{stage} returned HTTP {response.status_code}; response shape: {shape!r}"
        )
    if not isinstance(data, dict):
        raise ProtocolError(f"{stage} did not return a JSON object")
    return data


def establish_session(session: requests.Session) -> str:
    response = session.get(
        SKILLS_PAGE_URL,
        headers={"Referer": f"{BASE_URL}/"},
        timeout=20,
    )
    print(
        f"[skills page] HTTP {response.status_code}; redirects={len(response.history)}; "
        f"Set-Cookie={bool(response.headers.get('Set-Cookie'))}",
        flush=True,
    )
    response.raise_for_status()

    data = request_json(
        session,
        LOGIN_UID_URL,
        timeout=20,
        headers={"Referer": SKILLS_PAGE_URL},
        stage="getLoginUid",
    )
    uid = data.get("uid")
    if not isinstance(uid, str) or not uid:
        raise ProtocolError("WeRead did not return a valid login UID")
    return uid


def poll_login(
    session: requests.Session,
    uid: str,
    otp: str = "",
) -> dict[str, Any]:
    # The empty form is intentionally `&otp`, not `&otp=`.
    url = f"{LOGIN_INFO_URL}?uid={quote(uid, safe='')}&otp"
    if otp:
        url += f"={quote(otp, safe='')}"
    return request_json(
        session,
        url,
        timeout=70,
        headers={"Referer": SKILLS_PAGE_URL},
        stage="getLoginInfo",
    )


def wait_for_login(session: requests.Session, uid: str) -> dict[str, Any]:
    result = poll_login(session, uid)
    while result.get("succeed") is not True:
        logic_code = str(result.get("logicCode") or "")
        print(f"Login state: {logic_code or 'UNKNOWN'}", flush=True)

        if logic_code == "NEED_OTP":
            otp = input("Enter the four-digit code shown on your phone: ").strip()
            if len(otp) != 4 or not otp.isdigit():
                print("The verification code must contain four digits.")
                continue
            result = poll_login(session, uid, otp)
            continue

        if logic_code == "OTP_NOT_MATCH":
            print("The verification code did not match.")
            result = {"logicCode": "NEED_OTP"}
            continue

        if logic_code in {"LOGIN_TIMEOUT", "OTP_EXPIRED"}:
            raise ProtocolError(f"Login stopped with {logic_code}")

        raise ProtocolError(f"Unexpected login state: {logic_code or result!r}")

    return result


def open_qr_image(confirm_url: str) -> Path:
    try:
        import qrcode
    except ImportError as exc:
        raise ProtocolError(
            "Opening a local QR image requires `pip install qrcode[pil]`"
        ) from exc

    handle = tempfile.NamedTemporaryFile(
        prefix="weread-qr-",
        suffix=".png",
        delete=False,
    )
    handle.close()
    path = Path(handle.name)
    image = qrcode.make(confirm_url)
    image.save(path)
    webbrowser.open(path.as_uri())
    return path


def install_login_cookies(
    session: requests.Session,
    login_result: dict[str, Any],
) -> tuple[str, str]:
    web_login_vid = str(login_result.get("webLoginVid") or "")
    access_token = str(login_result.get("accessToken") or "")
    refresh_token = str(login_result.get("refreshToken") or "")
    if not web_login_vid or not access_token:
        raise ProtocolError("Successful response is missing account credentials")

    cookie_values = {
        "wr_vid": web_login_vid,
        "wr_skey": access_token,
        "wr_ql": "0",
    }
    if refresh_token:
        cookie_values["wr_rt"] = quote(refresh_token, safe="")
    for name, value in cookie_values.items():
        session.cookies.set(name, value, domain=".weread.qq.com", path="/")
    print(
        "[install credentials] session cookie names: "
        + ", ".join(sorted(cookie.name for cookie in session.cookies)),
        flush=True,
    )
    return web_login_vid, access_token


def verify_credentials(
    session: requests.Session,
    web_login_vid: str,
    access_token: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    headers = {
        "Referer": SKILLS_PAGE_URL,
        "X-Vid": web_login_vid,
        "X-Skey": access_token,
    }
    user_info = request_json(
        session,
        f"{USER_INFO_URL}?userVid={quote(web_login_vid, safe='')}",
        timeout=20,
        headers=headers,
        stage="userInfo",
    )
    api_result = request_json(
        session,
        API_KEY_URL,
        timeout=20,
        headers=headers,
        stage="apikeyGet",
    )
    api_key = api_result.get("apikey")
    if not isinstance(api_key, str) or not api_key:
        raise ProtocolError(
            "WeRead did not return an API key. This account may not have enabled "
            "WeRead Skill. In the WeRead app, open Me > Settings > WeRead Skill > "
            "Get API Key, then scan again. Response shape: "
            f"{describe_shape(api_result)!r}"
        )
    return user_info, api_result


def verify_renewal(session: requests.Session) -> dict[str, bool]:
    """Call the real renewal endpoint and return presence-only diagnostics."""
    response = session.post(
        RENEWAL_URL,
        json={"rq": "%2Fweb%2Fbook%2Fread", "ql": False},
        headers={
            "Origin": BASE_URL,
            "Referer": f"{BASE_URL}/",
        },
        timeout=20,
    )
    print(
        f"[renewal] HTTP {response.status_code}; "
        f"content-type={response.headers.get('content-type', 'unknown')}; "
        f"Set-Cookie={bool(response.headers.get('Set-Cookie'))}; "
        f"x-wr-ticket={bool(response.headers.get('x-wr-ticket'))}; "
        f"x-wrpa-0={bool(response.headers.get('x-wrpa-0'))}",
        flush=True,
    )
    response.raise_for_status()
    result = response.json()
    if not isinstance(result, dict):
        raise ProtocolError("Renewal endpoint did not return a JSON object")
    succ = result.get("succ")
    return {
        "succ": succ is True or str(succ) == "1",
        "set_cookie": bool(response.headers.get("Set-Cookie")),
        "wr_ticket": bool(response.headers.get("x-wr-ticket")),
        "wr_wrpa": bool(response.headers.get("x-wrpa-0")),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--open-browser",
        action="store_true",
        help="Generate a local QR image and open it in the default browser.",
    )
    args = parser.parse_args()

    session = requests.Session()
    session.headers.update(
        {
            "User-Agent": USER_AGENT,
            "Accept": "application/json, text/plain, */*",
        }
    )

    print("Establishing a temporary WeRead login session...", flush=True)
    uid = establish_session(session)
    confirm_url = f"{BASE_URL}/web/confirm?uid={quote(uid, safe='')}"
    print(f"Scan and confirm this URL:\n{confirm_url}", flush=True)
    qr_path = None
    if args.open_browser:
        qr_path = open_qr_image(confirm_url)

    try:
        login_result = wait_for_login(session, uid)
        web_login_vid, access_token = install_login_cookies(session, login_result)
        user_info, api_result = verify_credentials(
            session,
            web_login_vid,
            access_token,
        )
        renewal = verify_renewal(session)
    finally:
        if qr_path is not None:
            try:
                os.unlink(qr_path)
            except OSError:
                pass

    account_name = user_info.get("name")
    print("QR login protocol verified successfully.")
    print(f"Account name present: {isinstance(account_name, str) and bool(account_name)}")
    print(f"User VID present: {bool(web_login_vid)}")
    print(f"Access token present: {bool(access_token)}")
    print(f"Refresh token present: {bool(login_result.get('refreshToken'))}")
    print(f"Official API key present: {bool(api_result.get('apikey'))}")
    print(f"Renewal succ=1: {renewal['succ']}")
    print(f"Renewal Set-Cookie present: {renewal['set_cookie']}")
    print(f"Renewal x-wr-ticket present: {renewal['wr_ticket']}")
    print(f"Renewal x-wrpa-0 present: {renewal['wr_wrpa']}")
    print("No credentials were printed or saved.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        raise SystemExit(130)
    except (requests.RequestException, ProtocolError, ValueError) as exc:
        print(f"Verification failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
