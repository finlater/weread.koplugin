--[[--
微信读书想法自定义弹窗 Widget

照搬 KOReader FootnoteWidget 的布局结构，增加：
    1. 自定义高度（配置比例，默认 35%）
    2. 字体 fallback 链（书籍字体 → CJK → NotoSans）
    3. 左右滑动关闭弹窗
    4. 性能优化：regular weight 字体、CSS 缓存、MuPDF 预热

@module ui.thought_popup
--]]--

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local time = require("ui/time")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local logger = require("logger")

local function thought_perf(stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.dbg("weread: thought_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed), ...)
end
-- ============================================================================
-- 字体预加载模块
-- ============================================================================
local FontPreloader = {
    initialized = false,
    emoji_path = nil,
    font_paths_cache = {},
}

function FontPreloader:init()
    if self.initialized then return end

    self:findEmojiFont()

    pcall(function()
        require("document/credocument"):engineInit()
    end)

    self.initialized = true
    logger.info("weread: font preloader initialized, emoji font:", self.emoji_path or "not found")
end

local function plugin_root_dir()
    local source = debug.getinfo(1, "S").source or ""
    local path = source:match("^@(.+)$") or source
    local dir = path:match("^(.*)/[^/]+$") or "."
    return dir:match("^(.*)/lib$") or dir
end

function FontPreloader:findEmojiFont()
    if self.emoji_path then return self.emoji_path end

    local ffiutil = require("ffi/util")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

    local function resolveEmojiPath(path)
        if not path then return nil end
        if ok_lfs and lfs.attributes(path, "mode") ~= "file" then
            return nil
        end
        if ffiutil.realpath then
            return ffiutil.realpath(path) or path
        end
        return path
    end

    local emoji_rel = "fonts/NotoEmoji-Regular.ttf"
    local candidates = {
        plugin_root_dir() .. "/" .. emoji_rel,
        "weread.koplugin/" .. emoji_rel,
        "plugins/weread.koplugin/" .. emoji_rel,
    }
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds then
        local data_dir = DataStorage:getDataDir()
        candidates[#candidates + 1] = data_dir .. "/weread.koplugin/" .. emoji_rel
        candidates[#candidates + 1] = data_dir .. "/plugins/weread.koplugin/" .. emoji_rel
    end
    for _, path in ipairs(candidates) do
        local abs = resolveEmojiPath(path)
        if abs then
            self.emoji_path = abs
            logger.info("weread: thought popup emoji font:", abs)
            return self.emoji_path
        end
    end

    local dirs = {
        "/mnt/us/fonts/",
        "/usr/share/fonts/truetype/",
    }
    for _, dir in ipairs(dirs) do
        local fp = dir .. "NotoEmoji-Regular.ttf"
        if lfs.attributes(fp, "mode") == "file" then
            self.emoji_path = fp
            return self.emoji_path
        end
    end
    return nil
end

function FontPreloader:getFontPaths(doc_font_name)
    if not doc_font_name then return {} end

    if self.font_paths_cache[doc_font_name] then
        return self.font_paths_cache[doc_font_name]
    end

    local paths = {}
    local ok, cre = pcall(function()
        return require("document/credocument"):engineInit()
    end)
    if not ok or not cre or type(cre.getFontFaceFilenameAndFaceIndex) ~= "function" then
        self.font_paths_cache[doc_font_name] = paths
        return paths
    end

    local seen = {}
    for i = 1, 4 do
        local bold = i >= 3
        local italic = i == 2 or i == 4
        local font_path = cre.getFontFaceFilenameAndFaceIndex(doc_font_name, bold, italic)
        if font_path and not seen[font_path] then
            seen[font_path] = true
            paths[#paths + 1] = {path = font_path, bold = bold, italic = italic}
        end
    end

    self.font_paths_cache[doc_font_name] = paths
    return paths
end

function FontPreloader:preloadForFont(doc_font_name)
    if not doc_font_name then return end
    self:getFontPaths(doc_font_name)
end

-- ============================================================================
-- CSS 模板缓存模块（仅 regular weight 字体，减少 MuPDF I/O）
-- ============================================================================
local CSSCache = {
    font_css_cache = {},
    full_css_cache = {},
    emoji_pattern = nil,
}

function CSSCache:init()
    self.emoji_pattern = '([\240-\244][\128-\191][\128-\191][\128-\191]+)'
end

function CSSCache:getFontCSS(doc_font_name)
    local cache_key = doc_font_name or "__no_font__"
    if self.font_css_cache[cache_key] then
        return self.font_css_cache[cache_key]
    end

    -- 仅加载 regular weight 字体，减少 MuPDF 文档创建时的磁盘 I/O
    local css = ""
    local font_paths = FontPreloader:getFontPaths(doc_font_name)

    for _, fp in ipairs(font_paths) do
        if not fp.bold and not fp.italic then
            logger.info("weread: thought popup font file:", fp.path)
            css = css .. "\n@font-face { font-family: 'ThoughtMainFont'; src: url('" .. fp.path .. "') }"
            break
        end
    end
    if css == "" and font_paths[1] then
        local fp = font_paths[1]
        css = css .. "\n@font-face { font-family: 'ThoughtMainFont'; src: url('" .. fp.path .. "')"
            .. (fp.bold and "; font-weight: bold" or "")
            .. (fp.italic and "; font-style: italic" or "")
            .. "}"
    end

    if FontPreloader.emoji_path then
        css = css .. "\n@font-face { font-family: 'ThoughtEmojiFont'; src: url('"
            .. FontPreloader.emoji_path .. "') }"
    end

    local families = {}
    if doc_font_name then
        families[#families + 1] = "'ThoughtMainFont'"
    end
    families[#families + 1] = "'Noto Sans'"
    families[#families + 1] = "sans-serif"

    local line_height = doc_font_name and "1.2" or "1.3"
    css = css .. "\nbody { font-family: " .. table.concat(families, ", ")
    css = css .. "; line-height: " .. line_height .. " !important; }\n"

    self.font_css_cache[cache_key] = css
    return css
end

function CSSCache:getFullCSS(doc_font_name, doc_margins, extra_css)
    local cache_key = (doc_font_name or "__no_font__")
        .. string.format("_%d_%d_%d_%d",
            doc_margins.left, doc_margins.right,
            doc_margins.top, doc_margins.bottom)
        .. (extra_css or "")
    if self.full_css_cache[cache_key] then
        return self.full_css_cache[cache_key]
    end

    local font_css = self:getFontCSS(doc_font_name)
    if extra_css then
        font_css = font_css .. "\n" .. extra_css
    end

    local left_margin = doc_margins.left .. "px"
    local right_margin = "0"
    if BD.mirroredUILayout() then
        left_margin, right_margin = right_margin, left_margin
    end

    local families = {}
    if doc_font_name then
        families[#families + 1] = "'ThoughtMainFont'"
    end
    families[#families + 1] = "'Noto Sans'"
    families[#families + 1] = "sans-serif"

    local css = string.format([[
body {
    margin: 0;
    padding: 0;
    line-height: %s;
    font-family: %s;
}
p { margin: 0 0 0.3em 0; }
a { color: black; text-decoration: none; }
.wr-underline { border-bottom: 2px dashed #ff6b35; padding-bottom: 2px; }
.wr-thought-link { text-decoration: none; color: inherit; }
.wr-star{font-size:0.6em;vertical-align:super;line-height:0;color:#aaa;}
blockquote { margin: 0 0.5em; padding-left: 0.5em; border-left: 2px solid #ddd; }
.footnote { font-size: 0.9em; color: #555; }
@page { margin: 0 %s 0 %s; }
]],
        doc_font_name and "1.2" or "1.3",
        table.concat(families, ", "),
        right_margin, left_margin
    )

    css = css .. font_css

    self.full_css_cache[cache_key] = css
    return css
end

function CSSCache:wrapEmoji(html)
    if type(html) ~= "string" then return html end
    if not html:find('[\240-\244]') then return html end
    return html:gsub(self.emoji_pattern,
        '<span style="font-family: \'ThoughtEmojiFont\', \'ThoughtMainFont\', \'Noto Sans\', sans-serif">%1</span>')
end

-- ============================================================================
-- HTML 预处理 & ScrollHtmlWidget 构建
-- ============================================================================
local function cleanupHTML(html)
    if type(html) ~= "string" then return "" end
    html = html:gsub("<script[^>]*>.-</script>", "")
    html = html:gsub("<style[^>]*>.-</style>", "")
    html = html:gsub([[>[%s]+<]], [[><]])
    return html
end

local function prepareHTML(html)
    html = cleanupHTML(html)
    html = CSSCache:wrapEmoji(html)
    return html
end

local PREWARM_HTML = '<aside epub:type="footnote" class="footnote weread-thought"><p> </p></aside>'

local function createScrollHtmlWidget(html, css, doc_font_size, doc_margins, height_ratio, dialog)
    local ratio = math.max(0.1, math.min(0.9, height_ratio or 0.35))
    local width = Screen:getWidth()
    local height = math.floor(Screen:getHeight() * ratio)

    local item_width = math.min(math.ceil(doc_margins.right * 2 / 5), Screen:scaleBySize(10))
    local scroll_bar_width = item_width
    local padding_right = item_width
    local text_scroll_span = doc_margins.right - scroll_bar_width - padding_right
    if text_scroll_span < padding_right then
        text_scroll_span, padding_right = padding_right, text_scroll_span
    end
    local htmlwidget_width = width - padding_right

    local padding_top = Size.padding.large
    local padding_bottom = Size.padding.large
    local htmlwidget_height = height - padding_top - padding_bottom

    return ScrollHtmlWidget:new{
        html_body = html,
        is_xhtml = true,
        css = css,
        default_font_size = doc_font_size,
        width = htmlwidget_width,
        height = htmlwidget_height,
        scroll_bar_width = scroll_bar_width,
        text_scroll_span = text_scroll_span,
        dialog = dialog,
    }
end

-- ============================================================================
-- ThoughtPopupWidget 主模块
-- ============================================================================
local ThoughtPopupWidget = InputContainer:extend{
    html = nil,
    css = nil,
    font_face = "Noto Sans",
    doc_font_size = Screen:scaleBySize(18),
    doc_font_name = nil,
    doc_margins = {
        left = Screen:scaleBySize(20),
        right = Screen:scaleBySize(20),
        top = Screen:scaleBySize(10),
        bottom = Screen:scaleBySize(10),
    },
    height_ratio = 0.35,
    close_callback = nil,
    dialog = nil,
    covers_footer = true,
}

function ThoughtPopupWidget:init()
    local init_started = time.now()
    self.height_ratio = math.max(0.1, math.min(0.9, self.height_ratio or 0.35))
    self.width = Screen:getWidth()
    self.height = math.floor(Screen:getHeight() * self.height_ratio)

    if Device:isTouchDevice() then
        local range = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        self.ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = range,
                }
            },
            SwipeClose = {
                GestureRange:new{
                    ges = "swipe",
                    range = range,
                }
            },
        }
    end

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end

    local prepare_started = time.now()
    self.html = prepareHTML(self.html)
    thought_perf("prepare_html_new", prepare_started, "html_bytes=", tostring(#self.html))
    local css_started = time.now()
    local css = CSSCache:getFullCSS(self.doc_font_name, self.doc_margins, self.css)
    thought_perf("build_css_new", css_started, "css_bytes=", tostring(#css))
    local widget_started = time.now()
    self.htmlwidget = createScrollHtmlWidget(self.html, css, self.doc_font_size,
        self.doc_margins, self.height_ratio, self.dialog)
    thought_perf("create_html_widget_new", widget_started, "html_bytes=", tostring(#self.html))
    local layout_started = time.now()
    self:_buildLayout()
    thought_perf("build_layout_new", layout_started)
    thought_perf("popup_init_total", init_started, "html_bytes=", tostring(#self.html))
end

function ThoughtPopupWidget:onShow()
    UIManager:setDirty(self.dialog, function()
        return "partial", self.container.dimen
    end)
end

function ThoughtPopupWidget:_reopen(opts)
    local reopen_started = time.now()
    local prepare_started = time.now()
    self.html = prepareHTML(opts.html)
    thought_perf("prepare_html_reopen", prepare_started, "html_bytes=", tostring(#self.html))
    if opts.css then self.css = opts.css end
    self.doc_font_name = opts.doc_font_name or self.doc_font_name
    self.doc_font_size = opts.doc_font_size or self.doc_font_size
    self.doc_margins = opts.doc_margins or self.doc_margins
    self.height_ratio = opts.height_ratio or self.height_ratio
    self.dialog = opts.dialog or self.dialog
    self.close_callback = opts.close_callback
    self.height = math.floor(Screen:getHeight() * self.height_ratio)

    if self.htmlwidget then
        local free_started = time.now()
        self.htmlwidget:free()
        self.htmlwidget = nil
        thought_perf("free_html_widget", free_started)
    end

    local css_started = time.now()
    local css = CSSCache:getFullCSS(self.doc_font_name, self.doc_margins, self.css)
    thought_perf("build_css_reopen", css_started, "css_bytes=", tostring(#css))
    local widget_started = time.now()
    self.htmlwidget = createScrollHtmlWidget(self.html, css, self.doc_font_size,
        self.doc_margins, self.height_ratio, self.dialog)
    thought_perf("create_html_widget_reopen", widget_started, "html_bytes=", tostring(#self.html))
    local layout_started = time.now()
    self:_buildLayout()
    thought_perf("build_layout_reopen", layout_started)
    thought_perf("popup_reopen_total", reopen_started, "html_bytes=", tostring(#self.html))
end

function ThoughtPopupWidget:_buildLayout()
    self:clear()

    local item_width = math.min(math.ceil(self.doc_margins.right * 2 / 5), Screen:scaleBySize(10))
    local padding_right = item_width
    local padding_top = Size.padding.large
    local padding_bottom = Size.padding.large
    local top_border_size = Size.line.thick
    local vgroup = VerticalGroup:new{
        LineWidget:new{
            dimen = Geom:new{
                w = self.width,
                h = top_border_size,
            }
        },
        VerticalSpan:new{ width = padding_top },
        HorizontalGroup:new{
            self.htmlwidget,
            HorizontalSpan:new{ width = padding_right },
        },
        VerticalSpan:new{ width = padding_bottom },
    }

    -- Intentionally skip getSinglePageHeight(). That call forces an extra MuPDF
    -- layout pass on every open/reopen and is a major source of tap latency on
    -- e-ink. The popup uses a fixed height_ratio (default 35%) instead; short
    -- thoughts simply leave empty space at the bottom of the panel.

    self.container = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        vgroup,
    }

    self[1] = BottomContainer:new{
        dimen = Screen:getSize(),
        self.container
    }
end

function ThoughtPopupWidget:onCloseWidget()
    UIManager:setDirty(self.dialog, function()
        return "partial", self.container.dimen
    end)
    if self.close_callback then
        local callback = self.close_callback
        self.close_callback = nil
        callback(self.height)
    end
end

function ThoughtPopupWidget:onClose()
    UIManager:close(self)
    return true
end

function ThoughtPopupWidget:onTapClose(_, ges)
    if ges.pos:notIntersectWith(self.container.dimen) then
        UIManager:close(self)
        return true
    end
    return false
end

function ThoughtPopupWidget:onSwipeClose(_, ges)
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" or direction == "east" or direction == "south" then
        UIManager:close(self)
        return true
    else
        UIManager:setDirty(nil, "full")
    end
    return false
end

-- ============================================================================
-- 工厂函数和公共接口
-- ============================================================================
local PrewarmState = {
    generation = 0,
    done_key = nil,
}

local M = {}

function M.init(opts)
    opts = opts or {}
    FontPreloader:init()
    CSSCache:init()
    logger.info("weread: thought popup module initialized")
end

function M.preloadFonts(doc_font_name)
    FontPreloader:preloadForFont(doc_font_name)
end

function M.cancelPrewarm()
    PrewarmState.generation = PrewarmState.generation + 1
    PrewarmState.done_key = nil
end

function M.prewarm(opts)
    opts = opts or {}
    if not opts.doc_margins then return end

    local cache_key = string.format("%s_%d_%d_%d_%d_%d",
        opts.doc_font_name or "none",
        opts.doc_font_size or 0,
        opts.doc_margins.left or 0,
        opts.doc_margins.right or 0,
        opts.doc_margins.top or 0,
        opts.doc_margins.bottom or 0
    )
    if PrewarmState.done_key == cache_key then
        return
    end

    PrewarmState.generation = PrewarmState.generation + 1
    local gen = PrewarmState.generation

    UIManager:nextTick(function()
        if gen ~= PrewarmState.generation then return end

        local prewarm_started = time.now()
        local ok, err = pcall(function()
            FontPreloader:preloadForFont(opts.doc_font_name)

            local html = prepareHTML(PREWARM_HTML)
            local css = CSSCache:getFullCSS(opts.doc_font_name, opts.doc_margins, opts.css)
            local htmlwidget = createScrollHtmlWidget(html, css, opts.doc_font_size,
                opts.doc_margins, opts.height_ratio, opts.dialog)
            htmlwidget:free()

            if gen ~= PrewarmState.generation then return end
            PrewarmState.done_key = cache_key
        end)

        if ok then
            thought_perf("prewarm_total", prewarm_started, "ok=", "true")
        else
            thought_perf("prewarm_total", prewarm_started, "ok=", "false")
            logger.warn("weread: thought popup prewarm failed:", err)
        end
    end)
end

local _pooled_popup = nil

local ShowState = {
    generation = 0,
}

function M.show(opts)
    local show_started = time.now()
    if type(opts.html) ~= "string" or opts.html == "" then
        error("thought popup: invalid html")
    end

    ShowState.generation = ShowState.generation + 1

    if _pooled_popup then
        local reopen_started = time.now()
        _pooled_popup:_reopen(opts)
        thought_perf("reuse_popup", reopen_started, "html_bytes=", tostring(#opts.html))
        local ui_show_started = time.now()
        UIManager:show(_pooled_popup)
        thought_perf("ui_manager_show_reopen", ui_show_started)
        thought_perf("module_show_total_reopen", show_started,
            "html_bytes=", tostring(#opts.html))
        return _pooled_popup
    end

    local new_started = time.now()
    local popup = ThoughtPopupWidget:new{
        html = opts.html,
        css = opts.css,
        doc_font_name = opts.doc_font_name,
        doc_font_size = opts.doc_font_size,
        doc_margins = opts.doc_margins,
        height_ratio = opts.height_ratio,
        dialog = opts.dialog,
        close_callback = opts.close_callback,
    }
    thought_perf("create_popup", new_started, "html_bytes=", tostring(#opts.html))

    _pooled_popup = popup
    local ui_show_started = time.now()
    UIManager:show(popup)
    thought_perf("ui_manager_show_new", ui_show_started)
    thought_perf("module_show_total_new", show_started,
        "html_bytes=", tostring(#opts.html))
    return popup
end

function M.closeVisible()
    if _pooled_popup then
        UIManager:close(_pooled_popup)
    end
end

-- Whether a thought popup is actually on screen right now. The pooled widget is
-- kept for reuse after closing, so identity alone is not enough; ask UIManager
-- whether it is still in the window stack.
function M.isShowing()
    if not _pooled_popup then
        return false
    end
    local ok, shown = pcall(function()
        return UIManager:isWidgetShown(_pooled_popup)
    end)
    return ok and shown == true
end

function M.getPoolStats()
    local has_active = _pooled_popup ~= nil
    return { pool_size = has_active and 1 or 0, max_size = 1, has_active = has_active }
end

function M.clearCaches()
    CSSCache.font_css_cache = {}
    CSSCache.full_css_cache = {}
    FontPreloader.font_paths_cache = {}
end

function M.cleanup()
    ShowState.generation = ShowState.generation + 1
    if _pooled_popup then
        pcall(function()
            UIManager:close(_pooled_popup)
        end)
        if _pooled_popup.htmlwidget then
            _pooled_popup.htmlwidget:free()
            _pooled_popup.htmlwidget = nil
        end
        _pooled_popup:clear()
        _pooled_popup = nil
    end
end

function M.reset()
    M.clearCaches()
    M.cancelPrewarm()
end

return M
