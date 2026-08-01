package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        reader_url = function(book_id, chapter_uid)
            return "https://weread.qq.com/web/reader/"
                .. tostring(book_id) .. "/" .. tostring(chapter_uid or "")
        end,
    }
end
package.preload["weread.lib.thoughts"] = function() return {} end

local Annotations = require("weread.lib.annotations")
local Content = require("weread.lib.content")

local original = "\xef\xbb\xbf<p>你好世界</p>"
local processed = Annotations.injectUnderlines(original, {
    { range = "3-7" },
}, nil, "chapter", "book")
expect(processed:sub(1, 3) ~= "\xef\xbb\xbf",
    "leading BOM was not removed")
expect(processed:find('<span class="wr%-underline">你好世界</span>') ~= nil,
    "UTF-8 underline range was not injected correctly")
expect(processed:find("<p>", 1, true) and processed:find("</p>", 1, true),
    "underline injection corrupted surrounding HTML")

local thought_html = Annotations.injectUnderlines("<p>hello</p>", {
    { range = "3-8" },
}, { ["3-8"] = true }, "chapter/1", 'book"2')
expect(thought_html:find("wr%-thought%-link") ~= nil
    and thought_html:find("wr%-star") ~= nil,
    "thought link and marker were not generated")
expect(thought_html:find('id="wrthought%-book_2%-chapter_1%-3%-8"') ~= nil,
    "thought anchor id was not sanitized")

local unchanged = Annotations.injectUnderlines("<p>safe</p>", {
    { range = "bad" },
    { range = "999-1000" },
}, nil, "chapter", "book")
expect(unchanged == "<p>safe</p>", "invalid ranges changed the document")

local annotated, css = Annotations.process("<p>hello</p>", {
    chapterUid = "chapter",
    underlines = { { range = "3-8" } },
}, {
    { range = "3-8", pageReviews = { { review = { content = "idea" } } } },
}, "book")
expect(annotated ~= "<p>hello</p>", "annotation process did not change HTML")
expect(css:find(".wr%-underline") and css:find(".wr%-thought%-link"),
    "annotation CSS did not include underline and thought styles")

local xhtml = Content.txt_to_xhtml("first & <tag>\r\n\r\nsecond")
expect(xhtml:find("<p>first &amp; &lt;tag&gt;</p>", 1, true),
    "plain text was not XML-escaped")
expect(xhtml:find("<p>second</p>", 1, true),
    "plain text paragraph conversion lost content")

local rewritten = Content.rewrite_image_sources(
    '<img src="a.jpg"/><image xlink:href="b.png"/>',
    { ["a.jpg"] = "../images/a.jpg", ["b.png"] = "../images/b.png" })
expect(rewritten:find('src="../images/a.jpg"', 1, true),
    "image source was not rewritten")
expect(rewritten:find('xlink:href="b.png"', 1, true),
    "non-src image attribute should be left unchanged")

local body = Content.extract_mp_body(
    '<div id="js_content"><p data-src="x.jpg">article</p>'
        .. '<script>bad()</script></div><script>after()</script>')
expect(body and body:find('src="x.jpg"', 1, true)
    and not body:find("bad()", 1, true),
    "MP article body extraction did not normalize or sanitize content")
expect(Content.extract_mp_body("<html>missing</html>") == nil,
    "missing MP body should return nil")

local stripped = Content.strip_mp_images(
    '<p>before<img src="x"/></p><picture><source src="y"/></picture><p>after</p>')
expect(not stripped:lower():find("<img", 1, true)
    and not stripped:lower():find("<picture", 1, true)
    and stripped:find("before", 1, true) and stripped:find("after", 1, true),
    "MP image stripping removed text or kept media")

local articles = Content.parse_mp_articles({
    reviews = {{
        subReviews = {{
            reviewId = "outer",
            review = {
                reviewId = "inner",
                belongBookId = "book",
                mpInfo = {
                    originalId = "original",
                    title = "Article",
                    content_url = "https://mp.example/article",
                },
            },
        }},
    }},
})
expect(#articles == 1 and articles[1].title == "Article"
    and #articles[1].reviewIds == 3,
    "MP article metadata was not normalized")

print(("content_annotations_spec: %d checks"):format(checks))
