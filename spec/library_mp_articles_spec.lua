-- MP article list caching: the article list lives in a dedicated sidecar
-- JSON file so the settings "books" record stays thin. KOReader flushes
-- settings synchronously on document close, so a large inline article list
-- made closing a book/article sluggish. This spec locks the new file-backed
-- format plus legacy inline fallback.

package.path = "./?.lua;" .. package.path

local function empty_module() return {} end
package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weread.ui.book_reviews_view"] = empty_module
package.preload["ui/widget/buttondialog"] = empty_module
package.preload["ui/widget/confirmbox"] = empty_module
package.preload["ui/widget/infomessage"] = empty_module
package.preload["ui/widget/inputdialog"] = empty_module
package.preload["ui/widget/progressbardialog"] = empty_module
package.preload["ui/widget/textviewer"] = empty_module
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) callback() end,
        close = function() end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...) return text end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function(path)
            local file = io.open(path, "rb")
            if not file then return false end
            file:close()
            return true
        end,
    }
end
package.preload["weread.lib.content"] = function()
    return {
        parse_mp_articles = function(data) return data end,
        book_meta_dir = function(settings, book_id)
            return (settings.meta_dir or "/tmp/weread-meta") .. "/" .. tostring(book_id)
        end,
        ensure_book_meta_dir = function(settings, book_id)
            local dir = (settings.meta_dir or "/tmp/weread-meta") .. "/" .. tostring(book_id)
            os.execute("mkdir -p " .. string.format("%q", dir))
            return dir
        end,
    }
end

-- Minimal JSON fixture so the sidecar round-trip can be exercised without a
-- real cjson in the bare spec environment.
package.preload["json"] = function()
    return {
        encode = function(root_value)
            local function encode_value(v)
                if type(v) == "table" then
                    local parts = {}
                    local is_array = true
                    for key in pairs(v) do
                        if type(key) ~= "number" then is_array = false break end
                    end
                    if is_array then
                        for i = 1, #v do
                            parts[#parts + 1] = encode_value(v[i])
                        end
                        return "[" .. table.concat(parts, ",") .. "]"
                    end
                    for key, item in pairs(v) do
                        parts[#parts + 1] = string.format("%q:%s", tostring(key), encode_value(item))
                    end
                    return "{" .. table.concat(parts, ",") .. "}"
                elseif type(v) == "string" then
                    return string.format("%q", v)
                elseif type(v) == "number" then
                    return tostring(v)
                elseif type(v) == "boolean" then
                    return tostring(v)
                end
                return "null"
            end
            return encode_value(root_value)
        end,
        decode = function(text)
            -- Only used to verify the wrapper round-trips; parse the fixture
            -- format we emit (nested lists of string tables).
            local function parse_value(str, index)
                index = index or 1
                while str:sub(index, index) == " " do index = index + 1 end
                local char = str:sub(index, index)
                if char == "{" then
                    local result = {}
                    index = index + 1
                    while true do
                        while str:sub(index, index) == " " do index = index + 1 end
                        if str:sub(index, index) == "}" then
                            index = index + 1
                            break
                        end
                        local key = str:match('^"([^"]+)"', index)
                        index = str:find(":", index, true) + 1
                        local item, next_index = parse_value(str, index)
                        result[key] = item
                        index = next_index
                        while str:sub(index, index) == " " do index = index + 1 end
                        if str:sub(index, index) == "," then index = index + 1 end
                    end
                    return result, index
                elseif char == "[" then
                    local result = {}
                    index = index + 1
                    while true do
                        while str:sub(index, index) == " " do index = index + 1 end
                        if str:sub(index, index) == "]" then
                            index = index + 1
                            break
                        end
                        local item, next_index = parse_value(str, index)
                        result[#result + 1] = item
                        index = next_index
                        while str:sub(index, index) == " " do index = index + 1 end
                        if str:sub(index, index) == "," then index = index + 1 end
                    end
                    return result, index
                elseif char == '"' then
                    local item = str:match('^"([^"]*)"', index)
                    return item, index + #item + 2
                elseif char == "t" then
                    return true, index + 4
                elseif char == "f" then
                    return false, index + 5
                elseif char == "n" then
                    return nil, index + 4
                else
                    local item = str:match("^[%d%.%-]+", index)
                    return tonumber(item), index + #item
                end
            end
            return parse_value(text)
        end,
    }
end

local Library = require("weread.ui.library")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local meta_root = os.tmpname() .. "-weread-mp"
os.remove(meta_root)
local stored_books = {}
local flushed = 0
local host = {
    settings = {
        meta_dir = meta_root,
        get = function(_self, key, default)
            if key == "books" then return stored_books end
            return default
        end,
        set = function(_self, key, value)
            if key == "books" then stored_books = value end
        end,
        flush = function() flushed = flushed + 1 end,
    },
    library_db = {},
    client = {},
    showInfo = function() end,
    requireLogin = function() return true end,
    showBusy = function() end,
    closeBusy = function() end,
    refreshUI = function() end,
    ui = {
        document = nil,
        openFile = function() end,
        switchDocument = function() end,
    },
}
for key, value in pairs(Library) do
    if host[key] == nil then host[key] = value end
end

-- Case 1: caching writes the list to a sidecar file and keeps only a
-- pointer in the settings record (no inline mp_articles field).
local articles = {
    { title = "Article A", createTime = 100 },
    { title = "Article B", createTime = 200 },
}
host:cacheMPArticles("MP_WXS_42", articles)
local record = stored_books["MP_WXS_42"]
expect(type(record) == "table", "no book record created")
expect(record.mp_articles == nil, "inline mp_articles still stored in settings")
expect(type(record.mp_articles_file) == "string"
    and record.mp_articles_file ~= "", "mp_articles_file pointer missing")
expect(type(record.mp_articles_time) == "number",
    "mp_articles_time missing")
expect(flushed >= 1, "settings were not flushed after caching")
local file_path = record.mp_articles_file
expect(io.open(file_path, "rb") ~= nil, "sidecar mp_articles file missing")

-- Case 2: reading returns the file-backed list.
local cached = host:getCachedMPArticles("MP_WXS_42")
expect(type(cached) == "table" and #cached == 2,
    "file-backed article list did not round-trip")
expect(cached[1].title == "Article A", "article content mismatch")

-- Case 3: legacy inline format is still readable (pre-v1.0.10 records).
local legacy_book = { book_id = "MP_WXS_99", mp_articles = { { title = "Legacy" } } }
stored_books["MP_WXS_99"] = legacy_book
local legacy = host:getCachedMPArticles("MP_WXS_99")
expect(type(legacy) == "table" and legacy[1].title == "Legacy",
    "legacy inline mp_articles not readable")

-- Case 4: missing record returns nil without error.
expect(host:getCachedMPArticles("MP_WXS_NOPE") == nil,
    "missing book returned non-nil articles")

os.execute("rm -rf " .. string.format("%q", meta_root))

print("library_mp_articles_spec: " .. checks .. " checks, 0 failure(s)")
