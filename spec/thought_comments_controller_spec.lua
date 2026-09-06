-- End-to-end regression for the controller-side comment flow: fetch,
-- normalize, and display comments of one thought (Issue #104).
package.path = "./?.lua;" .. package.path

local textviewer_args
local infos, labels, api_calls = {}, {}, {}

package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.ui.download_dialog"] = function() return {} end
package.preload["weread.lib.thought_db"] = function() return {} end
package.preload["weread.ui.thought_popup"] = function() return {} end
package.preload["weread.ui.thought_popup.popup_config"] = function() return {} end
package.preload["ui/event"] = function() return {} end
package.preload["ui/time"] = function()
    return { now = function() return {} end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        close = function() end,
        scheduleIn = function() end,
        setDirty = function() end,
    }
end
package.preload["ui/widget/textviewer"] = function()
    return {
        new = function(_, args)
            textviewer_args = args
            return { is_textviewer = true }
        end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local out = tostring(text)
            for index, value in ipairs({ ... }) do
                out = out:gsub("%%" .. index, tostring(value), 1)
            end
            return out
        end,
        log_error = function(err) return tostring(err) end,
        display_error = function(err) return tostring(err) end,
        thought_perf = function() end,
    }
end

local Controller = require("weread.ui.annotations_controller")

local failures, checks = 0, 0
local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
    end
end
local function contains(haystack, needle, label)
    checks = checks + 1
    if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want it to contain %s",
            label, tostring(haystack), needle))
    end
end

-- Fake plugin: mixin target providing the collaborators the flow touches.
local function build_plugin(api)
    return setmetatable({
        client = { get_review_comments = api },
        showBusy = function() end,
        closeBusy = function() end,
        showInfo = function(_, text)
            infos[#infos + 1] = text
        end,
        runOnlineTask = function(_, label, callback)
            labels[#labels + 1] = label
            callback()
            return true
        end,
    }, { __index = Controller })
end

-- happy path: comments fetched, normalized, rendered in a TextViewer
do
    textviewer_args = nil
    infos, labels, api_calls = {}, {}, {}
    local plugin = build_plugin(function(_, review_id, count)
        api_calls[#api_calls + 1] = { review_id = review_id, count = count }
        return true, {
            reviewId = review_id,
            commentsCount = 2,
            comments = {
                { author = { name = "Alice" }, content = "hello", likesCount = 2 },
                { author = "Bob", content = "world" },
            },
        }
    end)

    plugin:_viewThoughtComments({ review_id = "rv-1" })
    eq(api_calls[1] and api_calls[1].review_id, "rv-1", "fetch uses the item review id")
    eq(api_calls[1] and api_calls[1].count, 50, "requests up to 50 comments")
    eq(textviewer_args ~= nil, true, "comments render in a TextViewer")
    eq(textviewer_args.title, "Comments (2)", "title carries the server total")
    contains(textviewer_args.text, "Alice", "author shown")
    contains(textviewer_args.text, "hello", "content shown")
    contains(textviewer_args.text, "♥ 2", "likes shown")
    contains(textviewer_args.text, "Bob", "second comment shown")
    eq(#infos, 0, "happy path shows no extra info dialog")
end

-- missing review id: no request, no UI
do
    textviewer_args = nil
    infos, labels, api_calls = {}, {}, {}
    local plugin = build_plugin(function(_, review_id)
        api_calls[#api_calls + 1] = review_id
        return true, {}
    end)
    plugin:_viewThoughtComments({ content = "legacy row" })
    eq(#api_calls, 0, "no request without review id")
    eq(textviewer_args, nil, "no viewer without review id")
    eq(#labels, 0, "no task started without review id")
end

-- empty comment list: info message instead of a viewer
do
    textviewer_args = nil
    infos, labels, api_calls = {}, {}, {}
    local plugin = build_plugin(function()
        return true, { reviewId = "rv-2", comments = {} }
    end)
    plugin:_viewThoughtComments({ review_id = "rv-2" })
    eq(textviewer_args, nil, "empty comments show no viewer")
    contains(infos[1], "No comments on this thought yet.", "empty state message")
end

-- transport failure: labeled error info
do
    textviewer_args = nil
    infos, labels, api_calls = {}, {}, {}
    local plugin = build_plugin(function()
        return false, nil, "boom"
    end)
    plugin:_viewThoughtComments({ review_id = "rv-3" })
    eq(textviewer_args, nil, "failure shows no viewer")
    contains(labels[1], "Comments", "failure label is the feature name")
    contains(infos[1], "failed", "failure message marks the failure")
    contains(infos[1], "boom", "failure message carries the error")
end

-- server rejection payload: errCode surfaced
do
    textviewer_args = nil
    infos, labels, api_calls = {}, {}, {}
    local plugin = build_plugin(function()
        return true, { errCode = -2003 }
    end)
    plugin:_viewThoughtComments({ review_id = "rv-4" })
    eq(textviewer_args, nil, "rejected payload shows no viewer")
    contains(infos[1], "-2003", "errCode surfaced to the user")
end

print(string.format("thought_comments_controller_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
