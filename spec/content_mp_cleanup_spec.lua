-- WeChat (公众号) article HTML cleanup specs.
-- Verifies strip_mp_reader_font_styles + strip_blank_mp_blocks through
-- Content.save_mp_article_html against a WeChat-editor-style raw article.
-- Run with: luajit spec/content_mp_cleanup_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return { mp_reader_url = function() return "https://weread.qq.com/" end }
end
package.preload["weread.lib.thoughts"] = function() return {} end

local Content = require("weread.lib.content")

local raw = [[
<h1 data-pm-slice="0 0 []">“人工智能是年轻的事业，这个判断不会错”</h1>
<h1 data-pm-slice="0 0 []"></h1>
<section style="margin: 0px 16px; letter-spacing: 0.578px;">
  <p style="margin: 0px; text-indent: 2em;">7月31日，21名平均年龄仅14岁的少年齐聚深圳。</p>
  <p style="margin: 0px 8px; letter-spacing: 1px; font-size: 17px; -webkit-text-stroke-width: 0px;">正文第二段<span style="color: rgb(51, 51, 51);">带内联颜色</span>继续。</p>
  <h2 style="font-size: 1.38em; letter-spacing: 1px;">小标题</h2>
  <p style="margin: 0px; text-align: justify; white-space: pre-wrap;">引用段落文字。</p>
  <section style="margin: 40px 16px; height: 120px; display: flex; justify-content: center; align-items: center; box-sizing: border-box;">
    <img src="https://example.com/a.jpg" style="width: 100%; height: auto; border-radius: 8px; border: 1px solid rgb(229, 229, 229);"/>
  </section>
  <blockquote data-mpa-template="t" style="margin: 0px 8px; padding: 8px; border-left: 4px solid rgb(221, 221, 221); background-color: rgb(247, 247, 247);">
    <p style="margin: 0px; text-indent: 2em;">引用内容，不该被撑成整页。</p>
  </blockquote>
  <p data-mpa-action-id="a1b2" style="margin: 0px; overflow-wrap: break-word; word-break: break-all; -webkit-tap-highlight-color: rgba(0,0,0,0);">结尾段，带各种杂七杂八的样式。</p>
</section>
]]

local settings = { meta_dir = "/tmp/weread-mp-spec-meta" }
local book = { book_id = "MP_X", title = "测试公众号" }
local article = { title = "测试文章" }

local path = Content.save_mp_article_html(settings, book, article, raw)
local f = assert(io.open(path, "rb"), "saved article not found")
local out = f:read("*a")
f:close()

local body = out:match("<body>(.*)</body>") or out

local function count(s, pat)
    local n = 0
    for _ in s:gmatch(pat) do n = n + 1 end
    return n
end

expect(count(body, "<h1>") == 1, "must keep exactly the plugin-written <h1>")
expect(count(body, "<h[2-6][ >]") == 0, "no h2-h6 should survive")
expect(count(body, "<h[1-6][^>]*></h[1-6]>") == 0, "empty headings must be dropped")
expect(count(body, "<[sS][eE][cC][tT][iI][oO][nN]") == 0, "section must become div")
expect(count(body, "data%-pm%-slice") == 0, "data-pm-slice must be stripped")
expect(count(body, "data%-mpa") == 0, "data-mpa-* must be stripped")
expect(count(body, "letter%-spacing") == 0, "letter-spacing must be stripped")
expect(count(body, "%-webkit%-") == 0, "vendor-prefixed props must be stripped")
expect(count(body, "text%-indent") == 0, "text-indent must be stripped")
expect(count(body, "display:%s*flex") == 0, "flex display must be stripped")
expect(count(body, "border%-left") == 0, "border direction shorthands must be stripped")
expect(count(body, "<img") == 1, "image must be kept")
expect(count(body, "<blockquote") == 1, "blockquote must be kept")
expect(count(body, "7月31日，21名平均年龄仅14岁的少年齐聚深圳") == 1, "lead paragraph text lost")
expect(count(body, "小标题") == 1, "in-body heading text lost")
expect(count(body, "“人工智能是年轻的事业，这个判断不会错”") == 1, "h1 lead text lost")
expect(count(body, "引用内容，不该被撑成整页") == 1, "blockquote text lost")
expect(count(body, "结尾段，带各种杂七杂八的样式") == 1, "trailing paragraph text lost")

print(string.format("content_mp_cleanup_spec: %d checks, 0 failure(s)", checks))
