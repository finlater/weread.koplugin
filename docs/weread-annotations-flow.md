# 划线与想法：下载 → SQLite → 原生弹框完整链路

本文说明「点击书籍正文里的划线，弹出该处的划线与想法」这一功能的端到端实现原理。

## 一句话原理

**下载时**把划线链接写入 EPUB，并把想法按 `chapter_uid + range + item_index` 存入本书的 `thoughts.db`；**阅读时**拦截划线链接，只查询被点击 range 的几条记录，再用原生位图渲染弹窗展示（短内容收缩、长内容滚动）。

展示阶段完全离线，不读取整章想法、不解析整章 JSON，也不启动 HTML/MuPDF 渲染器。

## 数据流总览

```
微信读书 gateway API
  /book/underlines   → 划线 range[]        ┐
  /book/readreviews  → 想法 reviews[]       ┘
        │ (下载时)
        ▼  Annotations.process
  原始章节 HTML ──► <a href="#wrthought-BOOK-UID-RANGE"><span wr-underline>划线</span></a>
        │                         想法 ──► thoughts.db / review_items
        ▼
   EPUB 文件（划线链接） + SQLite（想法正文）
        │ (阅读时，离线)
        ▼  点击 → 拦截 tap_link → SQLite 索引查询一个 range
   KOReader 原生位图渲染弹窗（短内容收缩 / 长内容滚动；点击弹窗外区域关闭）
```

## 阶段一：下载（Download）

前提：开启「下载划线和想法」（设置项 `cache.download_underlines_and_thoughts`）。在 `weread/lib/downloader.lua` 的每章下载流程中：

1. **拉划线** —— `_startAnnotations` → `Thoughts.fetch_underlines`（`weread/lib/thoughts.lua`）→ `client:get_chapter_underlines`（`weread/lib/client.lua`）→ gateway API **`/book/underlines`**。返回该章所有划线，每条带一个 `range`，如 `"383-415"` —— 这是**原始章节 HTML 的 rune（UTF-8 字符）索引区间**。
2. **分批拉想法** —— 收集所有 range → `build_chapter_review_batches`（`weread/lib/client.lua`，每 5 个 range 一批）→ `_annotationBatch` 逐批 → `get_chapter_reviews_batch` → gateway API **`/book/readreviews`**。返回每个 range 上的想法 `reviews`（含作者、内容、点赞数、引用原文 `abstract`）。批次间 0.3s 间隔 + 失败重试 2 次（防限流）。

## 阶段二：嵌入 EPUB（Process & Save）

`_applyAnnotations` → `Thoughts.apply_data`（`weread/lib/thoughts.lua`）→ **`Annotations.process`**（`weread/lib/annotations.lua`）。这是核心。

> **关键约束**：range 是**原始 HTML 的字符索引**，因此注释注入必须在图片改写等步骤之前完成，否则索引会错位。

### a) 注入下划线 `injectUnderlines`

- 把 HTML 拆成 rune 数组（range 是字符索引，不是字节索引）；range 是 0 索引（JS 惯例）→ +1 转 Lua 1 索引。
- `snapStartToSafeBoundary` / `snapEndToSafeBoundary`：把区间端点从 HTML 标签 / 实体内部挪出来，避免切坏标签。
- `wrapTextSegments`：区间内的**文本段**逐段用 `<span class="wr-underline">` 包裹，遇标签自动断开重开（不跨标签边界）。
- **若这条 range 有想法**：把每个下划线 span 用普通内部链接 `<a class="wr-thought-link" href="#wrthought-BOOK-UID-RANGE">` 包起来，使划线本身可点击（不使用 `epub:type="noteref"`，避免进入 KOReader 内建脚注路径）。

### b) 写入 SQLite

`ThoughtDB.putReviews` 在同一事务中写入 `review_items`。每条想法保存引用原文、作者、正文和点赞数，主键为 `(chapter_uid, range, item_index)`。

### CSS（`Annotations.UNDERLINE_CSS` / `THOUGHT_LINK_CSS`）

- `.wr-underline`：橙色虚线下划线。
- `.wr-thought-link`：保持正文原有文字样式。
处理后的 HTML + 注释 CSS 经 `Thoughts.merge_css` 合并，最终由 `Content.save_book_epub` 打包；想法正文保存在书籍目录的 `thoughts.db`。

## 阶段三：阅读时展示（Display）

### 打开书 `onReaderReady`（`main.lua`）

- 检测是 WeRead 书 → `_setupThoughtInterception`：注册一个**覆盖全屏的 tap 手势区**，`overrides = {"tap_link"}` —— **抢在 KOReader 内建的脚注弹窗（tap_link）之前**接管点击。
- `applyAnnotationVisibility`：按 `show_annotations` 开关，决定是否往排版样式表追加隐藏注释的 CSS —— 这就是「显示 / 隐藏划线」开关的实现。

### 点击划线 `_onThoughtTap`（`main.lua`）

1. `self.ui.link:getLinkFromGes(ges)` 拿到点击处链接。划线由 `<a href="#wrthought-...">` 包裹，因此 KOReader 能直接命中该链接。
2. 从链接解析 `book_id / chapter_uid / range`。
3. 用覆盖索引只查询 `review_items` 中该 range 的记录；结果按 href 做会话内缓存。
4. 若 `show_annotations == false`，让点击继续作为普通翻页手势处理；否则消费点击，并在 `nextTick` 里显示原生弹框。

### 旧缓存自动修复

如果 EPUB 中已有划线链接，但 `review_items` 查不到对应记录，说明书籍可能来自早期 HTML/单章 JSON 缓存。点击拦截同时识别旧版 `#thought_CHAPTER_START_END` 和新版 `#wrthought-BOOK-CHAPTER-START-END`：

- 当前打开的是单章 EPUB：自动重新下载该章全部划线想法并写入 SQLite。
- 当前打开的是合并全文 EPUB：按章节分批重新下载全书想法并重建 `thoughts.db`。

修复沿用每批 5 个 range、批次间隔和失败重试，并提供取消按钮；完成后若用户仍停留在原页，会自动打开刚才点击的想法。

### 原生弹框 `_showThoughtPopup` → `ThoughtPopup.show`

- 先 `highlightXPointer` 高亮被点的划线原文。
- 内容按可见高度动态合并 `pageReview`：短内容把弹窗收缩到内容高度（一页可显示多条），长内容保持设定高度并在弹窗内滚动，单条不跨页截断。
- 内容由 KOReader 原生位图渲染：每条按块用 `TextBoxWidget` 排版后合成到内容位图，再按页切片画入滚动视口；弹窗内点击左 / 右半区翻页，上下滑动滚动，点击弹窗外区域、左右滑动或 Back 键关闭。
- 弹窗位置可选「底部 / 居中」：底部为实线样式底栏（默认）；居中为 TextViewer 风格居中窗口，带标题栏与「上一页 / 下一页」按钮，长内容（含单条长想法）分页显示而非滚动，字号与高度沿用同一组设置。
- 不创建 HTML 文档、不解析 CSS、不初始化 MuPDF；弹窗沿用书籍字体渲染，书籍字体缺失时回退到内置字体。
- 关闭时清掉原文高亮。

### 防错机制 `_reader_session_gen`

每次开 / 关书都 +1，所有异步回调都校验它是否一致 —— 防止翻页或关书后，先前排队的异步浮层错误弹出。

## 涉及文件

| 文件 | 职责 |
|------|------|
| `weread/lib/downloader.lua` | 下载状态机，逐章调用划线/想法抓取与嵌入 |
| `weread/lib/client.lua` | gateway API：`/book/underlines`、`/book/readreviews`，range 分批 |
| `weread/lib/thoughts.lua` | 下载编排、SQLite 写入、CSS 合并 |
| `weread/lib/thought_db.lua` | SQLite schema、事务写入、按 range 索引查询 |
| `weread/lib/annotations.lua` | 注入下划线与普通内部链接 |
| `weread/ui/thought_popup.lua` | 展示：原生位图渲染弹窗（入口），实现见 `weread/ui/thought_popup/` |
| `main.lua` | tap 拦截、SQLite 查询、显隐开关、会话防错 |
