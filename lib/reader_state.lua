local ReaderState = {}

function ReaderState.extract(html, json_decode)
    local reader
    if type(json_decode) == "function" then
        local encoded = html:match(
            [[window%.__INITIAL_STATE__%s*=%s*(.-)%s*;%s*%(function]]
        )
        if encoded then
            local ok, initial_state = pcall(json_decode, encoded)
            if ok and type(initial_state) == "table" then
                reader = initial_state.reader
            end
        end
    end

    reader = type(reader) == "table" and reader or {}
    local book_info = type(reader.bookInfo) == "table" and reader.bookInfo or {}
    local current_chapter = type(reader.currentChapter) == "table" and reader.currentChapter or {}
    local progress = type(reader.progress) == "table" and reader.progress or {}
    local progress_book = type(progress.book) == "table" and progress.book or progress

    return {
        book_id = book_info.bookId
            or html:match([["bookId"%s*:%s*"([^"]+)"]])
            or html:match([["bookId"%s*:%s*(%d+)]]),
        title = book_info.title or html:match([["title"%s*:%s*"([^"]+)"]]),
        author = book_info.author or html:match([["author"%s*:%s*"([^"]+)"]]),
        psvts = reader.psvts or html:match([["psvts"%s*:%s*"([^"]+)"]]),
        pclts = reader.pclts or html:match([["pclts"%s*:%s*"([^"]+)"]]),
        token = reader.token or html:match([["token"%s*:%s*"([^"]+)"]]),
        current_chapter = current_chapter,
        progress = progress_book,
    }
end

function ReaderState.apply_to_book(book, state)
    local current_chapter = state.current_chapter or {}
    local progress = state.progress or {}
    book.chapter_uid = current_chapter.chapterUid or progress.chapterUid or book.chapter_uid
    book.chapter_idx = tonumber(current_chapter.chapterIdx or progress.chapterIdx)
        or tonumber(book.chapter_idx)
    book.chapter_offset = tonumber(current_chapter.chapterOffset or progress.chapterOffset)
        or tonumber(book.chapter_offset) or 0
    book.progress = tonumber(progress.progress) or tonumber(book.progress) or 0
    book.summary = progress.summary or book.summary or ""
    return book
end

return ReaderState
