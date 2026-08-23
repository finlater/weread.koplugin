-- Local WeRead collection and ZenOS/KOReader keyword tag helpers.
-- Full-book EPUBs are recorded in the "weread" collection and tagged "weread"
-- so CoverBrowser / ZenOS can treat them as a native tag source.
-- Existing books are backfilled only from "Scan and match local books".

local M = {}

M.COLLECTION_NAME = "weread"
M.TAG = "weread"

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

function M.merge_keywords(existing, tag)
    tag = tag or M.TAG
    local seen = {}
    local out = {}
    local function add(part)
        part = trim(part)
        if part == "" or seen[part] then return end
        seen[part] = true
        out[#out + 1] = part
    end
    if type(existing) == "string" and existing ~= "" then
        local normalized = existing:gsub(",", "\n")
        for part in normalized:gmatch("[^\n]+") do
            add(part)
        end
    end
    add(tag)
    return table.concat(out, "\n")
end

function M.epub_keyword_xml(tag)
    tag = tag or M.TAG
    return "<dc:subject>" .. tag .. "</dc:subject>\n"
        .. '<meta name="keywords" content="' .. tag .. '"/>\n'
end

local function default_file_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.attributes then
        local attr = lfs.attributes(path)
        return attr ~= nil and attr.mode == "file"
    end
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local function default_read_keywords(path)
    local keywords
    pcall(function()
        local DocSettings = require("docsettings")
        local custom_file = DocSettings:findCustomMetadataFile(path)
        if not custom_file then return end
        local settings = DocSettings.openSettingsFile(custom_file)
        local custom_props = settings:readSetting("custom_props") or {}
        if type(custom_props.keywords) == "string" and custom_props.keywords ~= "" then
            keywords = custom_props.keywords
            return
        end
        local doc_props = settings:readSetting("doc_props") or {}
        if type(doc_props.keywords) == "string" then
            keywords = doc_props.keywords
        end
    end)
    if keywords then return keywords end
    pcall(function()
        local BookInfoManager = require("bookinfomanager")
        local info = BookInfoManager:getBookInfo(path)
        if info and type(info.keywords) == "string" then
            keywords = info.keywords
        end
    end)
    return keywords
end

local function default_write_keywords(path, keywords)
    local DocSettings = require("docsettings")
    local custom_file = DocSettings:findCustomMetadataFile(path)
    local custom_doc_settings
    if custom_file then
        custom_doc_settings = DocSettings.openSettingsFile(custom_file)
    else
        custom_doc_settings = DocSettings.openSettingsFile()
        custom_doc_settings:saveSetting("doc_props", {})
    end
    local custom_props = custom_doc_settings:readSetting("custom_props", {})
    custom_props.keywords = keywords
    custom_doc_settings:saveSetting("custom_props", custom_props)
    custom_doc_settings:flushCustomMetadata(path)
end

local function default_get_bookinfo_keywords(path)
    local BookInfoManager = require("bookinfomanager")
    local info = BookInfoManager:getBookInfo(path)
    if not info then return nil end
    return info.keywords or ""
end

local function default_set_bookinfo_keywords(path, keywords)
    local BookInfoManager = require("bookinfomanager")
    BookInfoManager:setBookInfoProperties(path, { keywords = keywords })
end

local function default_extract_bookinfo(path)
    local BookInfoManager = require("bookinfomanager")
    BookInfoManager:extractBookInfo(path)
end

local function with_hooks(hooks)
    hooks = type(hooks) == "table" and hooks or {}
    return {
        file_exists = hooks.file_exists or default_file_exists,
        read_keywords = hooks.read_keywords or default_read_keywords,
        write_keywords = hooks.write_keywords or default_write_keywords,
        get_bookinfo_keywords = hooks.get_bookinfo_keywords
            or default_get_bookinfo_keywords,
        set_bookinfo_keywords = hooks.set_bookinfo_keywords
            or default_set_bookinfo_keywords,
        extract_bookinfo = hooks.extract_bookinfo or default_extract_bookinfo,
    }
end

function M.apply_tag(path, hooks)
    hooks = with_hooks(hooks)
    if type(path) ~= "string" or path == "" then
        return false
    end
    if not hooks.file_exists(path) then
        return false
    end
    local merged = M.merge_keywords(hooks.read_keywords(path))
    pcall(hooks.write_keywords, path, merged)
    local current
    local ok_get, result = pcall(hooks.get_bookinfo_keywords, path)
    if ok_get then
        current = result
    end
    if current == nil then
        pcall(hooks.extract_bookinfo, path)
    end
    pcall(hooks.set_bookinfo_keywords, path, merged)
    return true
end

function M.add_full_book(path, hooks)
    if type(path) ~= "string" or path == "" then
        return false
    end
    pcall(function()
        local ReadCollection = require("readcollection")
        if not ReadCollection.coll then
            ReadCollection:_read()
        end
        if not ReadCollection.coll[M.COLLECTION_NAME] then
            ReadCollection:addCollection(M.COLLECTION_NAME)
        end
        if not ReadCollection:isFileInCollection(path, M.COLLECTION_NAME) then
            ReadCollection:addItem(path, M.COLLECTION_NAME)
            ReadCollection:write({ [M.COLLECTION_NAME] = true })
        end
    end)
    return M.apply_tag(path, hooks)
end

function M.backfill(hooks)
    local tagged = 0
    pcall(function()
        local ReadCollection = require("readcollection")
        if not ReadCollection.coll then
            ReadCollection:_read()
        end
        local coll = ReadCollection.coll and ReadCollection.coll[M.COLLECTION_NAME]
        if type(coll) ~= "table" then return end
        for file, item in pairs(coll) do
            local path = type(item) == "table" and item.file or file
            if M.apply_tag(path, hooks) then
                tagged = tagged + 1
            end
        end
    end)
    return tagged
end

return M
