package.path = "./?.lua;" .. package.path
package.preload["util"] = function()
    return { htmlEntitiesToUtf8 = function(text) return text:gsub("&amp;", "&") end }
end
local Source = require("weread.lib.annotation_source")
local spans = Source.index("\239\187\191<p>甲乙<b>丙</b>&amp;丁</p>")
assert(Source.quote(spans, "3-5") == "甲乙", "rune offsets must not become UTF-8 byte offsets")
assert(Source.quote(spans, "4-9") == "乙丙", "quote failed across tags")
assert(Source.quote(spans, "13-19") == "&丁", "entity did not decode")
assert(Source.quote(spans, "13-15") == "", "partial entity was accepted")
assert(Source.quote(spans, "15-18") == "", "range starting inside an entity was accepted")
assert(Source.quote(Source.plain("甲<&乙"), "1-3") == "<&", "raw TXT offsets were interpreted as HTML")
local scripted = Source.index('<script>x</script><p>abc</p>')
assert(#scripted == 1 and scripted[1][3] == "abc", "script text entered quote source")
print("annotation_source_spec: original rune offsets, UTF-8, tags and entities passed")
