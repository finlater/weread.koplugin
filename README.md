# WeRead KOReader Plugin（二开版）

> **本仓库说明**：这是基于原作者 **[finlater/weread.koplugin](https://github.com/finlater/weread.koplugin)** 的二次开发分支，**不是**上游官方仓库。  
> 核心阅读、登录、同步、统计等能力均来自原项目；本仓库在其之上增加了**国内可访问的在线更新**、**自动 Release 发版**，以及 **v0.5.4 起的扁平 EPUB + 独立元数据目录**布局。  
> 请优先给原作者点 Star / 提上游问题：https://github.com/finlater/weread.koplugin

> **免责声明**：本项目仅供个人学习和技术研究使用，不得用于商业用途。使用本项目所产生的一切后果（包括但不限于账号封禁、数据丢失等）由使用者自行承担，项目作者与二开维护者概不负责。请遵守微信读书的用户协议和相关法律法规。

在 KOReader 上阅读微信读书书籍和公众号文章、同步阅读时长、进度的插件。

## 本仓库相对原版的改动

| 改动 | 说明 |
|------|------|
| **插件内在线更新** | 菜单 `工具 → 微信读书 → 插件更新`，设备上直接检查 / 下载 / 安装，不必每次用电脑覆盖插件目录 |
| **国内 GitHub 代理** | 默认 [ghspeedup.com](https://ghspeedup.com/)（worker: `runn.i.ng` 路径模式）；备用 `gh-proxy.com`、`ghfast.top`、直连；失败自动换备用 |
| **更新通道** | 自动（优先 Release，否则 `main`）/ 仅正式版 / 仅开发分支；可选启动时检查（默认关，12 小时节流） |
| **自动 Release** | 修改 `_meta.lua` 的 `version` 并推送 `main` 后，GitHub Actions 自动打 tag 并上传 `weread.koplugin-v*.zip` |
| **扁平书库 + 独立元数据** | 图书目录只放平铺 EPUB；想法/目录/metadata/公众号 HTML 进可配置的元数据目录（按 `bookId` 分夹）。默认元数据在 KOReader 数据目录 `weread/meta/`，不进书库 |
| **登录与缓存隔离** | 登录态在 `settings/weread.lua`，下载与元数据默认都不在 `plugins/`；覆盖/在线更新插件不会清掉扫码登录和已下载内容 |
| **从原作者版平滑迁移** | 与上游共用同一配置文件与字段（`AUTH_SCHEMA_VERSION = 1`）；旧「每书一目录」仍可识别；损坏的空 metadata 路径会在启动时尝试修复 |

> 上游原有功能（书架、EPUB/公众号下载、进度同步、阅读时长上报、划线想法、阅读统计等）保持兼容；下列「功能」章节描述的是完整能力集（含上游能力 + 本仓库增量）。
>
> **2026-08-01 已同步上游 v0.6.0**：书架/书籍详情 UI 重构（双 Tab + SQLite 快照 + 书架内搜索）、下载书脚注、多章节下载、章节预加载、WeRead 快捷菜单、SimpleUI/ZenUI 启动入口、README/截图与 CI/Release 流程更新。
>
> **2026-08-12 已同步上游 v1.1.0**：加入物理按键导航、磁盘流式下载、页内脚注、想法星标修复、阅读上报菜单刷新、快速切书防崩，以及可绑定的书架/搜索/阅读统计动作；继续保留本仓库的扁平书库、自研更新器与公众号优化。

### 相关链接

| 项目 | 链接 |
|------|------|
| 原作者仓库 | https://github.com/finlater/weread.koplugin |
| 本二开仓库 | https://github.com/rollingshmily/weread.koplugin |
| 本仓库 Releases | https://github.com/rollingshmily/weread.koplugin/releases |
| [kindlebtcontroller.koplugin](https://github.com/finlater/kindlebtcontroller.koplugin) | 蓝牙手柄/遥控器控制 Kindle |
| [one.koplugin](https://github.com/finlater/one.koplugin) | KOReader 离线阅读「ONE · 一个」 |

## 功能

| 主菜单 | 书架 | 公众号 |
|:---:|:---:|:---:|
| ![主菜单](screenshots/main_manu.png) | ![微信读书书架](screenshots/bookshelf.png) | ![公众号](screenshots/bookshelf_wp.png) |

| 阅读时间上报 | 阅读统计 | 阅读进度同步 |
|:---:|:---:|:---:|
| ![阅读时间上报](screenshots/read_report.png) | ![阅读统计](screenshots/read_stats.png) | ![阅读进度同步](screenshots/read_progress.png) |

| 多选章节下载 | 章节预下载 | 下载全书 |
|:---:|:---:|:---:|
| ![多选章节下载](screenshots/download_multi_chapter.png) | ![章节预下载](screenshots/pre_download_next_chapter.png) | ![下载全书](screenshots/download.png) |

| 书籍详情 | 书评 | 划线和想法 |
|:---:|:---:|:---:|
| ![书籍详情](screenshots/book_detail.png) | ![书评](screenshots/book_review.png) | ![划线和想法](screenshots/thought.png) |

| 搜索书籍 | 快捷菜单 | 设置 |
|:---:|:---:|:---:|
| ![搜索书籍](screenshots/book_search.png) | ![快捷菜单](screenshots/quick_menu.png) | ![设置](screenshots/setting.png) |

**书架（v0.6.0 起）**

- 书籍 / 公众号双 Tab，保留排序、阅读状态与下载状态筛选，书架内可直接搜索
- 书架快照、点开过的书籍信息和章节目录按登录账号隔离写入 SQLite
- 首次打开未缓存详情的书籍自动获取信息；已下载书籍及文章可离线浏览
- 下载书支持默认显示在页面底部的**页内脚注**；支持**多章节下载**、**章节预加载**与 WeRead 快捷菜单
- 方向键、翻页键和确认键可操作书架、书籍详情、章节列表、书评与阅读统计，适配无触屏或主要依赖物理按键的设备
- 可在 KOReader 手势/按键设置中绑定书架、搜索、阅读统计、阅读进度同步与阅读界面快捷菜单

**阅读时间上报**

- 自动向微信读书上报阅读时长（默认每 30 秒一次）
- 支持两种目标书籍模式：
  - **自动关联**：打开微信读书缓存书籍时自动上报该书，关闭时自动停止
  - **手动设置**：从书架选择一本固定书籍作为上报对象
- 支持「仅在阅读时上报」或「KOReader 启动即上报」两种触发模式，不检查翻页活动
- 上报状态可在菜单中查看（已上报次数、最近上报时间、错误信息）
- 阅读时长上报复用当前 KOReader 实时位置；云端冲突尚未处理时会暂停上报，避免旧位置覆盖新位置

**阅读进度同步**

- 打开微信读书缓存书籍时自动拉取进度，关闭书籍或设备挂起时上传进度
- 菜单中的「立即同步进度」可随时手动拉取、比较和处理冲突

**阅读统计**

完整移植 APP 阅读统计能力, 支持按照周/月/年/总 维度查看
- 阅读时长
- 阅读天数
- 阅读排行

**书籍管理**

- 书架支持多种排序方式（最后阅读时间、书名、默认顺序）与筛选（已读完/未读完、已下载/未下载，两组可组合）
- 书籍详情页展示作者、出版社、出版时间、评分、字数、阅读进度等信息，并可按需查看推荐书评和最新书评
- EPUB 自动嵌入封面图片
- 图片及 EPUB 资源通过磁盘流式处理，大书和图片较多书籍下载时不再把全部资源同时压在内存里；完成、失败或取消后自动清理临时文件
- 缓存管理：查看/清理单本或全部缓存；可分别设置**图书目录**与**元数据目录**；扫描本地缓存时会同时看这两个根（需联网，仅导入与微信读书书架 ID 匹配的目录）
- 图书目录：新下载的 EPUB **平铺**保存（默认 `<KOReader 数据目录>/weread/cache`，可改到你的书库根目录）
- 元数据目录：`catalog.json` / `metadata.json` / `reading_state.json` / `articles.json` / `thoughts.db` / 公众号 HTML 按 `<元数据目录>/<书籍 ID>/` 存放（默认 `<KOReader 数据目录>/weread/meta`）
- `weread.lua` 只保留路径索引（`cache_dir`、`cached_file` 等）；打开书时 sidecar 写元数据目录，不再在书库根下冒空的 `bookId` 文件夹
- 旧版「每书一目录」布局仍兼容；启动时会尝试把指到空壳 metadata 路径的 `cache_dir` 修回有内容的位置

**插件更新**

- 菜单内一键检查/下载/安装更新，无需电脑重新拷贝插件
- 默认通过 [ghspeedup.com](https://ghspeedup.com/)（worker: `runn.i.ng`）加速访问 GitHub（可选 `gh-proxy.com`、`ghfast.top` 或直连）
- 更新通道：
  - **自动**：优先 GitHub Release，没有正式版时回退到 `main` 分支 zipball
  - **正式版**：只使用 Release
  - **开发分支**：跟踪 `main`
- 可选「启动时检查更新」（默认关闭，且 12 小时内最多检查一次）
- 用户设置与书籍缓存不在插件目录内，更新不会清掉登录态和已下载内容

## 安装

> ⚠️ 建议使用 **KOReader 2026.03 或更高版本**。旧版本可能无法正常加载或使用插件，例如「工具」菜单中找不到「微信读书」。详见 [#14](https://github.com/finlater/weread.koplugin/issues/14)。

### 方式一：Release 包（推荐）

1. 打开 [Releases](https://github.com/rollingshmily/weread.koplugin/releases) 下载最新 `weread.koplugin-v*.zip`。
2. 国内网络可在链接前加代理前缀，例如：
   - `https://runn.i.ng/rollingshmily/weread.koplugin/releases/download/v1.1.0/weread.koplugin-v1.1.0.zip`（[ghspeedup.com](https://ghspeedup.com/)）
   - `https://gh-proxy.com/https://github.com/rollingshmily/weread.koplugin/releases/download/v1.1.0/weread.koplugin-v1.1.0.zip`
   - `https://ghfast.top/https://github.com/rollingshmily/weread.koplugin/releases/download/v1.1.0/weread.koplugin-v1.1.0.zip`
3. 解压后把 `weread.koplugin/` 目录放到 KOReader 的 `plugins` 目录。

### 方式二：手动复制源码目录

将插件目录复制到 KOReader 的 plugins 目录：

```
koreader/plugins/weread.koplugin/
```

4. 重启 KOReader，在菜单中找到：

```
工具 → 微信读书
```

### 后续在线更新

安装完成后，在设备上打开：

```
工具 → 微信读书 → 插件更新 → 检查更新
```

默认使用 [ghspeedup.com](https://ghspeedup.com/)（实际请求走 `runn.i.ng` 路径模式）拉取 GitHub 资源。如果某个代理不可用，可在同一菜单切换到 `gh-proxy.com` / `ghfast.top` / 直连；检查与下载时也会自动尝试备用代理。

## 登录与认证

插件只支持微信扫码登录，不需要创建或维护配置文件。

扫码前需要先为账号开通微信读书 Skill：

1. 手机打开**微信读书 App**。
2. 进入 **我 → 设置 → 微信读书 Skill**。
3. 点击 **获取 API Key**，确认已经生成个人官方 API Key。
4. 在 KOReader 打开 **工具 → 微信读书 → 微信扫码登录**。
5. 使用微信扫码并在手机端确认；若手机显示四位验证码，请在 KOReader 中输入。

## SimpleUI / Zen_UI 集成

插件提供统一的“微信读书书架”入口并支持集成到 SimpleUI和 ZenUI的快捷按钮中。(需要安装最新版 [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) 和 [ZenUI](https://github.com/AnthonyGress/zen_ui.koplugin)插件)。

- **SimpleUI**：进入 `快捷操作` 新建操作，类型选择 `插件 → 微信读书`，再把该操作加入底部栏即可。如需使用本项目图标，将 `icons/weread-w-book.svg` 或 `icons/weread-ink.png` 复制到 SimpleUI 的自定义图标目录后，在快捷操作中选中它。
- **Zen_UI 底栏**：进入 `控件 → 按钮 → ➕ → 插件 → 微信读书`，点击后直接打开微信读书书架。注册时会把 `weread-w-book.svg` 同步到 KOReader 用户图标目录，供 ZenUI 自动匹配或手动选择；不会自动修改、添加或启用 Tab。
- **Zen_UI 首页**：进入 `主页 → 小组件`，启用“微信读书”组件。组件默认关闭，可由用户自行排序。

原生 KOReader 的 “工具 → 微信读书” 菜单保持不变。

|                     SimpleUI                     |                   Zen_UI                   |
|:------------------------------------------------:|:------------------------------------------:|
| ![simpleui](screenshots/simpleui_quick_menu.png) | ![ZenUI](screenshots/zenui_quick_menu.png) |

## 菜单结构

```
微信读书
├── 微信扫码登录 / 已经登录 · 账号名
├── 立即同步进度       （阅读微信读书缓存书籍时显示）
├── 书籍详情           （阅读微信读书缓存书籍时显示）
├── 显示划线和想法     （阅读书籍时显示，开关）
├── 本地书划线和想法   （阅读非微信读书的可重排文档时显示；不修改 EPUB/KOReader 笔记）
│   ├── 匹配微信读书书目 / 已匹配：书名
│   ├── 同步划线与想法（同步后显示已匹配条数）
│   └── 清除数据
├── 书架               书籍 / 公众号 Tab；书架内搜索、离线缓存、手动更新
├── 搜索               搜索微信读书
├── 阅读时间上报        后台上报阅读时长
│   ├── 启用阅读时间上报
│   ├── 仅在阅读时上报
│   ├── 选择目标书籍
│   │   ├── 自动关联微信读书书籍
│   │   └── 手动设置上报书籍
│   └── 上报状态
├── 阅读统计            阅读时长/天数/排行/偏好可视化（页内 周/月/年/总 tab 切换，可翻阅历史周期）
├── 设置
│   ├── 缓存管理
│   │   ├── 扫描并关联本地书籍
│   │   ├── 缓存清理
│   │   └── 缓存目录
│   ├── 进度管理
│   │   ├── 打开时拉取进度（默认关闭）
│   │   └── 关闭时上传进度（默认关闭）
│   ├── 下载设置
│   │   ├── 书籍图片（默认开启）
│   │   ├── 公众号文章图片（默认关闭）
│   │   └── 章节预下载
│   │       ├── 自动预下载下一章（默认关闭，开启时会确认网络卡顿风险）
│   │       ├── 预下载划线和想法（默认关闭，总开关关闭时不可操作）
│   │       └── 显示预下载提示（默认开启，总开关关闭时不可操作）
│   ├── 划线设置
│   │   ├── 划线边缘防误触（默认开启）
│   │   └── 边缘区域：20%（可调 10%–40%）
│   └── 账号管理
│       ├── 账号状态
│       ├── 立即续期 Cookie
│       └── 清除账号数据
├── 插件更新
│   ├── 检查更新
│   ├── 更新通道（自动 / 正式版 / 开发分支）
│   ├── GitHub 代理（ghspeedup.com / gh-proxy.com / ghfast.top / 直连）
│   └── 启动时检查更新（默认关闭）
└── 关于
```

## TODO

- [ ] 书签/笔记展示
- [ ] 更丰富的书籍详情（热门划线等）
- [ ] 阅读时间上报手动选择目标书籍时支持搜索
- [x] ~~按需缓存章节，支持一次性缓存多个章节~~（v0.6.0 已支持）
- [x] ~~书架页面支持搜索功能~~（v0.6.0 已支持）

> **v1.1.0 脚注升级提示：**脚注显示方式会写入下载的 EPUB；旧书需要删除后重新下载，才能使用页内脚注。

## 贡献

欢迎提交 issue 和 PR。提交前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

XPointer 外部标注层仍是实验性功能，测试步骤和限制见
[原型说明](docs/xpointer-overlay-prototype.md)。

## 许可证

本项目代码采用 [GNU Affero General Public License v3.0](LICENSE)，SPDX 标识为 `AGPL-3.0-only`，与 KOReader 使用的许可证保持一致。

修改、整合或再分发本项目时，必须遵守 AGPL-3.0，保留版权和许可证声明，并按许可证要求将本项目代码或其衍生作品开源。

`fonts/NotoEmoji-Regular.ttf` 是第三方字体，采用 [SIL Open Font License 1.1](fonts/LICENSE)，不适用本项目的 AGPL-3.0。

Copyright © 2026 finlater and contributors.  
本仓库二次开发部分 Copyright © 2026 rollingshmily and contributors.

## 贡献

- **上游功能 / 通用 Bug**：优先到原作者仓库反馈：https://github.com/finlater/weread.koplugin  
- **本仓库二开改动**（在线更新、代理、Release 流程等）：在本仓库提 issue / PR  

提交前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。
