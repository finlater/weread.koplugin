# macOS 模拟器发版前测试

关联 [#145](https://github.com/finlater/weread.koplugin/issues/145)。从下一次发版开始，
发布负责人或 AI 先按本文执行，再进入 [发布流程](releasing.md)。

这里的“模拟测试”是在 Mac 上运行真实 KOReader、插件和排版引擎，使用 SDL 窗口
代替阅读器屏幕。它可以覆盖界面与软件流程；Kindle 硬件验证见文末。

## 1. 当前已经具备什么

以 v1.5.0 的功能和代码为基线，后续新增或调整功能时同步维护本清单。

| 层次 | 当前能力 | 不能据此声称通过的内容 |
| --- | --- | --- |
| `scripts/run_lua_specs.sh` | 逻辑与组件回归，大量使用 KOReader 替身 | 真实字体、控件绘制、点击和排版 |
| `scripts/run_koreader_integration.sh` | 固定 KOReader 版本的真实 PluginLoader 加载与命名空间检查 | 插件实例初始化后的完整功能、界面流程 |
| `spec/koreader/shelf_picker_geometry.lua` | 部分原生控件的几何检查，字体、屏幕与事件仍是替身 | 完整真实窗口渲染 |
| 2026-09-19 临时渲染探针 | 已验证真实 ReaderUI/插件初始化、合成 EPUB 翻页、PNG 输出 | 全功能回归；探针尚未纳入仓库 runner |
| ComputerUse | 已验证打开书籍、点击翻页、微信读书菜单、设置及列表/封面选项切换 | 未操作的下载、匹配、同步等用例 |

**下文是需要执行的用例，不是已通过的报告。** 本轮探索只证明上述链路可运行。
临时目录中的应用、书籍和截图可能被系统清理，不能作为下次发版的唯一依赖。
仓库现在提供 [本地 mock 服务和真实 KOReader 冒烟命令](mock-weread.md)，可直接启动
合成账号、书架、目录、下载和划线想法主流程；它尚未覆盖全部场景或自动执行完整 UI 清单。

## 2. 每次发版的顺序与通过规则

1. 确定候选代码、KOReader 版本和本次改动，记录插件 SHA、工作区差异、版本号。
   先完成下次版本的正常准备；测试结束后不要混入未经验证的功能改动。
2. 运行 [现有本地检查与 PluginLoader 集成测试](testing.md)。任何失败先定位，
   不把失败日志隐藏在后续成功命令或截图中。
3. 准备隔离配置、候选 ZIP 和合成数据；先跑一遍基础的开书、翻页、菜单冒烟。
4. 依次执行 **C01–C20 核心用例**。E01–E10 在相关代码、配置、依赖或兼容性变化时
   必须执行；逐项记录适用性，不能只写“其他功能正常”。
5. 对照改动补充原 bug 的复现路径，保留修复后的截图、断言与日志。网络、失败、
   取消和恢复分支也要验证，不能只走成功路径。
6. 执行适用的 Kindle 冒烟测试，填写结果记录，再继续版本提交、推送和远端验证。
   macOS 测试完成不表示 CI、打包、校验和或发布已完成。

结果只能使用 `PASS / FAIL / BLOCKED / N/A`：

- `PASS`：实际执行，结果符合标准，有证据；离屏、窗口操作、真实服务分别标明。
- `FAIL`：行为不符，记录复现与日志；修复后重跑该用例和受影响流程。
- `BLOCKED`：缺少构建、夹具、窗口权限、解锁状态或其他必要条件。记录原因，
  不能用单元测试结果代替，也不能默认为通过。
- `N/A`：仅用于本次不适用的扩展或设备项目，注明原因。核心用例不因“没有改到”跳过。

核心用例以及适用的扩展项出现 `FAIL/BLOCKED`，本轮验收未完成；需要例外时明确
列出未覆盖范围，由发布负责人决定，不能声称“全量通过”。功能代码或测试输入改变后
重跑受影响用例；仅版本号/发布说明变化仍需重新打包并核对版本、加载和入口。

## 3. 环境、数据与证据

### 固定 KOReader 与独立配置

固定提交以 [集成 runner](../scripts/run_koreader_integration.sh) 中的
`KOREADER_TESTED_COMMIT` 为准，与 CI 一致。构建按
[KOReader 官方文档](https://github.com/koreader/koreader/blob/v2026.07/doc/Building.md)
进行；使用 Homebrew Bash、GNU make 和 util-linux 的 getopt。首次构建需要下载
第三方依赖，后续复用构建目录。升级固定版本时同时更新 runner、CI 和测试文档。

以下命令在插件仓库根目录执行，`KOREADER_DIR` 替换为已构建且版本匹配的绝对路径：

```bash
export KOREADER_DIR="/absolute/path/to/koreader"
export WEREAD_BREW_PREFIX="$(brew --prefix)"
export PATH="$WEREAD_BREW_PREFIX/bin:$WEREAD_BREW_PREFIX/opt/findutils/libexec/gnubin:$WEREAD_BREW_PREFIX/opt/make/libexec/gnubin:$WEREAD_BREW_PREFIX/opt/util-linux/bin:$PATH"

# 使用与 ./kodev build 默认一致的 debug 构建，避免另建一套原生依赖。
KODEBUG=1 bash scripts/run_koreader_integration.sh

# 每次创建新目录，证据保留到发布完成；不复用日常账号配置。
export WEREAD_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/weread-release-ui.XXXXXX")"
mkdir -p "$WEREAD_RUN_DIR/profile/plugins" "$WEREAD_RUN_DIR/books" "$WEREAD_RUN_DIR/evidence"
bash scripts/package_release.sh "$WEREAD_RUN_DIR/candidate.zip"
unzip -q "$WEREAD_RUN_DIR/candidate.zip" -d "$WEREAD_RUN_DIR/profile/plugins"
shasum -a 256 "$WEREAD_RUN_DIR/candidate.zip" > "$WEREAD_RUN_DIR/evidence/package.sha256"
cat > "$WEREAD_RUN_DIR/profile/settings.reader.lua" <<'LUA'
return { language = "zh_CN", color_rendering = false }
LUA
```

运行窗口时令 `KO_HOME="$WEREAD_RUN_DIR/profile"`，KOReader 会从该目录的 `plugins`
发现候选包。**使用候选包的副本，不将被测安装目录软链到开发仓库**，尤其是更新和
缓存迁移测试。确认 KOReader 自带的 `plugins` 目录及其他额外路径没有第二份 WeRead。
集成 runner 会临时创建链接并在退出时清理，不要在它运行时同时修改这些路径。

准备下述书籍后，可由开发者在终端启动：

```bash
cd "$KOREADER_DIR"
KO_HOME="$WEREAD_RUN_DIR/profile" ./kodev run -b -d -W 600 -H 800 -D 167 \
    "$WEREAD_RUN_DIR/books" > "$WEREAD_RUN_DIR/evidence/runtime.log" 2>&1
```

AI 操作桌面时，通过 ComputerUse 选择已运行窗口，或使用指向本次构建和 `KO_HOME`
的本地应用启动器；只复用环境变量已核对的启动器。Mac 须保持解锁。
首次启动的语言、颜色等提示也需处理后再开始计数。

### 数据准备清单

使用自写内容与合成接口响应。先按 [mock 服务说明](mock-weread.md) 准备可运行环境。
下表是完整输入要求，**目前的 mock 仅覆盖其中一部分**，逐项以该文档覆盖边界为准。
现有单元测试中的合成数据可作为参考，但不能直接把其 UI 替身用作真实渲染验证。

| 数据 | 最小覆盖内容 |
| --- | --- |
| B0 普通 EPUB | 自写中文、多页、长段落、目录、可识别的页内标记；没有 WeRead 关联 |
| B1 下载书 | 同一合成书的单章、第 2/5 章合集、整本三种输出；通过真实 Content/Downloader 生成 |
| B2 本地书与旧书 | 可匹配的 EPUB、标题相同但正文有差异的版本、含子目录/重名章节的版本、旧嵌入式划线版本 |
| B3 脚注与资源 | 普通脚注、多处引用同一脚注、长脚注、校验需回退的章节、图片及图片失败响应 |
| S 书架 | 空架、超过两页的书籍、长书名/作者、无封面与坏封面；空分组、跨页分组、公众号及文章 |
| A 划线想法 | 无标注章节、重叠/跨行划线、章首章末、多批次数据、长想法、emoji、空回复和多页回复 |
| F 故障与状态 | 超时、离线、登录失效、畸形响应、缺资源、取消后迟到响应；两个合成账号及旧版配置副本 |

需要网络结果的离线用例，在 **Client/HTTP 边界**注入可记录请求的合成响应，或使用
测试专用本地服务。保留真实 UIManager、控件、文档、排版、下载落盘和 SQLite；
需要验证请求协议时在 HTTP 边界替换，不能替掉被测业务函数。未知请求直接报错。
已有注入入口在插件内置 mock 模式中，测试启动器自动配置；执行前补齐本次必测但尚未提供的夹具，写明启动方法；
缺失时该用例为 BLOCKED。

故障只作用于测试边界，不关闭 Mac 的全局网络。延迟、取消和重试用例保留真实事件
循环并控制返回时机。账号、云端进度与阅读时长默认使用替身；真实服务验证单列记录，
不混进离线 suite，也不把替身通过当成真实服务端通过。

### 屏幕、默认值与观察方式

- 必测中文、小屏竖屏；布局变更再跑一个较大的尺寸。记录窗口逻辑尺寸、截图实际
  像素、DPI、字体和字号。探索时 600×800 窗口在 Retina 下生成了 1200×1600 截图，
  离屏测试是 600×800；两者不能直接做像素基线比较。
- ComputerUse 的辅助功能树可能只有窗口，没有 KOReader 内部控件。以新截图定位，
  点击后观察结果；菜单可用 `F1`，返回用 `Escape`，截图用 `Alt+Shift+G`。
  不把上次的固定坐标或“点击调用成功”当作本次通过。
- 控件检查至少包括长文字、底部按钮、选中态、翻页/滚动、关闭与返回。截图配合状态、
  输出文件、数据库或请求记录，不能只以“没有崩溃”判定成功。
- 本轮基线以 [settings.lua](../weread/lib/settings.lua) 为准：列表分页默认开启；
  打开拉进度、关闭上传、阅读时长上报、下一章预下载、划线预下载、自动检查更新默认
  关闭；书籍图片开启、公众号图片关闭、隐藏脚注关闭。想法弹窗默认居中、70% 高、
  80% 宽、相对字号 0、对比度 +9、点击左右翻页关闭；划线边缘保护为 20%。
  旧配置的保留值与新安装默认值分开测试。

## 4. 核心用例：每次发版都走

每行的分支都需要执行；“重启”是退出当前 KOReader 后用同一测试配置重新启动。

| ID | 操作与前置条件 | 通过标准 |
| --- | --- | --- |
| C01 加载与入口 | 空配置启动文件管理器；进入工具 → 微信读书；打开 B0 后再检查主菜单与快捷动作 | 显示候选版本；无模块加载/初始化错误；依赖当前微信书籍的动作按上下文禁用或提示，普通本地书也可打开全局入口 |
| C02 设置持久化 | 按上节核对新安装默认值；切换列表/封面及一项弹窗设置，退出重开，再恢复 | 选中态和行为一致；设置持久化；未开启的进度、时长、预下载和自动更新没有请求 |
| C03 真实阅读 | 打开 B0，前后翻页、目录跳转、改变字号、关闭再打开 | 中文、换行与页码正常；字号变化后可继续阅读；位置合理恢复；无残留对话框 |
| C04 书架导航 | 用 S 切换书籍/公众号、分组、空分组；打开超过一页的分组选择器，再返回 | 标题、计数与内容一致；顶栏搜索/刷新/菜单不重叠；选择器页数和最后一项可见；没有错误复用上一个分组内容 |
| C05 书架布局 | 同一 S 依次使用列表分页、列表连续滚动、封面模式；按钮和滑动翻到首尾页；检查长标题/坏封面 | 不重复或漏书、不越界；关闭分页确实连续滚动；封面布局自适应、只处理当前页所需封面；占位与已缓存角标可辨认 |
| C06 搜索、筛选与离线缓存 | 在书架搜索、取消搜索、改变排序与筛选；刷新后重启；用边界替身模拟离线再打开 | 返回路径正确，筛选/排序生效；已有书架、分组及文章缓存仍可浏览；刷新失败保留旧快照；用请求记录确认缓存命中没有无谓重拉 |
| C07 详情与章节选择 | 从书架打开详情、目录，展开/收起层级；分别选择单章和第 2/5 章，取消一次再确认 | 长元信息与操作按钮可见；父子勾选关系正确；合集仅含选择的章节，章节 UID/顺序正确，不能误取第 3/4 章 |
| C08 下载与打开 | 用真实 Downloader/Content 生成 B1 的单章、合集、全书并打开；测试正常完成与错误提示 | EPUB/HTML 可读，目录、图片引用与元信息正确；完成状态、缓存角标与可打开文件一致；失败不显示完成；正文下载不强制同步想法 |
| C09 取消下载 | 全书分别在准备、已完成部分章节、等待响应时点击取消；注入迟到结果；再执行一次正常下载 | 进度框与取消按钮可操作；完成章节保留并提示可续传；取消后不误报完成、不被迟到回调重新打开；后续下载不被残留任务阻塞。记录打包阶段的响应情况 |
| C10 断点续传 | 取消后再次下载全书；退出进程后重启再续传；分别损坏或移除一个已存章节文件 | 请求记录显示有效已完成章节被复用；缺失/损坏项重新获取；最终目录和正文完整，工作目录正确清理；不能仅检查返回值，要检查真实文件 |
| C11 包装与回退 | 用 B3 覆盖原始 XHTML 与 rendered-text 回退，含脚注和资源；检查最终 EPUB 条目并逐章打开 | 回退章节仍进入最终书籍；无丢章、重复章、坏资源引用；失败不覆盖原有可读成品；脚注校验失败保留可读的原始标记 |
| C12 书籍关联与章节映射 | B1 自动关联；B2 本地书搜索绑定；测试子目录、重名标题、部分章节及正文不同版本 | 不把本地小节当作额外远端章节；只处理本文件能映射的章节；不确定匹配明确报告；单章的定位不能直接套到合集/全书 |
| C13 匹配暂停与恢复 | A 含多个批次；开始匹配，记录准备耗时；处理中暂停、关书、断网，再继续；测试空标注章节 | 阶段文字与进度一致；已保存章节/批次可复用，不重复写入；空结果能完成；取消/关书后没有旧会话更新当前界面。准备阶段长时间无反馈或不能响应也记为问题 |
| C14 划线显示与重排 | 在 B1/B2 显示/隐藏 A，翻页、换字号、改横竖屏；打开另一书再返回；检查旧嵌入式划线书 | 主菜单与快捷菜单状态一致；重排后划线仍落在目标文字；不会双画划线、弹两次想法或显示另一书的标注；不修改原 EPUB 与 KOReader 自有笔记 |
| C15 想法弹窗与边缘 | 打开长想法/emoji/多页回复；居中和底部各测；调整宽高/字号/对比度，测试按钮与左右点击翻页；点击阅读区左右边缘 | 长内容可读完，页码/按钮可达，关闭返回原阅读位置；设置有效且禁用项状态正确；边缘保护开启时翻页不会误开想法 |
| C16 原书脚注 | B3 分别以默认设置和“隐藏脚注文本”重新生成；后者同时启用 KOReader 脚注弹窗；点击多个注号并返回 | 原书脚注正文可达，长脚注可读；不与微信用户想法混淆；设置只影响新下载文件；检查章末异常留白、重复脚注和失效返回链接 |
| C17 章末与预下载 | B1 单章到末页：打开目录/下一章/关闭书籍；再测全书与最后一章；开启下一章预下载及其划线开关，切书/关书/手动下载 | 下一章可用性符合上下文；全书不误开另一章文件；关闭书籍返回文件管理器；关掉总开关后子选项不可用；旧预下载不污染新书或抢占前台任务 |
| C18 进度同步 | B1 单章/合集/全书各取章首/中间/章末，用合成远端进度测试相同、冲突、另一章、失效定位；关书或切书后返回迟到结果 | 冲突选择对应实际跳转；安全映射失败时不上传猜测位置；跨章跳转正确；旧重试不跳转/上传另一书；默认开关关闭时无自动请求 |
| C19 开书与会话清理 | B2 首次匹配后关书重开，同书重复三次再换另一书；记录冷/热开书、匹配开始和连续翻页 | 缓存命中不重复下载/全书重匹配；弹窗、回调、worker 与定时任务不叠加；定位不串书。与相同环境的上一版比较耗时，不用 Mac 数值宣称 Kindle 性能改善 |
| C20 候选包收尾 | 保留当前配置，退出/重启候选包；重新打开已缓存书、书架、设置；核对日志、版本与 ZIP 摘要 | 设置与完成结果仍在；无遗留进度框/后台任务错误；验证的确是待发布包。发现代码改变则更新包并重跑受影响场景 |

## 5. 扩展用例：按改动选择，逐项记录适用性

| ID / 触发范围 | 操作 | 通过标准 |
| --- | --- | --- |
| E01 登录、Cookie、Client | 合成扫码等待/成功/过期、四位验证码正确/错误、未开通 Skill、接口失败；关闭窗口、重复开始、续期 | 轮询能终止，旧响应不覆盖新会话；凭据与账号状态完整更新或明确失败；错误提示可返回。真实扫码另列，手机确认由用户完成 |
| E02 公众号及图片 | 公众号列表/文章分页、缓存后离线重开；图片开关两种模式及图片失败 | 文章标题/顺序/HTML 正常；关闭图片时不发对应资源请求；开启后图片可显示；失败不破坏正文，默认值仍为关闭 |
| E03 搜索、书评、收藏夹 | 全局中文搜索、无结果、详情、推荐/最新书评、长评论及回复；打开本地 weread 收藏夹 | 输入和返回正确；长文本可滚动；单章不误加入整书收藏；移除文件后状态不会假装仍可打开 |
| E04 阅读时长 | 合成账号下切换自动关联/手动指定、仅阅读时上报；开关、换书、关闭、失败重试 | 上报对象、阅读位置与时长正确；没有重复定时器；停止条件生效；失效定位不伪造进度。验证请求记录，不写真实阅读时长 |
| E05 阅读统计 | 周/月/年/总切换及历史周期；空数据、长标签、接口失败 | 标题、周期、总量与图表一致；图表和返回按钮不裁切；失败能恢复，不能保留错误周期的数据 |
| E06 缓存与文件迁移 | 扫描匹配合成文件；切换下载目录，分别迁移/保留；模拟写失败；清理单书和全部测试缓存 | 原文件在迁移失败时仍可用；路径与数据库同步；清理范围准确、其它书不受影响。仅操作本次隔离目录 |
| E07 更新器 | 合成相同/新版本、代理失败回退、校验失败、异常 ZIP；取消检查/下载；在候选安装副本测试更新与恢复 | UI 可返回；校验未过不能替换插件；成功后版本正确；失败旧版本可启动；自动检查默认关闭，开启后按一小时间隔去重，不实际等待一小时 |
| E08 SimpleUI / ZenUI | 在独立配置安装所支持的实际版本，使用快捷入口、底栏及主页组件 | 原生菜单仍可用；入口打开正确书架；重复初始化不重复注册。未安装时记 N/A；相关集成代码改变时需准备环境执行 |
| E09 非触屏/布局兼容 | 模拟器禁用触屏，用方向键、确认与返回操作书架、分组选择、章节多选、想法弹窗；补大屏/横屏 | 焦点可见，无不可达按钮、焦点陷阱或误触；尺寸改变后控件可达。这里只证明键盘路由，不证明 Kindle 实体键行为 |
| E10 配置/数据库迁移与账号隔离 | 用上一正式版生成合成配置/缓存再升级；两个合成账号来回切换；含已关联本地书和旧注释 | 设置和旧可读文件保留；迁移可重复执行；书架/账号缓存不串用；共享注释数据与文件投影按代码约定复用；失败可从测试备份恢复 |

修改 mock 入口、Settings 或 Client 时，E10 还须覆盖环境切换：真实/mock 分别设置不同
偏好、书架、下载和收藏夹；保存开关或地址后确认当前环境不变，重启后才切换，切回时
原数据仍在。连接测试要覆盖成功、错误端口和已配置全局 HTTP 代理；服务失败只报错，
请求记录中没有真实服务回退。测试流程见 [mock 服务说明](mock-weread.md)。

涉及真实 WeRead API 的变更，还应遵守仓库现有的接口验证要求。测试报告明确写出
真实服务验证的范围与结果；离线用例通过不填补这部分证据。

## 6. 与当前代码、现有规格的对应

路径相对于插件仓库根目录；这些现有规格用于定位和快速回归，不代替上面的窗口检查。

| 用例 | 主要实现 | 重点规格（`spec/`） |
| --- | --- | --- |
| C01–C03、C20 | `main.lua`、`weread/lib/settings.lua`、`weread/ui/menu.lua` | `plugin_load_spec.lua`、`settings_spec.lua`、`koreader/weread_plugin_spec.lua` |
| C04–C07、E03 | `weread/ui/library.lua`、`weread/ui/library_view.lua`、`weread/ui/chapter_list_view.lua`、`weread/lib/library_db.lua` | `shelf_groups_spec.lua`、`shelf_snapshot_spec.lua`、`bookshelf_pagination_spec.lua`、`chapter_selection_spec.lua`、`book_reviews_spec.lua`、`local_bookshelf_collection_spec.lua` |
| C08–C11、C16、E02 | `weread/lib/downloader.lua`、`weread/lib/content.lua`、`weread/lib/footnotes.lua`、`weread/ui/download_dialog.lua` | `downloader_resume_spec.lua`、`download_resume_content_spec.lua`、`download_disk_assets_spec.lua`、`downloader_lifecycle_spec.lua`、`footnotes_spec.lua`、`mp_article_images_spec.lua` |
| C12–C15、C19 | `weread/ui/annotation_sync_controller.lua`、`weread/ui/xpointer_overlay.lua`、`weread/ui/thought_popup/`、`weread/lib/annotation_chapters.lua`、`weread/lib/annotation_store.lua`、`weread/lib/reader_lifecycle.lua` | `annotation_chapters_spec.lua`、`annotation_sync_controller_spec.lua`、`annotation_locator_regressions_spec.lua`、`thought_popup_viewport_spec.lua`、`reader_lifecycle_highlight_spec.lua` |
| C17–C18、E04–E05 | `weread/ui/reader_navigation.lua`、`weread/lib/chapter_prefetch_worker.lua`、`weread/lib/progress_sync.lua`、`weread/lib/position_mapper.lua`、`weread/lib/read_report.lua`、`weread/lib/read_stats.lua` | `end_of_book_dialog_spec.lua`、`prefetch_lifecycle_spec.lua`、`progress_sync_spec.lua`、`position_mapper_spec.lua`、`read_report_progress_spec.lua` |
| E01、E06–E10 | `weread/lib/qr_login.lua`、`weread/lib/client.lua`、`weread/lib/updater.lua`、`weread/lib/migrations.lua`、`weread/ui/cache.lua`、`integrations/` | `qr_login_spec.lua`、`client_spec.lua`、`scan_spec.lua`、`updater_spec.lua`、`library_db_account_spec.lua`、`ui_integrations_spec.lua`、`focus_nav_spec.lua` |

## 7. 发版前仍需保留的 Kindle 验证

先确认当次设备、KOReader 版本与连接地址，不能沿用历史 IP 推断当前设备。

- 每次发版：候选包在真实设备加载、开书/翻页、进入微信读书、打开/关闭想法弹窗，
  检查墨水屏刷新与残影。
- 下载、worker、缓存或性能变更：长书下载/取消/续传、长书开书与连续翻页，核对
  内存和响应；Mac 的 CPU/RAM、`/proc/meminfo` 缺失情况不能代表 Kindle。
- 生命周期、防休眠或任务调度变更：下载/匹配中暂停、休眠/唤醒、关书与网络恢复，
  确认防休眠引用被释放，没有遗留任务。
- 按键或布局变更：在实际目标型号测试对应输入。支持非触屏设备的变更不能仅靠
  Mac 鼠标或键盘判定完成。

## 8. 结果记录模板

每次在独立证据目录保存一份，分享前检查日志与截图中是否有真实账号或私人内容。
发版报告链接该记录，不覆盖上一版结果。

```markdown
# macOS release test — vX.Y.Z

- 日期 / 执行者：
- 插件 SHA / 工作区差异 / 候选 ZIP SHA-256：
- KOReader SHA / base 修改或依赖替换说明：
- macOS / CPU 架构 / 逻辑窗口 / framebuffer / DPI / 字体 / 语言：
- KO_HOME / 数据版本 / 网络边界注入与启动方法：
- 本次改动及适用的 E 用例：
- 本地检查 / PluginLoader 结果与日志：

| 用例与子场景 | 离屏 / ComputerUse / 真实服务 / Kindle | 结果 | 截图、日志、断言或文件证据 | 问题与复测 |
| --- | --- | --- | --- | --- |
| C01 | | | | |
<!-- 按清单逐项列出 C01–C20、E01–E10 的结果或适用性；不能只保留汇总行。 -->

- FAIL / BLOCKED / N/A 及理由：
- Kindle 型号、版本与验证结果：
- 未覆盖范围或经发布负责人接受的例外：
- 本轮结论：验收通过 / 未完成（不得以 macOS 通过代替真机或远端 CI）
```
