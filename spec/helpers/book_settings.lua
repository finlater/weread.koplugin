-- Adds the per-book Settings interface (get_book/get_books/get_book_dirs/
-- put_book/delete_book) to a fake settings table over a plain `books` map.
local M = {}

local function find(books, book_id)
    return books[tostring(book_id)] or books[tonumber(book_id)]
end

function M.install(settings, books)
    settings.get_book = function(_self, book_id) return find(books, book_id) end
    settings.get_books = function() return books end
    settings.get_book_dirs = function()
        local dirs = {}
        for id, book in pairs(books) do dirs[id] = book.cache_dir end
        return dirs
    end
    settings.put_book = function(_self, book_id, book) books[tostring(book_id)] = book end
    settings.delete_book = function(_self, book_id) books[tostring(book_id)] = nil end
    return settings
end

return M
