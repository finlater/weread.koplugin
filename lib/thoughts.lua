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

function Thoughts.save_cache(settings, book_id, chapter_uid, reviews)
    if type(reviews) ~= "table" or #reviews == 0 then
        return false
    end
    local dir = Thoughts.cache_dir(settings, book_id)
    os.execute("mkdir -p " .. string.format("%q", dir))
    local path = Thoughts.cache_path(settings, book_id, chapter_uid)
    local file = io.open(path, "w")
    if not file then
        return false
    end
    local ok, encoded = pcall(require("json").encode, reviews)
    if not ok then
        ok, encoded = pcall(function()
            local json = require("rapidjson")
            return json:encode(reviews)
        end)
    end
    if not ok or not encoded then
        file:close()
        return false
    end
    file:write(encoded)
    file:close()
    log_info("cached thought groups:", #reviews, "chapter:", chapter_uid)
    return true
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

    local ok_ul, ul_data, err_ul = client:get_chapter_underlines(book_id, chapter_uid)
    if not ok_ul or type(ul_data) ~= "table" then
        log_info("skip underlines:", err_ul or "no data")
        return xhtml, ""
    end

    local ranges = Thoughts.collect_ranges(ul_data)
    local thought_reviews
    if #ranges > 0 then
        local ok_tr, tr_data = client:get_chapter_reviews(book_id, chapter_uid, ranges)
        if ok_tr and type(tr_data) == "table" and #(tr_data.reviews or {}) > 0 then
            thought_reviews = tr_data.reviews
            Thoughts.save_cache(settings, book_id, chapter_uid, thought_reviews)
        end
    end

    ul_data.chapterUid = chapter_uid
    local processed, annotation_css = Annotations.process(xhtml, ul_data, thought_reviews)
    if processed ~= xhtml then
        log_info("injected underlines for chapter:", chapter_uid)
    end
    return processed, annotation_css or ""
end

function Thoughts.merge_css(base_css, annotation_css)
    if not annotation_css or annotation_css == "" then
        return base_css
    end
    base_css = base_css or [[body { line-height: 1.7; margin: 5%; } img { max-width: 100%; }]]
    return base_css .. "\n" .. annotation_css
end

return Thoughts
