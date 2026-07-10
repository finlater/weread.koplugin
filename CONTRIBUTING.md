# Contributing / 贡献指南

Thanks for your interest in WeRead KOReader Plugin.

感谢你愿意参与 WeRead KOReader Plugin。为了让 issue 和 PR 更容易被处理，请遵循下面的规则。

## Issues / 提交 Issue

Before opening an issue, please search existing issues and read the README first.

提交 issue 前，请先搜索已有 issue，并阅读 README。

### Bug reports / Bug 反馈

Bug reports must include:

- Clear reproduction steps, or screenshots/recording that clearly show how the problem happens.
- KOReader logs.
- Plugin version, such as release version, download date, or commit hash.
- KOReader version.
- Device model and OS.
- Expected behavior and actual behavior.

Bug 反馈必须包含：

- 清晰的复现步骤，或能清楚展示问题如何发生的截图/录屏。
- KOReader 日志。
- 插件版本号，例如 release 版本、下载时间或 commit hash。
- KOReader 版本号。
- 设备型号和系统。
- 期望行为和实际行为。

KOReader logs are usually stored as `crash.log` inside the KOReader directory:

- Kindle: `koreader/crash.log`
- Kobo: `.adds/koreader/crash.log`
- PocketBook: `applications/koreader/crash.log`
- Android: use `Menu -> Help -> Bug Report` in KOReader to export logs

KOReader 日志通常是 KOReader 目录下的 `crash.log`：

- Kindle: `koreader/crash.log`
- Kobo: `.adds/koreader/crash.log`
- PocketBook: `applications/koreader/crash.log`
- Android: 在 KOReader 中打开 `菜单 -> 帮助 -> Bug Report` 导出日志

If the issue only happens with a specific book, you may optionally provide:

- WeRead book link.
- Imported book format and details.
- A source book file, only if you have the right to share it publicly.

如果问题只在特定书籍上出现，可以选择提供：

- 微信读书书籍链接。
- 自己导入书籍的格式和特征。
- 书籍源文件，但前提是你有权公开分享它。

Do not publicly upload copyrighted, private, or sensitive book files.

请不要公开上传受版权保护、包含隐私或不方便分享的书籍源文件。

### Privacy / 隐私

Never include these in issues, logs, screenshots, or PRs:

- API keys, including `wrk-...`.
- Cookies, including `wr_skey`, `wr_rt`, `wr_vid`, `ptcz`.
- `x-wrpa-*` headers.
- Full cURL commands copied from browser developer tools.
- Account IDs, private notes, or private book content.

不要在 issue、日志、截图或 PR 中包含：

- API key，例如 `wrk-...`。
- Cookie，例如 `wr_skey`、`wr_rt`、`wr_vid`、`ptcz`。
- `x-wrpa-*` 请求头。
- 从浏览器开发者工具复制的完整 cURL。
- 账号信息、私人笔记或私人书籍内容。

## Pull Requests / 提交 PR

Please keep PRs focused. Large features should be discussed in an issue before implementation.

请让 PR 尽量聚焦。较大的功能建议先开 issue 讨论，再开始实现。

Every PR must describe what it fixes or adds.

每个 PR 都必须说明它解决了什么问题，或新增了什么特性。

### Bugfix PRs / Bug 修复 PR

Bugfix PRs must include at least one of:

- A linked issue, such as `Fixes #123`.
- Clear reproduction steps for the original bug.

Bug 修复 PR 必须至少提供以下其中一项：

- 关联 issue，例如 `Fixes #123`。
- 原 bug 的清晰复现步骤。

Also describe how you verified the fix.

同时请说明你如何验证修复有效。

### Feature PRs / 新功能 PR

Feature PRs must describe:

- What feature was added.
- What user problem or workflow it improves.
- Screenshots or screen recording if it changes UI, menus, dialogs, layout, or interaction.

新增功能 PR 必须说明：

- 新增了什么功能。
- 它改善了什么用户问题或使用流程。
- 如果涉及 UI、菜单、弹窗、排版或交互，需要提供截图或录屏。

### Project conventions / 项目约定

- Code, variable names, and commit messages should be in English.
- User-facing strings should use `_()` and be translated in `lib/i18n.lua`.
- If menu items are added, removed, renamed, or moved, update `main.lua`, `lib/i18n.lua`, and the README menu tree together.
- For non-public WeRead Web APIs, validate the behavior with a script in `scripts/` before implementing it in Lua.
- Do not commit `config.lua`, generated EPUB/cache files, API keys, cookies, anti-abuse headers, or private book content.

项目约定：

- 代码、变量名和 commit message 使用英文。
- 用户可见文本需要使用 `_()`，并在 `lib/i18n.lua` 中添加中文翻译。
- 如果新增、删除、重命名或移动菜单项，需要同时更新 `main.lua`、`lib/i18n.lua` 和 README 菜单结构。
- 涉及非公开 WeRead Web API 时，先在 `scripts/` 中写脚本验证，再实现 Lua 版本。
- 不要提交 `config.lua`、生成的 EPUB/cache、API key、cookie、反滥用请求头或私人书籍内容。

## Local checks / 本地检查

Before submitting a PR, run the relevant checks if possible:

```bash
find . -name '*.lua' -not -path './config.lua' -print0 | xargs -0 -n1 luac -p
python3 -m py_compile scripts/*.py
rg -n -P "wrk-(?!x{8,})[A-Za-z0-9_-]{12,}|(wr_skey|wr_rt|wr_vid|ptcz)=((?!XXX)[^;[:space:]'\''\"]{8,})|x-wrpa-[0-9]+:\s*((?!\.\.\.)[A-Za-z0-9+/=_-]{12,})|thirdwx[=:]\s*[A-Za-z0-9_-]{8,}" . --glob '!config.lua' --glob '!cache/**' --glob '!*.epub'
```

提交 PR 前，如果可以，请运行相关检查：

```bash
find . -name '*.lua' -not -path './config.lua' -print0 | xargs -0 -n1 luac -p
python3 -m py_compile scripts/*.py
rg -n -P "wrk-(?!x{8,})[A-Za-z0-9_-]{12,}|(wr_skey|wr_rt|wr_vid|ptcz)=((?!XXX)[^;[:space:]'\''\"]{8,})|x-wrpa-[0-9]+:\s*((?!\.\.\.)[A-Za-z0-9+/=_-]{12,})|thirdwx[=:]\s*[A-Za-z0-9_-]{8,}" . --glob '!config.lua' --glob '!cache/**' --glob '!*.epub'
```
