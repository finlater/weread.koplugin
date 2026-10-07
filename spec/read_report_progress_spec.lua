-- Focused tests for ReadReport's progress gate and enter/report sequencing.
-- Run from the repo root with:
--   lua spec/read_report_progress_spec.lua

package.path = "./?.lua;" .. package.path

local cached_catalog
local saved_catalog
package.preload["weread.lib.content"] = function()
    return {
        load_catalog_cache = function(_client, _settings, book)
            if cached_catalog then book.chapters = cached_catalog end
            return cached_catalog
        end,
        save_catalog_cache = function(_client, _settings, _book, chapters)
            saved_catalog = chapters
            return true
        end,
    }
end

package.preload["weread.lib.protocol"] = function()
    return {
        e = function(value) return "e:" .. tostring(value) end,
        web_app_id = function() return "app" end,
        reader_url = function(book_id)
            return "https://reader/" .. tostring(book_id)
        end,
        make_enter_read_payload = function(options)
            return {
                kind = "enter",
                chapter_uid = options.chapter_uid,
                chapter_offset = options.chapter_offset,
                progress = options.progress,
            }
        end,
        make_read_payload = function(options)
            return {
                kind = "report",
                chapter_uid = options.chapter_uid,
                chapter_offset = options.chapter_offset,
                progress = options.progress,
                elapsed_seconds = options.elapsed_seconds,
            }
        end,
        is_success_response = function(value)
            return type(value) == "table" and value.succ == 1
        end,
    }
end

local ReadReport = require("weread.lib.read_report")

local failures, checks = 0, 0
local current_test

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %s, want %s",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

local function fixture(provider)
    local records = {}
    local settings = {
        get = function(_self, key)
            if key == "read_report" then
                return {
                    enabled = true,
                    mode = "auto",
                    interval_seconds = 30,
                }
            end
            if key == "books" then
                return { book = { title = "Book" } }
            end
            return {}
        end,
        is_cookie_configured = function() return true end,
    }
    local client = {
        report_read = function(_self, payload)
            records[#records + 1] = payload
            return { succ = 1 }
        end,
    }
    local report = ReadReport:new{
        settings = settings,
        client = client,
        scheduler = {
            scheduleIn = function() end,
            unschedule = function() end,
        },
        get_document = function() return { file = "/book.epub" } end,
        detect_book = function() return "book" end,
        position_provider = provider,
        is_online = function() return true end,
        subprocess = false,
        now = function() return 100 end,
    }
    return report, records
end

test("unverified position blocks reading-time reporting", function()
    local report = fixture(function()
        return nil, "progress_unverified", true
    end)
    local proceed = report:_precheck()
    eq(proceed, false, "precheck blocked")
    eq(report:status().state, "waiting_for_progress", "waiting state")
end)

test("verified live position passes the reporting gate", function()
    local live = { chapter_uid = 22, chapter_offset = 150, percent = 25 }
    local report = fixture(function()
        return live, nil, true
    end)
    local proceed, book_id, position = report:_precheck()
    eq(proceed, true, "precheck passed")
    eq(book_id, "book", "target book")
    eq(position, live, "live position forwarded")
end)

test("one reader session enters once and reports live position", function()
    local report, records = fixture()
    local book = {
        book_id = "book",
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 1,
        progress = 1,
        psvts = "ps",
        pclts = "pc",
        token = "token",
    }
    local position = {
        chapter_uid = 22,
        chapter_idx = 2,
        chapter_offset = 150,
        percent = 25,
    }
    report:_send("book", book, position, 0)
    report:_send("book", book, position, 30)
    eq(#records, 3, "enter plus two reports")
    eq(records[1].kind, "enter", "first request enters")
    eq(records[2].kind, "report", "second request reports")
    eq(records[2].chapter_uid, 22, "live chapter used")
    eq(records[2].chapter_offset, 150, "live offset used")
    eq(records[2].elapsed_seconds, 0, "progress-only report has zero time")
    eq(records[3].elapsed_seconds, 30, "time report keeps interval")
end)

test("open WeRead book wins over a pinned manual target", function()
    local report = fixture()
    report.settings = {
        get = function(_self, key)
            if key == "read_report" then
                return {
                    enabled = true,
                    mode = "manual",
                    book_id = "pinned",
                    book_title = "Pinned",
                    report_on_open = false,
                    interval_seconds = 120,
                }
            end
            if key == "books" then
                return { openbook = { title = "Open" } }
            end
            return {}
        end,
        is_cookie_configured = function() return true end,
    }
    report.detect_book = function() return "openbook" end
    local id, _title, source = report:resolve_target()
    eq(id, "openbook", "open book is the report target")
    eq(source, "current_document", "source follows the open book")
end)

test("time report enter does not send an rt=0 heartbeat", function()
    local report, records = fixture()
    local book = {
        book_id = "book",
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 1,
        progress = 1,
        psvts = "ps",
        pclts = "pc",
        token = "token",
    }
    report:_send("book", book, {
        chapter_uid = 22,
        chapter_idx = 2,
        chapter_offset = 150,
        percent = 25,
    }, 120, { time_report = true })
    eq(#records, 1, "enter is the only request")
    eq(records[1].kind, "enter", "session opens without rt")
end)

test("restored session credits wall time without entering again", function()
    local stored = {
        enabled = true,
        mode = "auto",
        interval_seconds = 120,
        session_book_id = "book",
        session_started_at = 1000,
        last_credit_at = 1000,
    }
    local records = {}
    local report = fixture()
    report.now = function() return 1180 end
    report.settings = {
        get = function() return stored end,
        set = function(_self, _key, value) stored = value end,
        flush = function() end,
        is_cookie_configured = function() return true end,
    }
    report.client = {
        report_read = function(_self, payload)
            records[#records + 1] = payload
            return { succ = 1 }
        end,
    }
    local elapsed, session_open = report:_reading_credit("book")
    eq(session_open, true, "session restored inside the ttl")
    eq(elapsed, 180, "credit is capped at max(interval, 180)")
    local book = {
        book_id = "book",
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 1,
        progress = 1,
        psvts = "ps",
        pclts = "pc",
        token = "token",
    }
    report:_send("book", book, {
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 400,
        percent = 1,
    }, elapsed, { session_open = true, time_report = true })
    eq(#records, 1, "no second enter")
    eq(records[1].kind, "report", "duration report")
    eq(records[1].elapsed_seconds, 180, "capped elapsed is sent")
    eq(records[1].chapter_offset, 400, "live offset is sent")
end)

test("report context restores SQLite catalog and backfills disk", function()
    local report = fixture()
    local db_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    report.library_db = {
        getChapters = function() return db_catalog end,
        putChapters = function() end,
    }
    cached_catalog = nil
    saved_catalog = nil
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    local context = report:_build_context("book", false, book)
    eq(context.chapters, db_catalog, "SQLite catalog restored")
    eq(saved_catalog, db_catalog, "catalog.json backfilled")
end)

test("report context backfills SQLite from catalog.json", function()
    local report = fixture()
    local disk_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    local written_catalog
    report.library_db = {
        getChapters = function() return nil end,
        putChapters = function(_self, _book_id, chapters)
            written_catalog = chapters
        end,
    }
    cached_catalog = disk_catalog
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    report:_build_context("book", false, book)
    eq(written_catalog, disk_catalog, "catalog.json backfills SQLite")
end)

print(string.format(
    "read_report_progress_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
