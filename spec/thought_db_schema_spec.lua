-- Opening the thought database must not delete legacy tables on every session.

package.path = "./?.lua;" .. package.path

local statements = {}
local db = {
    exec = function(_self, sql)
        statements[#statements + 1] = sql
    end,
    close = function() end,
}

package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function() return db end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { mkdir = function() end }
end
package.preload["weread.lib.logger"] = function()
    return { warn = function() end, info = function() end }
end

local ThoughtDB = require("weread.lib.thought_db")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local opened = ThoughtDB.open("/tmp/weread-book")
expect(opened == db, "thought database opens successfully")

local sql = table.concat(statements, "\n")
expect(not sql:match("DROP%s+TABLE"),
    "opening the thought database does not drop tables")
expect(sql:match("CREATE%s+TABLE%s+IF%s+NOT%s+EXISTS%s+review_items"),
    "opening ensures the current thought schema")

print(string.format(
    "thought_db_schema_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
