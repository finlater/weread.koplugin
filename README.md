# WeRead KOReader Plugin

> **免责声明**：本项目仅供个人学习和技术研究使用，不得用于商业用途。使用本项目所产生的一切后果（包括但不限于账号封禁、数据丢失等）由使用者自行承担，项目作者概不负责。请遵守微信读书的用户协议和相关法律法规。

在 KOReader 上阅读微信读书书籍和公众号文章、同步阅读时长的插件。

## 功能

**书籍**

- 浏览微信读书书架，搜索书籍
- 下载单章或整本书为 EPUB，直接在 KOReader 中阅读
- 章节内容解码、CSS 样式、图片资源打包
- 自动生成目录（TOC），自动嵌入封面
- 下载并嵌入划线和想法，阅读时可一键显示/隐藏，点击划线查看想法内容

**公众号**

- 浏览已关注的公众号列表
- 下载公众号文章为 HTML（图片内嵌 base64，KOReader 可自由调节字体大小）
- 文章列表本地缓存，无需重复请求

**阅读时间上报**

- 后台自动向微信读书上报阅读时长（默认每 30 秒一次）
- 支持两种目标书籍模式：
  - **自动关联**：打开微信读书缓存书籍时自动上报该书，关闭时自动停止
  - **手动设置**：从书架选择一本固定书籍作为上报对象
- 支持「仅在阅读时上报」或「KOReader 启动即上报」两种触发模式
- 上报状态可在菜单中查看（已上报次数、最近上报时间、错误信息）

**书籍管理**

- 书架支持多种排序方式（最后阅读时间、书名、默认顺序）与筛选（已读完/未读完、已下载/未下载，两组可组合）
- 书籍详情页展示作者、出版社、评分、字数、阅读进度等信息
- EPUB 自动嵌入封面图片
- 缓存管理：查看/清理单本或全部缓存
- 自定义下载目录：可指定书籍/文章的保存位置（默认 `<KOReader 数据目录>/weread/cache`）

## TODO

- [ ] 阅读进度双向同步（KOReader 位置 ↔ 微信读书进度映射）
- [ ] 当前书籍详情页（阅读中展示微信读书元数据）
- [ ] 独立的标注/笔记浏览界面（书签、热门划线聚合查看；阅读时查看划线和想法已支持，见「功能 → 书籍」）

## 安装

> ⚠️ 请使用**较新版本**的 KOReader，过旧的版本可能导致插件无法加载或启动失败（表现为「工具」菜单下找不到「微信读书」）。已知 `2024.11` 会出问题，`2026.3` 可正常使用；建议升级到最新版。详见 [#14](https://github.com/QiuYukang/weread.koplugin/issues/14)。

将插件目录复制到 KOReader 的 plugins 目录：

```
koreader/plugins/weread.koplugin/
```

重启 KOReader，在菜单中找到：

```
工具 → 微信读书
```

## 配置

所有配置通过 `config.lua` 文件完成。首次使用：

```bash
cp config.example.lua config.lua
```

在电脑上编辑 `config.lua`，然后将整个插件目录同步到设备。

插件启动时自动加载 `config.lua`，也可以在运行时通过 `设置 → 重新加载 config.lua` 热加载。

### 获取 API Key

API Key 用于浏览书架、搜索书籍、读取进度。

1. 手机打开**微信读书 App**
2. 点击底部 **我** 标签
3. 进入 **设置**
4. 找到 **微信读书SKILL** **获取API Key** 并复制

```lua
api_key = "wrk-xxxxxxxxxxxxxxxxxxxxxxxx",
```

### 获取书籍 cURL（cookie + 上报 payload）

`curl` 字段用于提取登录 cookie 和阅读上报所需的 payload 字段。

1. 电脑浏览器打开 [weread.qq.com](https://weread.qq.com)
2. 登录你的微信读书账号
3. 打开**任意一本书**的阅读页面
4. 按 **F12** 打开开发者工具，切换到 **Network（网络）** 标签
5. 在网络请求列表中找到 `read` 请求（URL 包含 `/web/book/read`）
6. 右键该请求 → **Copy as cURL (bash)**
7. 粘贴到 `config.lua` 的 `curl` 字段

```lua
curl = [[
curl 'https://weread.qq.com/web/book/read' \
  -H 'accept: ...' \
  -b '...' \
  --data-raw '{...}'
]],
```

> 如果找不到 `/web/book/read` 请求，在阅读页面等待 30 秒左右，它会自动发送阅读时长上报请求。

### 获取公众号 cURL（x-wrpa-0 验证头）

`mp_curl` 字段用于获取公众号文章列表所需的验证头。

1. 电脑浏览器打开 [weread.qq.com](https://weread.qq.com)
2. 进入**任意一个公众号**的文章列表页面
3. **F12** → **Network**
4. 找到 `articles` 请求（URL 包含 `/web/mp/articles`）
5. 右键 → **Copy as cURL (bash)**
6. 粘贴到 `config.lua` 的 `mp_curl` 字段

```lua
mp_curl = [[
curl 'https://weread.qq.com/web/mp/articles?bookId=...' \
  -H 'accept: ...' \
  -b '...' \
  -H 'x-wrpa-0: ...'
]],
```

> `mp_curl` 里包含的 cookie 如果比 `curl` 里的更新，插件会自动使用更新的版本。

### 配置项一览

| 字段 | 用途 | 必填 |
|------|------|------|
| `api_key` | 书架、搜索、进度同步 | 推荐 |
| `curl` | 登录 cookie + 阅读上报 payload | 推荐 |
| `mp_curl` | 公众号文章列表（x-wrpa-0） | 读公众号时需要 |
| `cookie` | 备选，仅在 curl 为空时使用 | 可选 |
| `sync` | 进度同步行为 | 可选 |
| `cache` | 图片/划线想法下载、缓存大小限制 | 可选 |
| `read_report` | 阅读时间上报间隔 | 可选 |

### Cookie 过期

微信读书的 cookie 会定期过期。插件会尝试自动续期，但如果续期失败：

1. 重新在浏览器中登录 weread.qq.com
2. 重新复制 cURL 到 `config.lua`
3. 在 KOReader 中：`设置 → 重新加载 config.lua`

## 菜单结构

```
微信读书
├── 同步进度           （阅读书籍时显示，开发中）
├── 书籍详情           （阅读书籍时显示，开发中）
├── 显示划线和想法     （阅读书籍时显示，开关，控制已下载书籍划线和想法的显隐）
├── 书架               书架浏览（书籍 + 公众号分类）
├── 搜索               搜索微信读书
├── 阅读时间上报        后台上报阅读时长
│   ├── 启用阅读时间上报
│   ├── 仅在阅读时上报
│   ├── 选择目标书籍
│   │   ├── 自动关联微信读书书籍
│   │   └── 手动设置上报书籍
│   └── 上报状态
├── 设置
│   ├── 缓存管理
│   │   ├── 缓存清理
│   │   └── 缓存目录
│   ├── 重新加载 config.lua
│   ├── 立即续期 Cookie
│   ├── 进度管理
│   │   ├── 打开时拉取进度（暂不可用）
│   │   └── 关闭时上传进度（暂不可用）
│   ├── 下载内容
│   │   ├── 书籍图片（默认开启）
│   │   ├── 公众号文章图片（默认关闭）
│   │   └── 划线和想法（默认关闭）
│   └── 账号管理
│       ├── 账号状态
│       └── 清除账号数据
└── 关于
```

## 文件结构

```
weread.koplugin/
├── _meta.lua              插件元数据
├── main.lua               入口、UI、业务逻辑
├── config.example.lua     配置模板
├── config.lua             用户配置（git 忽略）
├── CLAUDE.md              开发规范
├── lib/
│   ├── client.lua          HTTP 客户端
│   ├── content.lua         内容解码、EPUB/HTML 生成
│   ├── cookie.lua          Cookie 解析
│   ├── crypto.lua          SHA-256、MD5
│   ├── download_dialog.lua 下载进度对话框
│   ├── i18n.lua            中文翻译
│   ├── settings.lua        设置持久化
│   └── weread.lua          微信读书协议工具
├── scripts/
│   ├── fetch_weread_epub.py     EPUB 生成参考脚本
│   └── verify_mp_articles.py    公众号 API 验证脚本
└── docs/
    ├── weread-api-reference.md      API 接口参考
    └── weread-content-research.md   内容解码研究
```

