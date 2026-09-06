-- Normalization tests for /web/review/single comment payloads.
package.path = "./?.lua;" .. package.path

local ReviewComments = require("weread.lib.review_comments")

local failures, checks = 0, 0
local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
    end
end

do
    local result = ReviewComments.normalize({
        reviewId = "r1",
        commentsCount = 2,
        comments = {
            {
                author = { name = "Alice" },
                content = "<p>First &amp; foremost</p>",
                likesCount = 3,
                createTime = 1700000000000,
            },
            {
                author = "Bob",
                htmlContent = "Second<br>line",
            },
        },
    })
    eq(result.review_id, "r1", "review id passthrough")
    eq(result.err_code, nil, "successful payload carries no errCode")
    eq(result.total_count, 2, "server commentsCount becomes total")
    eq(#result.comments, 2, "both comments kept")
    eq(result.comments[1].author, "Alice", "author table resolves to name")
    eq(result.comments[1].content, "First & foremost", "html content flattened to plain text")
    eq(result.comments[1].likes_count, 3, "likes parsed")
    eq(result.comments[2].author, "Bob", "plain string author kept")
    eq(result.comments[2].content, "Second\nline", "htmlContent fallback with line breaks")
    eq(result.comments[2].likes_count, 0, "missing likes default to zero")
    eq(result.comments[2].create_time, 0, "missing create time defaults to zero")
end

-- A payload without a comments key is a valid, empty list.
do
    local result = ReviewComments.normalize({ reviewId = "r2", review = {} })
    eq(result.review_id, "r2", "review id kept without comments")
    eq(#result.comments, 0, "missing comments key normalizes to empty list")
    eq(result.total_count, 0, "total falls back to zero comments")
end

-- Server rejection payloads surface their errCode instead of masquerading
-- as an empty comment list.
do
    local result = ReviewComments.normalize({ errCode = -2003, errLine = "..." })
    eq(result.err_code, -2003, "errCode passthrough")
    eq(#result.comments, 0, "rejected payload has no comments")
end

-- Degraded payloads must not raise.
do
    local result = ReviewComments.normalize(nil)
    eq(#result.comments, 0, "nil payload normalizes to empty result")
    local messy = ReviewComments.normalize({
        comments = { "junk", { author = { nick = "Nick" }, content = "ok" }, 42 },
    })
    eq(#messy.comments, 1, "non-table comment entries skipped")
    eq(messy.comments[1].author, "Nick", "author nick preferred over name")
end

print(string.format("review_comments_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
