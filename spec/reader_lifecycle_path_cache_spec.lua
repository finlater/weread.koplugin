-- Current-document path detection must use a raw index and then cache the result.

package.path = "./?.lua;" .. package.path

local index_calls = 0

package.preload["weread.lib.content"] = function()
    return {}
end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return {} end }
end
package.preload["weread.lib.protocol"] = function()
    return {}
end
package.preload["ui/uimanager"] = function()
    return {}
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        display_error = tostring,
        file_exists = function() return false end,
        log_error = tostring,
    }
end

local Lifecycle = require("weread.lib.reader_lifecycle")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local host = {
    ui = {
        document = { file = "/books/flat-book.epub" },
    },
    settings = {
        cache_dir = "/books",
        meta_dir = "/meta",
        find_book_id_by_path = function(_self, file)
            index_calls = index_calls + 1
            if file == "/books/flat-book.epub" then
                return "book"
            end
        end,
        get = function(_self, key)
            if key == "books" then
                error("full book store should not be loaded")
            end
            return {}
        end,
    },
}
for key, value in pairs(Lifecycle) do
    host[key] = value
end

expect(host:detectWeReadBook() == "book",
    "raw path index detects the current flat EPUB")
expect(host:detectWeReadBook() == "book",
    "cached path detection returns the current book")
expect(index_calls == 1,
    "the same document path is indexed only once")

print(string.format(
    "reader_lifecycle_path_cache_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
