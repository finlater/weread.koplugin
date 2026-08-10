package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) callback() end,
        preventStandby = function() end,
        allowStandby = function() end,
    }
end
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["ui/time"] = function()
    return { now = function() return 1000 end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        normalize_cover_url = function(value) return value end,
        reader_url = function(book_id, chapter_uid)
            return "https://weread.qq.com/reader/" .. tostring(book_id)
                .. "/" .. tostring(chapter_uid or "")
        end,
    }
end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["weread.lib.footnotes"] = function() return {} end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.ui.download_dialog"] = function() return {} end

local pool_options
package.preload["weread.lib.parallel"] = function()
    return {
        start = function(options)
            pool_options = options
            return { fake = true }
        end,
    }
end

local Downloader = require("weread.lib.downloader")

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root)))
local workspace = {
    path = root .. "/.weread-download-100-123456",
}
workspace.incoming_dir = workspace.path .. "/incoming"
workspace.asset_dir = workspace.path .. "/images"
assert(os.execute("mkdir -p " .. string.format("%q", workspace.incoming_dir)))
assert(os.execute("mkdir -p " .. string.format("%q", workspace.asset_dir)))

local function tar_header(name, size)
    local header = name .. string.rep("\0", 100 - #name)
    header = header .. string.rep("0", 24)
    header = header .. string.format("%011o\0", size)
    header = header .. string.rep("0", 20) .. "0"
    return header .. string.rep("\0", 512 - #header)
end

local tar_image = "\255\216\255chapter-image"
local tar_padding = (512 - #tar_image % 512) % 512
local tar_data = tar_header("chapter.jpg", #tar_image)
    .. tar_image .. string.rep("\0", tar_padding) .. string.rep("\0", 1024)
local download_calls = {}
local client = {
    without_cookie_persistence = function(_self, callback) return callback() end,
    get_binary = function() error("image pool must not load a binary response") end,
    download_to_file = function(_self, url, path, options)
        download_calls[#download_calls + 1] = {
            url = url,
            path = path,
            max_bytes = options.max_bytes,
        }
        local file = assert(io.open(path, "wb"))
        if url:find("chapter.tar", 1, true) then
            file:write(tar_data)
        else
            file:write("\137PNG\r\n\26\nremote-image")
        end
        file:close()
        return path
    end,
}

local committed
local downloader = Downloader:new{ client = client }
downloader._scheduleGuarded = function(_self, _dl, callback) callback() end
downloader._commitChapter = function(_self, _dl, xhtml, assets)
    committed = { xhtml = xhtml, assets = assets }
end
local chapter = {
    chapterUid = 7,
    tar = "https://cdn.example/chapter.tar",
}
local dl = {
    book = { book_id = "book" },
    current = {
        chapter = chapter,
        xhtml = '<html><body><img src="chapter.jpg"/>'
            .. '<img src="https://cdn.example/remote.png"/></body></html>',
    },
    state = {},
    workspace = workspace,
    parallel = { images = 2 },
    index = 1,
    total = 1,
    cancelled = false,
}

expect(downloader:_startImagePool(dl), "image pool did not start")
expect(pool_options and pool_options.base_dir == workspace.incoming_dir,
    "image pool did not use the workspace filesystem")
expect(#pool_options.tasks == 2,
    "image pool did not schedule both TAR and remote image requests")

for index, task in ipairs(pool_options.tasks) do
    local task_dir = workspace.incoming_dir .. "/task-" .. tostring(index)
    assert(os.execute("mkdir -p " .. string.format("%q", task_dir)))
    pool_options.worker(task, task_dir)
    local path, load_error = pool_options.load_result(task, task_dir, true)
    expect(type(path) == "string" and load_error == nil,
        "image loader returned bytes or an error instead of a path")
    pool_options.on_result(task, path, nil, index, #pool_options.tasks)
    assert(os.execute("rm -rf " .. string.format("%q", task_dir)))
end
pool_options.on_complete(true)

expect(#download_calls == 2 and download_calls[1].max_bytes > 0
        and download_calls[2].max_bytes > 0,
    "image workers did not stream both bounded downloads")
expect(committed and #committed.assets == 2,
    "file-backed image results were not committed")
for _, asset in ipairs(committed.assets or {}) do
    expect(asset.data == nil and type(asset.path) == "string"
            and asset.path:find(workspace.asset_dir, 1, true) == 1,
        "image pool retained payload bytes outside the workspace")
end
expect(committed.xhtml:find("../images/chapter.jpg", 1, true)
        and not committed.xhtml:find("https://cdn.example/remote.png", 1, true),
    "image pool did not rewrite staged image sources")

assert(os.execute("rm -rf " .. string.format("%q", root)))
print(("downloader_image_pool_spec: %d checks"):format(checks))
