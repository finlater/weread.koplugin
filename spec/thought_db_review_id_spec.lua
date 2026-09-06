-- Review-id persistence in the thought database: schema, migration, roundtrip.
package.path = "./?.lua;" .. package.path

package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { mkdir = function() end }
end

-- Minimal SQLite fake: records executed SQL and bound INSERT values, and
-- simulates the PRAGMA/SELECT statements thought_db relies on.
local records
package.preload["lua-ljsqlite3/init"] = function()
    records = {
        executed = {},
        prepared = {},
        inserts = {},
        -- Programmed table_info rows: a current database with review_id.
        table_info_columns = {
            "chapter_uid", "range", "item_index",
            "abstract", "author", "content", "likes_count", "review_id",
        },
        -- Programmed rows returned by the getReviewItems SELECT.
        select_rows = {},
    }
    local SQ3 = { records = records }

    function SQ3.open()
        local db = {}
        function db:exec(sql)
            records.executed[#records.executed + 1] = sql
        end
        function db:prepare(sql)
            records.prepared[#records.prepared + 1] = sql
            local stmt = {}
            if sql:find("PRAGMA table_info", 1, true) then
                local index = 0
                function stmt:reset() index = 0; return self end
                function stmt:bind() return self end
                function stmt:step()
                    index = index + 1
                    local name = records.table_info_columns[index]
                    if name then return { index, name } end
                    return nil
                end
            elseif sql:find("INSERT INTO review_items", 1, true) then
                local bound
                function stmt:reset() return self end
                function stmt:bind(...)
                    local args = { ... }
                    -- Colon calls pass the statement as the first argument;
                    -- strip it so assertions see the bound values only.
                    if type(args[1]) == "table" then
                        table.remove(args, 1)
                    end
                    bound = args
                    return self
                end
                function stmt:step()
                    records.inserts[#records.inserts + 1] = bound
                end
            elseif sql:find("SELECT abstract", 1, true) then
                local index = 0
                function stmt:reset() index = 0; return self end
                function stmt:bind() return self end
                function stmt:step()
                    index = index + 1
                    return records.select_rows[index]
                end
            else
                function stmt:reset() return self end
                function stmt:bind() return self end
                function stmt:step() return true end
            end
            function stmt:close() end
            return stmt
        end
        function db:close() end
        return db
    end
    return SQ3
end

local ThoughtDB = require("weread.lib.thought_db")

local failures, checks = 0, 0
local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
    end
end

local function executed_contains(fragment, label)
    checks = checks + 1
    for _, sql in ipairs(records.executed) do
        if sql:find(fragment) then
            return
        end
    end
    failures = failures + 1
    print(string.format("FAIL %s: no executed statement contains %s", label, fragment))
end

-- New database: the schema carries review_id, no migration needed.
local db = ThoughtDB.open("/tmp/weread-spec-thoughts")
executed_contains("review_id%s+TEXT", "create table includes review_id column")

local migrated = false
for _, sql in ipairs(records.executed) do
    if sql:find("ALTER TABLE review_items ADD COLUMN review_id", 1, true) then
        migrated = true
    end
end
eq(migrated, false, "fresh schema needs no ALTER TABLE")

-- Roundtrip: putReviews extracts pageReviews[].review.reviewId through
-- buildThoughtPopupItems and stores it; getReviewItems returns it.
records.select_rows = {
    { "abstract one", "Alice", "thought one", 2, "review-1" },
    { nil, "Bob", "thought two", 0, nil }, -- row written before review_id existed
}
local items = ThoughtDB.getReviewItems(db, 42, "383-415")
eq(type(items), "table", "review items query returns rows")
eq(items[1].review_id, "review-1", "stored review_id returned")
eq(items[2].review_id, nil, "legacy row without review_id reads as nil")

do
    local reviews = {
        {
            range = "383-415",
            pageReviews = {
                { review = { content = "c1", reviewId = "rv-1" }, likesCount = 1 },
                { review = { content = "c2" }, likesCount = 0 },
            },
        },
    }
    ThoughtDB.putReviews(db, 42, reviews)
    eq(#records.inserts, 2, "both page reviews inserted")
    eq(records.inserts[1][8], "rv-1", "first thought binds its reviewId")
    eq(records.inserts[2][8], nil, "thought without reviewId binds NULL")
end

-- Legacy database: table_info without review_id triggers ALTER TABLE.
records.prepared = {}
records.executed = {}
records.table_info_columns = {
    "chapter_uid", "range", "item_index",
    "abstract", "author", "content", "likes_count",
}
db = ThoughtDB.open("/tmp/weread-spec-thoughts")
local altered = false
for _, sql in ipairs(records.executed) do
    if sql:find("ALTER TABLE review_items ADD COLUMN review_id", 1, true) then
        altered = true
    end
end
eq(altered, true, "legacy database is migrated in place")

ThoughtDB.close(db)

print(string.format("thought_db_review_id_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
