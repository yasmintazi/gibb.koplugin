--[[
The parts that live inside (or on top of) a book:
  * reader menu      - tap the bottom of the page
  * quick panel      - swipe down from the top (also works in the file browser)
  * header / footer  - small stats in the page margins
  * auto-highlight   - long selections are saved straight away
  * finish prompt    - rate and review at the end of a book

All hooks are put on this one reader window, not on KOReader's classes, so
they vanish when the book closes or the plugin is turned off.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Event = require("ui/event")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local ReadHistory = require("readhistory")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local D = require("gibb_data")
local U = require("gibb_ui")
local scale = U.scale

local R = {}

local function notify(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
end

-- Live numbers about the open book. Every lookup is guarded: a missing
-- piece just leaves that field empty.
function R.bookState(ui)
    local s = {}
    pcall(function() s.page = ui:getCurrentPage() end)
    pcall(function() s.pages = ui.document:getPageCount() end)
    if s.page and s.pages and s.pages > 0 then s.percent = s.page / s.pages end
    pcall(function() s.chapter = ui.toc:getTocTitleByPage(s.page) end)
    pcall(function() s.chapter_left = tonumber(ui.toc:getChapterPagesLeft(s.page)) end)
    pcall(function() s.avg = tonumber(ui.statistics.avg_time) end)
    if s.avg and s.avg > 0 then
        if s.page and s.pages then s.book_time = (s.pages - s.page) * s.avg end
        if s.chapter_left then s.chapter_time = s.chapter_left * s.avg end
    end
    pcall(function()
        local props = ui.doc_props or {}
        s.title = props.display_title or props.title
        s.authors = props.authors and props.authors:gsub("\n", ", ")
    end)
    return s
end

---------------------------------------------------------------------------
-- Reader menu (bottom sheet)
---------------------------------------------------------------------------

local ReaderMenu = U.Popup:extend{ plugin = nil, align = "bottom", width_ratio = 1 }

function ReaderMenu:setup()
    local ui = self.plugin.ui
    self.state = R.bookState(ui)
    self.others = {}
    local hist = ReadHistory.hist or {}
    local current = ui.document and ui.document.file
    for i = 1, math.min(#hist, 8) do
        local item = hist[i]
        if #self.others < 2 and item.file and not item.dim and item.file ~= current then
            local ok, e = pcall(D.readBook, ui, item.file)
            if ok and e and e.state == "reading" then self.others[#self.others + 1] = e end
        end
    end
end

function ReaderMenu:run(action)
    self:onClose()
    local ok, err = pcall(action)
    if not ok then logger.warn("gibb: reader menu action failed:", err) end
end

function ReaderMenu:build(w)
    local plugin, ui, s = self.plugin, self.plugin.ui, self.state
    local file = ui.document.file
    local vg = VerticalGroup:new{ align = "center" }

    -- This book
    local cover_h = scale(62)
    local cover_w = math.floor(cover_h / 1.4)
    local text_w = w - cover_w - scale(10)
    local lines = VerticalGroup:new{ align = "left" }
    table.insert(lines, U.text(s.title or "", 15, { bold = true, max_width = text_w }))
    local sub = {}
    if s.authors and s.authors ~= "" then sub[#sub + 1] = s.authors end
    if s.chapter and s.chapter ~= "" then sub[#sub + 1] = s.chapter end
    table.insert(lines, U.text(table.concat(sub, " · "), 12, { color = U.GRAY, max_width = text_w }))
    table.insert(lines, U.vspan(3))
    table.insert(lines, U.progress(text_w, scale(7), s.percent or 0))
    local status = math.floor((s.percent or 0) * 100 + 0.5) .. "%"
    if s.book_time then status = status .. " · " .. string.format(_("%s left in book"), U.duration(s.book_time)) end
    table.insert(lines, U.text(status, 12, { color = U.GRAY, max_width = text_w }))
    table.insert(vg, U.tap(HorizontalGroup:new{
        align = "center",
        U.centered(U.cover(file, cover_w, cover_h), cover_w, cover_h),
        U.hspan(10),
        lines,
    }, function() self:run(function() plugin:showBookPage(file) end) end))
    table.insert(vg, U.vspan(8))
    table.insert(vg, U.Rule:new{ w = w, h = scale(1) })
    table.insert(vg, U.vspan(8))

    -- Shortcuts
    local tiles = {
        { "list", _("Contents"), function() ui.toc:onShowToc() end },
        { "bookmark", _("Bookmarks"), function() ui.bookmark:onShowBookmark() end },
        { "highlight", _("Highlights"), function() plugin:showHighlights({ file = file }) end },
        { "search", _("Search"), function() ui.search:onShowFulltextSearchInput() end },
        { "text", _("Text style"), function()
            -- The flag lets KOReader's own settings strip through our hook.
            plugin.native_config = true
            local ok, err = pcall(ui.config.onShowConfigMenu, ui.config)
            plugin.native_config = false
            if not ok then error(err, 0) end
        end },
        { "margins", _("Margins"), function() plugin:showMarginsSettings() end },
        { "star", _("Book page"), function() plugin:showBookPage(file) end },
        { "books", _("Library"), function() plugin:showLibrary() end },
    }
    local col_w = math.floor(w / 4)
    local cells = {}
    for i = 1, #tiles do
        local t = tiles[i]
        cells[i] = U.iconTile{
            icon = t[1], label = t[2], plain = true, size = scale(30), w = col_w,
            callback = function() self:run(t[3]) end,
        }
    end
    table.insert(vg, U.grid(cells, 4, scale(10)))

    -- Other books in progress
    if #self.others > 0 then
        table.insert(vg, U.vspan(8))
        table.insert(vg, U.Rule:new{ w = w, h = scale(1) })
        table.insert(vg, U.vspan(6))
        table.insert(vg, U.splitRow(U.text(_("Also reading"), 12, { color = U.GRAY }), nil, w))
        table.insert(vg, U.vspan(4))
        local gap = scale(8)
        local bw = math.floor((w - (#self.others - 1) * gap) / #self.others)
        local hg = HorizontalGroup:new{ align = "center" }
        for i = 1, #self.others do
            local e = self.others[i]
            if i > 1 then table.insert(hg, HorizontalSpan:new{ width = gap }) end
            table.insert(hg, U.pill(e.title .. " · " .. math.floor(e.percent * 100 + 0.5) .. "%",
                function() self:run(function() plugin:openBook(e.file) end) end, { w = bw, padv = 6 }))
        end
        table.insert(vg, hg)
    end
    return vg
end
R.ReaderMenu = ReaderMenu

---------------------------------------------------------------------------
-- Quick panel (top sheet)
---------------------------------------------------------------------------

local QuickPanel = U.Popup:extend{ plugin = nil, align = "top", width_ratio = 1 }

local function wifiOn()
    local ok, on = pcall(function() return require("ui/network/manager"):isWifiOn() end)
    return ok and on or false
end

-- Airplane mode: Wi-Fi off, and KOReader told not to switch it back on by
-- itself. The previous choices are remembered and put back afterwards.
function R.setAirplane(plugin, on)
    local settings = plugin.settings
    if on then
        settings.airplane_saved = {
            action = G_reader_settings:readSetting("wifi_enable_action"),
            restore = G_reader_settings:readSetting("auto_restore_wifi"),
        }
        G_reader_settings:saveSetting("wifi_enable_action", "ignore")
        G_reader_settings:saveSetting("auto_restore_wifi", false)
        settings.airplane = true
        if wifiOn() then
            pcall(function() require("ui/network/manager"):toggleWifiOff(nil, true) end)
        end
    else
        local saved = settings.airplane_saved or {}
        if saved.action ~= nil then
            G_reader_settings:saveSetting("wifi_enable_action", saved.action)
        else
            G_reader_settings:delSetting("wifi_enable_action")
        end
        if saved.restore ~= nil then
            G_reader_settings:saveSetting("auto_restore_wifi", saved.restore)
        else
            G_reader_settings:delSetting("auto_restore_wifi")
        end
        settings.airplane, settings.airplane_saved = false, nil
    end
    plugin:save()
end

function QuickPanel:slider(icon, w, value, min, max, set)
    local side = scale(40)
    local gap = scale(8)
    local icon_w = scale(24)
    local bar_w = w - icon_w - 2 * side - 3 * gap - scale(34)
    local span = math.max(1, max - min)
    local function apply(v)
        v = math.max(min, math.min(max, math.floor(v + 0.5)))
        pcall(set, v)
        self:refresh()
    end
    return HorizontalGroup:new{
        align = "center",
        U.icon(icon, icon_w),
        HorizontalSpan:new{ width = gap },
        U.pill("−", function() apply(value - 1) end, { w = side, padv = 3, size = 16 }),
        HorizontalSpan:new{ width = gap },
        U.tap(U.centered(U.progress(bar_w, scale(14), (value - min) / span), bar_w, scale(34)), function(ges, dimen)
            if ges and ges.pos and dimen and dimen.w > 0 then
                apply(min + (ges.pos.x - dimen.x) / dimen.w * span)
            end
        end),
        HorizontalSpan:new{ width = gap },
        U.pill("+", function() apply(value + 1) end, { w = side, padv = 3, size = 16 }),
        U.centered(U.text(tostring(value), 13), scale(34)),
    }
end

function QuickPanel:build(w)
    local plugin, ui = self.plugin, self.plugin.ui
    local settings = plugin.settings
    local vg = VerticalGroup:new{ align = "center" }

    local clock = G_reader_settings:isTrue("twelve_hour_clock") and os.date("%I:%M %p") or os.date("%H:%M")
    local battery = ""
    pcall(function() battery = Device:getPowerDevice():getCapacity() .. "%" end)
    table.insert(vg, U.splitRow(
        U.text(clock .. " · " .. os.date("%a %d %b"), 15, { bold = true }),
        U.text(battery, 14), w))
    table.insert(vg, U.vspan(10))

    local col_w = math.floor(w / 4)
    local cells = {}
    local function tile(icon, label, sub, on, action, keep_open)
        cells[#cells + 1] = U.iconTile{
            icon = icon, label = label, sub = sub, on = on, w = col_w, size = scale(42),
            callback = function()
                if not keep_open then self:onClose() end
                local ok, err = pcall(action)
                if not ok then logger.warn("gibb: quick panel action failed:", err) end
                if keep_open then self:refresh() end
            end,
        }
    end

    local has_wifi = Device:hasWifiToggle()
    local wifi = has_wifi and wifiOn()
    local airplane = settings.airplane == true
    if has_wifi then
        tile("wifi", _("Wi-Fi"), airplane and _("Held off") or (wifi and _("On") or _("Off")), wifi, function()
            if settings.airplane then
                notify(_("Turn off airplane mode first."))
                return
            end
            local NetworkMgr = require("ui/network/manager")
            local function again() if not self.closed then self:refresh() end end
            if NetworkMgr:isWifiOn() then
                NetworkMgr:toggleWifiOff(again, true)
            else
                NetworkMgr:toggleWifiOn(again, false, true)
            end
        end, true)
        tile("plane", _("Airplane"), airplane and _("On") or _("Off"), airplane, function()
            R.setAirplane(plugin, not settings.airplane)
        end, true)
    end
    local night = G_reader_settings:isTrue("night_mode")
    tile("moon", _("Night"), night and _("On") or _("Off"), night, function()
        ui:handleEvent(Event:new("ToggleNightMode"))
    end)
    tile("rotate", _("Rotate"), _("Screen"), nil, function()
        ui:handleEvent(Event:new("IterateRotation"))
    end)
    tile("refresh", _("Refresh"), _("Screen"), nil, function()
        UIManager:setDirty("all", "full")
    end)
    tile("search", _("Search"), _("Books"), nil, function() plugin:showLibrary({ search = true }) end)
    tile("home", _("Home"), _("Dashboard"), nil, function() plugin:showDashboard() end)
    tile("menu", _("More"), _("Full menu"), nil, function() ui.menu:onShowMenu() end)
    table.insert(vg, U.grid(cells, 4, scale(10)))

    -- Light and warmth
    if Device:hasFrontlight() then
        local power = Device:getPowerDevice()
        table.insert(vg, U.vspan(10))
        table.insert(vg, U.Rule:new{ w = w, h = scale(1) })
        table.insert(vg, U.vspan(8))
        local ok, slider = pcall(function()
            return self:slider("sun", w, power:frontlightIntensity(), power.fl_min, power.fl_max,
                function(v) power:setIntensity(v) end)
        end)
        if ok and slider then table.insert(vg, slider) end
        if Device:hasNaturalLight() then
            local ok2, warm = pcall(function()
                return self:slider("flame", w, power:toNativeWarmth(power:frontlightWarmth()),
                    power.fl_warmth_min, power.fl_warmth_max,
                    function(v) power:setWarmth(power:fromNativeWarmth(v)) end)
            end)
            if ok2 and warm then
                table.insert(vg, U.vspan(6))
                table.insert(vg, warm)
            end
        end
    end

    table.insert(vg, U.vspan(10))
    table.insert(vg, U.Rule:new{ w = w, h = scale(1) })
    table.insert(vg, U.vspan(8))
    local gap = scale(8)
    local bw = math.floor((w - 2 * gap) / 3)
    local function send(name)
        self:onClose()
        UIManager:broadcastEvent(Event:new(name))
    end
    table.insert(vg, HorizontalGroup:new{
        align = "center",
        U.pill(_("Sleep"), function() send("RequestSuspend") end, { w = bw, padv = 6 }),
        HorizontalSpan:new{ width = gap },
        U.pill(_("Restart"), function()
            UIManager:show(ConfirmBox:new{
                text = _("Restart KOReader?"),
                ok_text = _("Restart"),
                ok_callback = function() send("Restart") end,
            })
        end, { w = bw, padv = 6 }),
        HorizontalSpan:new{ width = gap },
        U.pill(_("Exit"), function() send("Exit") end, { w = bw, padv = 6 }),
    })
    return vg
end

function QuickPanel:onCloseWidget()
    self.closed = true
    U.Popup.onCloseWidget(self)
end
R.QuickPanel = QuickPanel

---------------------------------------------------------------------------
-- Header and footer in the page margins
---------------------------------------------------------------------------

R.SLOT_ITEMS = {
    { id = "progress", label = _("Progress") },
    { id = "page", label = _("Page") },
    { id = "chapter_left", label = _("Pages left in chapter") },
    { id = "chapter_time", label = _("Chapter time") },
    { id = "book_time", label = _("Book time") },
    { id = "chapter", label = _("Chapter name") },
    { id = "title", label = _("Book title") },
    { id = "author", label = _("Author") },
    { id = "clock", label = _("Clock") },
    { id = "battery", label = _("Battery") },
    { id = "wifi", label = _("Wi-Fi") },
    { id = "none", label = _("Nothing") },
}
local SLOT_LABEL = {}
for i = 1, #R.SLOT_ITEMS do SLOT_LABEL[R.SLOT_ITEMS[i].id] = R.SLOT_ITEMS[i].label end

local function slotText(id, s)
    if id == "progress" then return s.percent and (math.floor(s.percent * 100 + 0.5) .. "%") end
    if id == "page" then return s.page and s.pages and (s.page .. " / " .. s.pages) end
    if id == "chapter_left" then return s.chapter_left and string.format(_("%d left in chapter"), s.chapter_left) end
    if id == "chapter_time" then return s.chapter_time and string.format(_("%s left in chapter"), U.duration(s.chapter_time)) end
    if id == "book_time" then return s.book_time and string.format(_("%s left"), U.duration(s.book_time)) end
    if id == "chapter" then return s.chapter end
    if id == "title" then return s.title end
    if id == "author" then return s.authors end
    if id == "clock" then
        return G_reader_settings:isTrue("twelve_hour_clock") and os.date("%I:%M %p") or os.date("%H:%M")
    end
    if id == "battery" then
        local ok, level = pcall(function() return Device:getPowerDevice():getCapacity() end)
        return ok and level and (level .. "%") or nil
    end
    if id == "wifi" then return wifiOn() and _("Wi-Fi on") or _("Wi-Fi off") end
    return nil
end

local SIZES = { small = 10, medium = 12, large = 14 }

-- The object KOReader calls after it has drawn each page.
function R.makeMargins(plugin)
    local module = { ticks = nil, ticks_for = nil }

    local function drawLine(bb, slots, s, y, size, sw)
        local side = scale(12)
        local third = math.floor((sw - 2 * side) / 3)
        local height = 0
        for i = 1, 3 do
            local text = slotText(slots[i], s)
            if text and text ~= "" then
                local widget = TextWidget:new{
                    text = text, face = U.face(size), fgcolor = U.GRAY,
                    max_width = (i == 2) and third or math.floor(third * 1.4),
                }
                local tw = widget:getSize()
                local x
                if i == 1 then x = side
                elseif i == 2 then x = math.floor((sw - tw.w) / 2)
                else x = sw - side - tw.w end
                widget:paintTo(bb, x, y)
                height = math.max(height, tw.h)
                widget:free()
            end
        end
        return height
    end

    function module:paintTo(bb, x, y)
        local m = plugin.settings.margins
        if not m or not (m.header or m.footer) then return end
        local ok, err = pcall(function()
            local ui = plugin.ui
            local s = R.bookState(ui)
            local sw, sh = Screen:getWidth(), Screen:getHeight()
            local size = SIZES[m.size] or SIZES.small
            if m.header then drawLine(bb, m.top, s, scale(3), size, sw) end
            if m.footer then
                local bottom = sh
                pcall(function()
                    if ui.view.footer_visible and ui.view.footer then
                        bottom = sh - ui.view.footer:getHeight()
                    end
                end)
                local text_h = U.face(size).size and math.floor(U.face(size).size * 1.4) or scale(14)
                local text_y = bottom - text_h - scale(3)
                drawLine(bb, m.bottom, s, text_y, size, sw)
                if m.line ~= "none" and s.percent then
                    local side = scale(12)
                    local line_w = sw - 2 * side
                    local line_y = text_y - scale(5)
                    local thick = scale(2)
                    bb:paintRect(side, line_y, line_w, thick, U.LIGHT)
                    bb:paintRect(side, line_y, math.floor(line_w * s.percent), thick, U.BLACK)
                    if m.line == "chapters" and s.pages and s.pages > 0 then
                        local file = ui.document.file
                        if self.ticks_for ~= file then
                            self.ticks_for, self.ticks = file, {}
                            pcall(function() self.ticks = ui.toc:getTocTicksFlattened() or {} end)
                        end
                        if #self.ticks <= 60 then
                            for i = 1, #self.ticks do
                                local tx = side + math.floor(line_w * (self.ticks[i] - 1) / s.pages)
                                bb:paintRect(tx, line_y - scale(2), math.max(1, scale(1)), thick + scale(4), U.BLACK)
                            end
                        end
                    end
                end
            end
        end)
        if not ok and not self.warned then
            self.warned = true
            logger.warn("gibb: margins failed:", err)
        end
    end

    return module
end

local MarginsSettings = U.Popup:extend{ plugin = nil }

function MarginsSettings:changed()
    self.plugin:save()
    self:refresh()
end

function MarginsSettings:chooseSlot(list, index)
    local dialog
    local buttons = {}
    local row
    for i = 1, #R.SLOT_ITEMS do
        local item = R.SLOT_ITEMS[i]
        if (i - 1) % 2 == 0 then
            row = {}
            buttons[#buttons + 1] = row
        end
        row[#row + 1] = {
            text = (list[index] == item.id and "✓ " or "") .. item.label,
            callback = function()
                UIManager:close(dialog)
                list[index] = item.id
                self:changed()
            end,
        }
    end
    dialog = ButtonDialog:new{ title = _("Show in this slot"), buttons = buttons }
    UIManager:show(dialog)
end

function MarginsSettings:build(w)
    local m = self.plugin.settings.margins
    local vg = VerticalGroup:new{ align = "center" }
    table.insert(vg, U.text(U.deco("✿", _("Header and footer")), 17, { bold = true }))
    table.insert(vg, U.vspan(8))

    local function row(label, value, action)
        local line = U.splitRow(U.text(label, 14, { max_width = math.floor(w * 0.6) }),
            U.text(value, 14, { bold = true, max_width = math.floor(w * 0.38) }), w)
        table.insert(vg, U.tap(U.centered(line, w, line:getSize().h + scale(10)), action))
        table.insert(vg, U.Rule:new{ w = w, h = scale(1), color = U.LIGHT })
    end
    local function onOff(v) return v and _("On") or _("Off") end
    row(_("Show header"), onOff(m.header), function() m.header = not m.header; self:changed() end)
    row(_("Show footer"), onOff(m.footer), function() m.footer = not m.footer; self:changed() end)
    local size_names = { small = _("Small"), medium = _("Medium"), large = _("Large") }
    local size_next = { small = "medium", medium = "large", large = "small" }
    row(_("Text size"), size_names[m.size] or m.size, function() m.size = size_next[m.size] or "small"; self:changed() end)
    local line_names = { chapters = _("With chapter marks"), plain = _("Plain"), none = _("Off") }
    local line_next = { chapters = "plain", plain = "none", none = "chapters" }
    row(_("Progress line"), line_names[m.line] or m.line, function() m.line = line_next[m.line] or "chapters"; self:changed() end)

    local gap = scale(6)
    local bw = math.floor((w - 2 * gap) / 3)
    local function slots(title, list)
        table.insert(vg, U.vspan(10))
        table.insert(vg, U.text(title, 13, { color = U.GRAY }))
        table.insert(vg, U.vspan(4))
        local hg = HorizontalGroup:new{ align = "center" }
        for i = 1, 3 do
            if i > 1 then table.insert(hg, HorizontalSpan:new{ width = gap }) end
            table.insert(hg, U.pill(SLOT_LABEL[list[i]] or _("Nothing"), function() self:chooseSlot(list, i) end,
                { w = bw, padv = 6, size = 12 }))
        end
        table.insert(vg, hg)
    end
    slots(_("Header: left, middle, right"), m.top)
    slots(_("Footer: left, middle, right"), m.bottom)
    table.insert(vg, U.vspan(12))
    table.insert(vg, U.pill(_("Done"), function() self:onClose() end, { w = math.floor(w * 0.5), padv = 7, filled = true }))
    return vg
end

function MarginsSettings:onCloseWidget()
    UIManager:setDirty("all", "ui")
end
R.MarginsSettings = MarginsSettings

---------------------------------------------------------------------------
-- Auto-highlight
---------------------------------------------------------------------------

local HighlightBar = U.Popup:extend{ plugin = nil, align = "bottom", width_ratio = 0.94, index = nil, text = nil }

function HighlightBar:setup()
    -- One single delayed close; nothing keeps running after it.
    self.auto_close = function() if not self.closed then self:onClose() end end
    UIManager:scheduleIn(5, self.auto_close)
end

function HighlightBar:build(w)
    local hl = self.plugin.ui.highlight
    local col_w = math.floor(w / 5)
    local function tile(icon, label, on, action)
        return U.iconTile{
            icon = icon, label = label, on = on, plain = (on == nil), w = col_w, size = scale(32),
            callback = function()
                self:onClose()
                if action then
                    local ok, err = pcall(action)
                    if not ok then logger.warn("gibb: highlight action failed:", err) end
                end
            end,
        }
    end
    return HorizontalGroup:new{
        align = "top",
        tile("check", _("Saved"), true, nil),
        tile("more", _("Style"), nil, function() self.show_menu(self.index) end),
        tile("note", _("Note"), nil, function() hl:editNote(self.index) end),
        tile("copy", _("Copy"), nil, function() Device.input.setClipboardText(self.text) end),
        tile("trash", _("Undo"), nil, function()
            hl:deleteHighlight(self.index)
            UIManager:setDirty("all", "ui")
        end),
    }
end

function HighlightBar:onCloseWidget()
    self.closed = true
    UIManager:unschedule(self.auto_close)
    U.Popup.onCloseWidget(self)
end

local function isLong(text, min_words)
    local words = 0
    for _w in text:gmatch("%S+") do words = words + 1 end
    if words >= min_words then return true end
    -- Languages written without spaces: go by length instead.
    return words <= 1 and #text >= min_words * 9
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------

function R.attach(plugin)
    local ui = plugin.ui
    if not ui or ui._gibb_hooked then return end
    ui._gibb_hooked = true

    -- Swipe down from the top: quick panel instead of the big menu.
    local menu = ui.menu
    if menu and menu.onSwipeShowMenu then
        local original = menu.onSwipeShowMenu
        menu.onSwipeShowMenu = function(m, ges, ...)
            if plugin.settings.quick_panel and ges and ges.direction == "south" then
                plugin:showQuickPanel()
                return true
            end
            return original(m, ges, ...)
        end
    end

    -- Tap at the top: the same quick panel. KOReader's full menu stays one
    -- tap away behind "More".
    if menu and menu.onTapShowMenu then
        local original_tap = menu.onTapShowMenu
        menu.onTapShowMenu = function(m, ges, ...)
            if plugin.settings.quick_panel_tap then
                plugin:showQuickPanel()
                return true
            end
            return original_tap(m, ges, ...)
        end
    end

    if not ui.document then return end

    -- Tap at the bottom: reader menu instead of the settings strip.
    -- Swiping up from the bottom still opens KOReader's own text settings.
    local config = ui.config
    local hook = config and ((config.onTapShowConfigMenu and "onTapShowConfigMenu")
        or (config.onShowConfigMenu and "onShowConfigMenu"))
    if hook then
        local original = config[hook]
        config[hook] = function(c, ...)
            if plugin.settings.reader_menu and not plugin.native_config then
                plugin:showReaderMenu()
                return true
            end
            return original(c, ...)
        end
    end

    -- Long selection: save it straight away.
    local hl = ui.highlight
    if hl and hl.onShowHighlightMenu then
        local original = hl.onShowHighlightMenu
        hl.onShowHighlightMenu = function(h, index, ...)
            local settings = plugin.settings
            local selected = h.selected_text
            if settings.auto_highlight and index == nil and selected and type(selected.text) == "string"
                and isLong(selected.text, settings.auto_words) then
                local text = selected.text
                local ok, new_index = pcall(h.saveHighlight, h, false)
                if ok and new_index then
                    pcall(h.clear, h)
                    UIManager:show(HighlightBar:new{
                        plugin = plugin, index = new_index, text = text,
                        show_menu = function(i) original(h, i) end,
                    })
                    return true
                end
            end
            return original(h, index, ...)
        end
    end

    -- End of the book: offer to rate and review.
    local status = ui.status
    if status and status.onEndOfBook then
        local original = status.onEndOfBook
        status.onEndOfBook = function(st, ...)
            local args = { ... }
            local function default() return original(st, unpack(args)) end
            if not plugin.settings.rate_on_finish then return default() end
            local file = ui.document and ui.document.file
            local summary = ui.doc_settings and ui.doc_settings:readSetting("summary")
            if not file or (type(summary) == "table" and (tonumber(summary.rating) or 0) > 0) then
                return default()
            end
            plugin:showRate(file, { finishing = true, on_skip = default })
            return true
        end
    end
end

return R
