## 变更说明

请说明这个 PR 解决了什么问题，或者新增了什么特性。

## 类型

- [ ] Bugfix
- [ ] Feature
- [ ] Refactor
- [ ] Documentation
- [ ] Other

## Bugfix 要求

如果这是 bugfix，请至少提供以下其中一项：

- 关联 issue：`Fixes #123`
- 修复前的清晰复现步骤

## Feature 要求

如果这是新增特性，请说明：

- 新增了什么能力
- 典型使用场景
- 如果涉及 UI、菜单、弹窗、排版或交互，请提供截图或录屏

## 测试

请说明你如何验证这个 PR。

- [ ] 已在 KOReader 中手动测试
- [ ] 已运行 `bash scripts/run_lua_specs.sh`
- [ ] 已运行 `bash scripts/check_lua_namespace.sh`
- [ ] 已运行 `luacheck main.lua _meta.lua weread spec`
- [ ] 如涉及插件加载/KOReader 兼容性，已运行或触发 `KOReader integration`
- [ ] 不适用，仅文档或注释变更

测试说明:

```text

```

## 非公开 WeRead API

如果本 PR 新增或修改任何非公开 WeRead Web API，必须同时在 `scripts/` 中提交一个可独立运行、可复现该接口行为的 Python 验证脚本。仅描述验证方式不能替代脚本。脚本不得打印或保存真实 API Key、Cookie、Token、完整 cURL 或账号标识。

- [ ] 不涉及非公开 WeRead API
- [ ] 已新增或更新可复现的 Python 验证脚本

脚本路径:

```text
scripts/
```

复现命令与脱敏结果:

```text

```

## 模块结构

项目自有 Lua 模块必须放在 `weread/` 命名空间下：

- 非 UI 模块：`weread/lib/`，使用 `require("weread.lib.<module>")`
- UI 模块：`weread/ui/`，使用 `require("weread.ui.<module>")`
- 禁止新增根级 `lib/`、`ui/` 项目模块或裸 `lib.*`、`ui.*` 模块键
- `require("ui/widget/menu")` 等 KOReader 自带模块不受此限制

## 截图

如果涉及 UI 或交互变更，请在这里添加截图或录屏。

## Checklist

- [ ] 我已经说明这个 PR 解决的问题或新增的特性。
- [ ] 如果是 bugfix，我已经提供复现步骤或关联 issue。
- [ ] 如果是新增 UI/交互特性，我已经提供截图或录屏。
- [ ] 我没有提交 KOReader `settings/weread.lua`、API key、cookie、token、`x-wrpa-*` 或私人书籍内容。
- [ ] 新增或移动的项目 Lua 模块遵循 `weread/lib/`、`weread/ui/` 命名空间规范。
- [ ] 新增或修复的逻辑包含对应回归测试；若无法自动化，已在测试说明中解释原因。
- [ ] 如果修改了用户可见文本，我已经更新 `weread/lib/i18n.lua`。
- [ ] 如果修改了菜单结构，我已经同步更新 README 菜单结构。
- [ ] 如果涉及非公开 WeRead Web API，我已经在 `scripts/` 中提交可独立运行、可复现的 Python 验证脚本，并填写了复现命令和脱敏结果。
