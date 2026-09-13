package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local scheduled = {}
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
        scheduleIn = function(_self, delay, callback)
            expect(delay >= 0.1, "footnote processing used a blocking schedule delay")
            scheduled[#scheduled + 1] = callback
        end,
        preventStandby = function() end,
        allowStandby = function() end,
        show = function() end,
    }
end
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
        dbg = function() end,
    }
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
local resumable_raw = {}
local resumable_rendered = {}
local rendered_resets = 0
package.preload["weread.lib.content"] = function()
    return {
        reset_full_download_rendered_text = function()
            rendered_resets = rendered_resets + 1
            resumable_rendered = {}
        end,
        load_full_download_chapter = function(_workspace, chapter)
            return resumable_raw[tostring(chapter.chapterUid)]
        end,
        save_full_download_rendered_chapter = function(_workspace, chapter, _index, body)
            resumable_rendered[tostring(chapter.chapterUid)] = body
        end,
    }
end
package.preload["weread.ui.download_dialog"] = function() return {} end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.thoughts"] = function()
    return { is_download_enabled = function() return false end }
end
package.preload["weread.lib.protocol"] = function()
    return { normalize_cover_url = function(value) return value end }
end

local Footnotes = require("weread.lib.footnotes")
local Downloader = require("weread.lib.downloader")

local source_chapter = {
    chapterUid = 1, chapterIdx = 1, files = { "Text/chapter1.xhtml" },
}
local note_chapter = {
    chapterUid = 2, chapterIdx = 2, files = { "Text/chapter2.xhtml" },
}
local source = [[<p><a class="noteref" href="../Text/chapter2.xhtml#target2">[2]</a></p>]]
local note = [[<p id="target2">[2] 下载器跨章脚注</p>]]

local network_accesses = 0
local client = setmetatable({}, {
    __index = function()
        network_accesses = network_accesses + 1
        error("footnote finalization must not access the network client")
    end,
})
local downloader = Downloader:new{
    client = client,
    settings = {
        get = function()
            return { book_footnotes_in_popup = true }
        end,
    },
    show_transient = function() end,
}
local dl = {
    client = client,
    cancelled = false,
    selected = { source_chapter, note_chapter },
    bodies = { ["1"] = source, ["2"] = note },
    footnote_scans = {
        ["1"] = Footnotes.scan_chapter(source, source_chapter),
        ["2"] = Footnotes.scan_chapter(note, note_chapter),
    },
    footnote_stats = {
        candidates = 0, converted = 0, image_notes = 0,
        backlinks = 0, removed_note_blocks = 0,
        unresolved = 0, fallback = 0,
    },
    state = { css = "body{}" },
    index = 3,
    total = 2,
    progress_dialog = {
        setTitle = function() end,
        reportProgress = function() end,
    },
}

downloader:_startFootnotes(dl)
expect(#scheduled == 1, "footnote phase did not schedule its first chapter")
scheduled[1]()
expect(#scheduled == 2, "first chapter did not yield before continuing")
scheduled[2]()
expect(#scheduled == 3, "second chapter did not yield before completion")
scheduled[3]()

expect(dl.footnotes_done == true, "footnote phase did not complete")
expect(network_accesses == 0, "full-book footnote processing accessed the network")
expect(dl.footnote_stats.converted == 1 and dl.footnote_stats.unresolved == 0,
    "downloader did not aggregate footnote conversion statistics")
expect(dl.bodies["1"]:find("下载器跨章脚注", 1, true),
    "downloader did not embed a cross-chapter note")
local _, css_count = dl.state.css:gsub("%.wr%-fn%-ref%{", "")
expect(css_count == 1, "footnote CSS was not merged exactly once")
expect(dl.state.css:find(
        "aside.wr%-book%-footnote{%-cr%-hint:footnote;", 1) ~= nil
        and dl.state.css:find("visibility:hidden", 1, true) ~= nil,
    "popup preference did not select the previous footnote CSS")

local resumed_source_chapter = {
    chapterUid = 11, chapterIdx = 1, files = { "Text/chapter1.xhtml" },
}
local resumed_reference_chapter = {
    chapterUid = 22, chapterIdx = 2, files = { "Text/chapter2.xhtml" },
}
resumable_raw = {
    ["11"] = [[<p><a class="noteref" href="#shared-note">[1]</a></p>
<p id="shared-note">[1] 可跨章节恢复的脚注</p>]],
    ["22"] = [[<p><a class="noteref" href="../Text/chapter1.xhtml#shared-note">[1]</a></p>]],
}

local function new_resumable_footnote_job()
    return {
        cancelled = false,
        resumable = true,
        workspace = { rendered_text_dir = "/cache/rendered-text" },
        chapters = { resumed_source_chapter, resumed_reference_chapter },
        selected = { resumed_source_chapter, resumed_reference_chapter },
        bodies = {},
        footnote_scans = {},
        footnote_stats = {
            candidates = 0, converted = 0, image_notes = 0,
            backlinks = 0, removed_note_blocks = 0,
            unresolved = 0, fallback = 0,
        },
        state = { css = "body{}" },
        index = 3,
        total = 2,
        progress_dialog = {
            setTitle = function() end,
            reportProgress = function() end,
        },
    }
end

local function run_resumable_footnotes(resumable_dl)
    local before = #scheduled
    downloader:_startFootnotes(resumable_dl)
    scheduled[before + 1]()
    scheduled[before + 2]()
    scheduled[before + 3]()
end

local first_run = new_resumable_footnote_job()
run_resumable_footnotes(first_run)
expect(resumable_raw["11"]:find('id="shared-note"', 1, true),
    "first footnote conversion mutated the raw resumable checkpoint")

local restarted_run = new_resumable_footnote_job()
run_resumable_footnotes(restarted_run)
expect(rendered_resets == 2,
    "resumed footnote pass did not discard stale rendered chapters")
expect(restarted_run.footnote_stats.unresolved == 0,
    "cross-chapter footnote was unresolved after rebuilding from checkpoints")
expect(resumable_rendered["22"]:find("可跨章节恢复的脚注", 1, true),
    "restarted footnote pass did not embed the cross-chapter definition")
expect(restarted_run.state.css:find("%.wr%-fn%-ref%{", 1) ~= nil,
    "restarted footnote pass did not rebuild its stylesheet")

local original_transform = Footnotes.transform_chapter
Footnotes.transform_chapter = function()
    error("injected footnote transformation failure")
end
local transform_fallback_run = new_resumable_footnote_job()
run_resumable_footnotes(transform_fallback_run)
Footnotes.transform_chapter = original_transform
expect(transform_fallback_run.footnote_stats.fallback == 2,
    "footnote transformation failures did not use original chapter fallbacks")
expect(resumable_rendered["11"] == resumable_raw["11"]
    and resumable_rendered["22"] == resumable_raw["22"],
    "footnote transformation fallback did not stage original chapters for packaging")

local original_validate = Footnotes.validate
Footnotes.validate = function() return false, "injected validation failure" end
local validation_fallback_run = new_resumable_footnote_job()
run_resumable_footnotes(validation_fallback_run)
Footnotes.validate = original_validate
expect(validation_fallback_run.footnote_stats.fallback == 2,
    "footnote validation failures did not use original chapter fallbacks")
expect(resumable_rendered["11"] == resumable_raw["11"]
    and resumable_rendered["22"] == resumable_raw["22"],
    "footnote validation fallback did not stage original chapters for packaging")

print(("downloader_footnotes_spec: %d checks"):format(checks))
