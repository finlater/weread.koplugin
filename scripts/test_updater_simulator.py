#!/usr/bin/env python3
"""Prepare an isolated update fixture and exercise the real KOReader updater."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import zipfile

REPO = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--koreader", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--width", type=int, default=600)
    parser.add_argument("--height", type=int, default=800)
    parser.add_argument("--dpi", type=int, default=167)
    parser.add_argument("--interactive", action="store_true", help="prepare a macOS app for window testing")
    args = parser.parse_args()
    runtime, root = args.koreader.resolve(), args.run_dir.resolve()
    if not (runtime / "luajit").is_file() or not (runtime / "reader.lua").is_file():
        parser.error("--koreader must be a built KOReader runtime")
    root.mkdir(parents=True, exist_ok=False)
    for directory in ("profile/settings", "profile/plugins", "fixtures", "evidence"):
        (root / directory).mkdir(parents=True, exist_ok=True)
    candidate = root / "candidate.zip"
    subprocess.run(["bash", str(REPO / "scripts/package_release.sh"), str(candidate)], check=True)
    name = "weread.koplugin-v9999.9.1.zip"
    with zipfile.ZipFile(candidate) as source:
        source.extractall(root / "profile/plugins")
        with zipfile.ZipFile(root / "fixtures" / name, "w", zipfile.ZIP_DEFLATED) as target:
            for entry in source.infolist():
                data = source.read(entry.filename)
                if entry.filename in ("weread.koplugin/_meta.lua", "weread.koplugin/main.lua"):
                    data = re.sub(rb'version\s*=\s*"[0-9.]+"', b'version = "9999.9.1"', data, count=1)
                target.writestr(entry.filename, data)
    digest = hashlib.sha256((root / "fixtures" / name).read_bytes()).hexdigest()
    (root / "fixtures" / (name + ".sha256")).write_text(digest + "  " + name + "\n")
    notes = "更新内容（模拟数据）\n\n" + "".join(
        f"{index}. 优化更新提醒与长说明阅读体验，正文可上下滑动，底部操作按钮始终可用。\n\n"
        for index in range(1, 46)
    ) + "最后一条更新：感谢使用微信读书插件。"
    metadata = dict(tag_name="v9999.9.1", body=notes, assets=[dict(
        name=asset,
        browser_download_url="https://github.com/finlater/weread.koplugin/releases/download/v9999.9.1/" + asset,
        size=(root / "fixtures" / asset).stat().st_size,
    ) for asset in (name, name + ".sha256")])
    (root / "fixtures/release.json").write_text(json.dumps(metadata, ensure_ascii=False))
    (root / "profile/settings.reader.lua").write_text('return { language = "zh_CN", color_rendering = false }\n')
    environment = dict(KO_HOME=str(root / "profile"), EMULATE_READER="1",
                       EMULATE_READER_W=str(args.width), EMULATE_READER_H=str(args.height),
                       EMULATE_READER_DPI=str(args.dpi), KO_DYLD_PREFIX=str(runtime))
    script = REPO / "spec/koreader/weread_updater_smoke.lua"
    if args.interactive:
        environment["WEREAD_UPDATER_INTERACTIVE"] = "1"
        app = root / "WeReadUpdateTest.app/Contents"
        (app / "MacOS").mkdir(parents=True)
        launcher = app / "MacOS/WeReadUpdateTest"
        launcher.write_text("#!/bin/sh\nset -eu\n" + "\n".join(
            f"export {key}={shlex.quote(value)}" for key, value in environment.items()
        ) + f"\ncd {shlex.quote(str(runtime))}\nexec ./luajit {shlex.quote(str(script))} "
            f"> {shlex.quote(str(root / 'evidence/window.log'))} 2>&1\n")
        launcher.chmod(0o755)
        (app / "Info.plist").write_bytes(plistlib.dumps(dict(
            CFBundleExecutable="WeReadUpdateTest", CFBundleIdentifier="local.weread.updatertest",
            CFBundleName="WeRead Update Test", CFBundlePackageType="APPL", NSHighResolutionCapable=True,
        )))
        print(app.parent)
    else:
        with (root / "evidence/smoke.log").open("w") as log:
            result = subprocess.run(["./luajit", str(script)], cwd=runtime,
                                    env={**os.environ, **environment}, stdout=log, stderr=subprocess.STDOUT)
        print((root / "evidence/smoke.log").read_text())
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
