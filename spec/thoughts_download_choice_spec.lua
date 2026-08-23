-- Manual per-download annotation choice must override the prefetch preference.

package.path = "./?.lua;" .. package.path

package.preload["weread.lib.logger"] = function()
    return { info = function() end }
end
package.preload["weread.lib.annotations"] = function()
    return {
        process = function(xhtml)
            return xhtml, ""
        end,
    }
end
package.preload["weread.lib.content"] = function()
    return {
        book_resolved_dir = function() return "/tmp/book" end,
    }
end
local stored_underlines
local open_count, close_count = 0, 0
package.preload["weread.lib.thought_db"] = function()
    return {
        open = function()
            open_count = open_count + 1
            return { id = "db" }
        end,
        putReviews = function() end,
        putUnderlineRanges = function(_db, chapter_uid, ranges)
            stored_underlines = { chapter_uid = chapter_uid, ranges = ranges }
            return true
        end,
        markRangesFetched = function() end,
        remove_db = function() end,
        close = function()
            close_count = close_count + 1
        end,
    }
end

local Thoughts = require("weread.lib.thoughts")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local request_count = 0
local client = {
    get_chapter_underlines = function(_self, _book_id, _chapter_uid)
        request_count = request_count + 1
        return true, { underlines = { { range = "1-2" } } }
    end,
}
local settings = {
    get = function()
        return { download_underlines_and_thoughts = false }
    end,
    is_cookie_configured = function() return true end,
}

local ok, data = Thoughts.fetch_underlines(client, settings, "book", "chapter")
expect(ok and data == nil and request_count == 0,
    "disabled prefetch preference skips annotations by default")

ok, data = Thoughts.fetch_underlines(client, settings, "book", "chapter", true)
expect(ok and data and request_count == 1,
    "explicit per-download choice fetches annotations")

local review_requests = 0
client.get_chapter_reviews = function()
    review_requests = review_requests + 1
    return true, { reviews = { { range = "1-2", pageReviews = {} } } }
end
local apply_settings = {
    get = function()
        return {
            download_underlines_and_thoughts = true,
        }
    end,
    is_cookie_configured = function() return true end,
}
local xhtml, css = Thoughts.apply(client, apply_settings, "book", "chapter", "<p>hi</p>")
expect(review_requests == 0, "content-path apply skips chapter review fetch")
expect(type(xhtml) == "string", "content-path apply still returns html")
expect(css ~= nil, "content-path apply still returns css")
expect(stored_underlines and stored_underlines.ranges
        and stored_underlines.ranges[1] == "1-2",
    "apply_data persists underline ranges without downloading thoughts")
expect(open_count == 1 and close_count == 1,
    "content-path apply opens and closes its own thought db")

local shared = { id = "shared" }
open_count, close_count = 0, 0
stored_underlines = nil
Thoughts.apply_data(apply_settings, "book", 11, "<p>hi</p>", {
    underlines = { { range = "3-4" } },
}, nil, nil, {
    thought_db = shared,
    close_thought_db = false,
})
Thoughts.apply_data(apply_settings, "book", 12, "<p>hi</p>", {
    underlines = { { range = "5-6" } },
}, nil, nil, {
    thought_db = shared,
    close_thought_db = false,
})
expect(open_count == 0 and close_count == 0,
    "shared thought db is not opened or closed per chapter")
expect(stored_underlines and stored_underlines.chapter_uid == 12
        and stored_underlines.ranges[1] == "5-6",
    "shared thought db still receives later chapter underline ranges")

print(string.format(
    "thoughts_download_choice_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
