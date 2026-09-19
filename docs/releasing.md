# Releasing / 发布

The release package contains only files needed by KOReader:

- `_meta.lua` and `main.lua`;
- `weread/` runtime modules;
- `fonts/`;
- `README.md`, `LICENSE`, and `NOTICE`.

Development-only directories such as `.github/`, `docs/`, `scripts/`, and
`spec/` are not shipped. The archive has a single top-level
`weread.koplugin/` directory, so users can extract it directly into KOReader's
`plugins/` directory.

## Pre-release validation / 发布前验收

Before the next and every subsequent release, complete the
[macOS simulator release checklist](macos-release-testing.md): run the existing
checks, test the candidate package in an isolated KOReader profile, execute all
core cases and applicable extended cases, and retain screenshots, logs, and a
result record. Complete the applicable Kindle checks as well. Do this before
pushing the release commit; a version bump on `main` can trigger publication.

从下一次发版开始，先执行 [macOS 模拟器发版前测试](macos-release-testing.md)，
再推送发布提交。核心用例和适用扩展项必须有实际结果；FAIL/BLOCKED 不能当作通过。
现有 PluginLoader CI 不代表这份 UI 清单已执行，macOS 通过也不代替适用的 Kindle
验证。代码或候选包变化后，按清单规定复测并更新证据。

## Local package / 本地打包

```bash
bash scripts/package_release.sh
```

The default output is `dist/weread.koplugin-vX.Y.Z.zip`, where `X.Y.Z` comes
from `_meta.lua`. A custom output path may be passed as the first argument.

## Manual GitHub package / 手动打包

Open **Actions → Release → Run workflow**. The optional `package_label` input
controls the filename:

- leave it empty to use the first eight characters of the selected commit ID;
- enter a label such as `preview-1` to create
  `weread.koplugin-preview-1.zip`.

A manual run validates the current version, builds the zip and SHA-256
checksum, and uploads them as two separate workflow artifacts retained for 14
days. It does not create a tag or GitHub Release.

## Automatic release / 自动发布

To publish a release:

1. Update `_meta.lua` and `main.lua` to the same new `X.Y.Z` version.
2. Add a non-empty `## [X.Y.Z]` section to `CHANGELOG.md`. Write only the
   curated content below that heading; the workflow adds the
   `## 新功能与改进` heading automatically.
3. Complete the pre-release validation above, then commit and push the change
   to `main`.
4. The normal `CI` and pinned KOReader integration workflows run.
5. After the KOReader integration succeeds, the `Release` workflow confirms
   that normal CI also passed for the same commit.
6. If `vX.Y.Z` does not already exist, it creates the package, checksum, tag,
   and GitHub Release.

Pushes that keep an existing version do not publish anything. Reusing an
existing release tag fails deliberately; bump to a new version instead.
Automatic packages use the versioned filename
`weread.koplugin-vX.Y.Z.zip`. The zip and its `.sha256` checksum are separate
workflow artifacts and separate GitHub Release assets.

The workflow extracts the matching version section from `CHANGELOG.md`, adds
the `## 新功能与改进` heading, and passes it to `gh release create --notes`.
GitHub prepends that text to the English notes generated from merged pull
requests. The generated part still includes **What's Changed**, **New
Contributors** when applicable, and a **Full Changelog** comparison link.
CI and the release workflow both fail if the current version has no non-empty
changelog section.
