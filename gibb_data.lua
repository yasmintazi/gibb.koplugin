--[[
Everything the dashboard knows about your books.

It reads KOReader's own files and never keeps a second copy of your data:
  * book status, rating, review, progress, highlights -> each book's sidecar
  * reading time and pages                           -> statistics.sqlite3 (read only)
The only thing written by this file is a small index of the library so the
folders do not have to be walked every time.
]]

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local LuaSettings = require("luasettings")
local ReadHistory = require("readhistory")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local D = {
    index = nil,      -- array of book entries
    by_file = nil,    -- file path -> entry
    hl_cache = nil,   -- all highlights, kept for the session
    MAX_FILES = 3000,
    RECENT = 60,
}

local INDEX_FILE = DataStorage:getSettingsDir() .. "/gibb_index.lua"
local STATS_DB = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

local function trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end

local function baseName(file)
    local name = file:match("([^/]+)$") or file
    return (name:gsub("%.[^.]+$", ""))
end

---------------------------------------------------------------------------
-- One book
---------------------------------------------------------------------------

-- Returns the book's settings and whether they belong to the open book.
function D.docSettings(ui, file, create)
    if ui and ui.document and ui.document.file == file and ui.doc_settings then
        return ui.doc_settings, true
    end
    if create or DocSettings:hasSidecarFile(file) then
        local ok, ds = pcall(DocSettings.open, DocSettings, file)
        if ok and ds then return ds, false end
    end
    return nil, false
end

local function splitList(text, pattern)
    local out = {}
    if type(text) ~= "string" then return out end
    for part in text:gmatch(pattern) do
        part = trim(part)
        if part ~= "" then out[#out + 1] = part end
    end
    return out
end

local function countHighlights(ds)
    local n = 0
    local list = ds:readSetting("annotations")
    if type(list) == "table" then
        for i = 1, #list do
            local a = list[i]
            if a.text and a.text ~= "" and (a.pos0 or a.drawer) then n = n + 1 end
        end
    end
    return n
end

function D.readBook(ui, file)
    local e = { file = file, percent = 0, n_highlights = 0 }
    local props = {}
    local ds, live = D.docSettings(ui, file)
    local status
    if ds then
        local stored = ds:readSetting("doc_props")
        if type(stored) == "table" then props = stored end
        local summary = ds:readSetting("summary")
        if type(summary) ~= "table" then summary = {} end
        status = summary.status
        e.rating = tonumber(summary.rating)
        e.note = type(summary.note) == "string" and summary.note ~= "" and summary.note or nil
        e.modified = summary.modified
        e.percent = tonumber(ds:readSetting("percent_finished")) or 0
        e.pages = tonumber(ds:readSetting("doc_pages"))
        e.n_highlights = countHighlights(ds)
        e.opened = true
    end
    if live then
        pcall(function()
            local pages = ui.document:getPageCount()
            e.pages = pages
            e.percent = ui:getCurrentPage() / pages
        end)
        if type(ui.doc_props) == "table" then
            local merged = {}
            for _i, key in ipairs({ "title", "authors", "series", "keywords", "description" }) do
                merged[key] = ui.doc_props[key] or props[key]
            end
            props = merged
        end
    end
    if not props.title then
        -- Never opened: borrow what the cover browser already extracted.
        local ok, BookInfoManager = pcall(require, "bookinfomanager")
        if ok and type(BookInfoManager) == "table" then
            local ok2, info = pcall(BookInfoManager.getBookInfo, BookInfoManager, file, false)
            if ok2 and type(info) == "table" then
                props = { title = info.title, authors = info.authors, keywords = info.keywords,
                          description = info.description, series = info.series }
                e.pages = e.pages or tonumber(info.pages)
            end
        end
    end
    local title = props.title
    e.title = (type(title) == "string" and trim(title) ~= "") and trim(title) or baseName(file)
    e.author_list = splitList(props.authors, "[^\n]+")
    e.authors = table.concat(e.author_list, ", ")
    e.series = type(props.series) == "string" and props.series or nil
    e.keywords = splitList(props.keywords, "[^\n;,]+")
    if type(props.description) == "string" and props.description ~= "" then
        local text = props.description
        local ok, plain = pcall(util.htmlToPlainTextIfHtml, text)
        if ok and type(plain) == "string" then text = plain end
        e.description = trim(text):sub(1, 600)
    end
    if status == "complete" then e.state = "finished"
    elseif status == "abandoned" then e.state = "hold"
    elseif e.opened and (e.percent > 0 or status == "reading") then e.state = "reading"
    else e.state = "new" end
    e.added = lfs.attributes(file, "modification") or 0
    return e
end

---------------------------------------------------------------------------
-- Library index
---------------------------------------------------------------------------

local function walk(dir, out, depth)
    if depth > 8 or #out >= D.MAX_FILES then return end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return end
    for name in iter, dir_obj do
        if name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
            local path = dir .. "/" .. name
            local mode = lfs.attributes(path, "mode")
            if mode == "directory" then
                walk(path, out, depth + 1)
            elseif mode == "file" and #out < D.MAX_FILES and DocumentRegistry:hasProvider(path) then
                out[#out + 1] = path
            end
        end
    end
end

function D.libraryDirs(settings)
    local dirs = {}
    if type(settings.library_dirs) == "table" then
        for i = 1, #settings.library_dirs do dirs[#dirs + 1] = settings.library_dirs[i] end
    end
    if #dirs == 0 then
        local home = G_reader_settings:readSetting("home_dir")
        if type(home) == "string" and home ~= "" then dirs[1] = home end
    end
    for i = 1, #dirs do dirs[i] = dirs[i]:gsub("/+$", "") end
    return dirs
end

local function dirStamp(dirs)
    local stamp = 0
    for i = 1, #dirs do stamp = stamp + (lfs.attributes(dirs[i], "modification") or 0) end
    return stamp
end

local function historyTimes()
    local times, order = {}, {}
    local hist = ReadHistory.hist or {}
    for i = 1, #hist do
        local item = hist[i]
        if item.file and not item.dim then
            times[item.file] = item.time or 0
            order[#order + 1] = item.file
        end
    end
    return times, order
end

local function setIndex(list)
    D.index = list
    D.by_file = {}
    for i = 1, #list do D.by_file[list[i].file] = list[i] end
    D.hl_cache = nil
end

local function saveIndex(stamp)
    local ok, err = pcall(function()
        local store = LuaSettings:open(INDEX_FILE)
        store:saveSetting("books", D.index)
        store:saveSetting("stamp", stamp)
        store:saveSetting("scanned", os.time())
        store:flush()
    end)
    if not ok then logger.warn("gibb: could not save index:", err) end
end

-- Walks the library folders. This is the only slow operation in the plugin.
function D.rebuild(ui, settings)
    local dirs = D.libraryDirs(settings)
    local files, seen = {}, {}
    for i = 1, #dirs do walk(dirs[i], files, 1) end
    for i = 1, #files do seen[files[i]] = true end
    local times, order = historyTimes()
    for i = 1, #order do
        if not seen[order[i]] and #files < D.MAX_FILES then
            files[#files + 1] = order[i]
            seen[order[i]] = true
        end
    end
    local list = {}
    for i = 1, #files do
        local ok, e = pcall(D.readBook, ui, files[i])
        if ok and e then
            e.last_read = times[files[i]]
            list[#list + 1] = e
        end
    end
    setIndex(list)
    saveIndex(dirStamp(dirs))
    return list
end

-- Re-reads only the books you touched lately; cheap enough for every open.
function D.refreshRecent(ui)
    if not D.index then return end
    local times, order = historyTimes()
    local highlights_changed = false
    for i = 1, math.min(#order, D.RECENT) do
        local file = order[i]
        local ok, e = pcall(D.readBook, ui, file)
        if ok and e then
            e.last_read = times[file]
            local old = D.by_file[file]
            if old then
                if (old.n_highlights or 0) ~= (e.n_highlights or 0) then highlights_changed = true end
                for k in pairs(old) do old[k] = nil end
                for k, v in pairs(e) do old[k] = v end
            else
                if (e.n_highlights or 0) > 0 then highlights_changed = true end
                D.index[#D.index + 1] = e
                D.by_file[file] = e
            end
        end
    end
    -- The gathered highlights stay in memory until a book gains or loses
    -- one, so picking a new quote does not re-read every book each time.
    if highlights_changed then D.hl_cache = nil end
end

function D.getIndex(ui, settings)
    local dirs = D.libraryDirs(settings)
    if not D.index then
        local ok, store = pcall(LuaSettings.open, LuaSettings, INDEX_FILE)
        local books = ok and store and store:readSetting("books")
        if type(books) == "table" and #books > 0 and store:readSetting("stamp") == dirStamp(dirs) then
            local list = {}
            for i = 1, #books do
                if type(books[i]) == "table" and books[i].file
                    and lfs.attributes(books[i].file, "mode") == "file" then
                    list[#list + 1] = books[i]
                end
            end
            setIndex(list)
        else
            D.rebuild(ui, settings)
            return D.index
        end
    end
    D.refreshRecent(ui)
    return D.index
end

function D.entry(ui, file)
    if D.by_file and D.by_file[file] then
        local ok, e = pcall(D.readBook, ui, file)
        if ok and e then
            local old = D.by_file[file]
            e.last_read = old.last_read
            for k in pairs(old) do old[k] = nil end
            for k, v in pairs(e) do old[k] = v end
        end
        return D.by_file[file]
    end
    local ok, e = pcall(D.readBook, ui, file)
    if ok then return e end
    return { file = file, title = baseName(file), authors = "", author_list = {}, keywords = {}, percent = 0, state = "new", n_highlights = 0 }
end

---------------------------------------------------------------------------
-- Writing a rating, review or status back to the book
---------------------------------------------------------------------------

local SIDECAR_STATUS = { finished = "complete", hold = "abandoned", reading = "reading" }

function D.saveSummary(ui, file, changes)
    local ds, live = D.docSettings(ui, file, true)
    if not ds then return false end
    local summary = ds:readSetting("summary")
    if type(summary) ~= "table" then summary = {} end
    if changes.rating ~= nil then
        summary.rating = (changes.rating and changes.rating > 0) and changes.rating or nil
    end
    if changes.note ~= nil then
        summary.note = changes.note ~= "" and changes.note or nil
    end
    if changes.state then
        local new_status = SIDECAR_STATUS[changes.state]
        if new_status and summary.status ~= new_status then
            summary.status = new_status
            summary.modified = os.date("%Y-%m-%d")
        end
    end
    ds:saveSetting("summary", summary)
    if not live then pcall(ds.flush, ds) end
    pcall(function()
        require("ui/widget/booklist").setBookInfoCacheProperty(file, "status", summary.status)
    end)
    if D.by_file and D.by_file[file] then D.entry(ui, file) end
    return true
end

---------------------------------------------------------------------------
-- Highlights
---------------------------------------------------------------------------

function D.highlightsFor(ui, e)
    local out = {}
    local ds = D.docSettings(ui, e.file)
    if not ds then return out end
    local list = ds:readSetting("annotations")
    if type(list) ~= "table" then return out end
    for i = 1, #list do
        local a = list[i]
        if type(a.text) == "string" and a.text ~= "" and (a.pos0 or a.drawer) then
            out[#out + 1] = {
                text = a.text, note = a.note, chapter = a.chapter, datetime = a.datetime,
                page = a.page, pos0 = type(a.pos0) == "string" and a.pos0 or nil,
                file = e.file, title = e.title, authors = e.authors,
            }
        end
    end
    return out
end

function D.allHighlights(ui)
    if D.hl_cache then return D.hl_cache end
    local all = {}
    for i = 1, #(D.index or {}) do
        local e = D.index[i]
        if (e.n_highlights or 0) > 0 and #all < 1500 then
            local ok, list = pcall(D.highlightsFor, ui, e)
            if ok then
                for j = 1, #list do all[#all + 1] = list[j] end
            end
        end
    end
    table.sort(all, function(a, b) return (a.datetime or "") > (b.datetime or "") end)
    D.hl_cache = all
    return all
end

-- One highlight for the dashboard card. It is remembered and swapped for a
-- new one once settings.hl_every minutes have passed (0 = every time the
-- dashboard opens). The check happens when the dashboard is drawn, so no
-- timer runs in the background.
function D.pickHighlight(ui, settings, another)
    local now = os.time()
    local pick = settings.hl_pick
    local every = (tonumber(settings.hl_every) or 30) * 60
    if not another and type(pick) == "table" and type(pick.item) == "table"
        and type(pick.time) == "number" and every > 0
        and now >= pick.time and now - pick.time < every
        and lfs.attributes(pick.item.file or "", "mode") == "file" then
        return pick.item
    end
    local all = D.allHighlights(ui)
    if #all == 0 then
        settings.hl_pick = nil
        return nil
    end
    local item = all[math.random(#all)]
    -- Avoid showing the same quote twice in a row.
    local previous = type(pick) == "table" and type(pick.item) == "table" and pick.item.text
    if #all > 1 and previous then
        local tries = 0
        while item.text == previous and tries < 8 do
            item = all[math.random(#all)]
            tries = tries + 1
        end
    end
    settings.hl_pick = { time = now, item = item }
    return item
end

---------------------------------------------------------------------------
-- Reading statistics (read only)
---------------------------------------------------------------------------

local function openStats()
    if lfs.attributes(STATS_DB, "mode") ~= "file" then return nil end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return nil end
    local ok2, conn = pcall(SQ3.open, STATS_DB)
    if not ok2 or not conn then return nil end
    local db = { conn = conn }
    function db.row(sql)
        local ok3, a, b, c = pcall(conn.rowexec, conn, sql)
        if ok3 then return tonumber(a), tonumber(b), tonumber(c) end
    end
    function db.rows(sql)
        local ok3, res = pcall(conn.exec, conn, sql)
        if ok3 then return res end
    end
    function db.close() pcall(conn.close, conn) end
    return db
end

local function dayStart()
    local t = os.date("*t")
    return os.time{ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 }
end

local function dayNumber(ymd)
    local y, m, d = ymd:match("^(%d+)-(%d+)-(%d+)")
    if not y then return nil end
    local t = os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
    return math.floor(t / 86400 + 0.5)
end

function D.stats()
    -- Reopening the dashboard within a minute reuses the last numbers.
    if D._stats and os.time() - (D._stats_at or 0) < 60 then return D._stats end
    local db = openStats()
    if not db then return nil end
    local s = { week = {}, week_pages = 0 }
    local today0 = dayStart()
    local noon = today0 + 12 * 3600

    s.today_pages, s.today_time = db.row(string.format([[
        SELECT count(*), sum(sum_duration) FROM (
            SELECT sum(duration) AS sum_duration FROM page_stat
            WHERE start_time >= %d GROUP BY id_book, page);]], today0))
    s.today_pages, s.today_time = s.today_pages or 0, s.today_time or 0

    local per_day = {}
    local res = db.rows([[
        SELECT dates, count(*) FROM (
            SELECT date(start_time, 'unixepoch', 'localtime') AS dates FROM page_stat
            GROUP BY id_book, page, dates) GROUP BY dates ORDER BY dates DESC;]])
    local days = {}
    if res and res[1] then
        for i = 1, #res[1] do
            per_day[res[1][i]] = tonumber(res[2][i]) or 0
            days[#days + 1] = res[1][i]
        end
    end

    for i = 6, 0, -1 do
        local t = noon - i * 86400
        local pages = per_day[os.date("%Y-%m-%d", t)] or 0
        s.week[#s.week + 1] = { label = os.date("%a", t), pages = pages, today = (i == 0) }
        s.week_pages = s.week_pages + pages
    end

    -- Current streak: consecutive days ending today (or yesterday).
    s.streak = 0
    local offset = per_day[os.date("%Y-%m-%d", noon)] and 0 or 1
    while per_day[os.date("%Y-%m-%d", noon - (offset + s.streak) * 86400)] do
        s.streak = s.streak + 1
    end

    -- Best streak and best day over everything recorded.
    s.best_streak, s.best_day = 0, 0
    local run, prev = 0, nil
    for i = 1, #days do
        local n = dayNumber(days[i])
        if n then
            if prev and prev - n == 1 then run = run + 1 else run = 1 end
            prev = n
            if run > s.best_streak then s.best_streak = run end
        end
        local pages = per_day[days[i]] or 0
        if pages > s.best_day then s.best_day = pages end
    end

    s.total_books, s.total_time, s.total_pages = db.row(
        "SELECT count(*), sum(total_read_time), sum(total_read_pages) FROM book;")
    s.total_books, s.total_time, s.total_pages = s.total_books or 0, s.total_time or 0, s.total_pages or 0
    db.close()
    D._stats, D._stats_at = s, os.time()
    return s
end

-- Reading numbers for one book, matched by title like KOReader does.
function D.bookStats(e)
    local db = openStats()
    if not db then return nil end
    local out
    pcall(function()
        local stmt = db.conn:prepare("SELECT id, total_read_time, total_read_pages FROM book WHERE title = ? ORDER BY last_open DESC LIMIT 1;")
        local row = stmt:bind(e.title):step()
        local id = row and tonumber(row[1])
        local time, pages = row and tonumber(row[2]), row and tonumber(row[3])
        stmt:close()
        if id then
            local n_days, first, last = db.row(string.format(
                "SELECT count(DISTINCT date(start_time, 'unixepoch', 'localtime')), min(start_time), max(start_time) FROM page_stat WHERE id_book = %d;", id))
            out = { time = time or 0, pages = pages or 0, days = n_days or 0, first = first, last = last }
        end
    end)
    db.close()
    return out
end

---------------------------------------------------------------------------
-- Moon
---------------------------------------------------------------------------

local MOON_NAMES = {
    "New moon", "Waxing crescent", "First quarter", "Waxing gibbous",
    "Full moon", "Waning gibbous", "Last quarter", "Waning crescent",
}

function D.moon()
    local synodic = 29.530588853
    -- 947182440 = new moon of 6 January 2000, 18:14 UTC
    local age = ((os.time() - 947182440) / 86400) % synodic
    local phase = age / synodic
    return {
        phase = phase,
        name = MOON_NAMES[math.floor(phase * 8 + 0.5) % 8 + 1],
        lit = math.floor((1 - math.cos(2 * math.pi * phase)) / 2 * 100 + 0.5),
        to_full = math.floor(((0.5 - phase) % 1) * synodic + 0.5),
    }
end

---------------------------------------------------------------------------
-- Everything the dashboard pages need, gathered once per opening
---------------------------------------------------------------------------

local function byRecent(a, b)
    return (a.last_read or 0) > (b.last_read or 0)
end

-- light = reuse what is already in memory (used when coming back to the dashboard).
function D.dashboard(ui, settings, light)
    local books = (light and D.index) or D.getIndex(ui, settings) or {}
    local data = {
        books = books,
        reading = {}, reviews = {}, authors = {}, genres = {}, recent = {},
        counts = { reading = 0, finished = 0, hold = 0, new = 0, finished_year = 0, total = #books },
    }
    local sorted = {}
    for i = 1, #books do sorted[i] = books[i] end
    table.sort(sorted, byRecent)

    local year = os.date("%Y")
    local author_seen, genre_seen = {}, {}
    for i = 1, #sorted do
        local e = sorted[i]
        data.counts[e.state] = (data.counts[e.state] or 0) + 1
        if e.state == "reading" then data.reading[#data.reading + 1] = e end
        if e.state == "finished" and type(e.modified) == "string" and e.modified:sub(1, 4) == year then
            data.counts.finished_year = data.counts.finished_year + 1
        end
        if (e.rating or 0) > 0 or e.note then data.reviews[#data.reviews + 1] = e end
        for j = 1, #(e.author_list or {}) do
            local name = e.author_list[j]
            local a = author_seen[name]
            if a then
                a.count = a.count + 1
            else
                a = { name = name, count = 1, title = e.title, file = e.file }
                author_seen[name] = a
                data.authors[#data.authors + 1] = a
            end
        end
        for j = 1, #(e.keywords or {}) do
            local word = e.keywords[j]
            if #word <= 28 then
                local key = word:lower()
                local g = genre_seen[key]
                if g then
                    g.count = g.count + 1
                else
                    g = { name = word, count = 1 }
                    genre_seen[key] = g
                    data.genres[#data.genres + 1] = g
                end
            end
        end
    end
    table.sort(data.reviews, function(a, b) return (a.modified or "") > (b.modified or "") end)
    table.sort(data.genres, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)

    local by_added = {}
    for i = 1, #books do by_added[i] = books[i] end
    table.sort(by_added, function(a, b) return (a.added or 0) > (b.added or 0) end)
    local week_ago = os.time() - 7 * 86400
    data.added_week = 0
    for i = 1, #by_added do
        if i <= 4 then data.recent[i] = by_added[i] end
        if (by_added[i].added or 0) >= week_ago then data.added_week = data.added_week + 1 end
    end

    local ok, stats = pcall(D.stats)
    data.stats = ok and stats or nil
    data.moon = D.moon()
    local ok2, pick = pcall(D.pickHighlight, ui, settings, false)
    data.highlight = ok2 and pick or nil
    return data
end

return D
