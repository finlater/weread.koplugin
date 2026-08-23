# 划线与想法：下载 → SQLite → 原生弹框完整链路

本文说明「点击书籍正文里的划线，弹出该处的划线与想法」这一功能的端到端实现原理。

## 一句话原理

**下载时**把每条划线做成可点击链接写入 EPUB。想法可以：

- **按需加载**（默认下载选项）：下载只嵌入划线，点划线再拉这一条 range 的想法；
- **随书下载**：下载阶段按批拉取本章全部想法并写入 `thoughts.db`。

**阅读时**拦截划线链接，按 `chapter_uid + range` 查 SQLite（或现场补拉），再用 KOReader 原生 `TextViewer` 展示。

展示阶段不解析整章 JSON，也不启动 HTML/MuPDF 渲染器。

## 数据流总览

```
微信读书 gateway API
  /book/underlines   → 划线 range[]
  /book/readreviews  → 想法 reviews[]   （按需：点击/当前页预取；随书：下载时整章分批）
        │
        ▼  Annotations.process
  原始章节 HTML ──► <a href="#wrthought-BOOK-UID-RANGE"><span wr-underline>划线</span></a>
        │            想法 ──► thoughts.db / review_items
        │            已查询过的 range（含空结果）──► thoughts.db / fetched_ranges
        ▼
   EPUB 文件（划线链接） + SQLite（想法正文 + 负缓存）
        │ (阅读时)
        ▼  点击 → 拦截 tap_link → SQLite 查 range
           未查过则单 range 在线补拉，并从该位置往后静默预取（本章结束且连续阅读时再接一章）
   KOReader 原生 TextViewer（上一页 / 关闭 / 下一页）
```

## 阶段一：下载（Download）

每次手动下载都会弹出三项选择，**没有全局设置项**：

1. 仅下载正文
2. 下载并嵌入划线（想法按需加载）
3. 下载正文、划线和想法（随书批量拉想法，更慢）

章节预下载若开启「预下载划线和想法」，按按需模式只嵌入划线，不在后台整章拉想法。

在 `weread/lib/downloader.lua` 的每章下载流程中：

1. **拉划线** —— `_startAnnotations` → `Thoughts.fetch_underlines`（`weread/lib/thoughts.lua`）→ `client:get_chapter_underlines` → gateway **`/book/underlines`**。返回该章所有划线，每条带一个 `range`，如 `"383-415"` —— 这是**原始章节 HTML 的 rune（UTF-8 字符）索引区间**。
2. **想法**
   - 按需：不组 review batch，直接进入嵌入。
   - 随书：`build_chapter_review_batches`（每 5 个 range 一批）→ `_annotationBatch` → `get_chapter_reviews_batch` → **`/book/readreviews`**。批次间 0.3s 间隔 + 失败重试 2 次。成功批次里的 range（含空结果）记入 `checked_ranges`，写入 `fetched_ranges`，避免以后再打。

## 阶段二：嵌入 EPUB（Process & Save）

`_applyAnnotations` → `Thoughts.apply_data` → **`Annotations.process`**。

> **关键约束**：range 是**原始 HTML 的字符索引**，因此注释注入必须在图片改写等步骤之前完成，否则索引会错位。

### a) 注入下划线 `injectUnderlines`

- 把 HTML 拆成 rune 数组（range 是字符索引，不是字节索引）；range 是 0 索引（JS 惯例）→ +1 转 Lua 1 索引。
- `snapStartToSafeBoundary` / `snapEndToSafeBoundary`：把区间端点从 HTML 标签 / 实体内部挪出来，避免切坏标签。
- `wrapTextSegments`：区间内的**文本段**逐段用 `<span class="wr-underline">` 包裹，遇标签自动断开重开（不跨标签边界）。
- **每条划线**都包上内部链接 `<a class="wr-thought-link" href="#wrthought-BOOK-UID-RANGE">`（不使用 `epub:type="noteref"`，避免进入 KOReader 内建脚注路径），以便按需点击补拉。划线本身可点，不另加星号。

### b) 写入 SQLite

- `review_items`：每条想法一行，主键 `(chapter_uid, range, item_index)`。
- `fetched_ranges`：已经向服务端查询过的 range。空结果也会写入，作为负缓存。
- 按需单 range 写入用 `ThoughtDB.putReviewRanges`，不会清掉同章其它 range。
- 随书整章写入用 `ThoughtDB.putReviews`，并标记本批成功查询过的全部 range。

### CSS（`Annotations.UNDERLINE_CSS` / `THOUGHT_LINK_CSS`）

- `.wr-underline`：橙色虚线下划线。
- `.wr-thought-link`：保持正文原有文字样式。

处理后的 HTML + 注释 CSS 经 `Thoughts.merge_css` 合并，最终由 `Content.save_book_epub` 打包；想法正文保存在书籍目录的 `thoughts.db`。

## 阶段三：阅读时展示（Display）

### 打开书 `onReaderReady`

- 检测是 WeRead 书 → `_setupThoughtInterception`：注册覆盖全屏的 tap 手势区，`overrides = {"tap_link"}`。
- `applyAnnotationVisibility`：按 `show_annotations` 决定是否隐藏划线样式。

### 点击划线 `_onThoughtTap`（`weread/ui/annotations_controller.lua`）

1. `self.ui.link:getLinkFromGes(ges)` 拿到点击处链接。
2. 从链接解析 `book_id / chapter_uid / range`。
3. 查 `review_items`；若 `fetched_ranges` 已记录且没有正文，视为「这条没有想法」，不再请求。
4. 未查过则只拉当前 range（超时 6s，最多 3 次），写入 SQLite 后弹框。
5. 成功或确认空结果后，以这条划线为**向前光标**静默预取：
   - 只下本章里起点更靠后、且尚未写入 `fetched_ranges` 的 range。
   - 光标前面的不下；中途再点更后面的想法，光标前移，中间已下的跳过，还没下的丢掉。
   - range 从当前打开的 EPUB 里收集本章锚点（不依赖后面几页是否已排版），不打 `/book/underlines`。弹窗关闭后再开始静默预取，避免关弹窗时被网络请求卡住。
   - 每批最多 5 条。
   - 本章尾巴下完、且仍在往前读（没跳到别的章、没明显往回翻）时，**只再接一章**：全书 EPUB 继续扫文档，单章则解析已缓存的下一章 EPUB。没有本地划线就停。再下一章要等用户读进去或再点划线。

### 原生弹框 `_showThoughtPopup` → `ThoughtPopup.show`

- 使用 KOReader 原生文字布局按可见高度动态合并 `pageReview`。
- 底部提供“上一页 / 当前已显示条数÷总条数 / 下一页”，关闭使用标题栏右上角 X。
- 不额外高亮原文（弹窗会挡住划线）。关闭后开始静默预取。

### 防错机制 `_reader_session_gen`

每次开 / 关书都 +1，所有异步回调都校验它是否一致 —— 防止翻页或关书后，先前排队的异步浮层错误弹出。

## 涉及文件

| 文件 | 职责 |
|------|------|
| `weread/lib/downloader.lua` | 下载状态机；按需跳过想法批次，随书分批拉取 |
| `weread/lib/client.lua` | gateway API：`/book/underlines`、`/book/readreviews`，range 分批 |
| `weread/lib/thoughts.lua` | 划线嵌入编排、SQLite 写入、CSS 合并 |
| `weread/lib/thought_db.lua` | `review_items` / `fetched_ranges`、按 range 查询与负缓存 |
| `weread/lib/annotations.lua` | 注入下划线链接 |
| `weread/ui/annotations_controller.lua` | tap 拦截、按需补拉、当前页静默预取 |
| `weread/ui/thought_popup.lua` | 展示：原生 TextViewer、上一页/下一页导航 |
| `weread/ui/library.lua` | 每次下载时的三项选择 |
