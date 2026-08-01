-- SQLite-backed offline index for shelf entries, book details, and catalogs.
-- Downloaded EPUB/HTML files remain in the ordinary cache directory; this
-- database only stores small, queryable metadata needed to browse offline.

local logger = require("weread.lib.logger")
local Crypto = require("weread.lib.crypto")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local LibraryDB = {}
LibraryDB.__index = LibraryDB

local function getSQ3()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    return ok and SQ3 or nil
end

local function encode(value)
    if not ok_json then return nil, "JSON module is not available" end
    local ok, result = pcall(function()
        return json.encode and json.encode(value) or json:encode(value)
    end)
    return ok and result or nil, ok and nil or result
end

local function decode(value)
    if type(value) ~= "string" or value == "" or not ok_json then return nil end
    local ok, result = pcall(function()
        return json.decode and json.decode(value) or json:decode(value)
    end)
    return ok and type(result) == "table" and result or nil
end

local function close_statement(stmt)
    if stmt then pcall(function() stmt:close() end) end
end

function LibraryDB:new(settings)
    local data_dir = settings.data_dir or settings.cache_dir or "."
    return setmetatable({
        settings = settings,
        data_dir = data_dir,
    }, self)
end

-- The hash keeps the user VID out of filenames while giving each login a
-- stable database that can be reused when the user switches back.
function LibraryDB:accountKey()
    local account = self.settings:get("account", {})
    local user_vid = type(account) == "table" and account.user_vid or nil
    if user_vid == nil or tostring(user_vid) == "" then return nil end
    return string.sub(Crypto.sha256_hex("weread-library:" .. tostring(user_vid)), 1, 20)
end

function LibraryDB:databasePath()
    local account_key = self:accountKey()
    if not account_key then return nil end
    return self.data_dir .. "/library-" .. account_key .. ".db"
end

function LibraryDB:open()
    local path = self:databasePath()
    if not path then
        logger.info("library_db skipped without an identified account")
        return nil
    end
    local SQ3 = getSQ3()
    if not SQ3 then
        logger.warn("library_db lua-ljsqlite3 unavailable")
        return nil
    end
    local ok, db = pcall(SQ3.open, path)
    if not ok or not db then
        logger.warn("library_db open failed:", path, db)
        return nil
    end
    local schema_ok, schema_err = pcall(function()
        db:exec("PRAGMA journal_mode=WAL")
        db:exec("PRAGMA synchronous=NORMAL")
        db:exec([[
            CREATE TABLE IF NOT EXISTS books (
                book_id           TEXT PRIMARY KEY,
                kind              TEXT NOT NULL DEFAULT 'book',
                payload           TEXT NOT NULL,
                on_shelf          INTEGER NOT NULL DEFAULT 0,
                shelf_position    INTEGER,
                shelf_updated_at  INTEGER,
                detail_updated_at INTEGER,
                detail_payload    TEXT
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS chapters (
                book_id      TEXT NOT NULL,
                chapter_uid  TEXT NOT NULL,
                position     INTEGER NOT NULL,
                payload      TEXT NOT NULL,
                updated_at   INTEGER NOT NULL,
                PRIMARY KEY (book_id, chapter_uid)
            ) WITHOUT ROWID
        ]])
        -- Adds the richer detail snapshot for databases created by an early
        -- development build. Duplicate-column errors are intentionally ignored.
        pcall(function() db:exec("ALTER TABLE books ADD COLUMN detail_payload TEXT") end)
        db:exec("CREATE INDEX IF NOT EXISTS chapters_position ON chapters(book_id, position)")
    end)
    if not schema_ok then
        logger.warn("library_db schema init failed:", schema_err)
        pcall(function() db:close() end)
        return nil
    end
    return db
end

function LibraryDB:cacheShelf(books)
    local db = self:open()
    if not db or type(books) ~= "table" then return false end
    local transaction_open = false
    local stmt
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        db:exec("UPDATE books SET on_shelf=0, shelf_position=NULL")
        stmt = db:prepare([[
            INSERT INTO books
                (book_id, kind, payload, on_shelf, shelf_position, shelf_updated_at)
            VALUES (?, ?, ?, 1, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET
                kind=excluded.kind,
                payload=excluded.payload,
                on_shelf=1,
                shelf_position=excluded.shelf_position,
                shelf_updated_at=excluded.shelf_updated_at
        ]])
        local now = os.time()
        for position, book in ipairs(books) do
            local book_id = book.book_id or book.bookId
            local payload, encode_err = encode(book)
            if book_id and payload then
                local kind = tostring(book_id):match("^MP_WXS_") and "mp" or "book"
                stmt:reset():bind(tostring(book_id), kind, payload, position, now):step()
            elseif encode_err then
                error(encode_err)
            end
        end
        close_statement(stmt)
        stmt = nil
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db shelf write failed:", err) end
    return ok
end

function LibraryDB:getShelf()
    local db = self:open()
    if not db then return nil end
    local books = {}
    local ok, stmt = pcall(function()
        return db:prepare([[
            SELECT payload FROM books
            WHERE on_shelf=1
            ORDER BY shelf_position, book_id
        ]])
    end)
    if ok and stmt then
        local row = stmt:reset():step()
        while row do
            local book = decode(row[1])
            if book then books[#books + 1] = book end
            row = stmt:step()
        end
    end
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok and books or nil
end

function LibraryDB:putBook(book)
    if type(book) ~= "table" then return false end
    local book_id = book.book_id or book.bookId
    local payload = encode(book)
    if not book_id or not payload then return false end
    local db = self:open()
    if not db then return false end
    local stmt
    local ok, err = pcall(function()
        stmt = db:prepare([[
            INSERT INTO books
                (book_id, kind, payload, detail_payload, detail_updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET
                kind=excluded.kind,
                detail_payload=excluded.detail_payload,
                detail_updated_at=excluded.detail_updated_at
        ]])
        local kind = tostring(book_id):match("^MP_WXS_") and "mp" or "book"
        stmt:reset():bind(tostring(book_id), kind, payload, payload, os.time()):step()
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db book write failed:", err) end
    return ok
end

function LibraryDB:getBook(book_id)
    if not book_id then return nil end
    local db = self:open()
    if not db then return nil end
    local stmt
    local result
    local ok = pcall(function()
        stmt = db:prepare("SELECT COALESCE(detail_payload, payload) FROM books WHERE book_id=?")
        local row = stmt:reset():bind(tostring(book_id)):step()
        result = row and decode(row[1]) or nil
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok and result or nil
end

function LibraryDB:putChapters(book_id, chapters)
    if not book_id or type(chapters) ~= "table" then return false end
    local db = self:open()
    if not db then return false end
    local transaction_open = false
    local stmt
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        local delete_stmt = db:prepare("DELETE FROM chapters WHERE book_id=?")
        delete_stmt:reset():bind(tostring(book_id)):step()
        delete_stmt:close()
        stmt = db:prepare([[
            INSERT INTO chapters (book_id, chapter_uid, position, payload, updated_at)
            VALUES (?, ?, ?, ?, ?)
        ]])
        local now = os.time()
        for position, chapter in ipairs(chapters) do
            local uid = chapter.chapterUid or chapter.chapterId or position
            local payload, encode_err = encode(chapter)
            if payload then
                stmt:reset():bind(tostring(book_id), tostring(uid), position, payload, now):step()
            else
                error(encode_err)
            end
        end
        close_statement(stmt)
        stmt = nil
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db catalog write failed:", err) end
    return ok
end

function LibraryDB:getChapters(book_id)
    if not book_id then return nil end
    local db = self:open()
    if not db then return nil end
    local chapters = {}
    local stmt
    local ok = pcall(function()
        stmt = db:prepare([[
            SELECT payload FROM chapters WHERE book_id=? ORDER BY position
        ]])
        local row = stmt:reset():bind(tostring(book_id)):step()
        while row do
            local chapter = decode(row[1])
            if chapter then chapters[#chapters + 1] = chapter end
            row = stmt:step()
        end
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok and #chapters > 0 and chapters or nil
end

return LibraryDB
