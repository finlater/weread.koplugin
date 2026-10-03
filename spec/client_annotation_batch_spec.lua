package.path = "./?.lua;" .. package.path

local set_timeout_calls = {}
package.preload["ltn12"] = function() return { source = { string = function() return end } } end
package.preload["socketutil"] = function()
    return {
        set_timeout = function(_self, block_timeout, total_timeout)
            set_timeout_calls[#set_timeout_calls + 1] = { block = block_timeout, total = total_timeout }
        end,
        reset_timeout = function() end,
        table_sink = function() return function() return 1 end end,
    }
end
package.preload["socket.http"] = function()
    return { request = function() return 1, 200, {}, "200 OK" end }
end
package.preload["json"] = function()
    return { encode = function() return "{}" end, decode = function() return {} end }
end
package.preload["weread.lib.cookie"] = function() return { to_header = function() return "" end } end
package.preload["weread.lib.protocol"] = function()
    return { USER_AGENT = "test", urlencode = function(value) return value end }
end

local Client = require("weread.lib.client")
local client = setmetatable({}, { __index = Client })
local ranges = {}
for index = 1, 61 do ranges[index] = tostring(index) end

local batches = client:build_chapter_review_batches(ranges)
assert(#batches == 3, "61 ranges must be split into three requests")
assert(#batches[1] == 30 and #batches[2] == 30 and #batches[3] == 1,
    "thought requests must contain at most 30 ranges")
assert(batches[1][1].range == "1" and batches[2][1].range == "31"
        and batches[3][1].range == "61",
    "thought range order changed while batching")
assert(batches[1][1].count == 30 and batches[1][1].maxIdx == 0
        and batches[1][1].synckey == 0,
    "thought pagination parameters changed")

-- The bounded total timeout is opt-in: only annotation sync passes it, so a
-- non-sync request keeps the transport default (unbounded total timeout).
client.settings = { get = function(_self, _key, default) return default end }
client:request({ url = "https://weread.qq.com/web/reader", method = "GET" })
assert(set_timeout_calls[1] and set_timeout_calls[1].block == 15
        and set_timeout_calls[1].total == -1,
    "a non-sync request changed its total timeout")
set_timeout_calls = {}
client:request({ url = "https://weread.qq.com/web/reader", method = "GET",
    total_timeout = Client.ANNOTATION_SYNC_TOTAL_TIMEOUT })
assert(set_timeout_calls[1] and set_timeout_calls[1].block == 15
        and set_timeout_calls[1].total == Client.ANNOTATION_SYNC_TOTAL_TIMEOUT,
    "an annotation-sync request did not bound its total timeout")

-- The annotation-sync client methods forward the option to the transport.
local forwarded = {}
client.gateway = function(_self, api, _params, opts)
    forwarded[api] = opts and opts.total_timeout
    return api == "/book/underlines" and { underlines = {} } or { reviews = {} }
end
client:get_chapter_underlines("1", "2", { total_timeout = Client.ANNOTATION_SYNC_TOTAL_TIMEOUT })
client:get_chapter_reviews_batch("1", "2", { { range = "1" } },
    { total_timeout = Client.ANNOTATION_SYNC_TOTAL_TIMEOUT })
assert(forwarded["/book/underlines"] == Client.ANNOTATION_SYNC_TOTAL_TIMEOUT
        and forwarded["/book/readreviews"] == Client.ANNOTATION_SYNC_TOTAL_TIMEOUT,
    "annotation client methods dropped the bounded total timeout")

print("client_annotation_batch_spec: 30-range thought batches and bounded sync timeout passed")
