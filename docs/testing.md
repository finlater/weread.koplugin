# Testing / 测试

The project uses three test layers. None of them contacts a real WeRead
account, and fixtures must not contain API keys, cookies, account identifiers,
private notes, or book content.

项目使用三层测试。测试不得访问真实微信读书账号；fixture 中不得包含 API key、Cookie、
账号标识、私人笔记或书籍内容。

## 1. Fast checks / 快速检查

Run these before every PR:

```bash
bash scripts/run_lua_specs.sh
bash scripts/check_lua_namespace.sh
luacheck main.lua _meta.lua weread spec
```

`run_lua_specs.sh` executes every top-level `spec/*_spec.lua` with LuaJIT.
These standalone tests stub KOReader services and cover pure logic, service
composition, state machines, migration behavior, and regressions.

`plugin_load_spec.lua` is the entry-point smoke test. It loads the real
`main.lua`, initializes the service graph with deterministic fakes, composes
the feature mixins, and verifies that legacy `lib.*` / `ui.*` module keys are
not touched.

`check_lua_namespace.sh` enforces the project module layout:

- non-UI modules belong in `weread/lib/`;
- UI modules belong in `weread/ui/`;
- project modules use `weread.lib.*` or `weread.ui.*`;
- root-level project `lib/` and `ui/` directories are forbidden.

KOReader-owned imports such as `require("ui/widget/menu")` remain valid.

## 2. Unit and component specs / 单元与组件测试

Add or update a regression test whenever behavior changes. Prefer dependency
injection and `package.preload` fakes over live network or UI automation.

High-risk areas that require focused coverage:

- HTTP redirect, timeout, cookie, and credential boundaries in
  `weread/lib/client.lua`;
- settings, authentication schema migrations, and split book storage;
- UTF-8 content decoding, HTML transformation, underlines, and thoughts;
- downloader cancellation, retry, completion callbacks, and standby guards;
- progress mapping and upload/download conflict decisions.

Every top-level spec must exit non-zero on failure and be deterministic when
run independently.

## 3. KOReader integration / KOReader 集成测试

The integration spec uses KOReader's own Busted environment,
`commonrequire.lua`, and real `PluginLoader`. It verifies discovery and loading
against the pinned KOReader commit without initializing an account or making a
WeRead request.

The repository includes a scheduled/manual GitHub Actions workflow named
`KOReader integration`. It is separate from normal PR checks because building
KOReader is comparatively expensive. The workflow runs on `ubuntu-latest`
inside KOReader's official `koreader/kobase:1.0.0-22.04` build image, matching
the project's Linux CI environment without installing host-specific packages.

To run it locally:

```bash
git clone https://github.com/koreader/koreader.git /path/to/koreader
git -C /path/to/koreader checkout 1e2fa5f1239028ab4b37acae833cdc86a71e5258
KOREADER_DIR=/path/to/koreader bash scripts/run_koreader_integration.sh
```

KOReader's test launcher requires Bash 4 or newer. The Bash 3.2 bundled with
macOS is not sufficient; install Homebrew Bash and ensure `bash` resolves to
that version before running the script.

The runner temporarily links this plugin into KOReader's `plugins/` directory,
copies the integration spec into KOReader's test tree, runs only that Busted
file, and removes both temporary entries on exit. It refuses to overwrite an
existing plugin or spec.

When updating the pinned KOReader commit, update all three locations together:

- `scripts/run_koreader_integration.sh`;
- `.github/workflows/koreader-integration.yml`;
- this document.
