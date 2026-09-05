-- One database per WeRead book. Source data and download progress are shared;
-- document-specific XPointers are disposable projections in the same database.
local LegacyDB = require("weread.lib.external_annotations_db")
local Crypto = require("weread.lib.crypto")
local ok_json, json = pcall(require, "json")
if not ok_json then json = require("rapidjson") end

local Store = {}
Store.__index = Store

function Store:new(settings)
    return setmetatable({ legacy = LegacyDB:new(settings) }, self)
end

function Store:open(book_id, create)
    assert(book_id and tostring(book_id) ~= "", "book id required")
    local db, err = self.legacy:open("weread-book-" .. tostring(book_id), create)
    if not db then return nil, err end
    local ok, schema_err = pcall(function()
        db:exec([[
            CREATE TABLE IF NOT EXISTS annotation_data (
                kind TEXT NOT NULL,
                entry_key TEXT NOT NULL,
                chapter_uid TEXT NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY(kind, entry_key)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS annotation_chapter
                ON annotation_data(chapter_uid, kind);
        ]])
    end)
    if not ok then db:close(); return nil, tostring(schema_err) end
    return db
end

function Store:get(book_id, kind, key)
    local db, err = self:open(book_id, false)
    if not db then
        if err then error(err) end
        return nil
    end
    local stmt, value
    local ok, read_err = pcall(function()
        stmt = db:prepare("SELECT payload FROM annotation_data WHERE kind=? AND entry_key=?")
        local row = stmt:reset():bind(kind, tostring(key)):step()
        if row then value = json.decode(row[1]) end
    end)
    if stmt then stmt:close() end
    db:close()
    if not ok then error(read_err) end
    return value
end

-- All mutations in a chapter commit share a transaction. A nil value deletes
-- an entry; nil key deletes this kind only for the supplied chapter UID.
function Store:write(book_id, changes)
    local db, open_err = self:open(book_id, true)
    if not db then error(open_err) end
    local stmt
    local ok, err = pcall(function()
        db:exec("BEGIN IMMEDIATE")
        for _, change in ipairs(changes) do
            if change.value ~= nil then
                stmt = db:prepare([[
                    INSERT INTO annotation_data(kind,entry_key,chapter_uid,payload)
                    VALUES(?,?,?,?) ON CONFLICT(kind,entry_key) DO UPDATE SET
                    chapter_uid=excluded.chapter_uid,payload=excluded.payload
                ]])
                stmt:reset():bind(change.kind, tostring(change.key),
                    tostring(change.uid or ""), json.encode(change.value)):step()
            elseif change.key ~= nil then
                stmt = db:prepare("DELETE FROM annotation_data WHERE kind=? AND entry_key=?")
                stmt:reset():bind(change.kind, tostring(change.key)):step()
            else
                stmt = db:prepare("DELETE FROM annotation_data WHERE kind=? AND chapter_uid=?")
                stmt:reset():bind(change.kind, tostring(change.uid)):step()
            end
            stmt:close()
            stmt = nil
        end
        db:exec("COMMIT")
    end)
    if stmt then pcall(function() stmt:close() end) end
    if not ok then pcall(function() db:exec("ROLLBACK") end) end
    db:close()
    if not ok then error(err) end
end

function Store:put(book_id, kind, key, value, uid)
    self:write(book_id, { { kind = kind, key = key, value = value, uid = uid } })
end

function Store:list(book_id, kind)
    local db, err = self:open(book_id, false)
    if not db then
        if err then error(err) end
        return {}
    end
    local stmt, result = nil, {}
    local ok, read_err = pcall(function()
        stmt = db:prepare("SELECT entry_key,payload FROM annotation_data WHERE kind=?")
        local row = stmt:reset():bind(kind):step()
        while row do
            result[row[1]] = json.decode(row[2])
            row = stmt:step()
        end
    end)
    if stmt then stmt:close() end
    db:close()
    if not ok then error(read_err) end
    return result
end

function Store:pruneCatalog(book_id, catalog)
    local valid = {}
    for _, chapter in ipairs(catalog) do
        valid[tostring(chapter.chapterUid or chapter.chapterId)] = true
    end
    local db, err = self:open(book_id, false)
    if not db then if err then error(err) end; return end
    local stmt
    local ok, prune_err = pcall(function()
        db:exec("BEGIN IMMEDIATE")
        stmt = db:prepare("SELECT DISTINCT chapter_uid FROM annotation_data WHERE chapter_uid<>''")
        local row, removed = stmt:reset():step(), {}
        while row do
            if not valid[row[1]] then removed[#removed + 1] = row[1] end
            row = stmt:step()
        end
        stmt:close()
        stmt = db:prepare("DELETE FROM annotation_data WHERE chapter_uid=?")
        for _, uid in ipairs(removed) do stmt:reset():bind(uid):step() end
        stmt:close(); stmt = nil
        db:exec("COMMIT")
    end)
    if stmt then pcall(function() stmt:close() end) end
    if not ok then pcall(function() db:exec("ROLLBACK") end) end
    db:close()
    if not ok then error(prune_err) end
end

function Store:projectionKey(document_key, uid)
    return document_key .. ":" .. tostring(uid)
end

function Store.documentKey(path)
    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(path) or {}
    -- File identity changes after replacement; renderer version also invalidates
    -- coordinates after a CREngine upgrade without discarding shared sources.
    local ok, version = pcall(require, "version")
    local engine = ok and type(version) == "table" and version.getCurrentRevision
        and version:getCurrentRevision() or "unknown"
    return Crypto.sha256_hex(table.concat({ path, tostring(attr.size),
        tostring(attr.modification), tostring(attr.change), tostring(engine) }, "\n"))
end

function Store:commitChapter(book_id, uid, source, document_key, projection)
    local changes = {
        { kind = "source", key = uid, uid = uid, value = source },
        { kind = "download", key = uid },
        { kind = "batch", uid = uid },
    }
    if document_key then
        local key = self:projectionKey(document_key, uid)
        changes[#changes + 1] = { kind = "projection", key = key, uid = uid, value = projection }
        changes[#changes + 1] = { kind = "matching", key = key }
    end
    self:write(book_id, changes)
end

-- Legacy databases remain intact until migration is verified. A migration is
-- idempotent and never overwrites newer shared chapter data from another file.
function Store:importLegacy(book_id, path, document_key)
    local marker = Crypto.sha256_hex(path)
    if self:get(book_id, "migration", marker) then return end
    local entry = self.legacy:getDocument(path)
    local checkpoint = self.legacy:getSyncCheckpoint(path)
    if entry and entry.binding and tostring(entry.binding.book_id) ~= tostring(book_id) then return end
    if checkpoint and tostring(checkpoint.book_id) == tostring(book_id) then
        for _, chapter in ipairs(checkpoint.chapters or {}) do
            local uid = tostring(chapter.chapter_uid)
            if not self:get(book_id, "source", uid) and not self:get(book_id, "download", uid) then
                if chapter.complete then
                    chapter.revision = "legacy-" .. tostring(checkpoint.started_at or 0)
                    self:put(book_id, "source", uid, chapter, uid)
                    self:put(book_id, "source_status", uid,
                        { revision = chapter.revision, total = #(chapter.underlines or {}) }, uid)
                else
                    local batches = chapter.review_batches or {}
                    chapter.next_batch = 1
                    for _, batch in ipairs(batches) do
                        if batch.batch_index ~= chapter.next_batch then break end
                        self:put(book_id, "batch", uid .. ":" .. batch.batch_index, batch.reviews, uid)
                        chapter.next_batch = chapter.next_batch + 1
                    end
                    chapter.review_batches = nil
                    self:put(book_id, "download", uid, chapter, uid)
                end
            end
        end
    end
    local grouped = {}
    for _, record in ipairs(entry and entry.records or {}) do
        local uid = record.chapter_uid
        if uid then
            uid = tostring(uid)
            grouped[uid] = grouped[uid] or {}
            grouped[uid][#grouped[uid] + 1] = record
        end
    end
    for uid, records in pairs(grouped) do
        local key = self:projectionKey(document_key, uid)
        if not self:get(book_id, "projection", key) then
            self:put(book_id, "projection", key, { records = records,
                legacy = true, stats = { total = #records, located = #records } }, uid)
        end
    end
    self:put(book_id, "migration", marker, { imported = true })
end

return Store
