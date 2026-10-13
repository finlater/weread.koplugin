local Content = require("weread.lib.content")
local logger = require("weread.lib.logger")

local PluginUtil = require("weread.lib.plugin_util")
local log_error = PluginUtil.log_error

local Migrations = {}

function Migrations.run(settings, client)
    local books = settings:get_books()
    local found, migrated, failed = false, 0, 0
    for _book_id, book in pairs(books) do
        if type(book) == "table" and book.chapters ~= nil then
            found = true
            if type(book.chapters) == "table" then
                local ok, saved = pcall(Content.save_catalog_cache,
                    client, settings, book, book.chapters)
                if ok and saved then
                    migrated = migrated + 1
                else
                    failed = failed + 1
                end
            end
            book.chapters = nil
        end
    end
    if not found and not settings:has_legacy_book_records() then
        return
    end

    local ok, err = pcall(function()
        for book_id, book in pairs(books) do
            settings:put_book(book_id, book)
        end
        settings:flush()
    end)
    if ok then
        logger.info("legacy per-book data migrated:",
            "catalogs=", tostring(migrated),
            "catalog_failures=", tostring(failed))
    else
        logger.err("legacy per-book data migration failed:",
            log_error(err))
    end
end

return Migrations
