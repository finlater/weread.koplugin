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

1. Update `_meta.lua` to a new `X.Y.Z` version.
2. Commit and push the change to `main`.
3. The normal `CI` and pinned KOReader integration workflows run.
4. After the KOReader integration succeeds, the `Release` workflow confirms
   that normal CI also passed for the same commit.
5. If `vX.Y.Z` does not already exist, it creates the package, checksum, tag,
   and GitHub Release.

Pushes that keep an existing version do not publish anything. Reusing an
existing release tag fails deliberately; bump to a new version instead.
Automatic packages use the versioned filename
`weread.koplugin-vX.Y.Z.zip`. The zip and its `.sha256` checksum are separate
workflow artifacts and separate GitHub Release assets.

GitHub automatically generates the English release notes from merged pull
requests since the previous tag. The generated body includes **What's
Changed**, **New Contributors** when applicable, and a **Full Changelog**
comparison link. After publication, maintainers can edit the Release and add
the Chinese summary above the generated English notes.
