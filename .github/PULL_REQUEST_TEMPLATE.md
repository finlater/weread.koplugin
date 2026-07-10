## 变更说明 / Summary

请说明这个 PR 解决了什么问题，或者新增了什么特性。

Describe what this PR fixes or adds.

## 类型 / Type

- [ ] Bugfix / Bug 修复
- [ ] Feature / 新功能
- [ ] Refactor / 重构
- [ ] Documentation / 文档
- [ ] Other / 其他

## Bugfix 要求 / Bugfix requirements

如果这是 bugfix，请至少提供以下其中一项：

- 关联 issue：`Fixes #123`
- 修复前的清晰复现步骤

If this is a bugfix, provide at least one of:

- Linked issue: `Fixes #123`
- Clear reproduction steps before the fix

## Feature 要求 / Feature requirements

如果这是新增特性，请说明：

- 新增了什么能力
- 典型使用场景
- 如果涉及 UI、菜单、弹窗、排版或交互，请提供截图或录屏

If this adds a feature, describe:

- What capability was added
- Typical use case
- Screenshots or screen recording if it changes UI, menus, dialogs, layout, or interaction

## 测试 / Testing

请说明你如何验证这个 PR。

Describe how you tested this PR.

- [ ] 已在 KOReader 中手动测试 / Manually tested in KOReader
- [ ] 已运行相关脚本或检查 / Ran relevant scripts or checks
- [ ] 不适用，仅文档或注释变更 / Not applicable, docs/comments only

测试说明 / Test details:

```text

```

## 截图 / Screenshots

如果涉及 UI 或交互变更，请在这里添加截图或录屏。

If this changes UI or interaction, add screenshots or a screen recording here.

## Checklist

- [ ] 我已经说明这个 PR 解决的问题或新增的特性。 / I described the problem fixed or feature added.
- [ ] 如果是 bugfix，我已经提供复现步骤或关联 issue。 / For a bugfix, I provided reproduction steps or linked an issue.
- [ ] 如果是新增 UI/交互特性，我已经提供截图或录屏。 / For a new UI/interaction feature, I added screenshots or a screen recording.
- [ ] 我没有提交 `config.lua`、API key、cookie、`x-wrpa-*`、完整 cURL 或私人书籍内容。 / I did not commit `config.lua`, API keys, cookies, `x-wrpa-*`, full cURL commands, or private book content.
- [ ] 如果修改了用户可见文本，我已经更新 `lib/i18n.lua`。 / If I changed user-facing text, I updated `lib/i18n.lua`.
- [ ] 如果修改了菜单结构，我已经同步更新 README 菜单结构。 / If I changed menu structure, I updated the README menu tree.
- [ ] 如果涉及非公开 WeRead Web API，我已经先在 `scripts/` 中验证或说明验证方式。 / If this touches non-public WeRead Web APIs, I validated it in `scripts/` or described the validation.
