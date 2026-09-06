--[[--
Normalization for WeRead review comments (GET /web/review/single).

The client method returns the raw decoded payload. This module turns it into
the plain-text shape used by the UI:

    {
        review_id = "…",
        err_code = nil,       -- server errCode passthrough (nil on success)
        total_count = 2,      -- server-reported total, falls back to #comments
        comments = {
            { author = "…", content = "…", likes_count = 0, create_time = 0 },
        },
    }

A payload without a `comments` key is a valid, empty comment list. A payload
carrying `errCode` means the server rejected the lookup (for example an
invalid reviewId); the code is surfaced via `err_code` so the caller can show
a failure instead of an empty view.
--]]--

local BookReviews = require("weread.lib.book_reviews")

local ReviewComments = {}

local function trim(text)
    return tostring(text or ""):match("^%s*(.-)%s*$")
end

local function author_name(author)
    if type(author) == "table" then
        return trim(author.nick or author.name or author.userName or author.username)
    end
    return trim(author)
end

local function normalize_comment(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local content = BookReviews.plain_text(entry.content)
    if content == "" then
        content = BookReviews.plain_text(entry.htmlContent)
    end
    return {
        author = author_name(entry.author),
        content = content,
        likes_count = tonumber(entry.likesCount) or tonumber(entry.likes) or 0,
        create_time = tonumber(entry.createTime) or 0,
    }
end

--- Normalize a raw /web/review/single payload. Never raises; non-table input
--- normalizes to an empty result so a degraded payload cannot break the popup.
function ReviewComments.normalize(data)
    data = type(data) == "table" and data or {}
    local comments = {}
    for _i, entry in ipairs(data.comments or {}) do
        local comment = normalize_comment(entry)
        if comment then
            comments[#comments + 1] = comment
        end
    end
    return {
        review_id = type(data.reviewId) == "string" and data.reviewId or nil,
        err_code = data.errCode,
        total_count = tonumber(data.commentsCount) or #comments,
        comments = comments,
    }
end

return ReviewComments
