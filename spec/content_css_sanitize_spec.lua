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
        dbg = function() end,
    }
end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function() return {} end
package.preload["weread.lib.thoughts"] = function() return {} end

local Content = require("weread/lib/content")

-- The hostile rule observed in real WeRead e_2 shards: crengine honors the
-- root-element zero sizing and p{font-size:1rem} then collapses the whole book.
local hostile = "html,\nbody {\n  margin: 0;\n  padding: 0;\n  font-size: 0;\n  }"
local cleaned, count = Content.sanitize_book_css(hostile)
expect(count == 1, "the single font-size:0 declaration must be reported as one removal")
expect(not cleaned:find("font%-size"), "font-size:0 declaration survived sanitization")
expect(cleaned:find("{", 1, true) and cleaned:find("}", 1, true),
    "sanitization must keep the rule braces intact")
expect(cleaned:find("margin: 0;", 1, true) and cleaned:find("padding: 0;", 1, true),
    "sibling margin/padding declarations must survive sanitization")

-- Review: `font-size: 0` can be intentional outside the root elements (e.g.
-- hiding whitespace between inline-block items), so only rules whose selector
-- list names exactly html/body may be touched.
cleaned, count = Content.sanitize_book_css(".a{font-size: 0 !important;color:red}")
expect(count == 0 and cleaned == ".a{font-size: 0 !important;color:red}",
    "a non-root selector had its intentional font-size:0 removed")

cleaned, count = Content.sanitize_book_css(".slide-nav { font-size: 0 }")
expect(count == 0 and cleaned == ".slide-nav { font-size: 0 }",
    "an inline-block whitespace trick on a class selector was stripped")

cleaned, count = Content.sanitize_book_css("body p{font-size:0}")
expect(count == 0 and cleaned == "body p{font-size:0}",
    "a descendant-of-body selector was treated as the root element")

cleaned, count = Content.sanitize_book_css("body,.wrapper{font-size:0}")
expect(count == 0 and cleaned == "body,.wrapper{font-size:0}",
    "a selector list mixing body with other targets was treated as root-only")

cleaned, count = Content.sanitize_book_css("HTML ,\nBODY { font-size: 0 }")
expect(count == 1 and not cleaned:find("font%-size"),
    "root selector matching must be case- and whitespace-insensitive")

-- Deliberate limits: :root and @media-wrapped root rules stay untouched.
cleaned, count = Content.sanitize_book_css(":root{font-size:0}")
expect(count == 0 and cleaned == ":root{font-size:0}",
    ":root sizing was stripped although only html/body rules are covered")

local media_css = "@media print { html, body { font-size: 0 } }"
cleaned, count = Content.sanitize_book_css(media_css)
expect(count == 0 and cleaned == media_css,
    "@media-wrapped root sizing was stripped although only top-level rules are covered")

-- An at-rule before the selector must not prevent matching the rule itself.
cleaned, count = Content.sanitize_book_css('@charset "utf-8";html,body{font-size:0}')
expect(count == 1 and not cleaned:find("font%-size"),
    "a preceding at-rule broke root-selector matching")

cleaned, count = Content.sanitize_book_css("html{font-size: 0px}body{font-size: 0%;}")
expect(count == 2 and not cleaned:find("font%-size"),
    "zero font-size with px/% units was not fully removed on root selectors")

cleaned, count = Content.sanitize_book_css(".fs05 { font-size: 0.5rem; }")
expect(count == 0 and cleaned == ".fs05 { font-size: 0.5rem; }",
    "fractional font-size must stay untouched")

cleaned, count = Content.sanitize_book_css("html, body { font-size: 0.5rem; }")
expect(count == 0 and cleaned == "html, body { font-size: 0.5rem; }",
    "fractional root font-size must stay untouched")

cleaned, count = Content.sanitize_book_css("p { font-size: 1rem; }")
expect(count == 0 and cleaned == "p { font-size: 1rem; }",
    "non-zero font-size must stay untouched")

cleaned, count = Content.sanitize_book_css("{ color: #000; font-size: 0\n}")
expect(count == 0 and cleaned:find("font-size: 0", 1, true),
    "a block without a selector must be left untouched")

local passthrough, passthrough_count = Content.sanitize_book_css(nil)
expect(passthrough == nil and passthrough_count == 0,
    "nil input must pass through unchanged with count 0")
passthrough, passthrough_count = Content.sanitize_book_css("")
expect(passthrough == "" and passthrough_count == 0,
    "empty input must pass through unchanged with count 0")

-- Integration-style: sanitizing an already-sanitized shard changes nothing.
-- Only the root rule qualifies; the other blocks keep their declarations.
local combined = table.concat({
    hostile,
    ".a{font-size: 0 !important;color:red}",
    "p{font-size: 0px}h1{font-size: 0%;}",
    "{ color: #000; font-size: 0\n}",
}, "\n")
local once, first_count = Content.sanitize_book_css(combined)
local twice, second_count = Content.sanitize_book_css(once)
expect(first_count == 1, "combined shard should lose only the root font-size declaration")
expect(second_count == 0 and twice == once, "sanitization must be idempotent")

-- Adjacent zero declarations: each pass consumes one boundary character, so
-- the sanitizer must iterate to a fixpoint instead of keeping the second one.
cleaned, count = Content.sanitize_book_css("html,body{font-size:0;font-size:0}")
expect(count == 2, "adjacent zero declarations must both be removed")
expect(not cleaned:find("font%-size"), "adjacent removal left a hostile declaration behind")
expect(cleaned:find("^html,body%{.*%}$"), "block structure was damaged by adjacent removal")

cleaned, count = Content.sanitize_book_css("html,body{font-size:0 ;font-size:0 ;color:red}")
expect(count == 2 and cleaned:find("color:red", 1, true),
    "spaced adjacent zeros must be removed while siblings survive")

cleaned, count = Content.sanitize_book_css("html,body{font-size:0vh}")
expect(count == 1 and not cleaned:find("font%-size"),
    "zero with any letter unit (0vh) is a zero length and must be removed")

-- A CSS comment carrying the exact declaration may lose its interior, but the
-- stylesheet structure around it must survive and the result stays idempotent.
local commented = "body{ /* font-size: 0 ; old */ color:blue }"
cleaned, count = Content.sanitize_book_css(commented)
local open_braces = select(2, cleaned:gsub("%{", ""))
local close_braces = select(2, cleaned:gsub("}", ""))
expect(count == 1 and cleaned:find("color:blue", 1, true) and open_braces == close_braces,
    "comment rewrite must keep the block structurally valid")
local _, recount = Content.sanitize_book_css(cleaned)
expect(recount == 0, "sanitization after comment rewrite must be idempotent")

print(("content_css_sanitize_spec: %d checks"):format(checks))
