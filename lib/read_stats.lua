-- lib/read_stats.lua — WeRead reading statistics data layer.
--
-- Pure logic, no UI dependencies:
--   * calls the /readdata/detail gateway API (via the shared Client)
--   * normalizes the response into a stable structure (raw seconds / date labels only)
--   * computes period navigation (previous / next natural week/month/year)
--
-- All user-facing formatting (durations -> "X小时Y分钟", localized labels) lives in
-- the view layer; this module stays locale-independent so it can be unit-tested.
--
-- Time zone: WeRead normalizes every period (baseTime) and every readTimes bucket
-- to Beijing time (UTC+8, no DST). We therefore interpret all timestamps in CST
-- regardless of the device time zone, so month/day labels never drift.

local M = {}

-- Supported statistic modes, in tab order.
M.MODES = { "weekly", "monthly", "annually", "overall" }

local DAY_SECONDS = 86400
local CST_OFFSET = 8 * 3600 -- Beijing time, east of UTC

-- Device offset east of UTC, in seconds (e.g. a CST device returns 28800).
local function utc_offset()
    local now = os.time()
    return os.difftime(now, os.time(os.date("!*t", now)))
end

-- Broken-down Beijing-time components for a timestamp (isdst = false).
local function cst_date(ts)
    return os.date("!*t", ts + CST_OFFSET)
end

-- Inverse of cst_date: real Unix timestamp for a Beijing-time components table.
-- os.time() treats the table as device-local, so we undo the device offset and
-- then shift by the fixed CST offset.
local function cst_time(t)
    return os.time(t) + utc_offset() - CST_OFFSET
end

-- strftime against Beijing wall-clock time.
local function cst_fmt(fmt, ts)
    return os.date("!" .. fmt, ts + CST_OFFSET)
end
M.cst_fmt = cst_fmt

-- Zero out the time-of-day part of a components table.
local function at_midnight(t)
    t.hour, t.min, t.sec = 0, 0, 0
    return t
end

-- Start-of-period timestamp (Beijing time) for the week/month/year containing `ts`.
-- weekly starts on Monday, matching the WeRead server normalization.
local function period_start(mode, ts)
    local t = at_midnight(cst_date(ts))
    if mode == "weekly" then
        -- wday: 1=Sunday .. 7=Saturday; days since Monday.
        local offset = (t.wday == 1) and 6 or (t.wday - 2)
        t.day = t.day - offset
    elseif mode == "monthly" then
        t.day = 1
    elseif mode == "annually" then
        t.month, t.day = 1, 1
    end
    return cst_time(t)
end
M.period_start = period_start

-- Shift a normalized period start by `delta` periods (delta = -1 prev, +1 next).
local function shift_period(mode, base_time, delta)
    if mode == "weekly" then
        -- Re-normalize after arithmetic to stay robust across any boundary.
        return period_start("weekly", base_time + delta * 7 * DAY_SECONDS + DAY_SECONDS)
    end
    local t = at_midnight(cst_date(base_time))
    if mode == "monthly" then
        t.month = t.month + delta -- os.time normalizes month over/underflow
        t.day = 1
    elseif mode == "annually" then
        t.year = t.year + delta
        t.month, t.day = 1, 1
    end
    return cst_time(t)
end
M.shift_period = shift_period

-- Human-readable, locale-independent period label (Beijing time).
-- "overall" has no bounded period, so it returns an empty string.
function M.period_label(mode, base_time)
    if mode == "weekly" then
        return cst_fmt("%Y-%m-%d", base_time) .. " ~ " .. cst_fmt("%m-%d", base_time + 6 * DAY_SECONDS)
    elseif mode == "monthly" then
        return cst_fmt("%Y-%m", base_time)
    elseif mode == "annually" then
        return cst_fmt("%Y", base_time)
    elseif mode == "overall" then
        return ""
    end
    return cst_fmt("%Y-%m-%d", base_time)
end

-- Bar-chart label for a single readTimes bucket, derived from its timestamp.
-- weekly/monthly bucket by day (day-of-month), annually by month, overall by year.
local function bucket_label(mode, ts)
    if mode == "annually" then
        return tostring(tonumber(cst_fmt("%m", ts)))
    elseif mode == "overall" then
        return cst_fmt("%Y", ts)
    end
    return tostring(tonumber(cst_fmt("%d", ts)))
end

-- Convert the readTimes map { [ts_string] = seconds } into a time-sorted array.
local function normalize_buckets(mode, read_times)
    local buckets = {}
    if type(read_times) ~= "table" then
        return buckets
    end
    for key, value in pairs(read_times) do
        local ts = tonumber(key)
        if ts then
            buckets[#buckets + 1] = {
                ts = ts,
                label = bucket_label(mode, ts),
                value = tonumber(value) or 0,
            }
        end
    end
    table.sort(buckets, function(a, b) return a.ts < b.ts end)
    return buckets
end

-- Ranking of most-read books / audio (readLongest).
local function normalize_top_books(read_longest)
    local list = {}
    if type(read_longest) ~= "table" then
        return list
    end
    for _i, item in ipairs(read_longest) do
        local book = item.book or {}
        local album = item.albumInfo or {}
        local title = book.title or album.name
        if title and title ~= "" then
            list[#list + 1] = {
                title = title,
                author = book.author or album.authorName,
                seconds = tonumber(item.readTime) or 0,
            }
        end
    end
    return list
end

-- Preferred categories (preferCategory). WeRead does not return the documented
-- `val` weight in practice, so bar length is scaled from readingTime by the view.
local function normalize_prefer_category(prefer_category)
    local list = {}
    if type(prefer_category) ~= "table" then
        return list
    end
    for _i, item in ipairs(prefer_category) do
        if item.categoryTitle and item.categoryTitle ~= "" then
            list[#list + 1] = {
                title = item.categoryTitle,
                seconds = tonumber(item.readingTime) or 0,
                count = tonumber(item.readingCount) or 0,
            }
        end
    end
    return list
end

-- Preferred authors / publishers: keep name + book count only.
local function normalize_named_counts(items, name_key)
    local list = {}
    if type(items) ~= "table" then
        return list
    end
    for _i, item in ipairs(items) do
        local name = item[name_key]
        if name and name ~= "" then
            list[#list + 1] = { name = name, count = tonumber(item.count) or 0 }
        end
    end
    return list
end

-- Summary chips (readStat): { stat = "读过", counts = "12本" }.
local function normalize_summary(read_stat)
    local list = {}
    if type(read_stat) ~= "table" then
        return list
    end
    for _i, item in ipairs(read_stat) do
        if item.stat and item.counts then
            list[#list + 1] = { name = item.stat, counts = item.counts }
        end
    end
    return list
end

-- Normalize a raw /readdata/detail response into the view's stable schema.
-- Every field is defensive: missing data yields empty tables / zero / nil, so the
-- view can simply hide the corresponding card or line.
function M.normalize(raw, mode)
    raw = type(raw) == "table" and raw or {}
    return {
        mode = mode,
        total_read_time = tonumber(raw.totalReadTime) or 0,
        read_days = tonumber(raw.readDays) or 0,
        day_average = tonumber(raw.dayAverageReadTime) or 0,
        compare = tonumber(raw.compare), -- may be nil (only current period w/ history)
        read_rate = tonumber(raw.readRate), -- text-reading %, annually/overall only
        buckets = normalize_buckets(mode, raw.readTimes),
        top_books = normalize_top_books(raw.readLongest),
        prefer_category = normalize_prefer_category(raw.preferCategory),
        prefer_category_word = raw.preferCategoryWord,
        prefer_time_word = raw.preferTimeWord,
        prefer_author = normalize_named_counts(raw.preferAuthor, "name"),
        prefer_publisher = normalize_named_counts(raw.preferPublisher, "name"),
        summary = normalize_summary(raw.readStat),
        rank_text = type(raw.rank) == "table" and raw.rank.text or nil,
    }
end

-- Fetch + normalize + resolve period navigation.
-- Returns a normalized table augmented with:
--   base_time  : canonical (server-normalized) period start
--   period_label
--   allow_prev / allow_next : whether previous/next period navigation is possible
--   prev_base_time / next_base_time : navigation targets (nil for "overall")
function M.fetch(client, mode, base_time)
    mode = mode or "monthly"
    local raw = client:get_read_stats(mode, base_time)
    local data = M.normalize(raw, mode)

    if mode == "overall" then
        -- A single unbounded period: no navigation.
        data.base_time = 0
        data.period_label = ""
        data.allow_prev = false
        data.allow_next = false
        return data
    end

    -- Prefer the server-normalized baseTime; fall back to local computation.
    local canonical = tonumber(raw and raw.baseTime)
    if not canonical then
        local seed = (base_time and tonumber(base_time) and tonumber(base_time) > 0)
            and tonumber(base_time) or os.time()
        canonical = period_start(mode, seed)
    end

    data.base_time = canonical
    data.period_label = M.period_label(mode, canonical)
    data.prev_base_time = shift_period(mode, canonical, -1)
    local next_base = shift_period(mode, canonical, 1)
    data.next_base_time = next_base
    data.allow_prev = true
    -- next_base is the actual start of the following period; if it is already in
    -- the past, that period has begun and navigating forward is allowed.
    data.allow_next = next_base <= os.time()
    return data
end

return M
