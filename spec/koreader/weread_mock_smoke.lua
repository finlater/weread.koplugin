-- Standalone real-KOReader smoke. See docs/mock-weread.md for the command.
-- luacheck: globals fastforward_ui_events
require("setupkoenv")
local home = assert(os.getenv("KO_HOME"))
package.path = "spec/front/unit/?.lua;" .. package.path
require("commonrequire")
disable_plugins()
G_reader_settings:saveSetting("language", "zh_CN")
G_reader_settings:saveSetting("extra_plugin_paths", { home .. "/plugins" })
load_plugin("weread.koplugin")
-- PluginLoader restores package.path after loading; later lazy requires in
-- this standalone test need the same installed candidate directory.
package.path = home .. "/plugins/weread.koplugin/?.lua;" .. package.path

local Settings = require("weread.lib.settings")
local Client = require("weread.lib.client")
local Content = require("weread.lib.content")
local settings = Settings:new()
assert(settings.mock_endpoint and settings.data_dir:match("/weread%-mock$"), "isolated mock environment")
local client = Client:new(settings)
-- A configured Internet proxy must not intercept local mock traffic or probes.
local http = require("socket.http")
http.PROXY = "http://127.0.0.1:1"
assert(client:test_mock_connection(require("weread.lib.mock_environment").active()) == settings.mock_endpoint)
local shelf = client:get_shelf()
assert(#shelf.books == 26 and #shelf.archive == 3, "shelf contract")
assert(http.PROXY == "http://127.0.0.1:1", "mock changed the global HTTP proxy")
local book = client:get_book_info("900001")
Content.ensure_reader_state(client, book)
local chapters = Content.fetch_catalog(client, book)
assert(#chapters == 6, "catalog contract")
assert(Content.save_catalog_cache(client, settings, book, chapters))
local path = Content.fetch_chapter_epub(client, settings, book, chapters[1])
settings:set("books", { [book.bookId] = book })
settings:flush()
local ok, marks = client:get_chapter_underlines(book.bookId, 1)
assert(ok and #marks.underlines == 1, "underlines contract")
local reviews_ok, thoughts = client:get_chapter_reviews(book.bookId, 1, { marks.underlines[1].range })
assert(reviews_ok and #thoughts.reviews == 1, "thoughts contract")
local denied, code = client:request({ url = "https://example.invalid/never-contact-upstream" })
assert(code == 501 and denied:find("Unimplemented mock route", 1, true), "HTTP must fail closed")

local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local reader = require("apps/reader/readerui"):new{
    dimen = Screen:getSize(),
    document = require("document/documentregistry"):openDocument(path),
}
assert(reader.weread, "real plugin instance")
UIManager:show(reader)
fastforward_ui_events()
assert(reader.document:getPageCount() > 1, "real downloaded EPUB must paginate")
reader.rolling:onGotoPage(1)
fastforward_ui_events()
Screen:shot(home .. "/../evidence/mock-page-1.png")
reader.rolling:onGotoPage(2)
fastforward_ui_events()
assert(reader:getCurrentPage() == 2, "real page turn")
Screen:shot(home .. "/../evidence/mock-page-2.png")
-- Exercise the real event loop, subprocesses, resume workspace, and packaging.
local completed, full_path, download_error
local function deadline()
    download_error = "full download exceeded 45 seconds"
    UIManager:quit()
end
UIManager:scheduleIn(45, deadline)
reader.weread.downloader:start(book, chapters, "full", {
    offer_read = false,
    silent_completion = true,
    on_complete = function(success, value)
        completed = success
        if success then full_path = value else download_error = tostring(value) end
        UIManager:unschedule(deadline)
        UIManager:quit()
    end,
})
UIManager:run()
assert(completed and full_path, download_error or "Downloader did not complete")
local file = assert(io.open(full_path, "rb"))
assert(file:read(2) == "PK", "full download must produce an EPUB ZIP")
file:close()
reader:onClose()
UIManager:quit()
print("PASS: mock HTTP -> real Client/Content/Downloader -> EPUB with image/footnote -> ReaderUI -> page 2")
print("EPUB: " .. path)
print("FULL EPUB: " .. full_path)
