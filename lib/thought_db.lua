--[[--
SQLite-based thought storage for WeRead KOReader plugin.

One database per book directory: {book_dir}/thoughts.db

Schema per lua-ljsqlite3 conventions:
  reviews(chapter_uid, range, review_json, review_html, item_count, updated_at)
  covering index on (chapter_uid, range)

Write: putReview / putReviews (from lib/thoughts.lua:apply_data).
Read:  getReviewHTML (from main.lua:_buildThoughtHtmlFromHref).
--]]--

local logger = require("logger")
local JSON = require("json")

local ThoughtDB = {}

local function getSQ3()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if ok and SQ3 then
        return SQ3
    end
    return nil
end

--- Open or create the per-book thought database.
function ThoughtDB.open(book_dir)
    if type(book_dir) ~= "string" or book_dir == "" then
        return nil
    end

    local SQ3 = getSQ3()
    if not SQ3 then
        logger.info("weread: thought_db lua-ljsqlite3 unavailable, fallback to json")
        return nil
    end

    
    local lfs = require("libs/libkoreader-lfs")
    lfs.mkdir(book_dir)
    local db_path = book_dir .. "/thoughts.db"

    local ok, db = pcall(SQ3.open, db_path)
    if not ok or not db then
        logger.warn("weread: thought_db open failed:", db_path, db)
        return nil
    end

    pcall(function() db:exec("PRAGMA journal_mode=WAL") end)
    pcall(function() db:exec("PRAGMA synchronous=NORMAL") end)

    db:exec([[
        CREATE TABLE IF NOT EXISTS reviews (
            chapter_uid INTEGER NOT NULL,
            range       TEXT    NOT NULL,
            review_json TEXT    NOT NULL,
            review_html TEXT    NOT NULL,
            item_count  INTEGER NOT NULL DEFAULT 0,
            updated_at  INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (chapter_uid, range)
        )
    ]])

    db:exec([[
        CREATE INDEX IF NOT EXISTS idx_reviews_lookup
        ON reviews(chapter_uid, range)
    ]])

    logger.info("weread: thought_db opened", db_path)
    return db
end

--- Look up pre-built popup HTML for a (chapter_uid, range) pair.
function ThoughtDB.getReviewHTML(db, chapter_uid, range_str)
    if not db then return nil end

    local SQ3 = getSQ3()
    if not SQ3 then return nil end

    local ok, stmt = pcall(function()
        return db:prepare(
            "SELECT review_html, item_count FROM reviews WHERE chapter_uid=? AND range=?"
        )
    end)
    if not ok or not stmt then return nil end

    local row = stmt:reset():bind(chapter_uid, range_str):step()
    if row then
        return row[1], row[2]
    end
    return nil
end

--- Insert or replace a single review row.
function ThoughtDB.putReview(db, chapter_uid, review, review_html)
    if not db or type(review) ~= "table" then return end

    local range_str = review.range
    if type(range_str) ~= "string" or range_str == "" then return end

    local json_str = JSON.encode(review)
    local item_count = review.pageReviews and #review.pageReviews or 0

    local ok, stmt = pcall(function()
        return db:prepare([[
            INSERT OR REPLACE INTO reviews
                (chapter_uid, range, review_json, review_html, item_count, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
        ]])
    end)
    if not ok or not stmt then return end

    stmt:reset():bind(chapter_uid, range_str, json_str, review_html or "", item_count, os.time()):step()
end

--- Batch-insert all reviews for a chapter in a single transaction.
function ThoughtDB.putReviews(db, chapter_uid, reviews)
    if not db or type(reviews) ~= "table" then return end

    local Annotations = require("lib.annotations")

    pcall(function() db:exec("BEGIN") end)

    local count = 0
    for _, rv in ipairs(reviews) do
        if type(rv) == "table" then
            local review_html = Annotations.buildThoughtPopupHtml(rv)
            ThoughtDB.putReview(db, chapter_uid, rv, review_html)
            count = count + 1
        end
    end

    pcall(function() db:exec("COMMIT") end)

    logger.info("weread: thought_db written chapter_uid=", chapter_uid,
        " count=", #reviews)
end

--- Close the database handle.
function ThoughtDB.close(db)
    if db then
        pcall(function() db:close() end)
    end
end

return ThoughtDB
