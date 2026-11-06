-- WeRead's chapterOffset (protocol field "co") is an offset into the chapter's
-- source HTML, not a word count: the official client converts it through
-- ChapterIndex.txt2html before reporting. Dividing it by wordCount mixes two
-- coordinate spaces and makes the upload land early while the pull lands late.
--
-- This spec pins the html space and the word fallback that must stay identical
-- to the previous behaviour.
--
-- The chapter lengths below are synthetic but keep the r = htmlLen / wordCount
-- ratio seen in real books (median 1.45).

package.path = "./?.lua;" .. package.path
local Mapper = require("weread.lib.position_mapper")

local chapters = {
    { chapterUid = 11, chapterIdx = 1, wordCount = 100 },
    { chapterUid = 22, chapterIdx = 2, wordCount = 300 },
    { chapterUid = 33, chapterIdx = 3, wordCount = 600 },
}

local HTML_LEN = { [11] = 145, [22] = 435, [33] = 870 }
local function chapter_len(uid)
    return HTML_LEN[tonumber(uid)]
end

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

local function near(got, want, tolerance, label)
    checks = checks + 1
    if math.abs(got - want) > tolerance then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %.6f, want %.6f",
            current_test, label, got, want))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

test("upload uses the html space when the chapter length is known", function()
    local position = assert(Mapper.local_to_remote(chapters, 0.25, {
        is_full_book = true,
        chapter_len = chapter_len,
    }))
    eq(position.chapter_uid, 22, "chapter uid")
    -- 0.5 * 435, not 0.5 * 300: the offset is reported in html units.
    eq(position.chapter_offset, 217, "offset in html units")
    eq(position.percent, 25, "book percent stays in word units")
end)

test("percent is no longer rounded to a whole number", function()
    local position = assert(Mapper.local_to_remote(chapters, 0.255, {
        is_full_book = true,
        chapter_len = chapter_len,
    }))
    near(position.percent, 25.5, 0.0001, "fractional percent survives")
    near(position.fraction, 0.255, 0.0001, "fraction survives")
end)

test("an uploaded offset reads back at the same place", function()
    local position = assert(Mapper.local_to_remote(chapters, 0.25, {
        is_full_book = true,
        chapter_len = chapter_len,
    }))
    local normalized = assert(Mapper.normalize_remote({
        progress = 99,
        chapterUid = position.chapter_uid,
        chapterIdx = position.chapter_idx,
        chapterOffset = position.chapter_offset,
    }, "book", "gateway", chapters, { chapter_len = chapter_len }))
    near(normalized.percent, 25, 0.05, "round-trip percent")
end)

test("remote offset is divided by the html length, not by words", function()
    local normalized = assert(Mapper.normalize_remote({
        progress = 99,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 217,
    }, "book", "gateway", chapters, { chapter_len = chapter_len }))
    eq(normalized.position_basis, "chapter_html_offset", "basis")
    eq(normalized.chapter_offset, 217, "offset echoed back")
    -- 217/435 of chapter 2 is the same place 0.25 of the book was.
    near(normalized.percent, 24.97, 0.05, "recomputed book percent")
end)

test("without a chapter length the word fallback is unchanged", function()
    local normalized = assert(Mapper.normalize_remote({
        progress = 99,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 217,
    }, "book", "gateway", chapters))
    eq(normalized.position_basis, "chapter_offset", "legacy basis name kept")
    -- Reading co as words is the old, wrong mapping: 31.7% instead of 25%.
    -- Keeping it for never-downloaded chapters is deliberate - better the old
    -- answer than a guess.
    near(normalized.percent, 31.7, 0.01, "legacy percent")
end)

test("download jumps into the html space", function()
    local target = assert(Mapper.remote_to_local(chapters, {
        percent = 99,
        chapter_uid = 22,
        chapter_offset = 217,
    }, {
        is_full_book = true,
        chapter_len = chapter_len,
    }))
    near(target.fraction, 0.25, 0.002, "whole book fraction")
    eq(target.requires_chapter_open, false, "no chapter switch")
end)

print(string.format("position_mapper_html_space_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
