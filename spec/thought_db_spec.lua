-- Underline catalog persistence must not mark thought ranges as fetched.
--   lua spec/thought_db_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then
        error(message or ("check " .. checks .. " failed"))
    end
end

package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        mkdir = function() return true end,
    }
end

local databases = {}
package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function(path)
            databases[path] = databases[path] or {
                underline_ranges = {},
                fetched_ranges = {},
            }
            local data = databases[path]
            local db = {}
            db.exec = function() end
            db.close = function() end
            db.prepare = function(_db, sql)
                local stmt = { sql = sql, args = {} }
                stmt.reset = function(current)
                    current.args = {}
                    current.row_index = 0
                    current.rows = nil
                    return current
                end
                stmt.bind = function(current, ...)
                    current.args = { ... }
                    return current
                end
                stmt.step = function(current)
                    if current.sql:find("DELETE FROM underline_ranges", 1, true) then
                        local chapter_uid = current.args[1]
                        local stale = {}
                        for key, row in pairs(data.underline_ranges) do
                            if row.chapter_uid == chapter_uid then
                                stale[#stale + 1] = key
                            end
                        end
                        for _, key in ipairs(stale) do
                            data.underline_ranges[key] = nil
                        end
                        return nil
                    end
                    if current.sql:find("INSERT OR IGNORE INTO underline_ranges", 1, true) then
                        local chapter_uid, range_str = current.args[1], current.args[2]
                        local key = tostring(chapter_uid) .. "\t" .. tostring(range_str)
                        data.underline_ranges[key] = {
                            chapter_uid = chapter_uid,
                            range = range_str,
                        }
                        return nil
                    end
                    if current.sql:find("SELECT range FROM underline_ranges", 1, true) then
                        if not current.rows then
                            local rows = {}
                            local chapter_uid = current.args[1]
                            for _, row in pairs(data.underline_ranges) do
                                if row.chapter_uid == chapter_uid then
                                    rows[#rows + 1] = { row.range }
                                end
                            end
                            current.rows = rows
                        end
                        current.row_index = (current.row_index or 0) + 1
                        return current.rows[current.row_index]
                    end
                    if current.sql:find("SELECT 1 FROM fetched_ranges", 1, true) then
                        local chapter_uid, range_str = current.args[1], current.args[2]
                        local key = tostring(chapter_uid) .. "\t" .. tostring(range_str)
                        return data.fetched_ranges[key] and { 1 } or nil
                    end
                    if current.sql:find("INSERT OR IGNORE INTO fetched_ranges", 1, true) then
                        local chapter_uid, range_str = current.args[1], current.args[2]
                        local key = tostring(chapter_uid) .. "\t" .. tostring(range_str)
                        data.fetched_ranges[key] = true
                        return nil
                    end
                    return nil
                end
                stmt.close = function() end
                return stmt
            end
            return db
        end,
    }
end

local ThoughtDB = require("weread.lib.thought_db")
local db = ThoughtDB.open("/books/one")
expect(db ~= nil, "thought db should open")

expect(ThoughtDB.putUnderlineRanges(db, 11, { "80-90", "1-4", "1-4", "", 3 }),
    "underline catalog write should succeed")
local ranges = ThoughtDB.getUnderlineRanges(db, 11)
expect(#ranges == 2 and ranges[1] == "1-4" and ranges[2] == "80-90",
    "underline ranges are unique and ordered by start")
expect(ThoughtDB.isRangeFetched(db, 11, "1-4") == false,
    "underline catalog must not mark ranges as fetched")

expect(ThoughtDB.putUnderlineRanges(db, 11, { "20-21" }),
    "second catalog write should replace the chapter")
ranges = ThoughtDB.getUnderlineRanges(db, 11)
expect(#ranges == 1 and ranges[1] == "20-21",
    "replaced catalog should drop previous ranges")
expect(#ThoughtDB.getUnderlineRanges(db, 12) == 0,
    "other chapters stay empty")

ThoughtDB.close(db)
print(string.format("thought_db_spec: %d checks, %d failure(s)", checks, 0))
os.exit(0)
