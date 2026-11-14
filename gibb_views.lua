--[[
The full-screen pages: dashboard, book page, library, highlights, plus the
rating pop-up and the single-highlight pop-up.

Every page takes a `plugin` (see main.lua) and asks it to open other pages,
so the pages never need to know about each other.
]]

local BottomContainer = require("ui/widget/container/bottomcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local D = require("gibb_data")
local U = require("gibb_ui")
local scale = U.scale

local V = {}

---------------------------------------------------------------------------
-- Small shared pieces
---------------------------------------------------------------------------

local function editText(title, initial, on_save, multiline)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = initial or "",
        allow_newline = multiline or false,
        cursor_at_end = true,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = not multiline, callback = function()
                local text = dialog:getInputText() or ""
                UIManager:close(dialog)
                on_save(text)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end
V.editText = editText

local function starRow(rating, size, on_tap)
    local hg = HorizontalGroup:new{ align = "center" }
    for i = 1, 5 do
        local star = U.icon(i <= (rating or 0) and "star-full" or "star", size)
        local padded = U.centered(star, size + scale(6), size + scale(6))
        table.insert(hg, on_tap and U.tap(padded, function() on_tap(i) end) or padded)
    end
    return hg
end

local function message(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
end

local function stateLabel(e)
    if e.state == "finished" then
        if e.modified then return _("Finished") .. " " .. U.shortDate(e.modified) end
        return _("Finished")
    elseif e.state == "hold" then return _("On hold")
    elseif e.state == "reading" then return _("Reading")
    end
    return _("Unread")
end

---------------------------------------------------------------------------
-- Rate and review pop-up
---------------------------------------------------------------------------

local RateDialog = U.Popup:extend{
    plugin = nil, file = nil, finishing = false, on_skip = nil, on_done = nil,
}

function RateDialog:setup()
    self.e = D.entry(self.plugin.ui, self.file)
    self.rating = self.e.rating or 0
    self.note = self.e.note or ""
end

function RateDialog:build(w)
    local vg = VerticalGroup:new{ align = "center" }
    local heading = self.finishing and U.deco("♥", _("You finished it")) or _("Rate this book")
    table.insert(vg, U.heading(heading, 18, { bold = true, max_width = w }))
    local sub = self.e.title
    if self.e.authors ~= "" then sub = sub .. " · " .. self.e.authors end
    table.insert(vg, U.text(sub, 13, { color = U.GRAY, max_width = w }))
    table.insert(vg, U.vspan(10))
    table.insert(vg, starRow(self.rating, scale(40), function(i)
        self.rating = (self.rating == i) and 0 or i
        self:refresh()
    end))
    table.insert(vg, U.text(_("Tap a star to rate"), 12, { color = U.GRAY }))
    table.insert(vg, U.vspan(10))

    local box_w = w - 2 * (scale(1) + scale(8))
    local has_note = self.note ~= ""
    local review = FrameContainer:new{
        radius = scale(8), bordersize = scale(1), padding = scale(8), margin = 0, background = U.WHITE,
        U.centered(U.textbox(has_note and self.note or _("Tap here to write your review"), 14, box_w, {
            color = has_note and U.BLACK or U.GRAY,
            max_height = math.floor(self.sh * 0.25),
        }), box_w, has_note and nil or scale(70)),
    }
    table.insert(vg, U.tap(review, function()
        editText(_("Your review"), self.note, function(text)
            self.note = text
            self:refresh()
        end, true)
    end))
    table.insert(vg, U.vspan(12))

    local gap = scale(8)
    local bw = math.floor((w - gap) / 2)
    table.insert(vg, HorizontalGroup:new{
        align = "center",
        U.pill(self.finishing and _("Not now") or _("Cancel"), function() self:onClose() end, { w = bw, padv = 8 }),
        HorizontalSpan:new{ width = gap },
        U.pill(_("Save"), function() self:save() end, { w = bw, padv = 8, filled = true }),
    })
    return vg
end

function RateDialog:save()
    D.saveSummary(self.plugin.ui, self.file, {
        rating = self.rating,
        note = self.note,
        state = self.finishing and "finished" or nil,
    })
    self.saved = true
    UIManager:close(self)
    if self.on_close then self.on_close() end
    if self.on_done then self.on_done() end
end

function RateDialog:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    if not self.saved and self.on_skip then self.on_skip() end
    return true
end
V.RateDialog = RateDialog

---------------------------------------------------------------------------
-- One highlight, in full
---------------------------------------------------------------------------

local HighlightView = U.Popup:extend{ plugin = nil, item = nil }

function HighlightView:build(w)
    local item = self.item
    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, U.textbox("“" .. item.text .. "”", 15, w, { max_height = math.floor(self.sh * 0.45) }))
    table.insert(vg, U.vspan(8))
    table.insert(vg, U.Rule:new{ w = w, h = scale(1) })
    table.insert(vg, U.vspan(6))
    table.insert(vg, U.text(item.title or "", 14, { bold = true, max_width = w }))
    local meta = {}
    if item.authors and item.authors ~= "" then meta[#meta + 1] = item.authors end
    if item.chapter and item.chapter ~= "" then meta[#meta + 1] = item.chapter end
    if item.datetime then meta[#meta + 1] = U.shortDate(item.datetime) end
    table.insert(vg, U.text(table.concat(meta, " · "), 12, { color = U.GRAY, max_width = w }))
    if type(item.note) == "string" and item.note ~= "" then
        local bw = w - 2 * (scale(1) + scale(6))
        table.insert(vg, U.vspan(8))
        table.insert(vg, FrameContainer:new{
            radius = scale(8), bordersize = scale(1), padding = scale(6), margin = 0, background = U.WHITE,
            VerticalGroup:new{
                align = "left",
                U.text(_("Your note"), 11, { color = U.GRAY }),
                U.textbox(item.note, 13, bw, { max_height = scale(90) }),
            },
        })
    end
    table.insert(vg, U.vspan(12))
    local gap = scale(6)
    local bw = math.floor((w - 2 * gap) / 3)
    table.insert(vg, HorizontalGroup:new{
        align = "center",
        U.pill(_("Close"), function() self:onClose() end, { w = bw, padv = 7 }),
        HorizontalSpan:new{ width = gap },
        U.pill(_("Book page"), function()
            self:onClose()
            self.plugin:showBookPage(item.file)
        end, { w = bw, padv = 7 }),
        HorizontalSpan:new{ width = gap },
        U.pill(_("Go there"), function()
            self:onClose()
            self.plugin:openBook(item.file, item)
        end, { w = bw, padv = 7, filled = true }),
    })
    return vg
end
V.HighlightView = HighlightView

---------------------------------------------------------------------------
-- Dashboard
---------------------------------------------------------------------------

V.CARDS = {
    { id = "header",    page = 1, label = _("Greeting") },
    { id = "resume",    page = 1, label = _("Continue reading") },
    { id = "books",     page = 1, label = _("Currently reading") },
    { id = "highlight", page = 1, label = _("From your highlights") },
    { id = "moon",      page = 1, label = _("Moon phase") },
    { id = "today",     page = 1, label = _("Today and daily goal") },
    { id = "apps",      page = 1, label = _("App tiles") },
    { id = "shelf",     page = 2, label = _("Shelf summary") },
    { id = "library",   page = 2, label = _("Library") },
    { id = "authors",   page = 2, label = _("Authors on your shelf") },
    { id = "genres",    page = 2, label = _("Genres") },
    { id = "reviews",   page = 3, label = _("Your reviews") },
    { id = "week",      page = 4, label = _("This week") },
    { id = "totals",    page = 4, label = _("All time") },
    { id = "year",      page = 4, label = _("Yearly goal") },
}
V.PAGE_NAMES = { _("Home"), _("Shelf"), _("Notes"), _("Stats") }

V.APPS = {
    { id = "zlibrary",   label = _("Z-library"),  icon = "search" },
    { id = "ao3",        label = _("AO3"),        icon = "feather" },
    { id = "storefront", label = _("Storefront"), icon = "store" },
    { id = "crossword",  label = _("Crossword"),  icon = "grid" },
}

local CARD_BY_ID = {}
for i = 1, #V.CARDS do CARD_BY_ID[V.CARDS[i].id] = V.CARDS[i] end

local Dashboard = U.Page:extend{ plugin = nil }
local cards = {}

function Dashboard:setup()
    self:load(false)
end

function Dashboard:load(light)
    local settings = self.plugin.settings
    local ok, data = pcall(D.dashboard, self.plugin.ui, settings, light)
    if not ok then
        require("logger").warn("gibb: could not gather data:", data)
        data = { books = {}, reading = {}, reviews = {}, authors = {}, genres = {}, recent = {},
                 counts = { reading = 0, finished = 0, hold = 0, new = 0, finished_year = 0, total = 0 },
                 moon = D.moon(), added_week = 0 }
    end
    self.data = data
    self.plugin:save()
    self.pages = {}
    for p = 1, #V.PAGE_NAMES do
        for i = 1, #settings.order do
            local card = CARD_BY_ID[settings.order[i]]
            if card and card.page == p and settings.enabled[card.id] then
                self.pages[#self.pages + 1] = p
                break
            end
        end
    end
    if #self.pages == 0 then self.pages = { 1 } end
    if self.page > #self.pages then self.page = 1 end
end

-- Called when a page opened on top of the dashboard closes.
function Dashboard:reload()
    self:load(true)
    self:refresh()
end

function Dashboard:pageCount() return #self.pages end

function Dashboard:navLabel()
    return string.format("%s · %d/%d", V.PAGE_NAMES[self.pages[self.page]], self.page, #self.pages)
end

function Dashboard:pageName()
    return V.PAGE_NAMES[self.pages[self.page]]
end

function Dashboard:buildCards(gap)
    local settings = self.plugin.settings
    local iw = self:cardWidth()
    local page_no = self.pages[self.page]
    local vg = VerticalGroup:new{ align = "center" }
    for i = 1, #settings.order do
        local card = CARD_BY_ID[settings.order[i]]
        if card and card.page == page_no and settings.enabled[card.id] and cards[card.id] then
            local ok, widget = pcall(cards[card.id], self, iw)
            if ok and widget then
                if #vg > 0 then table.insert(vg, U.vspan(gap)) end
                table.insert(vg, widget)
            elseif not ok then
                require("logger").warn("gibb: card failed:", card.id, widget)
            end
        end
    end
    if #vg == 0 then
        table.insert(vg, U.text(_("Every card on this page is hidden."), 14, { color = U.GRAY }))
    end
    return vg
end

-- Screens differ in height, so the page is built roomy first and then
-- tightened step by step until it fits between the top edge and the footer.
local DENSITIES = {
    { gap = 9, compact = false },
    { gap = 6, compact = false },
    { gap = 6, compact = true },
    { gap = 4, compact = true },
    { gap = 2, compact = true },
}

function Dashboard:buildBody(body_h)
    if self:usePaper() then
        local ok, built = pcall(self.buildScrapbook, self, body_h)
        if ok and built then return built end
        -- Fall back to the plain cards rather than show a broken page.
        require("logger").warn("gibb: scrapbook home failed:", built)
    end
    self.density = self.density or {}
    local room = body_h - scale(20)
    local vg
    for level = self.density[self.page] or 1, #DENSITIES do
        if vg and vg.free then vg:free() end
        self.compact = DENSITIES[level].compact
        U.compact = self.compact
        local ok, built = pcall(self.buildCards, self, DENSITIES[level].gap)
        U.compact = false
        if not ok then error(built, 0) end
        vg = built
        -- Remember what fitted, so redrawing this page does not start over.
        self.density[self.page] = level
        if vg:getSize().h <= room then break end
    end
    return vg
end

function cards.header(self, iw)
    local hour = tonumber(os.date("%H"))
    local hello
    local cats = U.cats
    if hour < 5 then hello = cats and _("Night prowl") or _("Cosy night reading")
    elseif hour < 12 then hello = cats and _("Good meowning") or _("Good morning")
    elseif hour < 18 then hello = _("Good afternoon")
    else hello = _("Good evening") end
    local name = self.plugin.settings.name
    if type(name) == "string" and name ~= "" then hello = hello .. ", " .. name end
    if U.symbols and not cats then hello = hello .. " ♥" end
    local clock = G_reader_settings:isTrue("twelve_hour_clock") and os.date("%I:%M %p") or os.date("%H:%M")
    local line = os.date("%A %d %B") .. " · " .. clock
    local ok, level = pcall(function() return Device:getPowerDevice():getCapacity() end)
    if ok and level then line = line .. " · " .. level .. "%" end
    local size = self.compact and 18 or 20
    -- Your critters sit either side of the greeting: the first picture on
    -- the left, the second on the right.
    local files = U.critters and U.critterFiles() or {}
    local critter_h = scale(self.compact and 50 or 62)
    local side_w = #files > 0 and math.floor(critter_h * 0.7) or 0
    local text_w = iw - 2 * (side_w + scale(8))
    local greeting = U.text(hello, size, { bold = true, max_width = text_w - scale(34) })
    if #files > 0 then
        local words = VerticalGroup:new{
            align = "center",
            greeting,
            U.text(line, 13, { color = U.GRAY, max_width = text_w }),
        }
        local function side(path)
            if not path then return HorizontalSpan:new{ width = side_w } end
            local ok, picture = pcall(U.critter, path, critter_h, side_w)
            if not ok then return HorizontalSpan:new{ width = side_w } end
            return U.centered(picture, side_w, critter_h)
        end
        return HorizontalGroup:new{
            align = "bottom",
            side(files[2] or files[1]),
            HorizontalSpan:new{ width = scale(8) },
            U.centered(words, text_w, critter_h),
            HorizontalSpan:new{ width = scale(8) },
            side(files[2] and files[1] or nil),
        }
    end
    if cats then
        -- A little cat face sits beside the greeting.
        greeting = HorizontalGroup:new{
            align = "center",
            greeting,
            HorizontalSpan:new{ width = scale(8) },
            U.icon("cat", scale(size + 4)),
        }
    end
    return VerticalGroup:new{
        align = "center",
        greeting,
        U.text(line, 13, { color = U.GRAY, max_width = iw }),
    }
end

function cards.books(self, iw)
    local settings = self.plugin.settings
    local n = settings.max_books
    local list = self.data.reading
    if #list == 0 then
        return U.card(U.deco("✿", _("Currently reading")),
            U.text(_("No books in progress yet"), 14, { color = U.GRAY }), iw)
    end
    -- Kept small so the Home page has room for other cards.
    local gap = scale(10)
    local item_w = math.floor((iw - (n - 1) * gap) / n)
    local cover_h = math.min(math.floor(item_w * 1.45), math.floor(self.sh * (self.compact and 0.095 or 0.115)))
    local hg = HorizontalGroup:new{ align = "top" }
    for i = 1, math.min(n, #list) do
        local e = list[i]
        local vg = VerticalGroup:new{
            align = "center",
            U.centered(U.cover(e.file, item_w, cover_h), item_w, cover_h),
            U.vspan(2),
            U.text(e.title, 12, { bold = true, max_width = item_w }),
            U.vspan(2),
            U.progress(math.floor(item_w * 0.8), scale(6), e.percent),
        }
        if i > 1 then table.insert(hg, HorizontalSpan:new{ width = gap }) end
        -- Tap shows the book's page; hold opens the book.
        table.insert(hg, U.tap(U.centered(vg, item_w),
            function() self.plugin:showBookPage(e.file) end,
            function() self.plugin:openBook(e.file) end))
    end
    return U.card(U.deco("✿", _("Currently reading")), hg, iw)
end

-- The book you had open last. Tapping anywhere on the card opens it.
function cards.resume(self, iw)
    local e = self.data.reading[1]
    if not e then return nil end
    local cover_h = scale(self.compact and 48 or 58)
    local cover_w = math.floor(cover_h / 1.4)
    -- With the cat theme, a ball of yarn sits at the right of the card.
    local yarn = U.cats and not (U.critters and #U.critterFiles() > 0)
    local yarn_w = yarn and scale(30) or 0
    local text_w = iw - cover_w - scale(10) - (yarn and (yarn_w + scale(8)) or 0)
    local percent = math.floor(e.percent * 100 + 0.5) .. "%"
    local bar_w = text_w - scale(44)
    local lines = VerticalGroup:new{
        align = "left",
        U.heading(U.deco("♥", _("Continue reading")), 12, { color = U.GRAY, max_width = text_w }),
        U.text(e.title, 15, { bold = true, max_width = text_w }),
        U.vspan(3),
        HorizontalGroup:new{
            align = "center",
            U.progress(bar_w, scale(7), e.percent),
            U.hspan(8),
            U.text(percent, 12, { color = U.GRAY }),
        },
    }
    local row = HorizontalGroup:new{
        align = "center",
        U.centered(U.cover(e.file, cover_w, cover_h), cover_w, cover_h),
        U.hspan(10),
        U.splitRow(lines, nil, text_w),
    }
    if yarn then
        table.insert(row, U.hspan(8))
        table.insert(row, U.icon("yarn", yarn_w))
    end
    return U.tap(U.card(nil, row, iw), function() self.plugin:openBook(e.file) end)
end

function cards.moon(self, iw)
    local moon = self.data.moon
    local when
    if moon.to_full == 0 then when = _("full moon tonight")
    elseif moon.to_full == 1 then when = _("full moon tomorrow")
    else when = string.format(_("full moon in %d days"), moon.to_full) end
    -- One slim line: a small moon, its name, then the details.
    local r = scale(13)
    local name = U.text(_(moon.name), 13, { bold = true, max_width = math.floor(iw * 0.45) })
    local detail_w = iw - 2 * r - name:getSize().w - scale(18)
    return U.card(nil, HorizontalGroup:new{
        align = "center",
        U.Moon:new{ radius = r, phase = moon.phase },
        U.hspan(8),
        name,
        U.hspan(8),
        U.text(string.format(_("%d%% lit"), moon.lit) .. " · " .. when, 12, { color = U.GRAY, max_width = detail_w }),
    }, iw, { slim = true })
end

local function noStats(title, iw)
    return U.card(title, U.textbox(_("Turn on KOReader's Reading statistics plugin to see this."), 13, iw,
        { align = "center", color = U.GRAY }), iw)
end

function cards.today(self, iw)
    local s = self.data.stats
    local title = U.deco("★", _("Today"))
    if not s then return noStats(title, iw) end
    local goal = self.plugin.settings.goal
    local vg = VerticalGroup:new{
        align = "center",
        U.statRow({
            { s.today_pages, _("pages") },
            { U.duration(s.today_time), _("reading") },
            { s.streak, _("day streak") },
        }, iw),
        U.vspan(self.compact and 3 or 6),
        U.progress(math.floor(iw * 0.86), scale(8), s.today_pages / math.max(1, goal)),
        U.vspan(2),
    }
    local caption
    if s.today_pages >= goal then
        local cheer = U.cats and _("Purr-fect! Daily goal of %d pages reached") or _("Daily goal of %d pages reached")
        caption = U.deco("★", string.format(cheer, goal))
    else
        caption = string.format(_("%d of %d pages, your daily goal"), s.today_pages, goal)
    end
    table.insert(vg, U.heading(caption, 12, { color = U.GRAY, max_width = iw }))
    return U.card(title, vg, iw)
end

function cards.apps(self, iw)
    local settings = self.plugin.settings
    local shown = {}
    for i = 1, #V.APPS do
        if settings.apps[V.APPS[i].id] then shown[#shown + 1] = V.APPS[i] end
    end
    if #shown == 0 then return nil end
    local gap = scale(8)
    local full_w = iw + 2 * (U.BORDER + U.PAD)
    local tile_w = math.floor((full_w - (#shown - 1) * gap) / #shown)
    local inner = tile_w - 2 * (U.BORDER + scale(6))
    local hg = HorizontalGroup:new{ align = "center" }
    for i = 1, #shown do
        local app = shown[i]
        local frame = FrameContainer:new{
            radius = scale(12), bordersize = U.BORDER, padding = scale(6), margin = 0, background = U.WHITE,
            U.centered(VerticalGroup:new{
                align = "center",
                U.icon(app.icon, scale(26)),
                U.vspan(2),
                U.text(app.label, 13, { bold = true, max_width = inner }),
            }, inner),
        }
        if i > 1 then table.insert(hg, HorizontalSpan:new{ width = gap }) end
        table.insert(hg, U.tap(frame, function() self.plugin:launch(app.id) end))
    end
    return hg
end

function cards.shelf(self, iw)
    local c = self.data.counts
    return U.card(U.deco("✿", _("Your shelf")), U.statRow({
        { c.reading, _("reading") },
        { c.finished, _("finished") },
        { c.hold, _("on hold") },
        { c.finished_year, string.format(_("in %s"), os.date("%Y")) },
    }, iw), iw)
end

function cards.library(self, iw)
    local recent = self.data.recent
    local gap = scale(8)
    local n = 4
    local cw = math.floor((iw - (n - 1) * gap) / n)
    local ch = math.min(math.floor(cw * 1.4), math.floor(self.sh * 0.11))
    local vg = VerticalGroup:new{ align = "center" }
    if #recent > 0 then
        local hg = HorizontalGroup:new{ align = "center" }
        for i = 1, math.min(n, #recent) do
            local e = recent[i]
            if i > 1 then table.insert(hg, HorizontalSpan:new{ width = gap }) end
            table.insert(hg, U.tap(U.centered(U.cover(e.file, cw, ch), cw, ch),
                function() self.plugin:showBookPage(e.file) end))
        end
        table.insert(vg, hg)
        table.insert(vg, U.vspan(6))
    end
    local summary = string.format(_("%d books"), self.data.counts.total)
    if (self.data.added_week or 0) > 0 then
        summary = summary .. " · " .. string.format(_("%d added this week"), self.data.added_week)
    end
    local open = U.pill(_("Open") .. " ›", function() self.plugin:showLibrary() end, { padv = 3 })
    table.insert(vg, U.splitRow(U.text(summary, 12, { color = U.GRAY, max_width = iw - open:getSize().w - scale(8) }), open, iw))
    return U.card(U.deco("✿", _("Library")), vg, iw)
end

function cards.authors(self, iw)
    local list = self.data.authors
    local title = U.deco("♥", _("Authors on your shelf"))
    if #list == 0 then
        return U.card(title, U.text(_("No authors found yet"), 14, { color = U.GRAY }), iw)
    end
    local vg = VerticalGroup:new{ align = "left" }
    for i = 1, math.min(self.plugin.settings.max_authors, #list) do
        local a = list[i]
        local right = a.count > 1 and string.format(_("%d books"), a.count) or a.title
        local row = U.splitRow(
            U.text(a.name, 14, { bold = true, max_width = math.floor(iw * 0.5) }),
            U.text(right, 12, { color = U.GRAY, max_width = math.floor(iw * 0.46) }), iw)
        if i > 1 then table.insert(vg, U.vspan(4)) end
        table.insert(vg, U.tap(row, function() self.plugin:showLibrary({ author = a.name }) end))
    end
    return U.card(title, vg, iw)
end

function cards.genres(self, iw)
    local list = self.data.genres
    local title = U.deco("★", _("Genres"))
    if #list == 0 then
        return U.card(title, U.textbox(_("Your books have no genre tags in their files."), 13, iw,
            { align = "center", color = U.GRAY }), iw)
    end
    local chips = {}
    for i = 1, math.min(8, #list) do
        local g = list[i]
        chips[#chips + 1] = U.pill(g.name .. " " .. g.count, function()
            self.plugin:showLibrary({ genre = g.name })
        end, { size = 12, padv = 2, padh = 8, border = scale(1), radius = 12, max_width = math.floor(iw * 0.6) })
    end
    return U.card(title, U.flow(chips, iw), iw)
end

function cards.highlight(self, iw)
    local item = self.data.highlight
    local title = U.deco("✿", _("From your highlights"))
    if not item then
        return U.card(title, U.text(_("No highlights yet"), 14, { color = U.GRAY }), iw)
    end
    local source = item.title or ""
    if item.authors and item.authors ~= "" then source = source .. " · " .. item.authors end
    -- A few lines only; tapping the quote shows it in full.
    local quote = U.tap(U.textbox("“" .. item.text .. "”", 14, iw, {
        align = "center", max_height = math.floor(self.sh * (self.compact and 0.06 or 0.085)),
    }), function() self.plugin:showHighlight(item) end)
    local gap = scale(8)
    return U.card(title, VerticalGroup:new{
        align = "center",
        quote,
        U.vspan(3),
        U.text(source, 12, { color = U.GRAY, max_width = iw }),
        U.vspan(5),
        HorizontalGroup:new{
            align = "center",
            U.pill(_("Another"), function()
                local ok, pick = pcall(D.pickHighlight, self.plugin.ui, self.plugin.settings, true)
                if ok and pick then
                    self.data.highlight = pick
                    self.plugin:save()
                    self:refresh()
                end
            end, { padv = 2, size = 12 }),
            HorizontalSpan:new{ width = gap },
            U.pill(_("All highlights"), function() self.plugin:showHighlights() end, { padv = 2, size = 12 }),
        },
    }, iw)
end

function cards.reviews(self, iw)
    local list = self.data.reviews
    local title = U.deco("✿", _("Your reviews"))
    if #list == 0 then
        return U.card(title, U.textbox(_("Rate a book from its page and it will show up here."), 13, iw,
            { align = "center", color = U.GRAY }), iw)
    end
    local vg = VerticalGroup:new{ align = "left" }
    for i = 1, math.min(self.plugin.settings.max_reviews, #list) do
        local e = list[i]
        local stars = U.text((e.rating or 0) > 0 and U.stars(e.rating) or _("review"), 14)
        local left_w = iw - stars:getSize().w - scale(8)
        local left = VerticalGroup:new{ align = "left", U.text(e.title, 14, { bold = true, max_width = left_w }) }
        if e.note then
            table.insert(left, U.text((e.note:gsub("%s+", " ")), 12, { color = U.GRAY, max_width = left_w }))
        end
        if i > 1 then table.insert(vg, U.vspan(6)) end
        table.insert(vg, U.tap(U.splitRow(left, stars, iw), function() self.plugin:showBookPage(e.file) end))
    end
    return U.card(title, vg, iw)
end

function cards.week(self, iw)
    local s = self.data.stats
    local title = U.deco("★", _("This week"))
    if not s then return noStats(title, iw) end
    local col_w = math.floor(iw / 7)
    local bar_h = math.floor(self.sh * 0.16)
    local top = 1
    for i = 1, #s.week do top = math.max(top, s.week[i].pages) end
    local hg = HorizontalGroup:new{ align = "bottom" }
    for i = 1, #s.week do
        local day = s.week[i]
        table.insert(hg, U.centered(VerticalGroup:new{
            align = "center",
            U.text(day.pages, 11, { color = U.GRAY }),
            U.VBar:new{ w = col_w, h = bar_h, fraction = day.pages / top, color = day.today and U.BLACK or U.GRAY },
            U.vspan(2),
            U.text(day.label, 11, { bold = day.today, color = day.today and U.BLACK or U.GRAY, max_width = col_w }),
        }, col_w))
    end
    local caption = string.format(_("%d pages this week · %d a day"), s.week_pages, math.floor(s.week_pages / 7 + 0.5))
    return U.card(title, VerticalGroup:new{
        align = "center", hg, U.vspan(4), U.text(caption, 12, { color = U.GRAY, max_width = iw }),
    }, iw)
end

function cards.totals(self, iw)
    local s = self.data.stats
    local title = U.deco("♥", _("All time"))
    if not s then return noStats(title, iw) end
    return U.card(title, VerticalGroup:new{
        align = "center",
        U.statRow({
            { s.total_pages, _("pages") },
            { U.duration(s.total_time), _("reading") },
            { s.total_books, _("books") },
        }, iw),
        U.vspan(8),
        U.statRow({
            { s.streak, _("day streak") },
            { s.best_streak, _("best streak") },
            { s.best_day, _("best day") },
        }, iw),
    }, iw)
end

function cards.year(self, iw)
    local goal = self.plugin.settings.year_goal
    local done = self.data.counts.finished_year
    return U.card(U.deco("✿", string.format(_("Finished in %s"), os.date("%Y"))), VerticalGroup:new{
        align = "center",
        U.progress(math.floor(iw * 0.9), scale(9), done / math.max(1, goal)),
        U.vspan(3),
        U.text(string.format(_("%d of %d books, your yearly goal"), done, goal), 12, { color = U.GRAY, max_width = iw }),
    }, iw)
end
---------------------------------------------------------------------------
-- Scrapbook home: squared paper, little labelled notes, your critters.
---------------------------------------------------------------------------

function Dashboard:usePaper()
    return self.plugin.settings.home_style == "scrapbook" and self.pages[self.page] == 1
end

-- A small note: a tiny grey label (and an optional widget on its right)
-- above the content. inner_w is the width inside the border.
local NOTE_PAD = scale(7)
local function note(label, content, inner_w, right)
    return FrameContainer:new{
        radius = scale(10), bordersize = U.BORDER, padding = NOTE_PAD, margin = 0, background = U.WHITE,
        VerticalGroup:new{
            align = "left",
            U.splitRow(U.text(label, 10, { color = U.GRAY, max_width = inner_w }), right, inner_w),
            U.vspan(3),
            content,
        },
    }
end

local function shortTime(secs)
    secs = tonumber(secs) or 0
    if secs >= 3600 then return math.floor(secs / 3600 + 0.5) .. "h" end
    return math.floor(secs / 60 + 0.5) .. "m"
end

function Dashboard:buildScrapbook(body_h)
    local plugin, settings, data = self.plugin, self.plugin.settings, self.data
    local s = data.stats
    local W = self.sw - 2 * U.MARGIN
    local gap = scale(8)
    local edge = U.BORDER + NOTE_PAD
    local files = U.critters and U.critterFiles() or {}
    local vg = VerticalGroup:new{ align = "center" }
    local function add(widget)
        if #vg > 0 then table.insert(vg, VerticalSpan:new{ width = gap }) end
        table.insert(vg, widget)
    end

    -- Time, date and battery
    local clock = G_reader_settings:isTrue("twelve_hour_clock") and os.date("%I:%M %p") or os.date("%H:%M")
    local left = clock .. " · " .. os.date("%d %b")
    local name = settings.name
    if type(name) == "string" and name ~= "" then left = name .. " · " .. left end
    local battery = ""
    pcall(function() battery = Device:getPowerDevice():getCapacity() .. "%" end)
    add(U.splitRow(U.heading(U.deco("♥", left), 12, { color = U.GRAY, max_width = math.floor(W * 0.8) }),
        U.text(battery, 12, { color = U.GRAY }), W))

    -- Quote of the day, with a critter stamp beside it
    local stamp_w = math.floor(W * 0.21)
    local quote_inner = W - stamp_w - gap - 2 * edge
    local item = data.highlight
    local quote
    if item then
        local source = "— " .. (item.title or "")
        if item.authors and item.authors ~= "" then source = source .. ", " .. item.authors end
        quote = VerticalGroup:new{
            align = "left",
            U.tap(U.textbox("“" .. item.text .. "”", 14, quote_inner, { max_height = math.floor(self.sh * 0.105) }),
                function() plugin:showHighlight(item) end),
            U.vspan(2),
            U.text(source, 11, { color = U.GRAY, max_width = quote_inner }),
        }
    else
        quote = U.text(_("Highlight something and it shows up here"), 12, { color = U.GRAY, max_width = quote_inner })
    end
    local another = item and U.pill(_("Another"), function()
        local ok, pick = pcall(D.pickHighlight, plugin.ui, settings, true)
        if ok and pick then
            data.highlight = pick
            plugin:save()
            self:refresh()
        end
    end, { size = 11, padv = 1, padh = 7 }) or nil
    local quote_card = note(_("QUOTE OF THE DAY"), quote, quote_inner, another)
    local stamp_h = math.max(quote_card:getSize().h, scale(70))
    local stamp_iw, stamp_ih = stamp_w - 2 * U.BORDER, stamp_h - 2 * U.BORDER
    local picture
    if files[1] then
        local ok, img = pcall(U.critter, files[1], stamp_ih - scale(6), stamp_iw - scale(6))
        if ok then picture = img end
    end
    picture = picture or U.icon("cat", math.floor(math.min(stamp_iw, stamp_ih) * 0.7))
    local stamp = FrameContainer:new{
        radius = 0, bordersize = U.BORDER, padding = 0, margin = 0, background = U.WHITE,
        U.centered(picture, stamp_iw, stamp_ih),
    }
    add(HorizontalGroup:new{ align = "top", quote_card, HorizontalSpan:new{ width = gap }, U.tap(stamp, function() plugin:showHighlights() end) })

    -- Today and this month
    if s then
        local half = math.floor((W - gap) / 2)
        local hi = half - 2 * edge
        local today = VerticalGroup:new{
            align = "left",
            U.text(string.format(_("%d pages"), s.today_pages), 15, { bold = true, max_width = hi }),
            U.text(string.format(_("%s read"), U.duration(s.today_time)), 11, { color = U.GRAY, max_width = hi }),
            U.text(string.format(_("Streak %d days"), s.streak), 11, { color = U.GRAY, max_width = hi }),
        }
        local col = math.floor(hi / 3)
        local function small(value, label)
            return U.centered(VerticalGroup:new{
                align = "center",
                U.text(value, 15, { bold = true, max_width = col }),
                U.text(label, 11, { color = U.GRAY, max_width = col }),
            }, col)
        end
        local month = HorizontalGroup:new{
            align = "top",
            small(data.month_books or 0, _("books")),
            small(shortTime(s.month_time), _("read")),
            small(s.month_pages or 0, _("pages")),
        }
        add(HorizontalGroup:new{
            align = "top",
            note(_("TODAY"), today, hi),
            HorizontalSpan:new{ width = gap },
            note(os.date("%B"):upper(), month, hi),
        })
    end

    -- Finish forecast for the book you are reading
    local e = data.reading[1]
    if e then
        local fi = W - 2 * edge
        self.forecast = self.forecast or {}
        if self.forecast[e.file] == nil then
            local ok, bs = pcall(D.bookStats, e)
            self.forecast[e.file] = (ok and bs) or false
        end
        local bs = self.forecast[e.file]
        local percent = math.floor(e.percent * 100 + 0.5) .. "%"
        local daily = s and (s.week_time or 0) / 7 or 0
        local when
        local line2 = percent
        if bs and bs.pages > 5 and e.pages and daily > 60 then
            local remaining = (1 - e.percent) * e.pages * (bs.time / bs.pages)
            when = os.time() + math.ceil(remaining / daily) * 86400
            line2 = percent .. " · " .. string.format(_("at %s a day"), U.duration(daily))
        end
        local cover_h = scale(58)
        local cover_w = math.floor(cover_h / 1.4)
        local box_w = scale(46)
        local text_w = fi - cover_w - box_w - scale(20)
        local lines = VerticalGroup:new{
            align = "left",
            U.text(e.title, 14, { bold = true, max_width = text_w }),
            U.text(line2, 11, { color = U.GRAY, max_width = text_w }),
        }
        local done = data.counts.finished_year or 0
        if done > 0 then
            local pace = math.floor(done / math.max(1, tonumber(os.date("%j"))) * 365 + 0.5)
            table.insert(lines, U.text(string.format(_("On pace for %d books this year"), pace), 11, { color = U.GRAY, max_width = text_w }))
        elseif not when then
            table.insert(lines, U.text(_("Read a little more for a forecast"), 11, { color = U.GRAY, max_width = text_w }))
        end
        local datebox = FrameContainer:new{
            radius = scale(6), bordersize = U.BORDER, padding = 0, margin = 0, background = U.WHITE,
            VerticalGroup:new{
                align = "center",
                FrameContainer:new{
                    bordersize = 0, padding = scale(1), margin = 0, background = U.BLACK,
                    U.centered(U.text(when and os.date("%b", when):upper() or "···", 10, { bold = true, color = U.WHITE }), box_w - scale(2)),
                },
                U.centered(U.text(when and tostring(tonumber(os.date("%d", when))) or "?", 18, { bold = true }), box_w),
            },
        }
        local row = HorizontalGroup:new{
            align = "center",
            U.centered(U.cover(e.file, cover_w, cover_h), cover_w, cover_h),
            U.hspan(10),
            U.splitRow(lines, datebox, fi - cover_w - scale(10)),
        }
        add(U.tap(note(_("FINISH FORECAST"), row, fi), function() plugin:openBook(e.file) end,
            function() plugin:showBookPage(e.file) end))
    end

    -- App tiles keep their place at the bottom
    local tiles
    if settings.enabled.apps then
        local ok, built = pcall(cards.apps, self, self:cardWidth())
        if ok then tiles = built end
    end

    -- Whatever height is left goes to a critter on a pile of books and the
    -- covers of what you finished this year.
    local used = vg:getSize().h + gap + (tiles and (tiles:getSize().h + gap) or 0)
    local bottom_h = math.max(scale(84), math.min(scale(210), body_h - scale(20) - used))
    local critter_w = math.floor(W * 0.36)
    local sitter
    local sitter_file = files[2] or files[1]
    if sitter_file then
        local ok, img = pcall(U.critter, sitter_file, bottom_h - scale(30), critter_w)
        if ok then sitter = img end
    end
    sitter = sitter or U.icon("cat", math.floor(math.min(critter_w, bottom_h - scale(30)) * 0.8))
    local function book(width, color)
        return FrameContainer:new{
            bordersize = math.max(1, scale(1)), padding = 0, margin = 0, background = color,
            HorizontalSpan:new{ width = width },
            -- a span has no height, so give the frame one through padding
            padding_top = scale(4), padding_bottom = scale(4),
        }
    end
    local pile = VerticalGroup:new{
        align = "center",
        sitter,
        book(math.floor(critter_w * 0.74), U.LIGHT),
        book(math.floor(critter_w * 0.9), U.WHITE),
        book(math.floor(critter_w * 0.66), U.GRAY),
    }
    local covers_inner = W - critter_w - gap - 2 * edge
    local finished = data.year_covers or {}
    local covers
    if #finished > 0 then
        local ch = math.max(scale(40), math.min(scale(84), bottom_h - scale(46)))
        local cw = math.floor(ch / 1.45)
        local cgap = scale(4)
        local n = math.max(1, math.floor((covers_inner + cgap) / (cw + cgap)))
        covers = HorizontalGroup:new{ align = "bottom" }
        for i = 1, math.min(n, #finished) do
            local f = finished[i]
            if i > 1 then table.insert(covers, HorizontalSpan:new{ width = cgap }) end
            table.insert(covers, U.tap(U.centered(U.cover(f.file, cw, ch, f.title), cw, ch),
                function() plugin:showBookPage(f.file) end))
        end
    else
        covers = U.textbox(_("Finish a book this year and its cover lands here."), 11, covers_inner, { color = U.GRAY })
    end
    local year_note = note(_("YEAR IN COVERS"), covers, covers_inner,
        U.text(string.format(_("%d finished"), #finished), 11, { color = U.GRAY }))
    add(HorizontalGroup:new{
        align = "bottom",
        U.centered(pile, critter_w),
        HorizontalSpan:new{ width = gap },
        year_note,
    })
    if tiles then add(tiles) end
    return vg
end

V.Dashboard = Dashboard

---------------------------------------------------------------------------
-- Book page
---------------------------------------------------------------------------

local BookPage = U.Page:extend{ plugin = nil, file = nil, align_top = true }

function BookPage:setup()
    self:load()
end

function BookPage:load()
    self.e = D.entry(self.plugin.ui, self.file)
    local ok, stats = pcall(D.bookStats, self.e)
    self.stats = ok and stats or nil
end

function BookPage:reload()
    self:load()
    self:refresh()
end

function BookPage:chooseStatus()
    local dialog
    local function option(label, state)
        return { {
            text = label,
            callback = function()
                UIManager:close(dialog)
                D.saveSummary(self.plugin.ui, self.file, { state = state })
                self:reload()
            end,
        } }
    end
    dialog = ButtonDialog:new{
        title = _("Book status"),
        buttons = { option(_("Reading"), "reading"), option(_("Finished"), "finished"), option(_("On hold"), "hold") },
    }
    UIManager:show(dialog)
end

function BookPage:buildBody()
    local e = self.e
    local iw = self:cardWidth()
    local full_w = iw + 2 * (U.BORDER + U.PAD)
    local vg = VerticalGroup:new{ align = "center" }

    -- Cover, title, status, stars
    local cover_w = math.floor(full_w * 0.3)
    local cover_h = math.floor(cover_w * 1.45)
    local text_w = full_w - cover_w - scale(12)
    local info = VerticalGroup:new{ align = "left" }
    table.insert(info, U.textbox(e.title, 18, text_w, { bold = true, max_height = scale(74) }))
    if e.authors ~= "" then table.insert(info, U.text(e.authors, 13, { color = U.GRAY, max_width = text_w })) end
    if e.series then table.insert(info, U.text(e.series, 12, { color = U.GRAY, max_width = text_w })) end
    table.insert(info, U.vspan(5))
    if #e.keywords > 0 then
        local chips = HorizontalGroup:new{ align = "center" }
        local used = 0
        for i = 1, math.min(3, #e.keywords) do
            local chip = U.pill(e.keywords[i], nil, { size = 11, padv = 1, padh = 7, border = scale(1), radius = 12, max_width = math.floor(text_w * 0.45) })
            local cw = chip:getSize().w + scale(4)
            if used + cw <= text_w then
                if #chips > 0 then table.insert(chips, HorizontalSpan:new{ width = scale(4) }) end
                table.insert(chips, chip)
                used = used + cw
            end
        end
        table.insert(info, chips)
        table.insert(info, U.vspan(5))
    end
    table.insert(info, U.pill(stateLabel(e), function() self:chooseStatus() end,
        { size = 12, padv = 3, filled = e.state == "finished" }))
    table.insert(info, U.vspan(4))
    table.insert(info, starRow(e.rating, scale(26), function(i)
        D.saveSummary(self.plugin.ui, self.file, { rating = (e.rating == i) and 0 or i })
        self:reload()
    end))
    table.insert(vg, HorizontalGroup:new{
        align = "top",
        U.centered(U.cover(e.file, cover_w, cover_h), cover_w, cover_h),
        U.hspan(12),
        info,
    })

    -- Progress
    if e.state ~= "finished" and e.opened then
        local parts = VerticalGroup:new{ align = "center", U.progress(iw, scale(9), e.percent), U.vspan(3) }
        local left
        if e.pages and e.pages > 0 then
            left = string.format(_("Page %d of %d"), math.max(1, math.floor(e.percent * e.pages + 0.5)), e.pages)
        else
            left = _("In progress")
        end
        table.insert(parts, U.splitRow(U.text(left, 12, { color = U.GRAY }),
            U.text(math.floor(e.percent * 100 + 0.5) .. "%", 13, { bold = true }), iw))
        local s = self.stats
        if s and s.pages > 5 and e.pages then
            local remaining = (1 - e.percent) * e.pages * (s.time / s.pages)
            table.insert(parts, U.splitRow(U.text(string.format(_("About %s left at your pace"), U.duration(remaining)), 12, { color = U.GRAY, max_width = iw }), nil, iw))
        end
        table.insert(vg, U.vspan(9))
        table.insert(vg, U.card(U.deco("✿", _("Progress")), parts, iw))
    end

    -- Review
    if e.state == "finished" or e.note or (e.rating or 0) > 0 then
        local review = U.textbox(e.note or _("Tap here to write your review"), 14, iw, {
            color = e.note and U.BLACK or U.GRAY, max_height = math.floor(self.sh * 0.2),
        })
        table.insert(vg, U.vspan(9))
        table.insert(vg, U.tap(U.card(U.deco("♥", _("Your review")), review, iw), function()
            editText(_("Your review"), e.note or "", function(text)
                D.saveSummary(self.plugin.ui, self.file, { note = text })
                self:reload()
            end, true)
        end))
    end

    -- Reading numbers
    local s = self.stats
    if s then
        local first = s.first and os.date("%Y-%m-%d", s.first)
        local second_row
        if e.state == "finished" then
            second_row = {
                { first and U.shortDate(first) or "–", _("started") },
                { e.modified and U.shortDate(e.modified) or "–", _("finished") },
                { e.n_highlights, _("highlights") },
            }
        else
            second_row = {
                { first and U.shortDate(first) or "–", _("started") },
                { s.last and U.shortDate(os.date("%Y-%m-%d", s.last)) or "–", _("last read") },
                { e.n_highlights, _("highlights") },
            }
        end
        local per_page = s.pages > 0 and (math.floor(s.time / s.pages + 0.5) .. "s") or "–"
        table.insert(vg, U.vspan(9))
        table.insert(vg, U.card(U.deco("★", _("Your reading")), VerticalGroup:new{
            align = "center",
            U.statRow({
                { U.duration(s.time), _("time read") },
                { s.days, _("days read") },
                e.state == "finished" and { s.pages, _("pages") } or { per_page, _("per page") },
            }, iw),
            U.vspan(6),
            U.statRow(second_row, iw),
        }, iw))
    end

    -- Description
    if e.description then
        table.insert(vg, U.vspan(9))
        table.insert(vg, U.card(U.deco("♥", _("About")),
            U.textbox(e.description, 13, iw, { max_height = math.floor(self.sh * 0.13) }), iw))
    end
    return vg
end

function BookPage:buildFooter()
    local gap = scale(8)
    local bw = math.floor((self.sw - 2 * U.MARGIN - 2 * gap) / 3)
    local action
    if self.e.state == "finished" then action = _("Read again")
    elseif self.e.opened then action = _("Resume")
    else action = _("Start reading") end
    return HorizontalGroup:new{
        align = "center",
        U.pill(_("Back"), function() self:onClose() end, { w = bw, padv = 7 }),
        HorizontalSpan:new{ width = gap },
        U.pill(_("Highlights"), function() self.plugin:showHighlights({ file = self.file }) end, { w = bw, padv = 7 }),
        HorizontalSpan:new{ width = gap },
        U.pill(action, function() self.plugin:openBook(self.file) end, { w = bw, padv = 7, filled = true }),
    }
end
V.BookPage = BookPage

---------------------------------------------------------------------------
-- Library
---------------------------------------------------------------------------

local Library = U.Page:extend{ plugin = nil, scope = nil, align_top = true }

local FILTERS = {
    { id = "all", label = _("All") },
    { id = "reading", label = _("Reading") },
    { id = "new", label = _("Unread") },
    { id = "finished", label = _("Finished") },
}
local SORTS = {
    { id = "recent", label = _("Recently read") },
    { id = "title", label = _("Title") },
    { id = "author", label = _("Author") },
    { id = "added", label = _("Recently added") },
}

function Library:setup()
    local settings = self.plugin.settings
    self.filter = "all"
    self.sort = settings.lib_sort or "recent"
    self.view = settings.lib_view
    if self.view ~= "grid" and self.view ~= "list" then self.view = "shelf" end
    self.grid = self.view == "grid"
    self.query = ""
    self.scope = self.scope or {}
    self.books = D.index or D.getIndex(self.plugin.ui, settings) or {}
    self:layout()
    self:apply()
end

function Library:layout()
    local usable = self.sh - scale(60) - scale(96)
    if self.view == "shelf" then
        local full_w = self.sw - 2 * U.MARGIN
        self.header_h = scale(96)
        self.gap = scale(8)
        self.cover_h = math.min(math.floor(self.sh * 0.17), scale(150))
        self.cover_w = math.floor(self.cover_h / 1.45)
        self.critter_h = math.floor(self.cover_h * 1.25)
        self.critter_w = math.floor(self.critter_h * 0.6)
        local shelf_h = self.critter_h + scale(5) + scale(12)
        self.rows = math.max(1, math.floor((usable - self.header_h - scale(8)) / shelf_h))
        local has_critters = U.critters and #U.critterFiles() > 0
        local room = full_w - (has_critters and (self.critter_w + self.gap) or 0)
        self.per_shelf = math.max(1, math.floor((room + self.gap) / (self.cover_w + self.gap)))
        self.per_page = self.rows * self.per_shelf
        return
    end
    if self.grid then
        self.cols = 3
        self.gap = scale(10)
        self.cell_w = math.floor((self.sw - 2 * U.MARGIN - (self.cols - 1) * self.gap) / self.cols)
        self.cover_h = math.floor(self.cell_w * 1.35)
        self.cell_h = self.cover_h + scale(58)
        self.rows = math.max(1, math.floor((usable + self.gap) / (self.cell_h + self.gap)))
        if self.rows * (self.cell_h + self.gap) > usable + self.gap then self.rows = math.max(1, self.rows - 1) end
        self.per_page = self.cols * self.rows
    else
        self.row_h = scale(74)
        self.per_page = math.max(1, math.floor(usable / self.row_h))
    end
end

function Library:apply()
    local q = self.query:lower()
    local list, counts = {}, { all = 0, reading = 0, new = 0, finished = 0 }
    for i = 1, #self.books do
        local e = self.books[i]
        local keep = true
        if self.scope.author then
            keep = false
            for j = 1, #(e.author_list or {}) do
                if e.author_list[j] == self.scope.author then keep = true end
            end
        end
        if keep and self.scope.genre then
            keep = false
            local want = self.scope.genre:lower()
            for j = 1, #(e.keywords or {}) do
                if e.keywords[j]:lower() == want then keep = true end
            end
        end
        if keep and q ~= "" then
            keep = (e.title or ""):lower():find(q, 1, true) ~= nil
                or (e.authors or ""):lower():find(q, 1, true) ~= nil
                or (e.series or ""):lower():find(q, 1, true) ~= nil
        end
        if keep then
            counts.all = counts.all + 1
            if counts[e.state] then counts[e.state] = counts[e.state] + 1 end
            if self.filter == "all" or self.filter == e.state then list[#list + 1] = e end
        end
    end
    local sort = self.sort
    table.sort(list, function(a, b)
        if sort == "title" then return (a.title or ""):lower() < (b.title or ""):lower() end
        if sort == "author" then
            local x, y = (a.authors or ""):lower(), (b.authors or ""):lower()
            if x ~= y then return x < y end
            return (a.title or ""):lower() < (b.title or ""):lower()
        end
        if sort == "added" then return (a.added or 0) > (b.added or 0) end
        local x, y = a.last_read or 0, b.last_read or 0
        if x ~= y then return x > y end
        return (a.title or ""):lower() < (b.title or ""):lower()
    end)
    self.list, self.counts = list, counts
    self.page = 1
end

function Library:reload()
    local page = self.page
    self:apply()
    self.page = math.min(page, self:pageCount())
    self:refresh()
end

function Library:pageCount()
    return math.max(1, math.ceil(#(self.list or {}) / (self.per_page or 9)))
end

function Library:navLabel()
    return string.format(_("Page %d of %d · %d books"), self.page, self:pageCount(), #self.list)
end

function Library:promptSearch()
    editText(_("Search your library"), self.query, function(text)
        self.query = text
        self:apply()
        self:refresh()
    end)
end

function Library:rescan(dir)
    local settings = self.plugin.settings
    if dir then
        settings.library_dirs = { dir }
        self.plugin:save()
    end
    local note = InfoMessage:new{ text = _("Scanning your library…") }
    UIManager:show(note)
    UIManager:forceRePaint()
    local ok, err = pcall(D.rebuild, self.plugin.ui, settings)
    UIManager:close(note)
    if not ok then
        message(_("The scan failed: ") .. tostring(err))
        return
    end
    self.books = D.index or {}
    self:apply()
    self:refresh()
end

function Library:showOptions()
    local dialog
    local buttons = {}
    for i = 1, #SORTS do
        local sort = SORTS[i]
        buttons[#buttons + 1] = { {
            text = (self.sort == sort.id and "✓ " or "") .. _("Sort by: ") .. sort.label,
            callback = function()
                UIManager:close(dialog)
                self.sort = sort.id
                self.plugin.settings.lib_sort = sort.id
                self.plugin:save()
                self:apply()
                self:refresh()
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Rescan library folder"),
        callback = function()
            UIManager:close(dialog)
            self:rescan()
        end,
    } }
    buttons[#buttons + 1] = { {
        text = _("Choose library folder"),
        callback = function()
            UIManager:close(dialog)
            require("ui/downloadmgr"):new{
                onConfirm = function(path) self:rescan(path) end,
            }:chooseDir()
        end,
    } }
    dialog = ButtonDialog:new{ title = _("Library options"), buttons = buttons }
    UIManager:show(dialog)
end

-- The view button names the view it will switch to.
local VIEW_NEXT = { shelf = "grid", grid = "list", list = "shelf" }
local VIEW_LABEL = { shelf = _("Shelf"), grid = _("Grid"), list = _("List") }

local function bookExtra(e, w)
    if e.state == "reading" then return U.progress(w, scale(6), e.percent) end
    if e.state == "finished" then
        if (e.rating or 0) > 0 then return U.text(U.stars(e.rating), 12) end
        return U.text(_("Finished"), 11, { color = U.GRAY })
    end
    if e.state == "hold" then return U.text(_("On hold"), 11, { color = U.GRAY }) end
    return U.text(_("New"), 11, { color = U.GRAY })
end

function Library:buildBody()
    local full_w = self.sw - 2 * U.MARGIN
    local gap = scale(6)
    local vg = VerticalGroup:new{ align = "center" }

    -- Search and options
    local opt_w, view_w = scale(70), scale(64)
    local search_w = full_w - opt_w - view_w - 2 * gap
    local search_label = self.query ~= "" and ("“" .. self.query .. "”") or _("Search title or author")
    table.insert(vg, HorizontalGroup:new{
        align = "center",
        U.pill(search_label, function() self:promptSearch() end,
            { w = search_w, padv = 6, color = self.query ~= "" and U.BLACK or U.GRAY }),
        HorizontalSpan:new{ width = gap },
        U.pill(_("Sort"), function() self:showOptions() end, { w = opt_w, padv = 6 }),
        HorizontalSpan:new{ width = gap },
        U.pill(VIEW_LABEL[VIEW_NEXT[self.view]] or _("Shelf"), function()
            self.view = VIEW_NEXT[self.view] or "shelf"
            self.grid = self.view == "grid"
            self.plugin.settings.lib_view = self.view
            self.plugin:save()
            self:layout()
            self.page = 1
            self:refresh()
        end, { w = view_w, padv = 6 }),
    })
    table.insert(vg, U.vspan(6))

    -- Filter chips, and the author or genre this view is narrowed to
    local chips = {}
    local scope = self.scope.author or self.scope.genre
    if scope then
        chips[#chips + 1] = U.pill(scope .. "  ✕", function()
            self.scope = {}
            self:apply()
            self:refresh()
        end, { size = 12, padv = 2, padh = 8, filled = true, radius = 12, max_width = math.floor(full_w * 0.4) })
    end
    for i = 1, #FILTERS do
        local f = FILTERS[i]
        chips[#chips + 1] = U.pill(f.label .. " " .. (self.counts[f.id] or 0), function()
            self.filter = f.id
            self:apply()
            self:refresh()
        end, { size = 12, padv = 2, padh = 8, border = scale(1), radius = 12, filled = self.filter == f.id })
    end
    table.insert(vg, U.flow(chips, full_w))
    table.insert(vg, U.vspan(10))

    if #self.list == 0 then
        local hint = #self.books == 0
            and _("No books found. Tap Sort, then Choose library folder.")
            or _("No books match.")
        table.insert(vg, U.textbox(hint, 14, full_w, { align = "center", color = U.GRAY }))
        return vg
    end

    if self.view == "shelf" then return self:buildShelves(vg, full_w) end

    local first = (self.page - 1) * self.per_page + 1
    local last = math.min(#self.list, first + self.per_page - 1)
    if self.grid then
        local cells = {}
        for i = first, last do
            local e = self.list[i]
            local w = self.cell_w
            local cell = VerticalGroup:new{
                align = "center",
                U.centered(U.cover(e.file, w, self.cover_h), w, self.cover_h),
                U.vspan(2),
                U.text(e.title, 13, { bold = true, max_width = w }),
                U.text(e.authors ~= "" and e.authors or " ", 11, { color = U.GRAY, max_width = w }),
                bookExtra(e, w),
            }
            local col = (i - first) % self.cols
            local box = U.tap(U.centered(cell, w, self.cell_h),
                function() self.plugin:showBookPage(e.file) end,
                function() self.plugin:openBook(e.file) end)
            if col > 0 then
                cells[#cells + 1] = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = self.gap }, box }
            else
                cells[#cells + 1] = box
            end
        end
        table.insert(vg, U.centered(U.grid(cells, self.cols, self.gap), full_w))
    else
        local cover_h = self.row_h - scale(10)
        local cover_w = math.floor(cover_h / 1.4)
        local text_w = full_w - cover_w - scale(10)
        for i = first, last do
            local e = self.list[i]
            local lines = VerticalGroup:new{
                align = "left",
                U.text(e.title, 15, { bold = true, max_width = text_w }),
                U.text(e.authors ~= "" and e.authors or " ", 12, { color = U.GRAY, max_width = text_w }),
                U.vspan(2),
                bookExtra(e, math.floor(text_w * 0.5)),
            }
            local row = HorizontalGroup:new{
                align = "center",
                U.centered(U.cover(e.file, cover_w, cover_h), cover_w, self.row_h),
                U.hspan(10),
                U.splitRow(lines, nil, text_w),
            }
            table.insert(vg, U.tap(row,
                function() self.plugin:showBookPage(e.file) end,
                function() self.plugin:openBook(e.file) end))
        end
    end
    return vg
end
-- Bookshelf view: the book in progress on top, then covers standing on
-- shelves, with a critter sitting at the end of the first shelves.
function Library:buildShelves(vg, full_w)
    local plugin = self.plugin
    local current
    for i = 1, #self.books do
        local e = self.books[i]
        if e.state == "reading" and (not current or (e.last_read or 0) > (current.last_read or 0)) then current = e end
    end
    if current then
        local ch = self.header_h - scale(8)
        local cw = math.floor(ch / 1.45)
        local tw = full_w - cw - scale(10)
        local lines = VerticalGroup:new{
            align = "left",
            U.text(current.title, 16, { bold = true, max_width = tw }),
            U.text(current.authors ~= "" and current.authors or " ", 12, { color = U.GRAY, max_width = tw }),
        }
        if current.description then
            table.insert(lines, U.textbox(current.description, 11, tw, { color = U.GRAY, max_height = scale(30) }))
        end
        table.insert(lines, U.vspan(3))
        local percent = U.text(math.floor(current.percent * 100 + 0.5) .. "%", 11, { color = U.GRAY })
        table.insert(lines, HorizontalGroup:new{
            align = "center",
            percent,
            U.hspan(6),
            U.progress(tw - percent:getSize().w - scale(8), scale(6), current.percent),
        })
        local head = HorizontalGroup:new{
            align = "center",
            U.centered(U.cover(current.file, cw, ch, current.title), cw, ch),
            U.hspan(10),
            U.splitRow(lines, nil, tw),
        }
        table.insert(vg, 1, U.tap(head, function() plugin:openBook(current.file) end,
            function() plugin:showBookPage(current.file) end))
        table.insert(vg, 2, U.vspan(8))
    end

    local files = U.critters and U.critterFiles() or {}
    local index = (self.page - 1) * self.per_page + 1
    for shelf = 1, self.rows do
        if index > #self.list then break end
        local row = HorizontalGroup:new{ align = "bottom" }
        local critter
        if files[shelf] then
            local ok, img = pcall(U.critter, files[shelf], self.critter_h, self.critter_w)
            if ok then critter = img end
        end
        -- The first critter sits on the left, the next on the right, and so on.
        if critter and shelf % 2 == 1 then
            table.insert(row, critter)
            table.insert(row, HorizontalSpan:new{ width = self.gap })
        end
        local placed = 0
        while placed < self.per_shelf and index <= #self.list do
            local e = self.list[index]
            if placed > 0 then table.insert(row, HorizontalSpan:new{ width = self.gap }) end
            table.insert(row, U.tap(U.centered(U.cover(e.file, self.cover_w, self.cover_h, e.title), self.cover_w, self.cover_h),
                function() plugin:showBookPage(e.file) end,
                function() plugin:openBook(e.file) end))
            placed = placed + 1
            index = index + 1
        end
        local row_w = row:getSize().w
        if critter and shelf % 2 == 0 then
            local free = full_w - row_w - critter:getSize().w
            table.insert(row, HorizontalSpan:new{ width = math.max(self.gap, free) })
            table.insert(row, critter)
        end
        table.insert(vg, BottomContainer:new{
            dimen = Geom:new{ w = full_w, h = self.critter_h },
            LeftContainer:new{ dimen = Geom:new{ w = full_w, h = row:getSize().h }, row },
        })
        table.insert(vg, U.Rule:new{ w = full_w, h = scale(5) })
        table.insert(vg, U.vspan(12))
    end
    return vg
end

V.Library = Library

---------------------------------------------------------------------------
-- All highlights
---------------------------------------------------------------------------

local Highlights = U.Page:extend{ plugin = nil, file = nil, align_top = true }

function Highlights:setup()
    local ui = self.plugin.ui
    if not D.index then D.getIndex(ui, self.plugin.settings) end
    self.this_file = self.file or (ui.document and ui.document.file)
    self.filter = self.file and "book" or "all"
    self:apply()
end

function Highlights:makeCard(h, iw)
    local meta = { h.title }
    if h.chapter and h.chapter ~= "" then meta[#meta + 1] = h.chapter end
    if h.datetime then meta[#meta + 1] = U.shortDate(h.datetime) end
    local inner = VerticalGroup:new{
        align = "left",
        U.textbox("“" .. h.text .. "”", 14, iw, { max_height = scale(88) }),
        U.vspan(3),
        U.text(table.concat(meta, " · "), 11, { color = U.GRAY, max_width = iw }),
    }
    if type(h.note) == "string" and h.note ~= "" then
        table.insert(inner, U.text(_("Note: ") .. (h.note:gsub("%s+", " ")), 12, { max_width = iw }))
    end
    return U.tap(U.card(nil, inner, iw, { slim = true }), function() self.plugin:showHighlight(h) end)
end

-- Highlights differ a lot in length, so a page is not a fixed number of
-- them: cards are added until the screen is full. page_starts remembers
-- where each page begins, filled in as you page forward.
function Highlights:layoutPage()
    local iw = self:cardWidth()
    local gap = scale(8)
    local budget = self.sh - scale(152)
    local i = self.page_starts[self.page] or 1
    local widgets, used = {}, 0
    while i <= #self.list do
        local card = self:makeCard(self.list[i], iw)
        local h = card:getSize().h + (#widgets > 0 and gap or 0)
        if #widgets > 0 and used + h > budget then
            card:free()
            break
        end
        widgets[#widgets + 1] = card
        used = used + h
        i = i + 1
    end
    self.page_widgets = widgets
    if i <= #self.list then
        self.page_starts[self.page + 1] = i
    else
        self.last_page = self.page
    end
end

function Highlights:refresh()
    local ok, err = pcall(self.layoutPage, self)
    if not ok then
        require("logger").warn("gibb: highlights layout failed:", err)
        self.page_widgets = {}
    end
    U.Page.refresh(self)
end

function Highlights:apply()
    local all = D.allHighlights(self.plugin.ui)
    local list = {}
    for i = 1, #all do
        local h = all[i]
        if self.filter == "all"
            or (self.filter == "book" and h.file == self.this_file)
            or (self.filter == "notes" and type(h.note) == "string" and h.note ~= "") then
            list[#list + 1] = h
        end
    end
    self.list = list
    self.page = 1
    self.page_starts = { 1 }
    self.last_page = nil
end

-- The true total is only known once the last page has been reached; until
-- then this is "the pages seen so far, plus one more".
function Highlights:pageCount()
    return self.last_page or math.max(1, #(self.page_starts or {}))
end

function Highlights:navLabel()
    if self.last_page then
        return string.format(_("Page %d of %d · %d highlights"), self.page, self.last_page, #self.list)
    end
    return string.format(_("Page %d · %d highlights"), self.page, #self.list)
end

function Highlights:buildBody()
    local iw = self:cardWidth()
    local full_w = iw + 2 * (U.BORDER + U.PAD)
    local vg = VerticalGroup:new{ align = "center" }
    table.insert(vg, U.heading(U.deco("✿", _("Highlights")), 17, { bold = true }))
    table.insert(vg, U.vspan(6))
    local chips = {}
    local function chip(id, label)
        chips[#chips + 1] = U.pill(label, function()
            self.filter = id
            self:apply()
            self:refresh()
        end, { size = 12, padv = 2, padh = 8, border = scale(1), radius = 12, filled = self.filter == id })
    end
    chip("all", _("All books"))
    if self.this_file then chip("book", _("This book")) end
    chip("notes", _("With notes"))
    table.insert(vg, U.flow(chips, full_w))
    table.insert(vg, U.vspan(10))

    if #self.list == 0 then
        table.insert(vg, U.text(_("No highlights here yet"), 14, { color = U.GRAY }))
        return vg
    end
    for i = 1, #(self.page_widgets or {}) do
        if i > 1 then table.insert(vg, U.vspan(8)) end
        table.insert(vg, self.page_widgets[i])
    end
    return vg
end
V.Highlights = Highlights

return V
