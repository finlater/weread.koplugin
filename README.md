# WeRead KOReader Plugin

> **免责声明**：本项目仅供个人学习和技术研究使用，不得用于商业用途。使用本项目所产生的一切后果（包括但不限于账号封禁、数据丢失等）由使用者自行承担，项目作者概不负责。请遵守微信读书的用户协议和相关法律法规。

在 KOReader 上阅读微信读书中的书籍、公众号文章的插件。支持同步进度同步，阅读时长同步和统计，查看书评、划线和想法。让Kindle、Kobo等封闭系统设备也能体验微信读书！

## 想要更完整的微信读书体验？试试 WeReader 闭源版

除了本仓库的 **WeRead 开源版**，我也在开发 **WeReader 闭源版**：采用微信读书墨水屏 App 风格的界面，提供书城与推荐、更精确的阅读进度同步、离线阅读上报，以及划线、写想法、评论、点赞等互动功能，适合希望在阅读器上获得更完整微信读书体验的朋友。

**欢迎在小红书观看演示视频，也可以在小红书或闲鱼请作者喝一杯咖啡。** 两个平台的昵称都是 **finlater**，感谢你对个人开发的支持。

| 小红书 · 看演示视频 / 请作者喝咖啡 | 闲鱼 · 请作者喝咖啡 |
|:---:|:---:|
| <a href="screenshots/wereader-xiaohongshu.png"><img src="screenshots/wereader-xiaohongshu.png" alt="finlater 的小红书二维码" width="280"></a> | <a href="screenshots/wereader-xianyu.png"><img src="screenshots/wereader-xianyu.png" alt="finlater 的闲鱼主页二维码" width="280"></a> |
| 小红书昵称：**finlater** | 闲鱼昵称：**finlater** |

<details>
<summary><strong>开源版与闭源版怎么选？点击展开功能对比</strong></summary>

喜欢 KOReader 的原生阅读体验，需要阅读本地书籍或离线查看已缓存的划线和想法，可以选择本仓库的开源版；希望把书城浏览、离线阅读、云端同步，以及划线、写想法、评论、点赞等互动融入日常阅读，可以了解 WeReader 闭源版。

| 功能 | WeRead 开源版（本项目） | WeReader 闭源版 |
|:---|:---|:---|
| 软件界面 | 自制界面，沿用 KOReader 阅读器 | 微信读书墨水屏 App 风格界面 |
| 书城 / 推荐 | 支持搜索书籍，无独立书城 | 支持书城、分类与推荐 |
| 书籍缓存 | 支持章节下载、预下载和全书下载 | 支持章节缓存、全书下载与离线阅读 |
| 阅读进度 | 支持同步，大致进度 | 支持同步，精确进度 |
| 阅读时长 | 支持自动上报、手动选择上报书籍 | 自动记录并上报，离线记录后联网补报 |
| 查看划线和想法 | 需预先拉取与匹配，支持离线查看 | 阅读中加载书友划线和想法，互动需联网 |
| 写划线 / 想法、评论、点赞 | 不支持将 KOReader 本地标注上传到微信读书，也不支持评论、点赞 | 支持创建划线、写想法、评论、点赞并同步云端 |
| 书评 / 热评 | 支持查看书评 | 支持查看书评、想法及评论互动 |
| 书签 / 读完状态同步 | 不支持同步到微信读书；可使用 KOReader 本地书签 | 支持同步到云端 |
| 本地书籍阅读 | 支持；可关联微信读书书目、上报时长、匹配划线和想法 | 以微信读书书架为主，本地文件需先导入微信读书 |
| 公众号文章 | 支持书架中的公众号书籍 | 支持公众号书籍、微信收藏文章和浮窗文章 |
| 阅读辅助 | 沿用 KOReader 的词典、手势、排版等功能 | 联网百科、自动翻页、四角长按快捷操作 |

</details>

### WeReader 闭源版截图

| 书架 | 书城 | 我的 |
|:---:|:---:|:---:|
| ![WeReader 闭源版书架](screenshots/wereader-bookshelf.png) | ![WeReader 闭源版书城](screenshots/wereader-bookstore.png) | ![WeReader 闭源版我的页面](screenshots/wereader-profile.png) |

| 阅读界面 | 划线与写想法 | 书友想法与评论 |
|:---:|:---:|:---:|
| ![WeReader 闭源版阅读界面](screenshots/wereader-reader.png) | ![WeReader 闭源版划线与写想法](screenshots/wereader-highlight.png) | ![WeReader 闭源版书友想法与评论](screenshots/wereader-comments.png) |

WeReader 闭源版不包含微信读书会员或付费书籍；可阅读内容取决于你的微信读书账号权益。**支持 Kindle、Kobo、reMarkable、PocketBook 全机型，运行流畅。**

## 安装

> ⚠️ 建议使用 **KOReader 2026.03 或更高版本**。旧版本可能无法正常加载或使用插件，例如「工具」菜单中找不到「微信读书」。详见 [#14](https://github.com/finlater/weread.koplugin/issues/14)。

1. 前往 [GitHub Releases](https://github.com/finlater/weread.koplugin/releases) 下载最新的 `weread.koplugin-vX.Y.Z.zip` 安装包。
2. 解压安装包，得到 `weread.koplugin` 文件夹。
3. 将该文件夹复制到 KOReader 的 `plugins` 目录：

```
koreader/plugins/weread.koplugin/
```

4. 重启 KOReader，在菜单中找到：

```
工具 → 微信读书
```

后续更新插件可在 **微信读书 → 设置 → 更新管理** 菜单中在线更新。

## 登录与认证

插件只支持微信扫码登录，扫码前需要先为账号开通微信读书 Skill：

1. 手机打开**微信读书 App**。
2. 进入 **我 → 设置 → 微信读书 Skill**。
3. 点击 **获取 API Key**，确认已经生成个人官方 API Key。
4. 在 KOReader 打开 **工具 → 微信读书 → 微信扫码登录**。
5. 使用微信扫码并在手机端确认；若手机显示四位验证码，请在 KOReader 中输入。

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


## SimpleUI / Zen_UI 集成

插件提供统一的“微信读书书架”入口并支持集成到 SimpleUI和 ZenUI的快捷按钮中。(需要安装最新版 [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) 和 [ZenUI](https://github.com/AnthonyGress/zen_ui.koplugin)插件)。

- **SimpleUI**：进入 `快捷操作` 新建操作，类型选择 `插件 → 微信读书`，再把该操作加入底部栏即可。如需使用本项目图标，将 `icons/weread-w-book.svg` 或 `icons/weread-ink.png` 复制到 SimpleUI 的自定义图标目录`koreader/setting/simpleui/sui_icons`后，在快捷操作中选中它。
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
├── 划线和想法管理     （本地书与微信下载书共用；不修改 EPUB/KOReader 笔记）
│   ├── 匹配微信读书书目 / 已关联微信书籍：书名（下载书自动关联）
│   ├── 继续匹配（手动续传、定位；开书仅显示已保存结果）
│   ├── 选择章节匹配（完整本地目录，可手动对应；勾选章节获取最新想法）
│   └── 清理划线和想法（再次匹配时下载最新数据）
├── 书架               单行顶栏：内容与分组 / 搜索 / 获取最新 / 菜单
│   ├── 内容与分组      书籍 / 公众号；书籍内选择微信读书分组，支持离线缓存
│   └── 菜单            排序、筛选、列表 / 封面；列表支持分页 / 连续滚动，分页支持滑动与按钮
├── weread收藏夹        已下载书籍（不包含单章）的本地入口
├── 搜索               搜索微信读书
├── 阅读时间上报        后台上报阅读时长
│   ├── 启用阅读时间上报
│   ├── 仅在阅读时上报
│   ├── 上报间隔
│   │   ├── 30 秒（默认）
│   │   └── 60 秒
│   ├── 选择目标书籍
│   │   ├── 自动关联微信读书书籍
│   │   └── 手动设置上报书籍
│   └── 上报状态
├── 阅读统计            阅读时长/天数/排行/偏好可视化（页内 周/月/年/总 tab 切换，可翻阅历史周期）
├── 设置
│   ├── 书架视图
│   │   ├── 列表模式（默认；适合连续滚动）
│   │   └── 封面模式（按屏幕自适应行列；仅加载当前页封面）
│   ├── 分页书架（仅列表模式；默认开启，关闭后使用连续滚动）
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
│   │   ├── 隐藏脚注文本（默认关闭；开启需同时启用 KOReader 脚注弹框；仅影响新下载书籍）
│   │   └── 章节预下载
│   │       ├── 自动预下载下一章（默认关闭，后台下载）
│   │       ├── 预下载划线和想法（默认关闭；需同时开启总开关，位置匹配仍手动触发）
│   │       └── 显示预下载提示（默认开启，总开关关闭时不可操作）
│   ├── 划线设置
│   │   ├── 划线边缘防误触（默认开启）
│   │   ├── 边缘区域：20%（可调 10%–40%）
│   │   └── 想法弹窗设置
│   │       ├── 位置：居中（可切换为 底部）
│   │       ├── 高度：62%（可调 20%–90%）
│   │       ├── 宽度：80%（仅居中时可用，40%–100%）
│   │       ├── 字体大小（相对文档字号，默认 -2；可切换为绝对字号）
│   │       ├── 字体对比度：默认（可调 -3–+9，最大为纯黑）
│   │       └── 点击左右区域翻页（默认关闭，底部与居中弹窗均生效）
│   │   └── 想法弹窗宽度：80%（仅居中时可用，40%–100%）
│   ├── 账号管理
│   │   ├── 账号状态
│   │   ├── 立即续期 Cookie
│   │   └── 清除账号数据
│   ├── 高级选项
│   │   └── Mock 服务
│   │       ├── 当前生效环境
│   │       ├── 重启后启用 Mock（默认关闭，测试数据独立保存）
│   │       ├── 服务器 IP：192.168.31.111（可修改）
│   │       ├── 服务器端口：8765（可修改）
│   │       └── 测试连接
│   └── 关于
│       ├── 版本 x.y.z
│       ├── 作者：finlater
│       ├── 检查更新
│       ├── 每小时自动检查一次（默认关闭）
│       └── 更新时优先使用代理（默认开启；代理失败会自动回退 GitHub）
```

## 贡献

欢迎提交 issue 和 PR。提交前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

XPointer 外部标注层仍是实验性功能，测试步骤和限制见
[原型说明](docs/xpointer-overlay-prototype.md)。

## 许可证

本项目代码采用 [GNU Affero General Public License v3.0](LICENSE)，SPDX 标识为 `AGPL-3.0-only`，与 KOReader 使用的许可证保持一致。

修改、整合或再分发本项目时，必须遵守 AGPL-3.0，保留版权和许可证声明，并按许可证要求将本项目代码或其衍生作品开源。

`fonts/NotoEmoji-Regular.ttf` 是第三方字体，采用 [SIL Open Font License 1.1](fonts/LICENSE)，不适用本项目的 AGPL-3.0。

Copyright © 2026 finlater and contributors.

## 项目推荐

| 插件 | 简介                                                  |
|------|-----------------------------------------------------|
| [kindlebtcontroller.koplugin](https://github.com/finlater/kindlebtcontroller.koplugin) | 蓝牙手柄/遥控器控制 Kindle —— 翻页、调节亮度、章节跳转等 20+ 操作，按键完全可自定义。 |
| [one.koplugin](https://github.com/finlater/one.koplugin) | 在 KOReader 上离线阅读「ONE · 一个」每日更新：一图、一文、一问答。           |
