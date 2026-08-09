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

local trailing_whitespace = Annotations.injectUnderlines("<p>abc</p>\n  ", {
    { range = "3-12" },
}, { ["3-12"] = true }, "chapter/11", "book")
expect(trailing_whitespace:find('<span class="wr%-star">%*</span>', 1) ~= nil,
    "thought star survives when range ends with whitespace")
local star_pos = trailing_whitespace:find('<span class="wr%-star">%*</span>', 1)
local p_close_pos = trailing_whitespace:find("</p>", 1, true)
expect(star_pos ~= nil and p_close_pos ~= nil and star_pos < p_close_pos,
    "thought star stays inside the paragraph before trailing whitespace")
expect(trailing_whitespace:find(
        '<span class="wr%-underline">abc<span class="wr%-star">%*</span></span>',
        1) ~= nil,
    "thought star stays inside the final underline span")

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
expect(css:find('wr%-star::before{content:"\\2060";}', 1) ~= nil,
    "thought star CSS includes word joiner glue")

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

local remote_urls = Content.collect_remote_image_urls(
    '<img src="//cdn.example/a.png"/><img src="https://cdn.example/a.png"/>'
        .. '<img src="local.png"/>')
expect(#remote_urls == 1 and remote_urls[1] == "https://cdn.example/a.png",
    "remote image collection did not normalize and deduplicate URLs")
local image_data = "\137PNG\r\n\26\nimage"
local embedded_xhtml, embedded_assets = Content.apply_remote_image_results(
    '<img src="//cdn.example/a.png"/><img src="https://cdn.example/a.png"/>',
    {}, { ["https://cdn.example/a.png"] = image_data })
expect(#embedded_assets == 1
        and embedded_xhtml:find("../images/", 1, true),
    "parallel image results were not rewritten or deduplicated")

local mp_requests = 0
local mp_body = Content.download_mp_images({
    get_binary = function()
        mp_requests = mp_requests + 1
        return image_data
    end,
}, '<img src="//mmbiz.qpic.cn/a.png"/><img src="https://mmbiz.qpic.cn/a.png"/>',
nil, true)
expect(mp_requests == 1 and mp_body:find("data:image/png;base64,", 1, true),
    "public article images were not deduplicated before download")

local complete_source = '<html><body><p>' .. string.rep("文", 300)
    .. '</p></body></html>'
local complete, actual, expected = Content.validate_chapter_source(
    { wordCount = 400 }, complete_source)
expect(complete and actual == 300 and expected == 400,
    "complete chapter source failed validation")
local truncated = Content.validate_chapter_source(
    { wordCount = 4000 }, '<html><body><p>' .. string.rep("文", 100)
        .. '</p></body></html>')
expect(not truncated, "truncated chapter source passed validation")
expect(not Content.validate_chapter_source({ wordCount = 10 }, "fragment"),
    "malformed chapter source passed validation")

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
