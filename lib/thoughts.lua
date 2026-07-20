local Annotations = require("lib.annotations")

local ok_logger, logger = pcall(require, "logger")
if not ok_logger then
    logger = nil
end

local LOG_MODULE = "[WeRead]"

local Thoughts = {}

local function basename_safe(value)
    value = tostring(value or ""):gsub("[^%w%._-]", "_")
    if value == "" then
        value = "unknown"
    end
    return value
end

local function log_info(...)
    if logger then
        logger.info(LOG_MODULE, ...)
    end
end

function Thoughts.cache_dir(settings, book_id)
    return settings.cache_dir .. "/" .. basename_safe(book_id) .. "/thoughts"
end

function Thoughts.cache_path(settings, book_id, chapter_uid)
    return Thoughts.cache_dir(settings, book_id) .. "/" .. tostring(chapter_uid) .. ".json"
end


--- 读取某章缓存的想法数据（save_cache 的对称读取端）。
-- 点击划线时由 main.lua 调用，按 range 匹配后渲染弹窗。
-- @return table|nil  原始 reviews 数组（每元素含 .range / .pageReviews），失败返回 nil
function Thoughts.load_cache(settings, book_id, chapter_uid)
    local path = Thoughts.cache_path(settings, book_id, chapter_uid)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local data = file:read("*a") or ""
    file:close()
    if data == "" then
        return nil
    end
    -- Prefer rapidjson (C parser) — much faster than the pure-Lua json module,
    -- which matters for chapters with many thoughts (large JSON) on slow devices.
    local ok, decoded = pcall(function()
        local json = require("rapidjson")
        return json.decode and json.decode(data) or json:decode(data)
    end)
    if not ok or type(decoded) ~= "table" then
        ok, decoded = pcall(require("json").decode, data)
    end
    if not ok or type(decoded) ~= "table" then
        return nil
    end
    return decoded
end

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

function Thoughts.fetch_underlines(client, settings, book_id, chapter_uid)
    if not Thoughts.is_download_enabled(settings) then
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

function Thoughts.apply_data(settings, book_id, chapter_uid, xhtml, underlines_data, reviews, book)
    if type(underlines_data) ~= "table" then
        underlines_data = {}
    end
    if type(reviews) == "table" and #reviews > 0 then
        local Content = require("lib.content")
        local book_dir = Content.book_resolved_dir(settings, book_id, book)
        local ThoughtDB = require("lib.thought_db")
        local db = ThoughtDB.open(book_dir)
        if db then
            pcall(ThoughtDB.putReviews, db, chapter_uid, reviews)
            ThoughtDB.close(db)
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

    local ok_ul, ul_data, ranges, err_ul = Thoughts.fetch_underlines(
        client, settings, book_id, chapter_uid
    )
    if not ok_ul or type(ul_data) ~= "table" then
        log_info("skip underlines:", err_ul or "no data")
        return xhtml, ""
    end

    local thought_reviews
    if #ranges > 0 then
        local ok_tr, tr_data = client:get_chapter_reviews(book_id, chapter_uid, ranges)
        if ok_tr and type(tr_data) == "table" and #(tr_data.reviews or {}) > 0 then
            thought_reviews = tr_data.reviews
        end
    end
    return Thoughts.apply_data(settings, book_id, chapter_uid, xhtml, ul_data, thought_reviews)
end

function Thoughts.merge_css(base_css, annotation_css)
    if not annotation_css or annotation_css == "" then
        return base_css
    end
    base_css = base_css or [[body { line-height: 1.7; margin: 5%; } img { max-width: 100%; }]]
    return base_css .. "\n" .. annotation_css
end

return Thoughts
