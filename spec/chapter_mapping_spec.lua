package.path = "./?.lua;" .. package.path
local Chapters = require("weread.lib.annotation_chapters")
local toc = {
    {title="雨季不再来", xpointer="a", depth=1},
    {title="版权信息", xpointer="b", depth=1},
    {title="当三毛还是在二毛的时候", xpointer="c", depth=1},
    {title="胆小鬼", xpointer="d", depth=1},
    {title="雨季不再来", xpointer="e", depth=1},
    {title="一个星期一的早晨", xpointer="f", depth=1},
}
local catalog = {
    {chapterUid="2",title="版权信息",level=1},
    {chapterUid="3",title="雨季不再来",level=1},
    {chapterUid="4",title="当三毛还是在二毛的时候",level=2},
    {chapterUid="5",title="胆小鬼",level=2},
    {chapterUid="21",title="雨季不再来",level=2},
    {chapterUid="22",title="一个星期一的早晨",level=2},
}
local doc={getToc=function() return toc end}
local selected,ranges=Chapters.map(doc,catalog)
assert(#selected==#catalog)
assert(ranges['4'].start_xpointer=='c' and ranges['5'].start_xpointer=='d', 'front chapters skipped')
assert(not ranges['3'] and not ranges['21'], 'duplicate volume/article guessed')
local reordered={catalog[6],catalog[4],catalog[3],catalog[1]}
selected,ranges=Chapters.map(doc,reordered)
assert(selected[1].chapterUid=='2' and selected[4].chapterUid=='22', 'remote reorder changed local processing order')
assert(ranges['4'].end_xpointer=='d')
local nested={
    {title='第一卷',depth=1,xpointer='1'}, {title='序言',depth=2,xpointer='2'},
    {title='第二卷',depth=1,xpointer='3'}, {title='序言',depth=2,xpointer='4'},
}
local remote={
    {title='第二卷',level=1,chapterUid='b'}, {title='序言',level=2,chapterUid='bp'},
    {title='第一卷',level=1,chapterUid='a'}, {title='序言',level=2,chapterUid='ap'},
}
local _,nr=Chapters.map({getToc=function() return nested end},remote)
assert(nr.ap.start_xpointer=='2' and nr.bp.start_xpointer=='4','duplicate parent scopes lost')
table.insert(remote,{title='序言',level=2,chapterUid='ap2'})
_,nr=Chapters.map({getToc=function() return nested end},remote)
assert(not nr.ap and not nr.ap2,'ambiguous siblings assigned by order')
local _,dr=Chapters.map(doc,catalog,{chapters={catalog[2],catalog[1]}})
assert(dr['3'].toc_index==1 and dr['2'].toc_index==2,'manifest identity changed')
-- Reconciliation is document-specific and does not discard source data.
local helper=require('spec.helpers.annotation_test_store')
local store=helper.new()
for _,uid in ipairs({'4','5'}) do
    local key='doc:'..uid
    store:put('book','status',key,{range_key=Chapters.rangeKey(ranges[uid])},uid)
    store:put('book','projection',key,{records={1}},uid)
    store:put('book','source',uid,{underlines={1}},uid)
end
store:put('book','status','other:4',{range_key='other'},'4')
local old=ranges['4'];ranges['4']={start_xpointer='new',end_xpointer=old.end_xpointer}
store:reconcileRanges('book','doc',ranges)
assert(not store:get('book','status','doc:4') and not store:get('book','projection','doc:4'))
assert(store:get('book','status','doc:5') and store:get('book','status','other:4'))
assert(store:get('book','source','4').underlines[1]==1)
helper.cleanup()
print('chapter_mapping_spec: reorder, duplicate scopes, bounds and cache retention passed')
