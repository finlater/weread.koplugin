-- End-of-book navigation dialog integration.
local EndOfBookDialog = require("weread.ui.end_of_book_dialog")
local PluginUtil = require("weread.lib.plugin_util")
local WeRead = require("weread.lib.protocol")

local _ = PluginUtil.tr

local M = {}

-- Dispatcher entry point used by KOReader gesture/profile actions. The quick
-- menu is a global WeRead entry point; actions that need a current WeRead book
-- explain why they are unavailable when invoked from another document.
function M:onShowWeReadQuickMenu()
    return self:showEndOfBookDialog(self:detectWeReadBook())
end

-- Dispatcher entry point for a gesture that opens the WeRead bookshelf from
-- any document currently open in KOReader.
function M:onShowWeReadBookshelf()
    self:showBookshelf()
    return true
end

function M:onShowWeReadReadingStatistics()
    self:showReadStats()
    return true
end

function M:onShowWeReadSearch()
    self:showSearch()
    return true
end

function M:showEndOfBookDialog(book_id)
    local file_path = self.ui.document and self.ui.document.file
    if not file_path then return false end

    local books = self.settings:get("books", {})
    local book = book_id and (books[tostring(book_id)] or books[book_id]) or nil
    local is_regular_weread_book = book ~= nil and not WeRead.is_mp_book(book_id)
    local chapters = is_regular_weread_book and self:ensureChaptersLoaded(book) or nil

    local current_idx, is_full_book
    if chapters then
        local chapter_info = { self:getChapterInfoFromFile(book, file_path) }
        current_idx, is_full_book = chapter_info[1], chapter_info[3]
    end
    -- The chapter-nav row is shown only for single downloaded chapters (a mapped
    -- current chapter that is not part of a full-book EPUB); "next chapter"
    -- additionally requires a successor.
    local next_chapter = current_idx and not is_full_book
        and chapters[current_idx + 1] or nil

    local function show_context_required()
        self:showTransientInfo(
            _("This action requires an open WeRead book."), 1)
    end

    EndOfBookDialog.show({
        show_chapter_nav = true,
        show_next_chapter = true,
        show_sync_progress = true,
    }, {
        on_bookshelf = function()
            self:showBookshelf()
        end,
        on_search = function()
            self:showSearch()
        end,
        on_chapter_list = function()
            if chapters then
                self:showChapterList(book)
            else
                show_context_required()
            end
        end,
        on_next = function()
            if next_chapter then
                self:openChapter(book, next_chapter)
            elseif is_regular_weread_book then
                self:showTransientInfo(_("You have reached the last chapter."), 1)
            else
                show_context_required()
            end
        end,
        on_book_details = function()
            if book then
                self:showCurrentBookDetails()
            else
                show_context_required()
            end
        end,
        on_read_stats = function()
            self:showReadStats()
        end,
        on_sync_progress = function()
            if is_regular_weread_book then
                self:onWeReadSyncProgress()
            else
                show_context_required()
            end
        end,
        on_close_book = function()
            -- Mirror KOReader's ReaderStatus:openFileBrowser(): closing the
            -- reader alone exits the app when there is no file-manager stack, so
            -- reopen the file browser right after (positioned on the book file).
            local ui = self.ui
            if not ui then return end
            local file = ui.document and ui.document.file
            ui:onClose()
            if file and ui.showFileManager then
                ui:showFileManager(file)
            end
        end,
    })
    return true
end

return M
