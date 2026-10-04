-- luacheck: globals disable_plugins load_plugin
-- Real KOReader/HTTP/SQLite regression for chapter mapping and annotation jobs.
-- Start scripts/mock_weread.py with a fresh --run-dir; run from the KOReader
-- runtime with KO_HOME=<run-dir>/profile and EMULATE_READER=1. See docs/mock-weread.md.
require('setupkoenv')
local home = assert(os.getenv('KO_HOME'))
package.path = 'spec/front/unit/?.lua;' .. package.path
require('commonrequire')
disable_plugins()
G_reader_settings:saveSetting('language', 'zh_CN')
G_reader_settings:saveSetting('extra_plugin_paths', { home .. '/plugins' })
load_plugin('weread.koplugin')
package.path = home .. '/plugins/weread.koplugin/?.lua;' .. package.path
local UIManager = require('ui/uimanager')
local Screen = require('device').screen
-- KOReader's dummy framebuffer defaults to 600x800 regardless of SDL env.
-- Size its real BlitBuffer explicitly for offscreen layout coverage.
local width = tonumber(os.getenv('EMULATE_READER_W')) or 600
local height = tonumber(os.getenv('EMULATE_READER_H')) or 800
if Screen:getWidth() ~= width or Screen:getHeight() ~= height then
    local BB = require('ffi/blitbuffer')
    Screen.bb:free()
    Screen.bb = BB.new(width, height)
    Screen.bb:fill(BB.COLOR_WHITE)
    Screen.screen_size = Screen:getRawSize()
end
assert(Screen:getWidth() == width and Screen:getHeight() == height)
print(string.format('Framebuffer: %dx%d', width, height))
local socket = require('socket')
local ffiutil = require('ffi/util')
local json = require('json')
local http = require('socket.http')
local ltn12 = require('ltn12')
local settings = require('weread.lib.settings'):new()
assert(settings.mock_endpoint and settings.data_dir:match('/weread%-mock$'))
local function control(values)
    local chunks, body = {}, values and json.encode(values)
    local _, status = http.request { url = settings.mock_endpoint .. (values and '/__control' or '/__state'),
        method = values and 'POST' or 'GET', headers = { ['Content-Type'] = 'application/json',
            ['Content-Length'] = body and #body or 0 },
        source = body and ltn12.source.string(body), sink = ltn12.sink.table(chunks) }
    assert(status == 200, tostring(status))
    return json.decode(table.concat(chunks))
end
local function annotation_requests()
    local count = 0
    for _, row in ipairs(control().requests) do
        if row.api == '/book/underlines' or row.api == '/book/readreviews' then count = count + 1 end
    end
    return count
end
UIManager:setRunForeverMode()
UIManager:setInputTimeout(0)
local function pump_until(predicate, timeout)
    local deadline = socket.gettime() + (timeout or 15)
    repeat
        UIManager:handleInput()
        if predicate() then return end
        assert(socket.gettime() < deadline, 'UI condition timed out')
        ffiutil.usleep(10000)
    until false
end
local function pump_for(seconds)
    local deadline = socket.gettime() + seconds
    pump_until(function() return socket.gettime() >= deadline end, seconds + 3)
end
local function dismiss_info()
    local top = UIManager._window_stack[#UIManager._window_stack]
    if top and getmetatable(top.widget) == require('ui/widget/infomessage') then UIManager:close(top.widget) end
end
local function shot(name)
    UIManager:forceRePaint()
    Screen:shot(home .. '/../evidence/' .. name .. '.png')
end
local Content = require('weread.lib.content')
local client = require('weread.lib.client'):new(settings)
local book = client:get_book_info('900001')
Content.ensure_reader_state(client, book)
local chapters = Content.fetch_catalog(client, book)
Content.save_catalog_cache(client, settings, book, chapters)
local path = Content.fetch_chapters_epub(client, settings, book, chapters, { suffix = 'annotation-test' })
settings:set('books', { [book.bookId] = book }); settings:flush()
local reader, plugin
local function open_reader()
    reader = require('apps/reader/readerui'):new { dimen = Screen:getSize(),
        document = require('document/documentregistry'):openDocument(path) }
    UIManager:show(reader)
    plugin = assert(reader.weread)
    pump_for(0.3)
end
open_reader()
local picker = assert(plugin:chooseAnnotationChapters())
assert(picker.model.count == 0 and picker.model.by_uid['1'] and picker.model.by_uid['6'])
local first = picker.model.by_uid['1']
assert(first.chapter and first.state == 'ready_to_fetch')
shot('01-matched-default-unchecked')
-- Native checkbox changes only one chapter, not its siblings.
picker.layout[2][1].callback()
assert(picker.model.count == 1 and picker.model.by_uid['2'].selected)
picker:edit(first)
local menu = UIManager._window_stack[#UIManager._window_stack].widget
assert(menu.item_table and menu.item_table[1].callback, 'native chapter menu')
shot('02-change-chapter-menu')
menu.item_table[1].callback()
assert(not picker.model.by_uid['1'] and picker.model.count == 1)
local unmatched = picker.model.nodes[first.index]
assert(not unmatched.chapter and not unmatched.selectable)
shot('03-unmatched-keeps-selection')
picker:edit(unmatched)
menu = UIManager._window_stack[#UIManager._window_stack].widget
menu.item_table[1].callback()
assert(picker.model.by_uid['1'] and picker.model.by_uid['2'].selected and picker.model.count == 1)
-- Slow real HTTP request, real progress dialog, real Trapper child.
control { match = '/book/readreviews', delay = 3, times = 0 }
picker.actions.buttons_layout[1][1].callback()
pump_until(function()
    local r = plugin._external_annotation_sync
    return r and r.progress and r.progress.dismiss_callback
        and plugin:_annotationStore():get('900001', 'download', '2')
end)
local request = plugin._external_annotation_sync
shot('04-cancel-during-thought-request')
local elapsed, requested_at = nil, socket.gettime()
UIManager:scheduleIn(0.1, function()
    request.progress.buttons[1][1].callback()
    elapsed = socket.gettime() - requested_at
end)
pump_until(function() return elapsed ~= nil end)
assert(elapsed < 0.6 and not plugin._external_annotation_sync, 'cancel blocked on HTTP')
local context = plugin:_prepareAnnotationContext(false)
local store = context.store
assert(store:get('900001', 'download', '2') and not store:get('900001', 'source_status', '2'))
pump_for(3.2)
assert(not plugin._external_annotation_sync and not store:get('900001', 'source_status', '2'), 'late response wrote source')
print(string.format('PASS: real dialog cancellation %.3fs; checkpoint retained; late response ignored', elapsed))
control { match = '', delay = 0, times = 0 }
local before_resume = annotation_requests()
plugin:startUnifiedAnnotationSync { chapters = { chapters[2] } }
pump_until(function() return plugin._external_annotation_sync ~= nil end)
pump_until(function() return not plugin._external_annotation_sync end)
assert(annotation_requests() == before_resume + 1, 'manual resume must request only the remaining thoughts batch')
context = plugin:_prepareAnnotationContext(false)
assert(context.statuses[store:projectionKey(context.document_key, '2')], 'manual matching did not finish')
assert(store:get('900001', 'source', '2').underlines[1].metadata == json.decode('null'),
    'HTTP/worker/SQLite roundtrip lost the JSON null fixture')
dismiss_info()
picker = plugin:chooseAnnotationChapters()
assert(picker.model.by_uid['2'].state == 'matched' and picker.model.count == 0)
shot('05-retrieved-default-unchecked')
picker:onClose()
-- An unfinished chapter and a cached source with no positions coexist on open.
local ok, data = plugin.client:get_chapter_underlines('900001', 4)
assert(ok)
store:put('900001', 'download', '4', { underlines = data.underlines, next_batch = 1, revision = '1' }, '4')
local before_open = annotation_requests()
for _, switches in ipairs({ { false, false }, { true, false }, { false, true } }) do
    local cache = plugin.settings:get('cache')
    cache.auto_prefetch_next_chapter, cache.prefetch_annotations = unpack(switches)
    plugin.settings:set('cache', cache); plugin.settings:flush()
    reader:onClose(); open_reader()
    assert(not plugin._external_annotation_sync and annotation_requests() == before_open,
        'opening with a disabled switch started annotation work')
    assert(plugin:_annotationStore():get('900001', 'download', '4'), 'opening lost checkpoint')
end
print('PASS: three disabled-switch combinations, real close/reopen, saved results and checkpoints retained')
local cache = plugin.settings:get('cache')
cache.auto_prefetch_next_chapter, cache.prefetch_annotations = true, true
plugin.settings:set('cache', cache); plugin.settings:flush()
control { match = '/book/readreviews', delay = 2, times = 0 }
reader:onClose(); open_reader()
assert(plugin._external_annotation_sync and plugin._external_annotation_sync.worker_handle)
assert(not plugin._external_annotation_sync.progress, 'background showed progress UI')
local ticks, max_gap, previous = 0, 0, socket.gettime()
local function tick()
    local now = socket.gettime()
    ticks, max_gap, previous = ticks + 1, math.max(max_gap, now - previous), now
    if plugin._external_annotation_sync then UIManager:scheduleIn(0.1, tick) end
end
UIManager:scheduleIn(0.1, tick)
reader.rolling:onGotoPage(2)
pump_for(0.2)
assert(reader:getCurrentPage() == 2)
shot('06-page-turn-during-background-resume')
pump_until(function() return not plugin._external_annotation_sync end)
assert(ticks >= 10 and max_gap < 0.6, 'background worker blocked UI ticks')
context = plugin:_prepareAnnotationContext(false); store = context.store
assert(store:get('900001', 'source_status', '4')
    and not store:get('900001', 'projection', store:projectionKey(context.document_key, '4')),
    'background download matched document positions')
local after_background = annotation_requests()
reader:onClose(); open_reader()
assert(not plugin._external_annotation_sync and annotation_requests() == after_background,
    'complete source auto-matched or redownloaded on reopen')
print(string.format('PASS: background HTTP/SQLite, page turn, %d UI ticks, maximum gap %.3fs; positions remain manual', ticks, max_gap))
control { match = '', delay = 0, times = 0 }
-- Turning either preference off cancels an active child and its queued successor.
local tr = require('weread.lib.plugin_util').tr
local function menu_item(items, title)
    for _, item in ipairs(items) do if item.text == tr(title) then return item end end
    error('missing menu: ' .. title)
end
for index, uid in ipairs({ 3, 5 }) do
    cache = plugin.settings:get('cache')
    cache.auto_prefetch_next_chapter, cache.prefetch_annotations = true, true
    plugin.settings:set('cache', cache); plugin.settings:flush()
    control { match = '/book/readreviews', delay = 2, times = 0 }
    plugin:prefetchChapterAnnotations(book, chapters[uid])
    -- Wait on the worker's progress channel, rather than reopening SQLite
    -- every UI tick while the child is committing its first checkpoint.
    pump_until(function()
        local job = plugin.prefetch_worker.job
        local state = job and plugin.prefetch_worker:_decode(job.progress_path)
        return state and state.stage == 'thoughts'
    end)
    pump_for(0.5)
    plugin:prefetchChapterAnnotations(book, chapters[6])
    assert(plugin._annotation_pending_prefetch)
    local menus = plugin:getSettingsMenuItems()
    local downloads = menu_item(menus, 'Download settings').sub_item_table_func()
    local switches = menu_item(downloads, 'Chapter prefetch').sub_item_table_func()
    switches[index == 1 and 2 or 1].callback()
    assert(plugin._external_annotation_sync.cancelled and not plugin._annotation_pending_prefetch)
    reader.rolling:onGotoPage(3)
    pump_for(0.2)
    assert(reader:getCurrentPage() == 3)
    pump_until(function() return not plugin._external_annotation_sync end, 8)
    assert(store:get('900001', 'download', tostring(uid))
        and not store:get('900001', 'source_status', tostring(uid))
        and not store:get('900001', 'download', '6'), 'disabled prefetch lost progress or launched pending work')
end
control { match = '', delay = 0, times = 0 }
cache = plugin.settings:get('cache')
cache.auto_prefetch_next_chapter, cache.prefetch_annotations = true, true
plugin.settings:set('cache', cache)
local runner, before_unavailable = plugin.prefetch_worker.runner, annotation_requests()
plugin.prefetch_worker.runner = nil -- fault at the subprocess-launch boundary
plugin:onUnifiedAnnotationsReady()
pump_for(0.4)
assert(not plugin._external_annotation_sync and annotation_requests() == before_unavailable,
    'unavailable subprocess fell back to UI network work')
plugin.prefetch_worker.runner = runner
cache.auto_prefetch_next_chapter, cache.prefetch_annotations = false, false
plugin.settings:set('cache', cache); plugin.settings:flush()
print('PASS: each real settings callback cancels active/queued prefetch; progress survives; unavailable worker never runs in UI')
-- Refetch is deliberate replacement; an empty success must clear old thoughts.
control { empty_annotations = true }
plugin:startUnifiedAnnotationSync { chapters = { chapters[2] }, clear_existing = true }
pump_until(function() return plugin._external_annotation_sync ~= nil end)
pump_until(function() return not plugin._external_annotation_sync end)
context = plugin:_prepareAnnotationContext(false); store = context.store
local source = assert(store:get('900001', 'source', '2'))
assert(#source.underlines == 0 and #source.reviews == 0)
dismiss_info()
picker = plugin:chooseAnnotationChapters()
assert(picker.model.by_uid['2'].state == 'matched' and picker.model.count == 0)
shot('07-empty-success-retrieved')
picker:onClose()
control { empty_annotations = false }
print('PASS: selected chapter refetch clears old data; successful empty result remains Matched')
-- A fresh display must activate as soon as its first chapter commits, even
-- if a later real HTTP request fails and the user resumes it afterward.
dismiss_info()
store:put('900001', 'display', context.document_key, nil)
plugin._unified_annotations_active = false
plugin:startUnifiedAnnotationSync { chapters = { chapters[1], chapters[2] }, clear_existing = true }
pump_until(function() return plugin._external_annotation_sync ~= nil end)
pump_until(function()
    return store:get('900001', 'status', store:projectionKey(context.document_key, '1')) ~= nil
end)
assert(plugin._unified_annotations_active and store:get('900001', 'display', context.document_key),
    'first completed chapter was not activated before the next network request')
control { match = '/book/underlines', status = 503, times = -1 }
pump_until(function() return not plugin._external_annotation_sync end, 25)
assert(store:get('900001', 'source_status', '1') and not store:get('900001', 'source_status', '2'))
assert(plugin._unified_annotations_active and store:get('900001', 'display', context.document_key))
dismiss_info()
reader.rolling:onGotoPage(1)
pump_for(0.2)
assert(#plugin._xpointer_overlay.records > 0, 'later HTTP failure hid completed underline records')
shot('08-completed-chapter-after-http-failure')
control { match = '', delay = 0, times = 0 }
local before_retry = annotation_requests()
plugin:startUnifiedAnnotationSync { chapters = { chapters[1], chapters[2] } }
pump_until(function() return plugin._external_annotation_sync ~= nil end)
pump_until(function() return not plugin._external_annotation_sync end)
assert(annotation_requests() == before_retry + 2, 'resume refetched the already completed first chapter')
assert(store:get('900001', 'status', store:projectionKey(context.document_key, '2')))
print('PASS: later HTTP failure preserves visible completed chapter; resume fetches only the unfinished chapter')
assert(not plugin:_annotationStore().legacy.busy_timeout_ms, 'child lock timeout leaked into UI')
assert(UIManager._prevent_standby_count == 0, 'standby guard leaked')
reader:onClose(); UIManager:quit()
print('PASS: annotation mock regression complete')
