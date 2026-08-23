--[[--
Normalized SQLite thought storage for the WeRead KOReader plugin.

One database per book directory: {book_dir}/thoughts.db

Each pageReview is stored as one row. Tapping an underline performs a single
indexed lookup by (chapter_uid, range), without decoding JSON or rendering HTML.
--]]--

local logger = require("weread.lib.logger")

local ThoughtDB = {}

local function getSQ3()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if ok and SQ3 then
        return SQ3
    end
    return nil
end

--- Delete thoughts.db and WAL/SHM sidecars. Missing files are ignored.
function ThoughtDB.remove_db(book_dir)
    if type(book_dir) ~= "string" or book_dir == "" then
        return false
    end
    for _, path in ipairs({
        book_dir .. "/thoughts.db",
        book_dir .. "/thoughts.db-wal",
        book_dir .. "/thoughts.db-shm",
    }) do
        os.remove(path)
    end
    return true
end

--- Open or create the per-book thought database.
function ThoughtDB.open(book_dir)
    if type(book_dir) ~= "string" or book_dir == "" then
        return nil
    end

    local SQ3 = getSQ3()
    if not SQ3 then
        logger.warn("thought_db lua-ljsqlite3 unavailable")
        return nil
    end

    local lfs = require("libs/libkoreader-lfs")
    lfs.mkdir(book_dir)
    local db_path = book_dir .. "/thoughts.db"

    local ok, db = pcall(SQ3.open, db_path)
    if not ok or not db then
        logger.warn("thought_db open failed:", db_path, db)
        return nil
    end

    pcall(function() db:exec("PRAGMA journal_mode=WAL") end)
    pcall(function() db:exec("PRAGMA synchronous=NORMAL") end)

    local schema_ok, schema_err = pcall(function()
        -- Keep schema setup idempotent. The old development-only `reviews`
        -- table is harmless and must not be dropped on every document open.
        db:exec([[
            CREATE TABLE IF NOT EXISTS review_items (
                chapter_uid INTEGER NOT NULL,
                range       TEXT    NOT NULL,
                item_index  INTEGER NOT NULL,
                abstract    TEXT,
                author      TEXT    NOT NULL,
                content     TEXT    NOT NULL,
                likes_count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (chapter_uid, range, item_index)
            ) WITHOUT ROWID
        ]])
    end)
    if not schema_ok then
        logger.warn("thought_db schema init failed:", db_path, schema_err)
        pcall(function() db:close() end)
        return nil
    end

    logger.info("thought_db opened", db_path)
    return db
end

--- Look up native-dialog thought records for a (chapter_uid, range) pair.
function ThoughtDB.getReviewItems(db, chapter_uid, range_str)
    if not db then return nil end

    local ok, stmt = pcall(function()
        return db:prepare([[
            SELECT abstract, author, content, likes_count
            FROM review_items
            WHERE chapter_uid=? AND range=?
            ORDER BY item_index
        ]])
    end)
    if not ok or not stmt then return nil end

    local items = {}
    local step_ok, row = pcall(function()
        return stmt:reset():bind(chapter_uid, range_str):step()
    end)
    if not step_ok then
        pcall(function() stmt:close() end)
        return nil
    end
    while row do
        items[#items + 1] = {
            abstract = row[1],
            author = row[2],
            content = row[3],
            likes_count = row[4],
        }
        step_ok, row = pcall(function() return stmt:step() end)
        if not step_ok then
            pcall(function() stmt:close() end)
            return nil
        end
    end
    pcall(function() stmt:close() end)
    return items
end

local function insert_reviews(db, chapter_uid, reviews)
    local Annotations = require("weread.lib.annotations")
    local insert_stmt = db:prepare([[
        INSERT INTO review_items
            (chapter_uid, range, item_index, abstract, author, content, likes_count)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]])

    local by_range = {}
    local range_order = {}
    for _, review in ipairs(reviews) do
        local range_str = type(review) == "table" and review.range or nil
        if type(range_str) == "string" and range_str ~= "" then
            if not by_range[range_str] then
                range_order[#range_order + 1] = range_str
            end
            by_range[range_str] = review
        end
    end

    local inserted = 0
    for _, range_str in ipairs(range_order) do
        local items = Annotations.buildThoughtPopupItems(by_range[range_str])
        for item_index, item in ipairs(items) do
            insert_stmt:reset():bind(
                chapter_uid, range_str, item_index,
                item.abstract, item.author, item.content, item.likes_count
            ):step()
            inserted = inserted + 1
        end
    end
    insert_stmt:close()
    return inserted
end

--- Replace all thought rows for one chapter in a single transaction.
function ThoughtDB.putReviews(db, chapter_uid, reviews)
    if not db or type(reviews) ~= "table" then return false end

    local transaction_open = false
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true

        local delete_stmt = db:prepare(
            "DELETE FROM review_items WHERE chapter_uid=?"
        )
        delete_stmt:reset():bind(chapter_uid):step()
        delete_stmt:close()

        insert_reviews(db, chapter_uid, reviews)

        db:exec("COMMIT")
        transaction_open = false
    end)

    if not ok then
        if transaction_open then
            pcall(function() db:exec("ROLLBACK") end)
        end
        logger.warn("thought_db chapter write failed:",
            "chapter_uid=", tostring(chapter_uid), "error=", tostring(err))
        return false
    end

    logger.info("thought_db written chapter_uid=", chapter_uid,
        " ranges=", #reviews)
    return true
end

--- Close the database handle.
function ThoughtDB.close(db)
    if db then
        pcall(function() db:close() end)
    end
end

return ThoughtDB
