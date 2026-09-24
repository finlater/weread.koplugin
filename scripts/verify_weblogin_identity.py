#!/usr/bin/env python3
"""Verify whether a per-device fingerprint gives WeRead sessions device identity.

Background
----------
A second QR login replaces the account's previous web session: the older
session then fails with ``-2012`` ("登录超时") and its ``/web/login/renewal``
returns ``-2013`` with an all-empty clearing ``Set-Cookie`` (upstream
finlater/weread.koplugin issue #158). Earlier phases tested a per-device
User-Agent and per-device identity variants; both were NEGATIVE. The last
untested lever is the official e-ink login chain: ink.qq.com uses
``/web/login/{getuid,getinfo,weblogin,session/init}`` with an ``fp`` parameter
and a 365-day ``wr_fp`` cookie, while the plugin flow
(``/api/auth/getLoginUid`` + ``getLoginInfo``) carries no device identity.
Phase 2 (2026-09-23) CONFIRMED the hypothesis: two sessions logged in through
this chain with different per-device ``fp`` coexisted (no mutual replacement).

Experiment
----------
1. Session A logs in through /web/login/* with ``fp_A = sha256(seed_a)``, then a
   baseline API probe. Session B repeats with ``fp_B``.
2. Kick detector: A's Web API is probed right after B's login.
3. If A survived: renew A -> probe A; renew B -> probe B; delayed A re-check.
   If A was replaced: renewal forensics on A report every Set-Cookie name and
   whether its value is empty (replacement credential set vs all-empty clearing).

Privacy
-------
No cookie, token, or API-key value is printed or saved. Only presence, type,
length, cookie *names* with emptiness, JSON field names, and non-secret status
fields (``succ``/``errCode``/``errMsg``) are reported. The uid appears only in
the scannable confirm URL. Temporary QR images are deleted after use.

Usage
-----
    python3 scripts/verify_weblogin_identity.py [--open-browser] \\
        [--seed-a SEED] [--seed-b SEED]

Both QR scans must be confirmed with the same account; under forty requests.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import random
import sys
import tempfile
import time
import webbrowser
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import quote

import requests


BASE_URL = "https://weread.qq.com"
SKILLS_PAGE_URL = f"{BASE_URL}/r/weread-skills"
LOGIN_UID_URL = f"{BASE_URL}/api/auth/getLoginUid"
LOGIN_INFO_URL = f"{BASE_URL}/api/auth/getLoginInfo"
WEB_GETUID_URL = f"{BASE_URL}/web/login/getuid"
WEB_GETINFO_URL = f"{BASE_URL}/web/login/getinfo"
WEB_WEBLOGIN_URL = f"{BASE_URL}/web/login/weblogin"
SESSION_INIT_URL = f"{BASE_URL}/web/login/session/init"
LEGACY_WEBLOGIN_URL = f"{BASE_URL}/wrwebsimplenjlogic/api/weblogin"
RENEWAL_URL = f"{BASE_URL}/web/login/renewal"
SHELF_API_URL = f"{BASE_URL}/web/shelf/sync?onlyBookid=1"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0"
)
RENEWAL_PAYLOAD: dict[str, Any] = {"rq": "%2Fweb%2Fbook%2Fread", "ql": False}
LOGIN_COOKIE_NAMES = ("wr_vid", "wr_skey", "wr_rt", "wr_ql")
UID_KEYS = ("uid", "loginUid", "userUid", "openid")
VID_KEYS = ("vid", "webLoginVid", "userVid", "user_vid", "openid", "wr_vid")
TOKEN_KEYS = ("accessToken", "access_token", "skey")
REFRESH_KEYS = ("refreshToken", "refresh_token", "rt")
DEFAULT_SEED_A, DEFAULT_SEED_B = "ko-identity-a", "ko-identity-b"
# An unscanned getinfo poll blocks ~55s, so a fixed poll count can expire before
# the user finishes scanning/OTP; poll on a wall-clock budget instead.
INK_LOGIN_BUDGET_SECONDS = 300


class ProtocolError(RuntimeError):
    """Raised when a login response cannot complete the flow."""


@dataclass(frozen=True, slots=True)
class DeviceIdentity:
    """Client-generated, non-secret per-device identity for one session."""

    fp: str
    device_id: str


@dataclass(slots=True)
class SessionOutcome:
    """Presence-only result of one login attempt."""

    label: str
    identity: DeviceIdentity
    mode: str
    login_ok: bool
    credential_source: str
    session: requests.Session


def derive_fp(seed: str) -> str:
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()


def derive_device_id(fp: str) -> str:
    return "eink" + str(int(fp[:12], 16) % 10**19).zfill(19)


def safe_json(response: requests.Response) -> Any:
    try:
        return response.json()
    except ValueError:
        return None


def field_names(data: Any) -> list[str]:
    """JSON field NAMES only; never values."""
    if isinstance(data, dict):
        return sorted(str(key) for key in data.keys())
    if isinstance(data, list):
        return [f"list[{len(data)}]"]
    return [type(data).__name__]


def error_and_logic(data: Any) -> tuple[Any, Any, str]:
    """Non-secret status fields; ``code`` is excluded (it is a login code)."""
    if not isinstance(data, dict):
        return None, None, ""
    return (data.get("errCode", data.get("errcode")),
            data.get("errMsg") or data.get("errmsg"),
            str(data.get("logicCode") or data.get("logic_code") or ""))


def set_cookie_values(response: requests.Response) -> dict[str, str]:
    """Parse raw Set-Cookie headers into name->value (kept in memory only)."""
    values: dict[str, str] = {}
    raw = getattr(response, "raw", None)
    lines: list[str] = []
    if raw is not None and hasattr(raw.headers, "getlist"):
        try:
            lines = raw.headers.getlist("Set-Cookie")
        except Exception:  # noqa: BLE001 - header containers differ by version
            lines = []
    if not lines:
        joined = response.headers.get("Set-Cookie")
        lines = [joined] if joined else []
    for line in lines:
        first = line.split(";", 1)[0]
        if "=" in first:
            name, value = first.split("=", 1)
            values[name.strip()] = value.strip()
    return values


def describe_cookies(cookies: dict[str, str]) -> str:
    """Names with emptiness only; never values."""
    if not cookies:
        return "(none)"
    return ", ".join(f"{n}({'empty' if v == '' else 'set'})" for n, v in sorted(cookies.items()))


def scalar_text(value: Any) -> str:
    if isinstance(value, bool):
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float)):
        return str(value)
    return ""


def first_value(data: Any, keys: tuple[str, ...]) -> str:
    if isinstance(data, dict):
        for key in keys:
            text = scalar_text(data.get(key))
            if text:
                return text
    return ""


def extract_uid(data: Any) -> str:
    uid = first_value(data, UID_KEYS)
    if uid:
        return uid
    if isinstance(data, dict):
        for key, value in data.items():
            if isinstance(key, str) and "uid" in key.lower():
                text = scalar_text(value)
                if text:
                    return text
    return ""


def response_credentials(response: requests.Response) -> dict[str, str]:
    values = set_cookie_values(response)
    return {name: values[name] for name in LOGIN_COOKIE_NAMES if values.get(name)}


def credentials_from(data: Any) -> dict[str, str]:
    """Build flat login cookies from a response carrying a vid and a token."""
    vid, token = first_value(data, VID_KEYS), first_value(data, TOKEN_KEYS)
    if not vid or not token:
        return {}
    credentials = {"wr_vid": vid, "wr_skey": token, "wr_ql": "0"}
    refresh = first_value(data, REFRESH_KEYS)
    if refresh:
        credentials["wr_rt"] = quote(refresh, safe="")
    return credentials


def send_json(session: requests.Session, method: str, url: str, *, timeout: int, stage: str,
              headers: dict[str, str] | None = None, payload: dict[str, Any] | None = None,
              params: dict[str, str] | None = None) -> tuple[requests.Response | None, Any]:
    try:
        response = session.request(method, url, json=payload, headers=headers,
                                   params=params, timeout=timeout)
    except requests.RequestException as exc:
        print(f"[{stage}] transport error: {exc}", flush=True)
        return None, None
    data = safe_json(response)
    print(
        f"[{stage}] HTTP {response.status_code}; "
        f"ct={response.headers.get('content-type', 'unknown')}; "
        f"Set-Cookie={sorted(set_cookie_values(response))}; "
        f"fields={field_names(data)}",
        flush=True,
    )
    return response, data


def open_qr_image(confirm_url: str) -> Path:
    try:
        import qrcode
    except ImportError as exc:
        raise ProtocolError(
            "Opening a local QR image requires `pip install qrcode[pil]`"
        ) from exc
    handle = tempfile.NamedTemporaryFile(prefix="weread-qr-", suffix=".png", delete=False)
    handle.close()
    path = Path(handle.name)
    qrcode.make(confirm_url).save(path)
    webbrowser.open(path.as_uri())
    return path


def ink_getuid(session: requests.Session, label: str) -> str:
    stage = f"{label} getuid(ink)"
    response, data = send_json(session, "POST", WEB_GETUID_URL, timeout=20, stage=stage,
                               headers={"Referer": f"{BASE_URL}/"}, payload={})
    if response is None or not response.ok:
        print(f"[{stage}] unavailable; fields={field_names(data)}", flush=True)
        return ""
    uid = extract_uid(data)
    if not uid:
        print(f"[{stage}] no uid field; fields={field_names(data)}", flush=True)
    return uid


def cookie_getuid(session: requests.Session, label: str) -> str:
    stage = f"{label} getuid(cookie)"
    response, data = send_json(session, "GET", LOGIN_UID_URL, timeout=20, stage=stage,
                               headers={"Referer": SKILLS_PAGE_URL})
    if response is None or not response.ok:
        print(f"[{stage}] unavailable; fields={field_names(data)}", flush=True)
        return ""
    uid = extract_uid(data)
    if not uid:
        print(f"[{stage}] no uid field; fields={field_names(data)}", flush=True)
    return uid


def prompt_otp() -> str:
    for _attempt in range(3):
        try:
            otp = input("Enter the four-digit code shown on your phone: ").strip()
        except EOFError:
            return ""
        if len(otp) == 4 and otp.isdigit():
            return otp
        print("The verification code must contain four digits.")
    return ""


def logic_kind(logic: str) -> str:
    upper = logic.upper()
    if "NEED_OTP" in upper:
        return "need_otp"
    if "OTP_NOT_MATCH" in upper or "MISMATCH" in upper:
        return "otp_mismatch"
    if "EXPIRED" in upper:
        return "expired"
    if "TIMEOUT" in upper:
        return "timeout"
    if "CANCEL" in upper or "FAIL" in upper:
        return "ended"
    return "waiting"


def scan_value(data: Any) -> Any:
    return data.get("scan") if isinstance(data, dict) else None


def credential_field_names(data: Any) -> list[str]:
    if not isinstance(data, dict):
        return []
    keys = VID_KEYS + TOKEN_KEYS + REFRESH_KEYS + ("code", "sessionKey")
    return [key for key in keys if data.get(key) not in (None, "")]


def ink_login_success(data: Any) -> bool:
    if not isinstance(data, dict):
        return False
    if data.get("succeed") is True:
        return True
    if str(data.get("logicCode") or "").upper() in {"LOGIN_SUCCESS", "SUCCESS"}:
        return True
    vid = first_value(data, VID_KEYS)
    token = first_value(data, TOKEN_KEYS)
    return bool(vid) and (bool(token) or data.get("code") is not None)


def wait_for_ink_login(session: requests.Session, uid: str, label: str) -> dict[str, Any] | None:
    """Poll /web/login/getinfo on a wall-clock budget; never raises."""
    stage, otp = f"{label} getinfo", ""
    started = time.monotonic()
    iteration = 0
    while time.monotonic() - started < INK_LOGIN_BUDGET_SECONDS:
        iteration += 1
        payload: dict[str, Any] = {"uid": uid}
        if otp:
            payload["otp"] = otp
        poll_started = time.monotonic()
        response, data = send_json(session, "POST", WEB_GETINFO_URL, timeout=70, stage=stage,
                                   headers={"Referer": f"{BASE_URL}/"}, payload=payload)
        elapsed = time.monotonic() - started
        poll_seconds = time.monotonic() - poll_started
        if response is None:
            return None
        scan = scan_value(data)
        if ink_login_success(data):
            print(f"[{stage}] success signal (scan={scan}); credential-ish fields: "
                  f"{credential_field_names(data) or '(none)'}", flush=True)
            print(f"[{stage}] credential payload detected "
                  f"(fields: {credential_field_names(data) or '(none)'})", flush=True)
            return data
        logic = error_and_logic(data)[2]
        kind = logic_kind(logic)
        print(f"[{stage}] iteration={iteration}; elapsed={elapsed:.1f}s; "
              f"state={logic or kind} (scan={scan}); fields={field_names(data)}", flush=True)
        if kind in {"need_otp", "otp_mismatch"}:
            if kind == "otp_mismatch":
                print("The verification code did not match.", flush=True)
            otp = prompt_otp()
            if not otp:
                return None
        elif kind in {"ended", "expired", "timeout"}:
            print(f"[{stage}] login ended: {logic or kind} (scan={scan})", flush=True)
            return None
        if poll_seconds < 2:
            time.sleep(1)
    print(f"[{stage}] login budget of {INK_LOGIN_BUDGET_SECONDS}s exhausted without "
          f"confirmation", flush=True)
    return None


def weblogin_variants(vid: str, skey: str, code: Any, identity: DeviceIdentity, pf: int
                      ) -> list[tuple[str, str, dict[str, Any], dict[str, str] | None]]:
    base = {"vid": vid, "skey": skey, "code": code, "fp": identity.fp, "isAutoLogout": 0, "pf": pf}
    rm_style = {**base, "deviceId": identity.device_id, "deviceType": 3,
                "deviceName": "KOReader", "fingerprint": identity.fp}
    legacy = {"vid": vid, "skey": skey, "code": code, "isAutoLogout": 0, "pf": 2,
              "cgiKey": random.randint(100, 999), "fp": identity.fp}
    return [
        ("V1 ink-style", WEB_WEBLOGIN_URL, base, None),
        ("V2 rM-style", WEB_WEBLOGIN_URL, rm_style, None),
        ("V3 legacy", LEGACY_WEBLOGIN_URL, legacy, {"platform": "desktop"}),
    ]


def weblogin_yielded(response: requests.Response, data: Any) -> bool:
    credentials = response_credentials(response)
    if credentials.get("wr_skey") or credentials.get("wr_vid"):
        return True
    if isinstance(data, dict):
        session_key = data.get("accessToken") or data.get("sessionKey")
        return bool(session_key) and bool(first_value(data, VID_KEYS))
    return False


def assemble_ink_credentials(cookies: dict[str, str], init_data: Any, getinfo: Any
                             ) -> tuple[dict[str, str], str]:
    """Priority: weblogin Set-Cookie, then session/init fields, then getinfo fields."""
    if cookies.get("wr_skey") and cookies.get("wr_vid"):
        merged = dict(cookies)
        merged.setdefault("wr_ql", "0")
        return merged, "weblogin Set-Cookie"
    for data, origin in ((init_data, "session/init fields"), (getinfo, "getinfo fields")):
        credentials = credentials_from(data)
        if credentials:
            return credentials, origin
    return {}, "none"


def run_weblogin_chain(session: requests.Session, label: str, getinfo: dict[str, Any],
                       identity: DeviceIdentity) -> tuple[dict[str, str], str]:
    """Attempt /weblogin variants in order; never raises; never prints values."""
    vid, skey = first_value(getinfo, VID_KEYS), first_value(getinfo, TOKEN_KEYS)
    code, raw_pf = getinfo.get("code"), getinfo.get("pf")
    pf = raw_pf if isinstance(raw_pf, int) else 2
    print(f"[{label}] getinfo fields: {field_names(getinfo)}", flush=True)
    if not vid or not skey or code is None:
        print(f"[{label}] getinfo lacks vid/skey/code; skipping /weblogin", flush=True)
        credentials = credentials_from(getinfo)
        return (credentials, "getinfo fields") if credentials else ({}, "none")
    collected: dict[str, str] = {}
    access_token = refresh_token = ""
    for name, url, payload, params in weblogin_variants(vid, skey, code, identity, pf):
        stage = f"{label} {name}"
        response, data = send_json(session, "POST", url, timeout=20, stage=stage,
                                   headers={"Origin": BASE_URL, "Referer": f"{BASE_URL}/"},
                                   payload=payload, params=params)
        if response is None:
            time.sleep(1)
            continue
        err_code, err_msg, _logic = error_and_logic(data)
        print(f"[{stage}] errCode={err_code}; errMsg={err_msg!r}; fields={field_names(data)}",
              flush=True)
        collected.update(response_credentials(response))
        if response.ok and weblogin_yielded(response, data):
            access_token, refresh_token = first_value(data, TOKEN_KEYS), first_value(data, REFRESH_KEYS)
            print(f"[{stage}] yielded credentials; stopping variants", flush=True)
            break
        time.sleep(1)
    init_data: Any = None
    token = access_token or collected.get("wr_skey", "")
    if token:
        stage = f"{label} session/init"
        response, data = send_json(session, "POST", SESSION_INIT_URL, timeout=20, stage=stage,
                                   headers={"Origin": BASE_URL, "Referer": f"{BASE_URL}/"},
                                   payload={"vid": vid, "skey": token, "pf": pf, "ql": 0,
                                            "rt": refresh_token or collected.get("wr_rt", "")})
        if response is not None:
            err_code, err_msg, _logic = error_and_logic(data)
            print(f"[{stage}] errCode={err_code}; errMsg={err_msg!r}; fields={field_names(data)}",
                  flush=True)
            collected.update(response_credentials(response))
            init_data = data
        time.sleep(1)
    return assemble_ink_credentials(collected, init_data, getinfo)


def poll_cookie_login(session: requests.Session, uid: str, otp: str = "") -> dict[str, Any]:
    # The empty form is intentionally `&otp`, not `&otp=`.
    url = f"{LOGIN_INFO_URL}?uid={quote(uid, safe='')}&otp"
    if otp:
        url += f"={quote(otp, safe='')}"
    response, data = send_json(session, "GET", url, timeout=70, stage="getLoginInfo",
                               headers={"Referer": SKILLS_PAGE_URL})
    if response is None:
        raise ProtocolError("getLoginInfo transport error")
    if not response.ok:
        raise ProtocolError(f"getLoginInfo returned HTTP {response.status_code}")
    if not isinstance(data, dict):
        raise ProtocolError(f"getLoginInfo JSON fields: {field_names(data)}")
    return data


def wait_for_cookie_login(session: requests.Session, uid: str) -> dict[str, Any]:
    """Classic cookie-login baseline used for the coexistence comparison."""
    result = poll_cookie_login(session, uid)
    while result.get("succeed") is not True:
        logic_code = str(result.get("logicCode") or "")
        print(f"Login state: {logic_code or 'UNKNOWN'}", flush=True)
        if logic_code == "NEED_OTP":
            otp = input("Enter the four-digit code shown on your phone: ").strip()
            if len(otp) != 4 or not otp.isdigit():
                print("The verification code must contain four digits.")
                continue
            result = poll_cookie_login(session, uid, otp)
            continue
        if logic_code == "OTP_NOT_MATCH":
            print("The verification code did not match.")
            result = {"logicCode": "NEED_OTP"}
            continue
        raise ProtocolError(f"Login stopped with {logic_code or 'unknown state'}")
    return result


def login_session(label: str, *, identity: DeviceIdentity, open_browser: bool) -> SessionOutcome:
    """Run the per-session login chain; never raises out of a step."""
    session = requests.Session()
    session.headers.update({"User-Agent": USER_AGENT,
                            "Accept": "application/json, text/plain, */*"})
    print(f"--- Session {label}: /web/login/* identity experiment (fp from seed) ---\n"
          f"[{label}] fp (client-generated, non-secret): {identity.fp}\n"
          f"[{label}] deviceId (derived, non-secret): {identity.device_id}", flush=True)
    try:
        response = session.get(SKILLS_PAGE_URL, headers={"Referer": f"{BASE_URL}/"}, timeout=20)
        print(f"[{label} skills] HTTP {response.status_code}; redirects={len(response.history)}; "
              f"Set-Cookie={bool(response.headers.get('Set-Cookie'))}", flush=True)
    except requests.RequestException as exc:
        print(f"[{label} skills] transport error: {exc}", flush=True)

    mode = "ink"
    uid = ink_getuid(session, label)
    if not uid:
        print(f"[{label}] ink getuid unavailable; falling back to /api/auth/getLoginUid", flush=True)
        uid = cookie_getuid(session, label)
        mode = "cookie-fallback"
    if not uid:
        print(f"[{label}] could not obtain a login uid; skipping login", flush=True)
        return SessionOutcome(label, identity, mode, False, "none", session)

    confirm_url = f"{BASE_URL}/web/confirm?pf=2&uid={quote(uid, safe='')}"
    print(f"[{label}] Scan and confirm this URL:\n{confirm_url}", flush=True)
    qr_path = None
    if open_browser:
        try:
            qr_path = open_qr_image(confirm_url)
        except ProtocolError as exc:
            print(f"[{label}] QR image unavailable: {exc}", flush=True)

    credentials: dict[str, str] = {}
    credential_source = "none"
    try:
        if mode == "ink":
            getinfo = wait_for_ink_login(session, uid, label)
            if getinfo is None:
                print(f"[{label}] ink getinfo did not confirm; falling back to the cookie flow",
                      flush=True)
                mode = "cookie-fallback"
            else:
                credentials, credential_source = run_weblogin_chain(session, label, getinfo, identity)
        if not credentials:
            print(f"[{label}] completing login through /api/auth/getLoginInfo", flush=True)
            try:
                login_result = wait_for_cookie_login(session, uid)
            except (ProtocolError, requests.RequestException) as exc:
                print(f"[{label}] cookie login flow failed: {exc}", flush=True)
                login_result = None
            if login_result is not None:
                credentials = credentials_from(login_result)
                if credentials:
                    credential_source, mode = "getLoginInfo (cookie)", "cookie-fallback"
    finally:
        if qr_path is not None:
            try:
                os.unlink(qr_path)
            except OSError:
                pass

    for name, value in credentials.items():
        if value:
            session.cookies.set(name, value, domain=".weread.qq.com", path="/")
    session.cookies.set("wr_fp", identity.fp, domain=".weread.qq.com", path="/")
    cookies = sorted({cookie.name for cookie in session.cookies})
    login_ok = bool(credentials.get("wr_skey") and credentials.get("wr_vid"))
    print(f"[{label}] session cookies: {', '.join(cookies)}\n"
          f"[{label}] login ok: {login_ok}; mode={mode}; source={credential_source}", flush=True)
    return SessionOutcome(label, identity, mode, login_ok, credential_source, session)


def probe_api(session: requests.Session, stage: str) -> dict[str, Any]:
    """Probe Web API access and classify the non-secret status fields."""
    try:
        response = session.get(SHELF_API_URL, headers={"Referer": f"{BASE_URL}/"}, timeout=20)
    except requests.RequestException as exc:
        print(f"[{stage}] transport error: {exc}", flush=True)
        return {"status": None, "code": None, "msg": None, "transport_error": True}
    data = safe_json(response)
    code = message = None
    shape = field_names(data) if data is not None else "non-JSON body"
    if isinstance(data, dict):
        code = data.get("errCode", data.get("errcode", data.get("code")))
        message = data.get("errMsg") or data.get("errmsg")
    print(f"[{stage}] HTTP {response.status_code}; errCode={code}; errMsg={message!r}; "
          f"fields={shape}", flush=True)
    return {"status": response.status_code, "code": code, "msg": message}


def renewal_probe(session: requests.Session, stage: str, payload: dict[str, Any]) -> dict[str, Any]:
    """Call renewal and report presence-only diagnostics, including emptiness."""
    try:
        response = session.post(RENEWAL_URL, json=payload, timeout=20,
                                headers={"Origin": BASE_URL, "Referer": f"{BASE_URL}/"})
    except requests.RequestException as exc:
        print(f"[{stage}] transport error: {exc}", flush=True)
        return {"transport_error": True, "set_cookie_names": [], "body_keys": []}
    data = safe_json(response)
    succ = code = message = None
    body_keys: list[str] = []
    if isinstance(data, dict):
        body_keys = field_names(data)
        raw_succ = data.get("succ")
        succ = raw_succ is True or str(raw_succ) == "1"
        code = data.get("errCode", data.get("errcode"))
        message = data.get("errMsg") or data.get("errmsg")
    returned = set_cookie_values(response)
    login_returned = {n: v for n, v in returned.items() if n in LOGIN_COOKIE_NAMES}
    all_login_empty = bool(login_returned) and all(v == "" for v in login_returned.values())
    has_nonempty = any(v != "" for v in login_returned.values())
    x_wr_ticket = bool(response.headers.get("x-wr-ticket"))
    x_wrpa_0 = bool(response.headers.get("x-wrpa-0"))
    print(f"[{stage}] HTTP {response.status_code}; succ={succ}; errCode={code}; errMsg={message!r}\n"
          f"[{stage}] Set-Cookie: {describe_cookies(returned)}\n"
          f"[{stage}] body keys: {body_keys}; x-wr-ticket={x_wr_ticket}; x-wrpa-0={x_wrpa_0}",
          flush=True)
    return {"status": response.status_code, "succ": bool(succ), "code": code, "msg": message,
            "body_keys": body_keys, "set_cookie_names": sorted(returned),
            "all_login_empty": all_login_empty, "has_nonempty": has_nonempty,
            "x_wr_ticket": x_wr_ticket, "x_wrpa_0": x_wrpa_0}


def api_access_ok(result: dict[str, Any] | None) -> bool:
    if not result or result.get("transport_error"):
        return False
    return result.get("status") == 200 and result.get("code") in (None, 0)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--open-browser", action="store_true",
                        help="Generate a local QR image and open it in the default browser.")
    parser.add_argument("--seed-a", default=DEFAULT_SEED_A,
                        help="Seed for session A's fingerprint (default: %(default)s).")
    parser.add_argument("--seed-b", default=DEFAULT_SEED_B,
                        help="Seed for session B's fingerprint (default: %(default)s).")
    return parser.parse_args()


def coexistence_checks(a: SessionOutcome, b: SessionOutcome) -> tuple[dict[str, Any], ...]:
    print("\n[A] coexistence check: renew A, then probe A:", flush=True)
    a_ren = renewal_probe(a.session, "A renewal after B login", RENEWAL_PAYLOAD)
    time.sleep(1)
    a_api = probe_api(a.session, "A API after its post-B renewal")
    print("\n[B] coexistence check: renew B, then probe B:", flush=True)
    b_ren = renewal_probe(b.session, "B renewal", RENEWAL_PAYLOAD)
    time.sleep(1)
    b_api = probe_api(b.session, "B API after its renewal")
    print("\n[A] delayed re-check (was coexistence sustained?):", flush=True)
    time.sleep(1)
    return a_ren, a_api, b_ren, b_api, probe_api(a.session, "A delayed API re-check")


def print_interpretation(a: SessionOutcome, b: SessionOutcome, survived: bool,
                         a_delay: dict[str, Any] | None, forensics: dict[str, Any] | None) -> None:
    print("Interpretation:")
    if not (a.login_ok and b.login_ok):
        print("- NOTE: a login lacked credentials, so the kick result is inconclusive; re-run.")
    if survived:
        print("- Session A SURVIVED B's login: a per-device fp in the weblogin flow prevented")
        print("  replacement in this run. => Per-device fp in /web/login/* is a candidate")
        print("  isolation lever. Next step: port the /web/login/{getuid,getinfo,weblogin,")
        print("  session/init} chain plus the fp/wr_fp identity into the plugin")
        print("  (weread/lib/device_identity.lua), then re-verify on both real devices.")
        if not api_access_ok(a_delay):
            print("  Caveat: A's delayed re-check failed; coexistence was not fully sustained.")
    elif forensics is not None and forensics.get("has_nonempty"):
        print("- Session A was REPLACED, but its failed renewal returned NON-EMPTY replacement")
        print("  credentials: silent recovery may be possible in the weblogin session family.")
        print("  Next step: capture the exact replacement cookie/field names and ordering, then")
        print("  implement adoption (merge Set-Cookie, empty values delete) with a generation guard.")
    else:
        print("- Session A was REPLACED and its failed renewal emptied all login cookies (or")
        print("  returned no login cookies): a clearing/logout response - a dead end for device")
        print("  identity here. Next step: close the avenue; keep the fallback design (L2/L3).")


def main() -> int:
    args = parse_args()
    fp_a, fp_b = derive_fp(args.seed_a), derive_fp(args.seed_b)
    identity_a = DeviceIdentity(fp_a, derive_device_id(fp_a))
    identity_b = DeviceIdentity(fp_b, derive_device_id(fp_b))

    print("This experiment performs TWO QR logins with the SAME WeRead account.")
    print("Each session uses a DIFFERENT per-device fp through the /web/login/* chain.")
    print(f"seed A: {args.seed_a}; seed B: {args.seed_b}; fp differ: {fp_a != fp_b}")
    print("Keep the request volume low and interrupt with Ctrl+C at any time.\n")

    outcome_a = login_session("A", identity=identity_a, open_browser=args.open_browser)
    print("\n[A] baseline Web API probe (control, no pre-B renewal):", flush=True)
    a_baseline_api = probe_api(outcome_a.session, "A baseline API")
    time.sleep(1)

    print("\n--- Now scan AGAIN with the same account and the DIFFERENT fp_B ---\n", flush=True)
    outcome_b = login_session("B", identity=identity_b, open_browser=args.open_browser)
    print("\n[B] sanity Web API probe:", flush=True)
    b_sanity_api = probe_api(outcome_b.session, "B sanity API")
    time.sleep(1)

    print("\n[A] kick detector: probing A right after B logged in:", flush=True)
    a_after_api = probe_api(outcome_a.session, "A after B login (kick detector)")
    survived = api_access_ok(a_after_api)

    a_ren = a_api = b_ren = b_api = a_delay = a_forensics = None
    if survived:
        a_ren, a_api, b_ren, b_api, a_delay = coexistence_checks(outcome_a, outcome_b)
    else:
        print("\n[A] A did not survive; renewal forensics on A "
              "(replacement key vs clearing response):", flush=True)
        a_forensics = renewal_probe(outcome_a.session, "A replacement renewal forensics",
                                    RENEWAL_PAYLOAD)
        time.sleep(1)

    print("\n================ Summary ================")
    for label, outcome in (("A", outcome_a), ("B", outcome_b)):
        print(f"{label} mode: {outcome.mode}; fp={outcome.identity.fp}; "
              f"deviceId={outcome.identity.device_id}; login ok: {outcome.login_ok}; "
              f"credential source: {outcome.credential_source}")
    print(f"A baseline API ok: {api_access_ok(a_baseline_api)}")
    print(f"B sanity API ok: {api_access_ok(b_sanity_api)}")
    print(f"A survived B login: {survived} (API errCode={a_after_api.get('code')})")
    if survived:
        print(f"A renewal after B login: succ={a_ren.get('succ')}; errCode={a_ren.get('code')}; "
              f"Set-Cookie={a_ren.get('set_cookie_names')}")
        print(f"A API ok after its post-B renewal: {api_access_ok(a_api)}")
        print(f"B renewal: succ={b_ren.get('succ')}; errCode={b_ren.get('code')}; "
              f"Set-Cookie={b_ren.get('set_cookie_names')}")
        print(f"B API ok after its renewal: {api_access_ok(b_api)}")
        print(f"A API ok on delayed re-check: {api_access_ok(a_delay)} "
              f"(errCode={a_delay.get('code')})")
    else:
        print(f"A replacement renewal: succ={a_forensics.get('succ')}; "
              f"errCode={a_forensics.get('code')}; body keys={a_forensics.get('body_keys')}")
        print(f"A replacement renewal x-wr-ticket={a_forensics.get('x_wr_ticket')}; "
              f"x-wrpa-0={a_forensics.get('x_wrpa_0')}")
        print(f"failed renewal emptied all login cookies: {a_forensics.get('all_login_empty')}")
    print("=========================================\n")
    print_interpretation(outcome_a, outcome_b, survived, a_delay, a_forensics)
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
