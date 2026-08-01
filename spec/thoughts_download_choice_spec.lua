-- Manual per-download annotation choice must override the prefetch preference.

package.path = "./?.lua;" .. package.path

package.preload["weread.lib.logger"] = function()
    return { info = function() end }
end
package.preload["weread.lib.annotations"] = function()
    return {}
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

print(string.format(
    "thoughts_download_choice_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
