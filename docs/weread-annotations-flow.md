# 划线与想法：下载 → 嵌入 → 展示完整链路

本文说明「点击书籍正文里的划线，弹出该处的划线与想法」这一功能的端到端实现原理。

## 一句话原理

**下载时**把微信读书的划线 / 想法转换成 **EPUB 标准脚注结构**（`epub:type="noteref"` 引用链接 + `epub:type="footnote"` 脚注块）直接烧进 EPUB，想法脚注块用 CSS 隐藏；**阅读时**抢在 KOReader 内建脚注弹窗之前拦截点击，从被点节点提取那段隐藏的脚注 HTML，用自定义浮层渲染出来。

核心巧思：**复用 EPUB 原生的 noteref / footnote 机制**承载数据（链接、定位由 CREngine 免费提供），但用 **CSS 隐藏 + 拦截点击 + 自定义浮层**接管展示，从而绕开 KOReader 内建脚注弹窗，并实现划线高亮、字体跟随、显隐开关等原生做不到的效果。展示阶段**完全离线**，不联网。

## 数据流总览

```
微信读书 gateway API
  /book/underlines   → 划线 range[]        ┐
  /book/readreviews  → 想法 reviews[]       ┘
        │ (下载时)
        ▼  Annotations.process
  原始章节 HTML ──► <a noteref href="#thought_UID_RANGE"><span wr-underline>划线</span>*</a>
                   <aside footnote id="thought_UID_RANGE" class="weread-thought">想法…</aside>  (display:none)
        │  save_book_epub
        ▼
   EPUB 文件（划线 + 想法已内嵌）
        │ (阅读时，离线)
        ▼  点击 → 拦截 tap_link → getHTMLFromXPointer 提取隐藏 aside
   ThoughtPopup 底部浮层渲染想法
```

## 阶段一：下载（Download）

前提：开启「下载划线和想法」（设置项 `cache.download_underlines_and_thoughts`）。在 `lib/downloader.lua` 的每章下载流程中：

1. **拉划线** —— `_startAnnotations` → `Thoughts.fetch_underlines`（`lib/thoughts.lua`）→ `client:get_chapter_underlines`（`lib/client.lua`）→ gateway API **`/book/underlines`**。返回该章所有划线，每条带一个 `range`，如 `"383-415"` —— 这是**原始章节 HTML 的 rune（UTF-8 字符）索引区间**。
2. **分批拉想法** —— 收集所有 range → `build_chapter_review_batches`（`lib/client.lua`，每 5 个 range 一批）→ `_annotationBatch` 逐批 → `get_chapter_reviews_batch` → gateway API **`/book/readreviews`**。返回每个 range 上的想法 `reviews`（含作者、内容、点赞数、引用原文 `abstract`）。批次间 0.3s 间隔 + 失败重试 2 次（防限流）。

## 阶段二：嵌入 EPUB（Process & Save）

`_applyAnnotations` → `Thoughts.apply_data`（`lib/thoughts.lua`）→ **`Annotations.process`**（`lib/annotations.lua`）。这是核心。

> **关键约束**：range 是**原始 HTML 的字符索引**，因此注释注入必须在图片改写等步骤之前完成，否则索引会错位。

### a) 注入下划线 `injectUnderlines`

- 把 HTML 拆成 rune 数组（range 是字符索引，不是字节索引）；range 是 0 索引（JS 惯例）→ +1 转 Lua 1 索引。
- `snapStartToSafeBoundary` / `snapEndToSafeBoundary`：把区间端点从 HTML 标签 / 实体内部挪出来，避免切坏标签。
- `wrapTextSegments`：区间内的**文本段**逐段用 `<span class="wr-underline">` 包裹，遇标签自动断开重开（不跨标签边界）。
- **若这条 range 有想法**：在最后一个下划线 span 末尾加 `<span class="wr-star">*</span>`（灰色星号上标），并把每个下划线 span 用 `<a epub:type="noteref" class="wr-thought-link" href="#thought_<chapterUid>_<range>">` 包起来 —— 即 EPUB 标准脚注引用链接（逐 span 包裹是为了避免块级边界导致 MuPDF 截断链接）。

### b) 生成脚注块 `buildThoughtAsides`

把想法内容拼成 `<aside epub:type="footnote" id="thought_<uid>_<range>" class="footnote weread-thought">`（含引用原文、作者 + 点赞、正文），注入到 `</body>` 之前。

### CSS（`Annotations.UNDERLINE_CSS` / `THOUGHT_CSS`）

- `.wr-underline`：橙色虚线下划线。
- `.wr-star`：灰色小星号上标。
- **`.weread-thought{display:none}`**：想法脚注块在正文里**隐藏**，正常阅读看不到。

处理后的 HTML + 注释 CSS 经 `Thoughts.merge_css` 合并，最终由 `Content.save_book_epub` 打包。想法同时另存一份 `thoughts/<chapter_uid>.json` 缓存（`Thoughts.save_cache`）。**至此，划线和想法已固化在 EPUB 文件内。**

## 阶段三：阅读时展示（Display）

### 打开书 `onReaderReady`（`main.lua`）

- 检测是 WeRead 书 → `_setupThoughtInterception`：注册一个**覆盖全屏的 tap 手势区**，`overrides = {"tap_link"}` —— **抢在 KOReader 内建的脚注弹窗（tap_link）之前**接管点击。
- `applyAnnotationVisibility`：按 `show_annotations` 开关，决定是否往排版样式表追加隐藏注释的 CSS —— 这就是「显示 / 隐藏划线」开关的实现。
- **预热** `ThoughtPopup.prewarm`（`ui/thought_popup.lua`）：用占位 HTML 提前创建一次渲染 widget，把 MuPDF 引擎 / 字体 / CSS 缓存热起来，让首次点击不卡。

### 点击划线 `_onThoughtTap`（`main.lua`）

1. `self.ui.link:getLinkFromGes(ges)` 拿到点击处链接 —— 因为划线被 `<a href="#thought_...">` 包裹，KOReader 把它当作 link，返回 `link.xpointer`（指向目标 aside 节点）。
2. `getHTMLFromXPointer(link.xpointer, 0x1001, false)` 提取**那一个 aside 节点**的 HTML。第三参数 `false` 很关键：不扩展到父节点，否则会把整个 footnotes section（上百条脚注）全拉出来，MuPDF 会卡死。结果按 `xpointer` 缓存。
3. 校验提取的 HTML 含 `weread-thought` 标记。
4. 若 `show_annotations == false`：只 `return true` **吃掉这次点击**（阻止内建脚注弹窗弹出），但不显示自己的浮层。
5. 否则 `return true` 消费点击，`nextTick` 里调 `_showThoughtPopup`。

### 渲染浮层 `_showThoughtPopup` → `ThoughtPopup.show`

- 先 `highlightXPointer` 高亮被点的划线原文。
- 把提取的 aside HTML 交给 `ScrollHtmlWidget`（内部 MuPDF/CRE 渲染 xhtml 片段），渲成**底部浮层**（默认屏高 35%，按内容自适应）。
- 浮层自带 CSS 把 `.weread-thought` 重新设为**可见**（浮层是独立文档，不继承正文那条隐藏 CSS），并配字体 fallback 链（书籍字体 → Noto Sans → emoji）。
- **单例池** `_pooled_popup`：第二次点击直接 `_reopen` 换内容重排，不重建 widget，更快。
- 点空白 / 左右下滑关闭；关闭时清掉原文高亮。

### 防错机制 `_reader_session_gen`

每次开 / 关书都 +1，所有异步回调都校验它是否一致 —— 防止翻页或关书后，先前排队的异步浮层错误弹出。

## 涉及文件

| 文件 | 职责 |
|------|------|
| `lib/downloader.lua` | 下载状态机，逐章调用划线/想法抓取与嵌入 |
| `lib/client.lua` | gateway API：`/book/underlines`、`/book/readreviews`，range 分批 |
| `lib/thoughts.lua` | 下载编排、想法 JSON 缓存、CSS 合并 |
| `lib/annotations.lua` | 核心：把划线/想法注入 HTML（下划线 span + noteref 链接 + footnote aside） |
| `ui/thought_popup.lua` | 展示：ScrollHtmlWidget 底部浮层、字体预热、单例复用 |
| `main.lua` | tap 拦截、xpointer 提取、显隐开关、会话防错 |
