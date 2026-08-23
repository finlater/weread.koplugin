local Annotations = require("weread.lib.annotations")

local logger = require("weread.lib.logger")

local Thoughts = {}


function Thoughts.collect_ranges(underlines_data)
    local ranges = {}
    if type(underlines_data) ~= "table" then
        return ranges
    end
    for _, ul in ipairs(underlines_data.underlines or {}) do
        if ul.range then
            ranges[#ranges + 1] = ul.range
        end
    end
    return ranges
end

--- Fetch underlines/reviews and inject markup into raw chapter HTML.
-- Must run before image rewriting (range indices are based on original HTML).
-- @return processed_html, annotation_css
function Thoughts.is_download_enabled(settings)
    local cache = settings:get("cache", {})
    return cache.download_underlines_and_thoughts == true
end

function Thoughts.fetch_underlines(client, settings, book_id, chapter_uid, force_enabled)
    if force_enabled ~= true and not Thoughts.is_download_enabled(settings) then
        return true, nil, {}
    end
    if not settings:is_cookie_configured() then
        return false, nil, {}, "cookie not configured"
    end
    local ok, data, err = client:get_chapter_underlines(book_id, chapter_uid)
    if not ok or type(data) ~= "table" then
        return false, nil, {}, err or "no underline data"
    end
    data.chapterUid = chapter_uid
    return true, data, Thoughts.collect_ranges(data)
end

function Thoughts.apply_data(settings, book_id, chapter_uid, xhtml, underlines_data, reviews, book, opts)
    if type(underlines_data) ~= "table" then
        underlines_data = {}
    end
    local rebuild_db = opts and opts.rebuild_thought_db
    local checked_ranges = opts and opts.checked_ranges
    local has_reviews = type(reviews) == "table" and #reviews > 0
    local has_checked = type(checked_ranges) == "table" and #checked_ranges > 0
    local underline_ranges = Thoughts.collect_ranges(underlines_data)
    local has_underlines = #underline_ranges > 0
    if rebuild_db or has_reviews or has_checked or has_underlines then
        local Content = require("weread.lib.content")
        local book_dir = Content.book_resolved_dir(settings, book_id, book)
        local ThoughtDB = require("weread.lib.thought_db")
        if rebuild_db then
            ThoughtDB.remove_db(book_dir)
        end
        if has_reviews or has_checked or has_underlines then
            local db = ThoughtDB.open(book_dir)
            if db then
                if has_reviews then
                    pcall(ThoughtDB.putReviews, db, chapter_uid, reviews)
                end
                if has_checked then
                    pcall(ThoughtDB.markRangesFetched, db, chapter_uid, checked_ranges)
                end
                if has_underlines then
                    pcall(ThoughtDB.putUnderlineRanges, db, chapter_uid, underline_ranges)
                end
                ThoughtDB.close(db)
            end
        end
    end
    underlines_data.chapterUid = chapter_uid
    local processed, annotation_css = Annotations.process(xhtml, underlines_data, reviews, book_id)
    return processed, annotation_css or ""
end

function Thoughts.apply(client, settings, book_id, chapter_uid, xhtml)
    if type(xhtml) ~= "string" or xhtml == "" then
        return xhtml, ""
    end
    if not Thoughts.is_download_enabled(settings) then
        return xhtml, ""
    end
    if not settings:is_cookie_configured() then
        return xhtml, ""
    end
    if not book_id or not chapter_uid then
        return xhtml, ""
    end
    local function log_info(...)
        logger.info(...)
    end

    local ok_ul, ul_data, _, err_ul = Thoughts.fetch_underlines(
        client, settings, book_id, chapter_uid
    )
    if not ok_ul or type(ul_data) ~= "table" then
        log_info("skip underlines:", err_ul or "no data")
        return xhtml, ""
    end

    -- Content-path apply only embeds underlines. Bulk thought download stays
    -- in the downloader job so the UI can stay cooperative.
    return Thoughts.apply_data(settings, book_id, chapter_uid, xhtml, ul_data, nil)
end

function Thoughts.merge_css(base_css, annotation_css)
    if not annotation_css or annotation_css == "" then
        return base_css
    end
    base_css = base_css or [[body { line-height: 1.7; margin: 5%; } img { max-width: 100%; }]]
    return base_css .. "\n" .. annotation_css
end

return Thoughts
