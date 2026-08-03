--[[--
Thought popup face factory.

Builds KOReader FontFaceObj tables directly:

  * primary face: the document font (real font file resolved through
    cre.getFontFaceFilenameAndFaceIndex), or the built-in Noto Sans family
    when no document font is available;
  * fallback chain: NotoSansCJKsc -> ... -> NotoEmoji prefilled into
    face.fallbacks; xtext (HarfBuzz) switches fonts per glyph automatically,
    so emoji never needs per-character spans.

Faces are cached process-wide by (doc_font_name, size, variant); glyph bitmaps
are cached by KOReader's Fontcache, so after the first popup there is no font
file I/O.

The face table mirrors Font:getAdjustedFace's clone (frontend/ui/font.lua);
prefilling fallbacks short-circuits font.lua's name-based resolution
(_getFallbackFont checks face_obj.fallbacks[num] first).
--]]

local FontList = require("fontlist")
local Freetype = require("ffi/freetype")
local logger = require("weread.lib.logger")

local FaceFactory = {
    initialized = false,
    emoji_path = nil,
    font_paths_cache = {},
    face_cache = {},
    fallback_cache = {}, -- path|size -> FontFaceObj (fallback faces shared across variants)
}

-- Size variants (relative to the base size). quote/meta render one step
-- smaller; meta is the author line.
FaceFactory.VARIANTS = {
    content = 0.9,  -- thought body
    quote   = 0.9,  -- quoted abstract (italic, gray)
    meta    = 0.765, -- author line (0.85em * 0.9)
}

function FaceFactory:init()
    if self.initialized then return end
    -- The cre engine resolves document font file paths.
    pcall(function()
        require("document/credocument"):engineInit()
    end)
    self:findEmojiFont()
    self.initialized = true
end

--- Locate the NotoEmoji font shipped with the plugin (it lives outside
--- KOReader's font scan directories).
function FaceFactory:findEmojiFont()
    if self.emoji_path then return self.emoji_path end

    local ffiutil = require("ffi/util")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

    local function resolve(path)
        if not path then return nil end
        if ok_lfs and lfs.attributes(path, "mode") ~= "file" then return nil end
        if ffiutil.realpath then
            return ffiutil.realpath(path) or path
        end
        return path
    end

    local candidates = {
        "plugins/weread.koplugin/fonts/NotoEmoji-Regular.ttf",
    }
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds then
        candidates[#candidates + 1] = DataStorage:getDataDir()
            .. "/plugins/weread.koplugin/fonts/NotoEmoji-Regular.ttf"
    end
    for _, path in ipairs(candidates) do
        local abs = resolve(path)
        if abs then
            self.emoji_path = abs
            logger.info("thought popup emoji font:", abs)
            return self.emoji_path
        end
    end

    for _, dir in ipairs({ "/mnt/us/fonts/", "/usr/share/fonts/truetype/" }) do
        local fp = dir .. "NotoEmoji-Regular.ttf"
        if ok_lfs and lfs.attributes(fp, "mode") == "file" then
            self.emoji_path = fp
            return self.emoji_path
        end
    end
    return nil
end

--- Real font files of the document font, cached by font name.
--- @param doc_font_name string|nil
--- @return table[] { { path=string, bold=bool, italic=bool }, ... }
function FaceFactory:getFontPaths(doc_font_name)
    if not doc_font_name then return {} end
    if self.font_paths_cache[doc_font_name] then
        return self.font_paths_cache[doc_font_name]
    end

    local paths = {}
    local ok, cre = pcall(function()
        return require("document/credocument"):engineInit()
    end)
    if ok and cre and type(cre.getFontFaceFilenameAndFaceIndex) == "function" then
        local seen = {}
        for i = 1, 4 do
            local bold = i >= 3
            local italic = i == 2 or i == 4
            local font_path = cre.getFontFaceFilenameAndFaceIndex(doc_font_name, bold, italic)
            if font_path and not seen[font_path] then
                seen[font_path] = true
                paths[#paths + 1] = { path = font_path, bold = bold, italic = italic }
            end
        end
    end

    self.font_paths_cache[doc_font_name] = paths
    return paths
end

--- Hand-built FontFaceObj (modeled on Font:getAdjustedFace's clone).
--- xtext enumerates fallback fonts through face.getFallbackFont(num); a
--- prefilled fallbacks table short-circuits font.lua's name lookup.
--- Fonts are resolved through fontdir first, then a full FontList scan.
--- Faces are built by hand (not Font:getFace) because Font:getFace rescales
--- the size by DPI again; passing an already-scaled size would render glyphs
--- twice as large.
local function resolveBundledFont(fontname)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local path = FontList.fontdir and (FontList.fontdir .. "/" .. fontname)
    if path and ok_lfs and lfs.attributes(path, "mode") == "file" then
        return path
    end
    local fonts = FontList:getFontList()
    if fonts then
        for _, fp in ipairs(fonts) do
            if fp:find(fontname, 1, true) then
                return fp
            end
        end
    end
    return nil
end

function FaceFactory:_buildFace(path, size)
    if not path or not size or size <= 0 then return nil end
    local ok, ftsize = pcall(Freetype.newFaceSize, path, size)
    if not ok or not ftsize then
        logger.warn("thought popup failed to open font:", path, ftsize)
        return nil
    end
    local face_obj = {
        orig_font = path,
        realname = path,
        size = size,
        orig_size = size,
        ftsize = ftsize,
        hash = path .. "|" .. size,
        is_real_bold = false,
        hb_features = { "+kern", "+liga" },
    }
    face_obj.fallbacks = {}
    face_obj.getFallbackFont = function(num)
        if not num or num == 0 then return face_obj end
        if face_obj.fallbacks[num] ~= nil then
            return face_obj.fallbacks[num]
        end
        return false -- chain end
    end
    return face_obj
end

--- Fallback faces are shared process-wide: one FT face per (path, size).
function FaceFactory:_getFallbackFace(path, size)
    if not path or not size or size <= 0 then return nil end
    local key = path .. "|" .. size
    local cached = self.fallback_cache[key]
    if cached then return cached end
    local face = self:_buildFace(path, size)
    if face then
        self.fallback_cache[key] = face
    end
    return face
end

--- Fallback chain, first hit wins (silently skipped when the font is not
--- installed). Mirrors KOReader's own UI fallback chain
--- (frontend/ui/font.lua Font.fallbacks): freefont/FreeSans.ttf + FreeSerif.ttf
--- cover symbols (▸ U+25B8, ♥, arrows) and rare math alphanumerics
--- (𝓕 U+1D4D5 is only covered by FreeSerif).
---
--- NotoEmoji MUST stay at the absolute chain end: xtext's fallback is
--- cluster-granular (xtext.cpp shapeSegment: when a cluster contains a .notdef
--- glyph, the whole cluster starting at the notdef is reshaped by the next
--- fallback font; only a last-chance font renders partial hits). Putting emoji
--- mid-chain degrades an emoji sharing a cluster with combining marks to
--- subsequent fonts, one box after another. At the chain end the emoji is
--- always drawn by it.
---
--- The other Noto fonts (Tibetan/Egyptian Hieroglyphs/Brahmi/Symbols2) are not
--- shipped with KOReader; when installed on the device or dropped into the
--- KOReader fonts directory they are resolved by name and extend coverage to
--- scripts such as ྀི (U+0F80, U+0F72) / 𓂃 (U+13083) / 𑁍 (U+1104D).
--- xtext supports at most 15 fallback fonts (MAX_FONT_NUM = 16); this chain
--- has 9 plus the primary face.
local FALLBACK_FONT_NAMES = {
    "FreeSans.ttf",
    "NotoSansCJKsc-Regular.otf",
    "freefont/FreeSerif.ttf",
    "nerdfonts/symbols.ttf",
    "NotoSansTibetan-Regular.ttf",
    "NotoSansEgyptianHieroglyphs-Regular.ttf",
    "NotoSansBrahmi-Regular.ttf",
    "NotoSansSymbols2-Regular.ttf",
    "NotoEmoji-Regular.ttf", -- special: resolved via self.emoji_path; must stay last
}

function FaceFactory:_addFallbacks(face, size)
    local fallbacks = {}
    local n = 0
    for _, fontname in ipairs(FALLBACK_FONT_NAMES) do
        local path
        if fontname == "NotoEmoji-Regular.ttf" then
            path = self.emoji_path
        else
            -- Hand-built (not Font:getFace): size is already DPI-scaled.
            path = resolveBundledFont(fontname)
        end
        if path then
            local fb = self:_getFallbackFace(path, size)
            if fb then
                n = n + 1
                fallbacks[n] = fb
            end
        end
    end
    fallbacks[n + 1] = false -- explicit chain end
    face.fallbacks = fallbacks
end

--- Get a variant face (process-wide cache).
--- @param doc_font_name string|nil document font name (nil -> Noto Sans family)
--- @param size number DPI-scaled base size (i.e. doc_font_size)
--- @param variant string key of VARIANTS
function FaceFactory:getFace(doc_font_name, size, variant)
    variant = variant or "content"
    local key = string.format("%s|%d|%s", doc_font_name or "", size or 0, variant)
    local cached = self.face_cache[key]
    if cached then return cached end

    local ratio = self.VARIANTS[variant] or 1.0
    local v_size = math.max(8, math.floor(size * ratio + 0.5))
    local face

    local paths = self:getFontPaths(doc_font_name)
    local regular, italic
    for _, fp in ipairs(paths) do
        if not fp.bold then
            if fp.italic then
                if not italic then italic = fp.path end
            elseif not regular then
                regular = fp.path
            end
        end
    end
    local prefer_italic = variant == "quote"
    local path = prefer_italic and (italic or regular) or (regular or italic)
    if path then
        face = self:_buildFace(path, v_size)
        if face then
            self:_addFallbacks(face, v_size)
        end
    end

    -- Fallback when the document font cannot be resolved: use a bundled font
    -- (also hand-built to avoid the double DPI scaling).
    if not face then
        local fallback_path = resolveBundledFont(
            prefer_italic and "NotoSans-Italic.ttf" or "NotoSans-Regular.ttf")
            or resolveBundledFont("NotoSansCJKsc-Regular.otf")
        if fallback_path then
            face = self:_buildFace(fallback_path, v_size)
            if face then
                self:_addFallbacks(face, v_size)
            end
        end
    end

    if face then
        self.face_cache[key] = face
    end
    return face
end

function FaceFactory:clearCache()
    self.face_cache = {}
    self.fallback_cache = {}
    self.font_paths_cache = {}
end

return FaceFactory
