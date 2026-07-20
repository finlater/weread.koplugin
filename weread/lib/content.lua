local Crypto = require("lib.crypto")
local ReaderState = require("lib.reader_state")
local WeRead = require("lib.weread")
local Thoughts = require("lib.thoughts")
local Footnotes = require("lib.footnotes")
local bit = require("bit")
local ok_logger, logger = pcall(require, "logger")
if not ok_logger then
    logger = nil
end
local LOG_MODULE = "[WeRead]"

local Content = {}

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
    local out = {}
    local len = #data
    for i = 1, len, 3 do
        local a = data:byte(i)
        local b = i + 1 <= len and data:byte(i + 1) or 0
        local c = i + 2 <= len and data:byte(i + 2) or 0
        local n = a * 65536 + b * 256 + c
        table.insert(out, b64chars:sub(bit.rshift(n, 18) % 64 + 1, bit.rshift(n, 18) % 64 + 1))
        table.insert(out, b64chars:sub(bit.rshift(n, 12) % 64 + 1, bit.rshift(n, 12) % 64 + 1))
        if i + 1 <= len then
            table.insert(out, b64chars:sub(bit.rshift(n, 6) % 64 + 1, bit.rshift(n, 6) % 64 + 1))
        else
            table.insert(out, "=")
        end
        if i + 2 <= len then
            table.insert(out, b64chars:sub(n % 64 + 1, n % 64 + 1))
        else
            table.insert(out, "=")
        end
    end
    return table.concat(out)
end

local function basename_safe(value)
    value = tostring(value or ""):gsub("[^%w%._-]", "_")
    if value == "" then
        value = "weread"
    end
    return value
end

-- Directory name a book is stored under (sanitized book id). Exposed so the
-- local-cache scanner can match on-disk directory names against shelf book ids.
function Content.book_dir_name(book_id)
    return basename_safe(book_id)
end

function Content.book_cache_dir(settings, book_id)
    return settings.cache_dir .. "/" .. Content.book_dir_name(book_id)
end

-- Resolve where a book's files actually live. The current settings.cache_dir may
-- differ from where a book was downloaded (the user changed it since), so prefer
-- concrete evidence of the real location: an explicit book.cache_dir (set when any
-- file — chapter or MP article — is written), then the directory of a stored
-- cached_file/chapter path, and only as a last resort the path recomputed under
-- the current root. This keeps deletion, stats and moves on the real files instead
-- of orphaning them. MP article-only books have no cached_file, so book.cache_dir
-- is the only thing that pins them down.
function Content.book_resolved_dir(settings, book_id, book)
    if book and type(book.cache_dir) == "string" and book.cache_dir ~= "" then
        return book.cache_dir
    end
    local function dirname(path)
        if type(path) == "string" then
            return path:match("^(.*)/[^/]+$")
        end
    end
    local dir = book and dirname(book.cached_file)
    if not dir and book and type(book.cached_chapters) == "table" then
        for _i, chapter_path in pairs(book.cached_chapters) do
            dir = dirname(chapter_path)
            if dir then
                break
            end
        end
    end
    return dir or Content.book_cache_dir(settings, book_id)
end

function Content.catalog_cache_path(settings, book)
    local book_id = book and (book.book_id or book.bookId)
    if not book_id then
        return nil
    end
    return Content.book_resolved_dir(settings, book_id, book) .. "/catalog.json"
end

function Content.save_catalog_cache(client, settings, book, chapters)
    if type(chapters) ~= "table" then
        return false, "chapter list is not a table"
    end
    local path = Content.catalog_cache_path(settings, book)
    if not path then
        return false, "missing book id"
    end
    local dir = path:match("^(.*)/[^/]+$")
    os.execute("mkdir -p " .. string.format("%q", dir))
    local ok, encoded = pcall(function()
        return client:json_encode({
            version = 1,
            updated_at = os.time(),
            chapters = chapters,
        })
    end)
    if not ok then
        return false, encoded
    end
    local tmp_path = path .. ".tmp"
    local file, err = io.open(tmp_path, "wb")
    if not file then
        return false, err
    end
    local write_ok, write_err = file:write(encoded)
    file:close()
    if not write_ok then
        os.remove(tmp_path)
        return false, write_err
    end
    local rename_ok, rename_err = os.rename(tmp_path, path)
    if not rename_ok then
        os.remove(tmp_path)
        return false, rename_err
    end
    book.cache_dir = dir
    return true, path
end

function Content.load_catalog_cache(client, settings, book)
    local path = Content.catalog_cache_path(settings, book)
    if not path then
        return nil
    end
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local encoded = file:read("*a")
    file:close()
    local ok, decoded = pcall(function()
        return client:json_decode(encoded)
    end)
    if not ok or type(decoded) ~= "table" then
        if logger then
            logger.warn(LOG_MODULE, "ignore invalid catalog cache:", path)
        end
        return nil
    end
    local chapters = decoded.chapters
    if type(chapters) ~= "table" then
        return nil
    end
    book.chapters = chapters
    return chapters
end

local function filename_safe(value)
    value = tostring(value or ""):gsub("[%z%c/\\:%*%?\"<>|]", "_")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("%s+", " ")
    if value == "" then
        value = "weread"
    end
    return value
end

local function item_id(prefix, value)
    return prefix .. basename_safe(value):gsub("%.", "_")
end

local function utc_modified()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function media_type_for(data)
    if data:sub(1, 8) == "\137PNG\r\n\026\n" then
        return ".png", "image/png"
    elseif data:sub(1, 3) == "\255\216\255" then
        return ".jpg", "image/jpeg"
    elseif data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then
        return ".gif", "image/gif"
    elseif data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return ".webp", "image/webp"
    end
    return ".bin", "application/octet-stream"
end

local function trim_nulls(value)
    return tostring(value or ""):gsub("%z.*$", ""):gsub("%s+$", "")
end

local function tar_entries(data)
    local entries = {}
    local offset = 1
    while offset + 511 <= #data do
        local header = data:sub(offset, offset + 511)
        if header:match("^%z+$") then
            break
        end
        local name = trim_nulls(header:sub(1, 100))
        local size_text = trim_nulls(header:sub(125, 136)):gsub("%s", "")
        local size = tonumber(size_text, 8) or 0
        local typeflag = header:sub(157, 157)
        local body_start = offset + 512
        local body_end = body_start + size - 1
        if name ~= "" and (typeflag == "0" or typeflag == "" or typeflag == "\0") and size > 0 then
            table.insert(entries, {
                name = name,
                data = data:sub(body_start, body_end),
            })
        end
        offset = body_start + math.ceil(size / 512) * 512
    end
    return entries
end

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

local function unique_asset_name(used, name, ext)
    local base = filename_safe(name)
    if not base:lower():match(ext:gsub("%.", "%%.") .. "$") then
        base = base .. ext
    end
    local candidate = base
    local index = 2
    while used[candidate] do
        local stem = base:gsub("%.[^%.]+$", "")
        candidate = stem .. "-" .. tostring(index) .. ext
        index = index + 1
    end
    used[candidate] = true
    return candidate
end

local function write_file(path, data)
    local file, err = io.open(path, "wb")
    if not file then
        error(err)
    end
    file:write(data)
    file:close()
end

local function write_epub(path, entries)
    local Archiver = require("ffi/archiver")
    local archive = Archiver.Writer:new{}
    if not archive:open(path, "epub") then
        error("failed to open archive for writing: " .. tostring(archive.err))
    end

    local mtime = os.time()

    archive:setZipCompression("store")
    local mimetype_data = "application/epub+zip"
    for _, entry in ipairs(entries) do
        if entry.name == "mimetype" then
            mimetype_data = entry.data
            break
        end
    end
    archive:addFileFromMemory("mimetype", mimetype_data, mtime)

    archive:setZipCompression("deflate")
    for _, entry in ipairs(entries) do
        if entry.name ~= "mimetype" then
            archive:addFileFromMemory(entry.name, entry.data or "", mtime)
        end
    end

    archive:close()
end

local function xml_escape(value)
    value = tostring(value or "")
    value = value:gsub("&", "&amp;")
    value = value:gsub("<", "&lt;")
    value = value:gsub(">", "&gt;")
    value = value:gsub("\"", "&quot;")
    return value
end

-- WeRead EPUB chapters may decode to multiple concatenated XHTML documents.
-- The first <body> is often a title shell; main content lives in later bodies.
local function body_fragment(xhtml)
    xhtml = tostring(xhtml or "")
    local bodies = {}
    local remaining = xhtml
    while remaining ~= "" do
        local body_start = remaining:find("<body", 1, true)
        if not body_start then
            break
        end
        local body_open_end = remaining:find(">", body_start, true)
        if not body_open_end then
            break
        end
        local body_close = remaining:find("</body>", body_open_end, true)
        if not body_close then
            bodies[#bodies + 1] = remaining:sub(body_open_end + 1)
            break
        end
        bodies[#bodies + 1] = remaining:sub(body_open_end + 1, body_close - 1)
        remaining = remaining:sub(body_close + 7)
    end
    if #bodies > 0 then
        return table.concat(bodies, "\n")
    end
    xhtml = xhtml:gsub("<%?xml.-%?>", "")
    xhtml = xhtml:gsub("<!DOCTYPE.-%>", "")
    return xhtml
end

local function checked_body(response_text)
    if not response_text or #response_text <= 32 then
        return ""
    end
    local expected = response_text:sub(1, 32)
    local body = response_text:sub(33)
    local actual = Crypto.md5_hex(body):upper()
    if actual ~= expected then
        error("Shard MD5 mismatch")
    end
    return body
end

local function base64_decode(data)
    data = data:gsub("-", "+"):gsub("_", "/")
    local pad = #data % 4
    if pad > 0 then
        data = data .. string.rep("=", 4 - pad)
    end
    data = data:gsub("[^" .. b64chars .. "=]", "")
    return (data:gsub(".", function(char)
        if char == "=" then
            return ""
        end
        local bits = ""
        local index = b64chars:find(char, 1, true) - 1
        for bit = 6, 1, -1 do
            bits = bits .. (index % 2 ^ bit - index % 2 ^ (bit - 1) > 0 and "1" or "0")
        end
        return bits
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(bits)
        if #bits ~= 8 then
            return ""
        end
        local byte = 0
        for i = 1, 8 do
            if bits:sub(i, i) == "1" then
                byte = byte + 2 ^ (8 - i)
            end
        end
        return string.char(byte)
    end))
end

local function swap_positions(encoded)
    local length = #encoded
    if length < 4 then
        return {}
    end
    if length < 11 then
        return {0, 2}
    end

    local n = math.min(4, math.floor((length + 9) / 10))
    local tmp = {}
    for i = length, length - n + 1, -1 do
        local byte = encoded:byte(i)
        local bin = {}
        repeat
            table.insert(bin, 1, tostring(byte % 2))
            byte = math.floor(byte / 2)
        until byte == 0
        local value = tonumber(table.concat(bin), 4) or 0
        table.insert(tmp, tostring(value))
    end
    tmp = table.concat(tmp)

    local result = {}
    local m = length - n - 2
    local step = #tostring(m)
    local i = 1
    while #result < 10 and i + step - 1 < #tmp do
        table.insert(result, (tonumber(tmp:sub(i, i + step - 1)) or 0) % m)
        local end2 = math.min(i + step, #tmp)
        if i + 1 <= #tmp then
            table.insert(result, (tonumber(tmp:sub(i + 1, end2)) or 0) % m)
        end
        i = i + step
    end
    return result
end

local function reverse_swaps(encoded, positions)
    local chars = {}
    for i = 1, #encoded do
        chars[i] = encoded:sub(i, i)
    end
    for i = #positions, 1, -2 do
        for k = 1, 0, -1 do
            local left = positions[i] + k + 1
            local right = positions[i - 1] + k + 1
            chars[left], chars[right] = chars[right], chars[left]
        end
    end
    return table.concat(chars)
end

local function decode_encoded_body(body)
    if #body == 0 then
        return ""
    end
    local encoded = body:sub(2)
    local restored = reverse_swaps(encoded, swap_positions(encoded))
    return base64_decode(restored)
end

function Content.decode_content_shards(e0, e1, e3)
    local body = checked_body(e0) .. checked_body(e1) .. checked_body(e3)
    return decode_encoded_body(body)
end

function Content.decode_content_shard(e0)
    return decode_encoded_body(checked_body(e0))
end

function Content.extract_reader_state(html, json_decode)
    return ReaderState.extract(html, json_decode)
end

function Content.normalize_chapters(payload, book_id)
    local records = payload
    if type(payload) == "table" and payload.data then
        records = payload.data
    end
    if type(records) ~= "table" then
        return {}
    end
    if records.bookId or records.updated then
        records = { records }
    end
    for record_index, record in ipairs(records) do
        if tostring(record.bookId or "") == tostring(book_id) then
            return record.updated or record.chapterInfos or record.chapters or {}
        end
    end
    return {}
end

function Content.first_readable_chapter(chapters)
    for chapter_index, chapter in ipairs(chapters or {}) do
        if tonumber(chapter.wordCount or 0) > 0 and tostring(chapter.title or "") ~= "封面" then
            return chapter
        end
    end
end

function Content.readable_chapters(chapters)
    local out = {}
    for chapter_index, chapter in ipairs(chapters or {}) do
        if tonumber(chapter.wordCount or 0) > 0 and tostring(chapter.title or "") ~= "封面" then
            table.insert(out, chapter)
        end
    end
    return out
end

local function chapter_level(chapter)
    local level = tonumber(chapter and chapter.level or 1) or 1
    if level < 1 then
        level = 1
    elseif level > 6 then
        level = 6
    end
    return level
end

local function build_chapter_tree(chapters, filename_for)
    local root = { children = {} }
    local stack = { root }
    for chapter_index, chapter in ipairs(chapters or {}) do
        local level = chapter_level(chapter)
        if level > #stack then
            level = #stack
        end
        while #stack > level do
            table.remove(stack)
        end
        local parent = stack[#stack] or root
        local node = {
            title = chapter.title or ("Chapter " .. tostring(chapter.chapterUid or chapter_index)),
            href = filename_for(chapter_index, chapter),
            children = {},
        }
        table.insert(parent.children, node)
        stack[level + 1] = node
    end
    return root.children
end

local function build_nav_items(chapters, filename_for)
    local tree = build_chapter_tree(chapters, filename_for)
    local function render(nodes)
        local out = {}
        for node_index, node in ipairs(nodes or {}) do
            table.insert(out, [[<li><a href="]] .. xml_escape(node.href) .. [[">]] .. xml_escape(node.title) .. [[</a>]])
            if node.children and #node.children > 0 then
                table.insert(out, "<ol>")
                table.insert(out, render(node.children))
                table.insert(out, "</ol>")
            end
            table.insert(out, "</li>")
        end
        return table.concat(out, "\n")
    end

    return render(tree)
end

local function build_ncx_points(chapters, filename_for)
    local tree = build_chapter_tree(chapters, filename_for)
    local play_order = 0
    local function render(nodes)
        local out = {}
        for node_index, node in ipairs(nodes or {}) do
            play_order = play_order + 1
            local current_order = play_order
            table.insert(out, [[<navPoint id="navPoint-]] .. tostring(current_order) .. [[" playOrder="]] .. tostring(current_order) .. [[">]])
            table.insert(out, [[<navLabel><text>]] .. xml_escape(node.title) .. [[</text></navLabel>]])
            table.insert(out, [[<content src="]] .. xml_escape(node.href) .. [["/>]])
            if node.children and #node.children > 0 then
                table.insert(out, render(node.children))
            end
            table.insert(out, "</navPoint>")
        end
        return table.concat(out, "\n")
    end
    return render(tree), play_order
end

function Content.save_chapter_epub(settings, book, chapter, xhtml, assets, css)
    local book_id = book.book_id or book.bookId
    local dir = Content.book_resolved_dir(settings, book_id, book)
    os.execute("mkdir -p " .. string.format("%q", dir))
    book.cache_dir = dir
    local book_title = book.title or "WeRead"
    local path = dir .. "/" .. filename_safe(book_title .. " - " .. (chapter.title or tostring(chapter.chapterUid or "chapter"))) .. ".epub"
    local title = chapter.title or book.title or "WeRead"
    local author = book.author or "WeRead"
    local manifest_assets = {}
    local asset_entries = {}
    for asset_index, asset in ipairs(assets or {}) do
        table.insert(manifest_assets, [[<item id="asset_]] .. tostring(asset_index) .. [[" href="]] .. xml_escape(asset.href) .. [[" media-type="]] .. xml_escape(asset.media_type) .. [["/>]])
        table.insert(asset_entries, { name = "OEBPS/" .. asset.href, data = asset.data })
    end
    local chapter_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
<head>
<title>]] .. xml_escape(title) .. [[</title>
<link rel="stylesheet" type="text/css" href="../style.css"/>
</head>
<body>
]] .. body_fragment(xhtml) .. [[
</body>
</html>]]
    local opf = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">weread-]] .. xml_escape(book_id) .. [[-]] .. xml_escape(chapter.chapterUid or "chapter") .. [[</dc:identifier>
<dc:title>]] .. xml_escape(book_title) .. [[</dc:title>
<dc:creator>]] .. xml_escape(author) .. [[</dc:creator>
<dc:publisher>WeRead</dc:publisher>
<dc:source>]] .. xml_escape(WeRead.reader_url(book_id, chapter.chapterUid)) .. [[</dc:source>
<dc:language>zh-CN</dc:language>
<meta property="dcterms:modified">]] .. utc_modified() .. [[</meta>
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="style" href="style.css" media-type="text/css"/>
<item id="chapter" href="text/chapter.xhtml" media-type="application/xhtml+xml"/>
]] .. table.concat(manifest_assets, "\n") .. [[
</manifest>
<spine>
<itemref idref="chapter"/>
</spine>
</package>]]
    local nav = [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Navigation</title></head>
<body>
<nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
<ol><li><a href="text/chapter.xhtml">]] .. xml_escape(title) .. [[</a></li></ol>
</nav>
</body>
</html>]]
    css = css or [[body { line-height: 1.7; margin: 5%; } img { max-width: 100%; }]]
    local entries = {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = [[<?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]] },
        { name = "OEBPS/content.opf", data = opf },
        { name = "OEBPS/nav.xhtml", data = nav },
        { name = "OEBPS/style.css", data = css },
        { name = "OEBPS/text/chapter.xhtml", data = chapter_xhtml },
    }
    for asset_index, asset in ipairs(asset_entries) do
        table.insert(entries, asset)
    end
    write_epub(path, entries)
    return path
end

function Content.save_book_epub(settings, book, chapters, chapter_bodies, suffix, assets, css, cover_data)
    local book_id = book.book_id or book.bookId
    local dir = Content.book_resolved_dir(settings, book_id, book)
    os.execute("mkdir -p " .. string.format("%q", dir))
    book.cache_dir = dir
    local book_title = book.title or "WeRead"
    local path = dir .. "/" .. filename_safe(book_title .. " - " .. (suffix or "book")) .. ".epub"
    local author = book.author or "WeRead"
    local manifest_items = {
        [[<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>]],
        [[<item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>]],
        [[<item id="style" href="style.css" media-type="text/css"/>]],
    }
    local spine_items = {}
    local entries = {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = [[<?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]] },
    }

    local cover_meta = ""
    if cover_data and #cover_data > 0 then
        local ext, mime = media_type_for(cover_data)
        local cover_img_href = "images/cover" .. ext
        table.insert(entries, { name = "OEBPS/" .. cover_img_href, data = cover_data })
        table.insert(manifest_items, [[<item id="cover-image" href="]] .. xml_escape(cover_img_href) .. [[" media-type="]] .. xml_escape(mime) .. [[" properties="cover-image"/>]])
        table.insert(manifest_items, [[<item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>]])
        table.insert(spine_items, [[<itemref idref="cover"/>]])
        local cover_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head><title>Cover</title>
<style>html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;}img{display:block;width:100%;height:100%;object-fit:contain;}</style>
</head>
<body><img src="../]] .. xml_escape(cover_img_href) .. [[" alt="Cover"/></body>
</html>]]
        table.insert(entries, { name = "OEBPS/text/cover.xhtml", data = cover_xhtml })
        cover_meta = '\n<meta name="cover" content="cover-image"/>'
    end

    for asset_index, asset in ipairs(assets or {}) do
        table.insert(manifest_items, [[<item id="asset_]] .. tostring(asset_index) .. [[" href="]] .. xml_escape(asset.href) .. [[" media-type="]] .. xml_escape(asset.media_type) .. [["/>]])
        table.insert(entries, { name = "OEBPS/" .. asset.href, data = asset.data })
    end

    for chapter_index, chapter in ipairs(chapters or {}) do
        local uid = tostring(chapter.chapterUid or chapter_index)
        local filename = string.format("text/chapter-%03d.xhtml", chapter_index)
        local id = item_id("chapter_", uid)
        local title = chapter.title or ("Chapter " .. uid)
        local chapter_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
<head>
<title>]] .. xml_escape(title) .. [[</title>
<link rel="stylesheet" type="text/css" href="../style.css"/>
</head>
<body>
]] .. body_fragment(chapter_bodies[uid] or "") .. [[
</body>
</html>]]
        table.insert(entries, { name = "OEBPS/" .. filename, data = chapter_xhtml })
        table.insert(manifest_items, [[<item id="]] .. id .. [[" href="]] .. filename .. [[" media-type="application/xhtml+xml"/>]])
        table.insert(spine_items, [[<itemref idref="]] .. id .. [["/>]])
    end

    local opf = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">weread-]] .. xml_escape(book_id) .. [[-]] .. xml_escape(suffix or "book") .. [[</dc:identifier>
<dc:title>]] .. xml_escape(book_title) .. [[</dc:title>
<dc:creator>]] .. xml_escape(author) .. [[</dc:creator>
<dc:publisher>WeRead</dc:publisher>
<dc:source>]] .. xml_escape(WeRead.reader_url(book_id)) .. [[</dc:source>
<dc:language>zh-CN</dc:language>
<meta property="dcterms:modified">]] .. utc_modified() .. [[</meta>]] .. cover_meta .. [[
</metadata>
<manifest>
]] .. table.concat(manifest_items, "\n") .. [[
</manifest>
<spine toc="toc">
]] .. table.concat(spine_items, "\n") .. [[
</spine>
</package>]]
    local ncx_points = build_ncx_points(chapters, function(chapter_index)
        return string.format("text/chapter-%03d.xhtml", chapter_index)
    end)
    local ncx = [[<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head>
<meta name="dtb:uid" content="weread-]] .. xml_escape(book_id) .. [[-]] .. xml_escape(suffix or "book") .. [["/>
<meta name="dtb:depth" content="6"/>
<meta name="dtb:totalPageCount" content="0"/>
<meta name="dtb:maxPageNumber" content="0"/>
</head>
<docTitle><text>]] .. xml_escape(book_title) .. [[</text></docTitle>
<navMap>
]] .. ncx_points .. [[
</navMap>
</ncx>]]
    local nav = [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Navigation</title></head>
<body>
<nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
<ol>
]] .. build_nav_items(chapters, function(chapter_index)
        return string.format("text/chapter-%03d.xhtml", chapter_index)
    end) .. [[
</ol>
</nav>
</body>
</html>]]
    css = css or [[body { line-height: 1.7; margin: 5%; } img { max-width: 100%; }]]
    table.insert(entries, { name = "OEBPS/content.opf", data = opf })
    table.insert(entries, { name = "OEBPS/nav.xhtml", data = nav })
    table.insert(entries, { name = "OEBPS/toc.ncx", data = ncx })
    table.insert(entries, { name = "OEBPS/style.css", data = css })
    write_epub(path, entries)
    return path
end

function Content.rewrite_image_sources(xhtml, src_map)
    if not src_map or not next(src_map) then
        return xhtml
    end
    local function replace_src(quote, src)
        local clean = tostring(src or ""):gsub("&amp;", "&")
        local key = basename(clean:match("^[^%?#]+") or clean)
        local href = src_map[key]
        if href then
            return "src=" .. quote .. href .. quote
        end
        return "src=" .. quote .. src .. quote
    end
    xhtml = xhtml:gsub("src=(['\"])(.-)%1", replace_src)
    return xhtml
end

function Content.download_remote_images(client, xhtml, used_names, progress)
    local assets = {}
    used_names = used_names or {}
    used_names.__remote_image_hrefs = used_names.__remote_image_hrefs or {}
    local remote_image_hrefs = used_names.__remote_image_hrefs
    local function remote_url(src)
        local url = tostring(src or "")
        if url:match("^//") then
            url = "https:" .. url
        end
        if url:match("^https?://") then
            return url
        end
    end
    local img_total = 0
    xhtml:gsub('src=(["\'])(.-)%1', function(_, src)
        if remote_url(src) then
            img_total = img_total + 1
        end
    end)
    if img_total == 0 then
        return xhtml, assets
    end
    local index = 0
    local body = xhtml:gsub('src=(["\'])(.-)%1', function(quote, src)
        local url = remote_url(src)
        if not url then
            return "src=" .. quote .. src .. quote
        end
        index = index + 1
        if progress then
            progress(index, img_total)
        end
        local cached_href = remote_image_hrefs[url]
        if cached_href then
            return "src=" .. quote .. "../" .. cached_href .. quote
        end
        local ok, data = pcall(function()
            return client:get_binary(url, { referer = "https://weread.qq.com/" })
        end)
        if not ok or not data or #data == 0 then
            return "src=" .. quote .. src .. quote
        end
        local ext, mt = media_type_for(data)
        if not mt:match("^image/") then
            return "src=" .. quote .. src .. quote
        end
        local seed = basename((url:match("^[^%?#]+") or url))
        local fname = unique_asset_name(used_names, seed ~= "" and seed or ("img" .. tostring(index)), ext)
        local href = "images/" .. fname
        remote_image_hrefs[url] = href
        table.insert(assets, {
            href = href,
            media_type = mt,
            data = data,
        })
        return "src=" .. quote .. "../" .. href .. quote
    end)
    return body, assets
end

function Content.download_chapter_assets(client, book, chapter, used_names)
    if not chapter or not chapter.tar or chapter.tar == "" then
        return {}, {}
    end
    used_names = used_names or {}
    local book_id = book.book_id or book.bookId
    local referer = WeRead.reader_url(book_id, chapter.chapterUid)
    local tar_url = tostring(chapter.tar)
    if tar_url:match("^//") then
        tar_url = "https:" .. tar_url
    elseif tar_url:match("^/") then
        tar_url = "https://weread.qq.com" .. tar_url
    end
    local raw = client:get_binary(tar_url, { referer = referer })
    local assets = {}
    local src_map = {}
    for entry_index, entry in ipairs(tar_entries(raw)) do
        local ext, media_type = media_type_for(entry.data)
        if media_type:match("^image/") then
            local stem = basename(entry.name)
            local filename = unique_asset_name(used_names, stem, ext)
            local href = "images/" .. filename
            local epub_relative = "../" .. href
            table.insert(assets, {
                href = href,
                media_type = media_type,
                data = entry.data,
            })
            src_map[stem] = epub_relative
            src_map[filename] = epub_relative
        end
    end
    return assets, src_map
end

function Content.ensure_reader_state(client, book)
    local book_id = book.book_id or book.bookId
    local reader_url = book.reader_url or WeRead.reader_url(book_id)
    local reader_html = client:get_text(reader_url, { referer = reader_url })
    local state = Content.extract_reader_state(reader_html, function(encoded)
        return client:json_decode(encoded)
    end)
    book.book_id = book.book_id or state.book_id or book.bookId
    book.title = book.title or state.title
    book.author = book.author or state.author
    -- These values belong to one Web Reader session. Never retain a cached
    -- value when the freshly opened reader omits it (notably pclts).
    book.psvts = state.psvts
    book.pclts = state.pclts
    book.token = state.token
    book.reader_url = reader_url

    ReaderState.apply_to_book(book, state)

    if not book.psvts then
        error("reader.psvts not found")
    end
    return state
end

--- Refresh psvts before downloading a chapter (matches per-chapter reader page fetch).
function Content.refresh_reader_state(client, book, chapter)
    book.psvts = nil
    local book_id = book.book_id or book.bookId
    if chapter and chapter.chapterUid then
        book.reader_url = WeRead.reader_url(book_id, chapter.chapterUid)
    else
        book.reader_url = book.reader_url or WeRead.reader_url(book_id)
    end
    Content.ensure_reader_state(client, book)
end

function Content.fetch_catalog(client, book)
    local book_id = book.book_id or book.bookId
    local reader_url = book.reader_url or WeRead.reader_url(book_id)
    local catalog = client:post_json("https://weread.qq.com/web/book/chapterInfos", {
        bookIds = { tostring(book_id) },
    }, { referer = reader_url })
    local chapters = Content.readable_chapters(Content.normalize_chapters(catalog, book_id))
    book.chapters = chapters
    return chapters
end

function Content.fetch_chapter_shard(client, _settings, book, chapter, endpoint)
    if not book.psvts then
        Content.ensure_reader_state(client, book)
    end
    local book_id = book.book_id or book.bookId
    if not chapter then
        error("chapter is required")
    end

    local chapter_url = WeRead.reader_url(book_id, chapter.chapterUid)
    local is_style_shard = endpoint:find("/e_2", 1, true) ~= nil
    local params = WeRead.make_content_params(book_id, chapter.chapterUid, book.psvts, {
        sc = 1,
        style = is_style_shard,
    })
    local text, code = client:request({
        url = "https://weread.qq.com" .. endpoint,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["Origin"] = "https://weread.qq.com",
            ["Referer"] = chapter_url,
        },
        body = client:json_encode(params),
    })
    if not code or code < 200 or code >= 300 then
        error(endpoint .. " failed: HTTP " .. tostring(code or "unknown"))
    end
    if text == "{}" then
        error(endpoint .. " returned empty object")
    end
    return text
end

function Content.txt_to_xhtml(text)
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local parts = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:match("^(.-)%s*$") or ""
        if line ~= "" then
            table.insert(parts, "<p>" .. xml_escape(line) .. "</p>")
        end
    end
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml"><head><title></title></head>\n'
        .. '<body>\n' .. table.concat(parts, "\n") .. '\n</body></html>'
end

function Content.fetch_txt_as_xhtml(client, settings, book, chapter)
    local t0 = Content.fetch_chapter_shard(client, settings, book, chapter, "/web/book/chapter/t_0")
    local ok_t1, t1 = pcall(Content.fetch_chapter_shard, client, settings, book, chapter, "/web/book/chapter/t_1")
    if not ok_t1 then t1 = "" end
    local plain = Content.decode_content_shards(t0, t1, "")
    return Content.txt_to_xhtml(plain)
end

function Content.fetch_chapter_xhtml(client, settings, book, chapter)
    Content.refresh_reader_state(client, book, chapter)

    if book._content_format == "txt" then
        return Content.fetch_txt_as_xhtml(client, settings, book, chapter)
    end

    local ok, e0 = pcall(Content.fetch_chapter_shard, client, settings, book, chapter, "/web/book/chapter/e_0")

    if ok and e0:sub(1, 1) == "{" and e0:find('"bookId"', 1, true) then
        book._content_format = "txt"
        return Content.fetch_txt_as_xhtml(client, settings, book, chapter)
    end

    if not ok then
        error(e0)
    end

    book._content_format = "epub"
    return Content.decode_content_shards(
        e0,
        Content.fetch_chapter_shard(client, settings, book, chapter, "/web/book/chapter/e_1"),
        Content.fetch_chapter_shard(client, settings, book, chapter, "/web/book/chapter/e_3")
    )
end

function Content.fetch_chapter_css(client, settings, book, chapter)
    local ok, css = pcall(function()
        return Content.decode_content_shard(Content.fetch_chapter_shard(client, settings, book, chapter, "/web/book/chapter/e_2"))
    end)
    if ok then
        return css
    end
    return nil
end


local function append_before_body_close(xhtml, fragment)
    if type(fragment) ~= "string" or fragment == "" then
        return xhtml
    end
    local pos = xhtml:lower():find("</body>", 1, true)
    if pos then
        return xhtml:sub(1, pos - 1) .. fragment .. xhtml:sub(pos)
    end
    return xhtml .. fragment
end

local function footnote_meta(client, settings, book, state)
    state = state or {}
    local book_id = book.book_id or book.bookId
    return {
        book_dir = Content.book_cache_dir(settings, book_id),
        book_id = book_id,
        is_txt = book._content_format == "txt",
        fetch_chapter_html = function(chapter)
            return Content.fetch_chapter_xhtml(client, settings, book, chapter)
        end,
        fetch_catalog = function()
            return Content.fetch_catalog(client, book)
        end,
    }
end

local function apply_chapter_annotations(client, settings, book, chapter, xhtml, css)
    local cache = settings:get("cache", {})
    if cache.download_underlines_and_thoughts ~= true then
        return xhtml, css
    end
    local book_id = book.book_id or book.bookId
    local chapter_uid = chapter and chapter.chapterUid
    local processed, annotation_css = Thoughts.apply(client, settings, book_id, chapter_uid, xhtml)
    return processed, Thoughts.merge_css(css, annotation_css)
end

local function apply_chapter_footnotes(client, settings, book, chapter, xhtml, css, state)
    if book._content_format == "txt" then
        return xhtml, css
    end
    local processed, section = Footnotes.process(xhtml, footnote_meta(client, settings, book, state))
    if section and section ~= "" then
        processed = append_before_body_close(processed, section)
    end
    if processed ~= xhtml or (section and section ~= "") then
        css = Thoughts.merge_css(css, Footnotes.FOOTNOTES_CSS)
    end
    return processed, css
end

local function apply_chapter_enrichments(client, settings, book, chapter, xhtml, css, state)
    xhtml, css = apply_chapter_annotations(client, settings, book, chapter, xhtml, css)
    xhtml, css = apply_chapter_footnotes(client, settings, book, chapter, xhtml, css, state)
    return xhtml, css
end

function Content.fetch_chapter_epub(client, settings, book, chapter)
    local book_id = book.book_id or book.bookId
    local xhtml = Content.fetch_chapter_xhtml(client, settings, book, chapter)
    local css = Content.fetch_chapter_css(client, settings, book, chapter)
    xhtml, css = apply_chapter_enrichments(client, settings, book, chapter, xhtml, css, { chapters = book.chapters })
    local assets = {}
    local cache = settings:get("cache", {})
    if cache.download_book_images then
        local used_names = {}
        local src_map
        assets, src_map = Content.download_chapter_assets(client, book, chapter, used_names)
        xhtml = Content.rewrite_image_sources(xhtml, src_map)
        local inline_xhtml, inline_assets = Content.download_remote_images(client, xhtml, used_names)
        xhtml = inline_xhtml
        for _, a in ipairs(inline_assets) do
            table.insert(assets, a)
        end
    end
    local path = Content.save_chapter_epub(settings, book, chapter, xhtml, assets, css)
    book.cached_chapters = book.cached_chapters or {}
    book.cached_chapters[tostring(chapter.chapterUid)] = path
    book.cached_file = path
    book.chapter_uid = chapter.chapterUid
    book.chapter_idx = chapter.chapterIdx
    book.reader_url = book.reader_url or WeRead.reader_url(book_id)
    return path, chapter
end

-- Split chapter downloading around annotation fetching so the UI can request
-- thought batches cooperatively instead of blocking inside Thoughts.apply().
function Content.fetch_single_chapter_source(client, settings, book, chapter, state)
    state = state or {}
    local xhtml = Content.fetch_chapter_xhtml(client, settings, book, chapter)
    if not state.css then
        state.css = Content.fetch_chapter_css(client, settings, book, chapter)
    end
    return xhtml
end

function Content.finalize_single_chapter_content(client, settings, book, chapter, xhtml, state)
    state = state or {}
    -- Apply footnotes (image-based and cross-file). The downloader pipeline
    -- applies annotations separately; footnotes are handled here so they
    -- run regardless of annotation settings.
    local new_css
    xhtml, new_css = apply_chapter_footnotes(client, settings, book, chapter, xhtml, state.css, state)
    state.css = new_css
    local chapter_assets = {}
    local cache = settings:get("cache", {})
    if cache.download_book_images then
        state.used_asset_names = state.used_asset_names or {}
        local tar_assets, src_map = Content.download_chapter_assets(client, book, chapter, state.used_asset_names)
        for _, asset in ipairs(tar_assets) do
            table.insert(chapter_assets, asset)
        end
        xhtml = Content.rewrite_image_sources(xhtml, src_map)
        local inline_xhtml, inline_assets = Content.download_remote_images(client, xhtml, state.used_asset_names)
        xhtml = inline_xhtml
        for _, asset in ipairs(inline_assets) do
            table.insert(chapter_assets, asset)
        end
    end
    return xhtml, chapter_assets
end

function Content.fetch_chapters_epub(client, settings, book, chapters, options)
    options = options or {}
    local selected = {}
    local bodies = {}
    local assets = {}
    local used_asset_names = {}
    local cache = settings:get("cache", {})
    local css
    for chapter_index, chapter in ipairs(chapters or {}) do
        if options.progress then
            options.progress(chapter_index, #chapters, chapter, "text")
        end
        local xhtml = Content.fetch_chapter_xhtml(client, settings, book, chapter)
        if not css then
            css = Content.fetch_chapter_css(client, settings, book, chapter)
        end
        xhtml, css = apply_chapter_enrichments(client, settings, book, chapter, xhtml, css, { chapters = chapters })
        if cache.download_book_images then
            if options.progress then
                options.progress(chapter_index, #chapters, chapter, "images")
            end
            local chapter_assets, src_map = Content.download_chapter_assets(client, book, chapter, used_asset_names)
            for _, asset in ipairs(chapter_assets) do
                table.insert(assets, asset)
            end
            xhtml = Content.rewrite_image_sources(xhtml, src_map)
            local inline_xhtml, inline_assets = Content.download_remote_images(client, xhtml, used_asset_names)
            xhtml = inline_xhtml
            for _, a in ipairs(inline_assets) do
                table.insert(assets, a)
            end
        end
        local uid = tostring(chapter.chapterUid or chapter_index)
        table.insert(selected, chapter)
        bodies[uid] = xhtml
    end
    if #selected == 0 then
        error("No readable chapter found")
    end
    local path = Content.save_book_epub(settings, book, selected, bodies, options.suffix or "book", assets, css)
    book.cached_chapters = book.cached_chapters or {}
    for chapter_index, chapter in ipairs(selected) do
        book.cached_chapters[tostring(chapter.chapterUid or chapter_index)] = path
    end
    book.cached_file = path
    book.reader_url = book.reader_url or WeRead.reader_url(book.book_id or book.bookId)
    return path, selected
end

function Content.fetch_first_chapter(client, settings, book)
    Content.ensure_reader_state(client, book)
    local chapters = book.chapters or Content.load_catalog_cache(client, settings, book)
    if not chapters then
        chapters = Content.fetch_catalog(client, book)
        Content.save_catalog_cache(client, settings, book, chapters)
    end
    local chapter = Content.first_readable_chapter(chapters)
    if not chapter then
        error("No readable chapter found")
    end
    return Content.fetch_chapter_epub(client, settings, book, chapter)
end

function Content.parse_mp_articles(data)
    local articles = {}
    for _, group in ipairs(data.reviews or {}) do
        for _, sub in ipairs(group.subReviews or {}) do
            local review = sub.review or sub
            local mp = review.mpInfo or {}
            local review_ids = {}
            local seen_ids = {}
            for _, review_id in ipairs({ sub.reviewId, review.reviewId, mp.originalId }) do
                review_id = tostring(review_id or "")
                if review_id ~= "" and not seen_ids[review_id] then
                    seen_ids[review_id] = true
                    table.insert(review_ids, review_id)
                end
            end
            table.insert(articles, {
                reviewId = review.reviewId or sub.reviewId or "",
                reviewIds = review_ids,
                originalId = mp.originalId or "",
                bookId = review.belongBookId or "",
                sourceUrl = mp.content_url or mp.contentUrl or mp.source_url or mp.sourceUrl or mp.url
                    or review.content_url or review.contentUrl or review.source_url or review.sourceUrl or review.url or "",
                title = mp.title or "",
                pic_url = mp.pic_url or "",
                createTime = review.createTime or 0,
            })
        end
    end
    return articles
end

function Content.extract_mp_body(html)
    html = tostring(html or "")
    local body = html:match('<div[^>]*id="js_content"[^>]*>(.-)</div>%s*<script')
    if not body then
        body = html:match('class="rich_media_content[^"]*"[^>]*>(.-)</div>%s*<script')
    end
    if not body then
        body = html:match('<div[^>]*id="js_content"[^>]*>(.*)')
    end
    if not body or body == "" then
        return nil
    end
    body = body:gsub("<script.-</script>", "")
    body = body:gsub("<style.-</style>", "")
    body = body:gsub(' src=""', '')
    body = body:gsub(" src=''", "")
    body = body:gsub("data%-src=", "src=")
    return body
end

local function normalize_void_elements(html)
    html = html:gsub("<(br)%s*>", "<%1/>")
    html = html:gsub("<(hr)%s*>", "<%1/>")
    html = html:gsub("<(img)(%s[^>]-)>", function(tag, attrs)
        if not attrs:match("/$") then
            return "<" .. tag .. attrs .. "/>"
        end
        return "<" .. tag .. attrs .. ">"
    end)
    return html
end

local function strip_mp_reader_font_styles(html)
    local blocked = {
        ["font"] = true,
        ["font-family"] = true,
        ["line-height"] = true,
        ["color"] = true,
        ["-webkit-text-fill-color"] = true,
        ["opacity"] = true,
        ["page-break-before"] = true,
        ["page-break-after"] = true,
        ["page-break-inside"] = true,
        ["break-before"] = true,
        ["break-after"] = true,
        ["break-inside"] = true,
        ["text-size-adjust"] = true,
        ["-webkit-text-size-adjust"] = true,
    }

    local function relative_heading_size(value)
        local lower = tostring(value or ""):lower():gsub("%s*!important%s*$", "")
        local px = tonumber(lower:match("^%s*([%d%.]+)%s*px%s*$"))
        if px then
            return px >= 18 and string.format("%.2fem", px / 16) or nil
        end
        local pt = tonumber(lower:match("^%s*([%d%.]+)%s*pt%s*$"))
        if pt then
            return pt >= 13.5 and string.format("%.2fem", pt / 12) or nil
        end
        local rem = tonumber(lower:match("^%s*([%d%.]+)%s*rem%s*$"))
        if rem then
            return rem > 1.05 and string.format("%.2fem", rem) or nil
        end
        local em = tonumber(lower:match("^%s*([%d%.]+)%s*em%s*$"))
        if em then
            return em > 1.05 and string.format("%.2fem", em) or nil
        end
        local percent = tonumber(lower:match("^%s*([%d%.]+)%s*%%%s*$"))
        if percent then
            return percent > 105 and string.format("%.0f%%", percent) or nil
        end
        local keyword = lower:match("^%s*(.-)%s*$")
        if keyword == "large" or keyword == "larger" or keyword == "x-large" or keyword == "xx-large" then
            return keyword
        end
        return nil
    end

    return tostring(html or ""):gsub('style=(["\'])(.-)%1', function(quote, style)
        local kept = {}
        for decl in style:gmatch("[^;]+") do
            local name, value = decl:match("^%s*([^:]+)%s*:%s*(.-)%s*$")
            if name and value then
                local property = name:lower()
                if property == "font-size" then
                    local heading_size = relative_heading_size(value)
                    if heading_size then
                        table.insert(kept, "font-size: " .. heading_size)
                    end
                elseif not blocked[property] then
                    table.insert(kept, name .. ": " .. value)
                end
            end
        end
        if #kept == 0 then
            return ""
        end
        return "style=" .. quote .. table.concat(kept, "; ") .. quote
    end)
end

function Content.strip_mp_images(html)
    html = tostring(html or "")
    html = html:gsub(
        "<[pP][iI][cC][tT][uU][rR][eE][^>]*>.-</[pP][iI][cC][tT][uU][rR][eE]%s*>",
        ""
    )
    html = html:gsub("<[iI][mM][gG][^>]*>", "")
    html = html:gsub("</[iI][mM][gG]%s*>", "")
    html = html:gsub("<[sS][oO][uU][rR][cC][eE][^>]*>", "")
    return html
end

local function strip_blank_mp_blocks(html)
    html = tostring(html or "")
    html = html:gsub("<mp%-common%-profile[^>]->.-</mp%-common%-profile>", "")
    html = html:gsub("<mp%-style%-type[^>]->.-</mp%-style%-type>", "")
    html = html:gsub("<[bB][rR]%s*/?%s*>", "<br/>")
    html = html:gsub("&nbsp;", " ")
    html = html:gsub("&#160;", " ")
    html = html:gsub("&#x[aA]0;", " ")
    html = html:gsub("\194\160", " ")

    for _ = 1, 12 do
        local previous = html
        for _, tag in ipairs({ "a", "span", "p", "section", "div", "figure", "picture" }) do
            html = html:gsub("<" .. tag .. "[^>]->%s*<br/>%s*</" .. tag .. ">", "")
            html = html:gsub("<" .. tag .. "[^>]->%s*</" .. tag .. ">", "")
        end
        if html == previous then
            break
        end
    end

    for _ = 1, 4 do
        local updated = html:gsub("(%s*<br/>%s*)%s*<br/>%s*", "<br/>")
        if updated == html then
            break
        end
        html = updated
    end
    html = html:gsub("\n%s*\n%s*\n+", "\n\n")
    return html
end

function Content.download_mp_images(client, body_html, progress, embed_base64)
    local assets = {}
    local used_names = {}
    local img_total = 0
    body_html:gsub('src=(["\'])(.-)%1', function(quote, src)
        if src:match("mmbiz%.qpic%.cn") or src:match("mmbiz%.qlogo%.cn") then
            img_total = img_total + 1
        end
    end)
    local index = 0
    local body = body_html:gsub('src=(["\'])(.-)%1', function(quote, src)
        if not src:match("mmbiz%.qpic%.cn") and not src:match("mmbiz%.qlogo%.cn") then
            return "src=" .. quote .. src .. quote
        end
        index = index + 1
        if progress then
            progress(index, img_total)
        end
        local url = src
        if url:match("^//") then
            url = "https:" .. url
        end
        local ok, data = pcall(function()
            return client:get_binary(url, { referer = "https://weread.qq.com/" })
        end)
        if not ok or not data or #data == 0 then
            return "src=" .. quote .. src .. quote
        end
        local ext, mt = media_type_for(data)
        if embed_base64 then
            local b64 = base64_encode(data)
            return "src=" .. quote .. "data:" .. mt .. ";base64," .. b64 .. quote
        end
        local fname = unique_asset_name(used_names, "img" .. tostring(index), ext)
        local href = "images/" .. fname
        table.insert(assets, {
            href = href,
            media_type = mt,
            data = data,
        })
        return "src=" .. quote .. "../" .. href .. quote
    end)
    return body, assets
end

function Content.mp_article_path(settings, book, article)
    local book_id = book.book_id or book.bookId
    local dir = Content.book_resolved_dir(settings, book_id, book)
    local title = filename_safe(article.title or "article")
    return dir .. "/" .. title .. ".html"
end

function Content.mp_article_cached_path(settings, book, article)
    local html_path = Content.mp_article_path(settings, book, article)
    local f = io.open(html_path, "r")
    if f then
        f:close()
        return html_path
    end
    local epub_path = html_path:gsub("%.html$", ".epub")
    f = io.open(epub_path, "r")
    if f then
        f:close()
        return epub_path
    end
    return nil
end

function Content.save_mp_article_html(settings, book, article, body_html)
    local book_id = book.book_id or book.bookId
    local dir = Content.book_resolved_dir(settings, book_id, book)
    -- Pin the real directory on the record so later lookups, moves and cleanup
    -- can find these files after the download directory changes.
    book.cache_dir = dir
    os.execute("mkdir -p " .. string.format("%q", dir))
    local title = article.title or "Article"
    local path = Content.mp_article_path(settings, book, article)
    body_html = strip_mp_reader_font_styles(body_html)
    body_html = strip_blank_mp_blocks(body_html)

    local html = [[<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<title>]] .. xml_escape(title) .. [[</title>
<style>
html, body {
  color: #000 !important;
  font-size: 1em !important;
  line-height: 1.7;
  margin: 0;
  padding: 0;
  -webkit-text-size-adjust: 100%;
  text-size-adjust: 100%;
}
body {
  margin: 0 !important;
  padding: 0 !important;
}
body * {
  color: inherit !important;
  font-family: inherit !important;
  line-height: inherit !important;
}
img {
  display: inline !important;
  max-width: 100%;
  height: auto;
  margin: 0.2em 0 !important;
  vertical-align: middle;
  page-break-before: auto !important;
  page-break-after: auto !important;
  break-before: auto !important;
  break-after: auto !important;
}
h1 {
  font-size: 1.35em !important;
  line-height: 1.35 !important;
  margin: 0 0 1em;
}
p {
  margin: 0.25em 0 !important;
}
</style>
</head>
<body>
<h1>]] .. xml_escape(title) .. [[</h1>
]] .. body_html .. [[
</body>
</html>]]

    write_file(path, html)
    return path
end

function Content.fetch_mp_article_html(client, settings, book, article, opts)
    opts = opts or {}
    local book_id = article.bookId
    if not book_id or book_id == "" then
        book_id = book.book_id or book.bookId
    end
    local referer = book_id and book_id ~= "" and WeRead.mp_reader_url(book_id) or "https://weread.qq.com/"
    local candidate_ids = {}
    local seen_ids = {}
    local function add_candidate(review_id)
        review_id = tostring(review_id or "")
        if review_id ~= "" and not seen_ids[review_id] then
            seen_ids[review_id] = true
            table.insert(candidate_ids, review_id)
        end
    end
    add_candidate(article.reviewId)
    for _, review_id in ipairs(article.reviewIds or {}) do
        add_candidate(review_id)
    end
    add_candidate(article.originalId)
    add_candidate(tostring(article.reviewId or ""):match("^MP_WXS_%d+_(.+)$"))

    local html, meta, used_review_id
    local attempts = {}
    local function fetch_candidates(prefix, request_opts)
        for candidate_index, review_id in ipairs(candidate_ids) do
            local ok, candidate_html, candidate_meta = pcall(function()
                return client:get_mp_content(review_id, {
                    referer = referer,
                    skip_mp_auth_headers = request_opts and request_opts.skip_mp_auth_headers,
                })
            end)
            if ok then
                table.insert(
                    attempts,
                    prefix .. tostring(candidate_index) .. ":" .. tostring(candidate_meta and candidate_meta.length or #(candidate_html or ""))
                )
                if candidate_html and not candidate_html:match("^%s*$") then
                    html = candidate_html
                    meta = candidate_meta
                    used_review_id = review_id
                    return true
                end
                meta = meta or candidate_meta
            else
                table.insert(attempts, prefix .. tostring(candidate_index) .. ":error")
            end
        end
        return false
    end

    fetch_candidates("")
    if not html or html:match("^%s*$") then
        if logger then
            logger.info(LOG_MODULE, "MP content empty, renewing cookie before retry")
        end
        local renew_ok = pcall(function()
            return client:renew_cookie()
        end)
        table.insert(attempts, renew_ok and "renew:ok" or "renew:error")
        if renew_ok then
            fetch_candidates("renewed:", { skip_mp_auth_headers = true })
        end
    end

    local source_url = tostring(article.sourceUrl or "")
    if (not html or html:match("^%s*$")) and source_url:match("^https?://mp%.weixin%.qq%.com/") then
        local ok, source_html, source_meta = pcall(function()
            return client:get_public_text(source_url)
        end)
        if ok and source_html and not source_html:match("^%s*$") then
            html = source_html
            meta = source_meta
            used_review_id = "source_url"
        else
            table.insert(attempts, "source_url:error")
        end
    end
    local body = Content.extract_mp_body(html)
    if not body then
        local empty_response = not html or html:match("^%s*$") ~= nil
        if logger then
            logger.warn(
                LOG_MODULE,
                "could not extract MP article body:",
                "reason=", empty_response and "empty_response" or "missing_body",
                "candidate_count=", tostring(#candidate_ids),
                "used_candidate=", used_review_id and "yes" or "no",
                "html_length=", tostring(meta and meta.length or #(html or "")),
                "content_type=", tostring(meta and meta.content_type or ""),
                "attempts=", table.concat(attempts, ","),
                "has_source_url=", source_url ~= "" and "yes" or "no"
            )
        end
        if empty_response then
            error("Article content response is empty. See KOReader log for details.", 0)
        end
        error("Could not extract article body. See KOReader log for details.", 0)
    end
    local cache = settings:get("cache", {})
    if cache.download_mp_images then
        body = Content.download_mp_images(client, body, opts.progress, true)
    else
        body = Content.strip_mp_images(body)
    end
    return Content.save_mp_article_html(settings, book, article, body)
end

return Content
