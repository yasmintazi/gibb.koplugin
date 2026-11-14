--[[
Shared drawing helpers for the dashboard plugin: text, cards, buttons, icons,
the moon, bars, and the two base screens (full page and pop-up).
Nothing in here runs on a timer; everything is drawn once when asked.
]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local Screen = Device.screen

local U = {
    symbols = true,     -- set from settings: show the little hearts and flowers
    cats = true,        -- set from settings: paws, whiskers and fish
    critters = true,    -- set from settings: show the photo critters
    scrap = false,      -- set briefly while a scrapbook-style page is built
    compact = false,    -- set briefly by a page that is short of room
    plugin_dir = nil,   -- set by main.lua
    BLACK = Blitbuffer.COLOR_BLACK,
    WHITE = Blitbuffer.COLOR_WHITE,
    GRAY = Blitbuffer.COLOR_DARK_GRAY,
    LIGHT = Blitbuffer.COLOR_LIGHT_GRAY,
}

local function scale(n) return Screen:scaleBySize(n) end
U.scale = scale
U.BORDER = scale(2)
U.PAD = scale(9)
U.MARGIN = scale(14)

function U.face(size) return Font:getFace("cfont", size) end

-- "♥ Title" when symbols are on, plain "Title" when they are off.
function U.deco(sym, text)
    if U.symbols or U.cats then return sym .. " " .. text end
    return text
end

-- With the cat theme on, the little symbols become drawn cat things.
local CAT_ICONS = { ["✿"] = "paw", ["♥"] = "cat", ["★"] = "fish" }

-- A line of text that may start with one of the symbols above. Use this
-- wherever U.deco() text is shown, so the cat theme can swap the symbol.
function U.heading(text, size, o)
    o = o or {}
    text = tostring(text or "")
    local sym, rest = text:match("^(%S+) (.+)$")
    local icon = sym and CAT_ICONS[sym]
    if icon and U.cats then
        local icon_size = scale(math.floor((size or 15) * 1.1))
        local opts = { bold = o.bold, color = o.color }
        if o.max_width then opts.max_width = o.max_width - icon_size - scale(5) end
        return HorizontalGroup:new{
            align = "center",
            U.icon(icon, icon_size),
            HorizontalSpan:new{ width = scale(5) },
            U.text(rest, size, opts),
        }
    end
    if icon and not U.symbols then text = rest end
    return U.text(text, size, o)
end

function U.stars(n)
    n = math.max(0, math.min(5, math.floor(tonumber(n) or 0)))
    if U.symbols then return string.rep("★", n) .. string.rep("☆", 5 - n) end
    return n .. "/5"
end

function U.duration(secs)
    secs = math.floor(tonumber(secs) or 0)
    local h, m = math.floor(secs / 3600), math.floor((secs % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm", m)
end

function U.shortDate(ymd)
    if type(ymd) ~= "string" then return "" end
    local y, m, d = ymd:match("^(%d+)-(%d+)-(%d+)")
    if not y then return ymd end
    local t = os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
    return os.date("%d %b", t):gsub("^0", "")
end

function U.vspan(n) return VerticalSpan:new{ width = scale(n) } end
function U.hspan(n) return HorizontalSpan:new{ width = scale(n) } end

function U.text(text, size, o)
    o = o or {}
    return TextWidget:new{
        text = tostring(text or ""),
        face = U.face(size or 15),
        bold = o.bold,
        fgcolor = o.color or U.BLACK,
        max_width = o.max_width,
    }
end

-- Multi-line text. o.max_height cuts it off with an ellipsis.
function U.textbox(text, size, width, o)
    o = o or {}
    local function make(height)
        return TextBoxWidget:new{
            text = tostring(text or ""),
            face = U.face(size or 15),
            width = width,
            alignment = o.align or "left",
            fgcolor = o.color or U.BLACK,
            bgcolor = o.bgcolor or U.WHITE,
            bold = o.bold,
            height = height,
            height_overflow_show_ellipsis = height and true or nil,
        }
    end
    local box = make(nil)
    if o.max_height and box:getSize().h > o.max_height then
        box:free()
        box = make(o.max_height)
    end
    return box
end

-- A widget centred in a box of a fixed width (and its own height).
function U.centered(widget, w, h)
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h or widget:getSize().h }, widget }
end

-- Rounded, outlined card with an optional centred title.
function U.card(title, content, inner_w, o)
    o = o or {}
    if U.scrap then
        -- Scrapbook look: a small grey label in the corner, like a note.
        local label = title and tostring(title) or nil
        if label then
            local sym, rest = label:match("^(%S+) (.+)$")
            if sym and CAT_ICONS[sym] then label = rest end
        end
        local note = VerticalGroup:new{ align = "left" }
        if label then
            table.insert(note, U.splitRow(U.text(label:upper(), 10, { color = U.GRAY, max_width = inner_w }), nil, inner_w))
            table.insert(note, U.vspan(3))
        end
        table.insert(note, U.centered(content, inner_w))
        local pad = (o.slim and scale(4)) or (U.compact and scale(5)) or scale(7)
        return FrameContainer:new{
            radius = scale(10), bordersize = U.BORDER, padding = U.PAD,
            padding_top = pad, padding_bottom = pad, margin = 0, background = U.WHITE,
            note,
        }
    end
    local vg = VerticalGroup:new{ align = "center" }
    if title then
        table.insert(vg, U.heading(title, U.compact and 14 or 15, { bold = true, max_width = inner_w }))
        table.insert(vg, U.vspan(U.compact and 2 or 5))
    end
    table.insert(vg, content)
    -- o.slim: less space above and below, for one-line cards.
    -- U.compact: the page is short of room, so every card tightens up.
    local pad_v = (o.slim and scale(4)) or (U.compact and scale(5)) or nil
    return FrameContainer:new{
        radius = scale(12),
        bordersize = U.BORDER,
        padding = U.PAD,
        padding_top = pad_v,
        padding_bottom = pad_v,
        margin = 0,
        background = U.WHITE,
        U.centered(vg, inner_w),
    }
end

-- Anything wrapped in this becomes tappable (and optionally holdable).
local Tappable = InputContainer:extend{ callback = nil, hold_callback = nil }
function Tappable:init()
    local sz = self[1]:getSize()
    self.dimen = Geom:new{ w = sz.w, h = sz.h }
    self.ges_events = {
        TapItem = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
    if self.hold_callback then
        self.ges_events.HoldItem = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } }
    end
end
function Tappable:onTapItem(arg, ges)
    if self.callback then self.callback(ges, self.dimen) end
    return true
end
function Tappable:onHoldItem(arg, ges)
    if self.hold_callback then self.hold_callback(ges, self.dimen) end
    return true
end
U.Tappable = Tappable

function U.tap(widget, callback, hold_callback)
    return Tappable:new{ callback = callback, hold_callback = hold_callback, widget }
end

-- Rounded text button. o.filled = black with white text, o.w = fixed outer width.
function U.pill(text, callback, o)
    o = o or {}
    local border = o.border or U.BORDER
    local padh, padv = scale(o.padh or 10), scale(o.padv or 5)
    local label = U.text(text, o.size or 14, {
        bold = o.bold or o.filled,
        color = o.filled and U.WHITE or (o.color or U.BLACK),
        max_width = o.w and (o.w - 2 * border - 2 * scale(4)) or o.max_width,
    })
    local lsz = label:getSize()
    local w = o.w and (o.w - 2 * border) or (lsz.w + 2 * padh)
    local frame = FrameContainer:new{
        radius = scale(o.radius or 10),
        bordersize = border,
        padding = 0,
        margin = 0,
        background = o.filled and U.BLACK or U.WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = w, h = lsz.h + 2 * padv }, label },
    }
    if not callback then return frame end
    return U.tap(frame, callback, o.hold_callback)
end

-- One of the plugin's own icons. white = the version for black backgrounds.
function U.icon(name, size, white)
    local path = U.plugin_dir and (U.plugin_dir .. "/icons/" .. name .. (white and "-w" or "") .. ".svg")
    if path and lfs.attributes(path, "mode") == "file" then
        return ImageWidget:new{ file = path, width = size, height = size, alpha = true, is_icon = true }
    end
    return U.text("?", 14, { color = white and U.WHITE or U.BLACK })
end

--[[ Icon with a label under it.
    o.on == true  -> filled black circle (a switch that is on)
    o.on == false -> empty circle (a switch that is off)
    o.on == nil   -> rounded square (does one thing)
    o.plain       -> no outline at all (used in the reader menu)
]]
function U.iconTile(o)
    local d = o.size or scale(44)
    local filled = o.on == true
    local glyph = U.icon(o.icon, math.floor(d * (o.plain and 0.8 or 0.56)), filled)
    local badge
    if o.plain then
        badge = U.centered(glyph, d, d)
    else
        badge = FrameContainer:new{
            radius = (o.on ~= nil) and math.floor((d + 2 * U.BORDER) / 2) or scale(10),
            bordersize = U.BORDER,
            padding = 0,
            margin = 0,
            background = filled and U.BLACK or U.WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = d, h = d }, glyph },
        }
    end
    local vg = VerticalGroup:new{ align = "center", badge, U.vspan(2) }
    if o.label then table.insert(vg, U.text(o.label, 13, { bold = true, max_width = o.w })) end
    if o.sub then table.insert(vg, U.text(o.sub, 11, { color = U.GRAY, max_width = o.w })) end
    local box = U.centered(vg, o.w or vg:getSize().w)
    if not o.callback then return box end
    return U.tap(box, o.callback, o.hold_callback)
end

-- Critters: your own cut-out pictures, kept as PNG files in the plugin's
-- "critters" folder. Any PNG dropped in there is picked up, in name order.
function U.critterFiles()
    if U._critters then return U._critters end
    local found = {}
    local dir = U.plugin_dir and (U.plugin_dir .. "/critters")
    if dir and lfs.attributes(dir, "mode") == "directory" then
        for name in lfs.dir(dir) do
            if name:lower():match("%.png$") then found[#found + 1] = dir .. "/" .. name end
        end
        table.sort(found)
    end
    U._critters = found
    return found
end

-- One critter, scaled to fit a box of the given height (and width).
function U.critter(path, h, w)
    return ImageWidget:new{ file = path, width = w or h, height = h, scale_factor = 0, alpha = true }
end

-- A big number with a small grey label under it.
function U.stat(value, label, w)
    local vg = VerticalGroup:new{
        align = "center",
        U.text(value, 18, { bold = true, max_width = w }),
        U.text(label, 12, { color = U.GRAY, max_width = w }),
    }
    return U.centered(vg, w)
end

-- A row of stats sharing the width equally. items = { {value, label}, ... }
function U.statRow(items, inner_w)
    local hg = HorizontalGroup:new{ align = "top" }
    local w = math.floor(inner_w / #items)
    for i = 1, #items do
        table.insert(hg, U.stat(items[i][1], items[i][2], w))
    end
    return hg
end

function U.progress(w, h, fraction)
    return ProgressWidget:new{
        width = w,
        height = h or scale(8),
        percentage = math.max(0, math.min(1, tonumber(fraction) or 0)),
        margin_h = 0,
        margin_v = 0,
        radius = scale(3),
        bordersize = scale(1),
        bgcolor = U.WHITE,
        fillcolor = U.BLACK,
        bordercolor = U.BLACK,
    }
end

-- Left-aligned and right-aligned widgets on one line of a fixed width.
function U.splitRow(left, right, w)
    local rw = right and right:getSize().w or 0
    local lw = math.max(0, w - rw)
    local h = math.max(left:getSize().h, right and right:getSize().h or 0)
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local RightContainer = require("ui/widget/container/rightcontainer")
    local hg = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = lw, h = h }, left },
    }
    if right then table.insert(hg, RightContainer:new{ dimen = Geom:new{ w = rw, h = h }, right }) end
    return hg
end

-- The moon, drawn row by row so it never depends on a font having moon glyphs.
local Moon = Widget:extend{ radius = 30, phase = 0 }
function Moon:getSize() return Geom:new{ w = self.radius * 2, h = self.radius * 2 } end
function Moon:paintTo(bb, x, y)
    local r = self.radius
    local border = math.max(1, math.floor(r / 12))
    local ri = r - border
    local cx = x + r
    local c = math.cos(2 * math.pi * self.phase)
    for i = 0, 2 * r - 1 do
        local yy = i - r + 0.5
        local hw = math.sqrt(math.max(0, r * r - yy * yy))
        bb:paintRect(math.floor(cx - hw), y + i, math.max(1, math.floor(2 * hw)), 1, U.BLACK)
        if math.abs(yy) < ri then
            local hwi = math.sqrt(ri * ri - yy * yy)
            bb:paintRect(math.floor(cx - hwi), y + i, math.max(1, math.floor(2 * hwi)), 1, U.GRAY)
            local x0, x1
            if self.phase < 0.5 then x0, x1 = hwi * c, hwi else x0, x1 = -hwi, -hwi * c end
            local lw = math.floor(x1 - x0)
            if lw >= 1 then bb:paintRect(math.floor(cx + x0), y + i, lw, 1, U.WHITE) end
        end
    end
end
U.Moon = Moon

-- A progress ring: a grey circle with a black arc that starts at the top
-- and runs clockwise, and a label (such as "39%") in the middle.
local Ring = Widget:extend{ size = 60, thickness = nil, fraction = 0, label = nil }
function Ring:getSize() return Geom:new{ w = self.size, h = self.size } end
function Ring:paintTo(bb, x, y)
    local d = self.size
    local r_out = d / 2
    local thick = self.thickness or math.max(3, math.floor(d * 0.13))
    local r_in = r_out - thick
    local frac = math.max(0, math.min(1, tonumber(self.fraction) or 0))
    local limit = frac * 2 * math.pi
    for py = 0, d - 1 do
        local dy = py + 0.5 - r_out
        -- Shades are tracked as plain numbers (0 = nothing, 1 = grey track,
        -- 2 = black arc). Comparing KOReader's colour objects with "no
        -- colour" is an error, which is what broke this before.
        local run_x, run_shade = 0, 0
        for px = 0, d - 1 do
            local dx = px + 0.5 - r_out
            local dist2 = dx * dx + dy * dy
            local shade = 0
            if dist2 <= r_out * r_out and dist2 >= r_in * r_in then
                local angle = math.atan2(dx, -dy)
                if angle < 0 then angle = angle + 2 * math.pi end
                shade = (frac > 0 and angle <= limit) and 2 or 1
            end
            -- Paint in runs of the same shade, not pixel by pixel.
            if shade ~= run_shade then
                if run_shade ~= 0 then
                    bb:paintRect(x + run_x, y + py, px - run_x, 1, run_shade == 2 and U.BLACK or U.LIGHT)
                end
                run_x, run_shade = px, shade
            end
        end
        if run_shade ~= 0 then
            bb:paintRect(x + run_x, y + py, d - run_x, 1, run_shade == 2 and U.BLACK or U.LIGHT)
        end
    end
    if self.label then
        local text = TextWidget:new{ text = self.label, face = U.face(self.label_size or 13), bold = true }
        local size = text:getSize()
        text:paintTo(bb, x + math.floor((d - size.w) / 2), y + math.floor((d - size.h) / 2))
        text:free()
    end
end
U.Ring = Ring

-- One vertical bar of the weekly chart.
local VBar = Widget:extend{ w = 20, h = 80, fraction = 0, color = nil }
function VBar:getSize() return Geom:new{ w = self.w, h = self.h } end
function VBar:paintTo(bb, x, y)
    local bw = math.floor(self.w * 0.6)
    local bh = math.max(scale(2), math.floor(self.h * math.max(0, math.min(1, self.fraction))))
    bb:paintRect(x + math.floor((self.w - bw) / 2), y + self.h - bh, bw, bh, self.color or U.GRAY)
end
U.VBar = VBar

-- A plain horizontal rule.
local Rule = Widget:extend{ w = 10, h = 1, color = nil }
function Rule:getSize() return Geom:new{ w = self.w, h = self.h } end
function Rule:paintTo(bb, x, y) bb:paintRect(x, y, self.w, self.h, self.color or U.BLACK) end
U.Rule = Rule

-- Book cover from KOReader's cover cache, or a little placeholder.
-- title (optional): shown on the placeholder when the book has no cover.
function U.cover(file, w, h, title)
    local border = scale(1)
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if ok and type(BookInfoManager) == "table" and file then
        local ok2, info = pcall(BookInfoManager.getBookInfo, BookInfoManager, file, true)
        if ok2 and info and info.has_cover and info.cover_bb and not info.ignore_cover
            and (info.cover_w or 0) > 0 and (info.cover_h or 0) > 0 then
            local factor = math.min((w - 2 * border) / info.cover_w, (h - 2 * border) / info.cover_h)
            return CenterContainer:new{
                dimen = Geom:new{ w = w, h = h },
                FrameContainer:new{
                    padding = 0, margin = 0, bordersize = border,
                    ImageWidget:new{ image = info.cover_bb, scale_factor = factor },
                },
            }
        end
    end
    return FrameContainer:new{
        radius = scale(6), bordersize = border, padding = 0, margin = 0, background = U.WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * border, h = h - 2 * border },
            (title and U.textbox(title, 10, w - 2 * border - scale(6), { align = "center", bold = true, max_height = h - 2 * border - scale(6) }))
                or (U.cats and U.icon("cat", math.floor(math.min(w, h) * 0.6)))
                or (U.symbols and U.text("♥", 22))
                or U.icon("book", math.floor(w * 0.4)),
        },
    }
end

-- Lays small widgets out left to right, wrapping onto new centred rows.
function U.flow(widgets, max_w, gap)
    gap = gap or scale(5)
    local rows = VerticalGroup:new{ align = "center" }
    local row, row_w = HorizontalGroup:new{ align = "center" }, 0
    for i = 1, #widgets do
        local ww = widgets[i]:getSize().w
        if #row > 0 and row_w + gap + ww > max_w then
            table.insert(rows, row)
            table.insert(rows, VerticalSpan:new{ width = gap })
            row, row_w = HorizontalGroup:new{ align = "center" }, 0
        end
        if #row > 0 then
            table.insert(row, HorizontalSpan:new{ width = gap })
            row_w = row_w + gap
        end
        table.insert(row, widgets[i])
        row_w = row_w + ww
    end
    if #row > 0 then table.insert(rows, row) end
    return rows
end

-- A grid of equally wide cells. cells = widgets already sized to cell width.
function U.grid(cells, columns, row_gap)
    local vg = VerticalGroup:new{ align = "left" }
    local row
    for i = 1, #cells do
        if (i - 1) % columns == 0 then
            if row then
                table.insert(vg, row)
                table.insert(vg, VerticalSpan:new{ width = row_gap or scale(8) })
            end
            row = HorizontalGroup:new{ align = "top" }
        end
        table.insert(row, cells[i])
    end
    if row then table.insert(vg, row) end
    return vg
end

-- Squared paper behind a whole page, like a notebook. Drawn once per
-- repaint as plain lines, so it costs next to nothing.
local GridPaper = WidgetContainer:extend{}
function GridPaper:getSize() return self[1]:getSize() end
function GridPaper:paintTo(bb, x, y)
    local size = self[1]:getSize()
    bb:paintRect(x, y, size.w, size.h, U.WHITE)
    local step = scale(22)
    local line = math.max(1, scale(1))
    for gx = x + step, x + size.w - 1, step do bb:paintRect(gx, y, line, size.h, U.LIGHT) end
    for gy = y + step, y + size.h - 1, step do bb:paintRect(x, gy, size.w, line, U.LIGHT) end
    self[1]:paintTo(bb, x, y)
end
U.GridPaper = GridPaper

---------------------------------------------------------------------------
-- Full-screen page. Subclasses provide buildBody(body_h) and may provide
-- setup(), pageCount(), navLabel(). self.page is the current page number.
---------------------------------------------------------------------------

-- Safety net: if drawing this screen ever fails, close it and say so,
-- instead of letting the error take KOReader down with it.
local function safePaint(self, bb, x, y)
    local ok, err = xpcall(function() return InputContainer.paintTo(self, bb, x, y) end, debug.traceback)
    if ok or self.paint_failed then return end
    self.paint_failed = true
    err = tostring(err)
    require("logger").warn("gibb: drawing failed:", err)
    -- Keep the first line (what went wrong) and the lines that say where:
    -- anything in Gibb's own files, plus the widget just above them.
    local shown, kept = {}, 0
    for line in err:gmatch("[^\n]+") do
        local where = line:match("([%w_]+%.lua:%d+)")
        if #shown == 0 then
            shown[1] = line
        elseif where and kept < 7 and not line:find("gibb_ui.lua:%d+: in function <") then
            local name = line:match("in function '([^']+)'") or line:match("in method '([^']+)'") or ""
            shown[#shown + 1] = where .. " " .. name
            kept = kept + 1
        end
    end
    UIManager:nextTick(function()
        UIManager:close(self)
        if self.on_close then pcall(self.on_close) end
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("Gibb could not draw this screen, so it was closed.") .. "\n\n" .. table.concat(shown, "\n"),
        })
        -- Let the screen offer a simpler version of itself.
        if self.on_paint_fail then pcall(self.on_paint_fail) end
    end)
end

local Page = InputContainer:extend{ page = 1, align_top = false, title = nil }
Page.paintTo = safePaint

function Page:init()
    self.sw, self.sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.sw, h = self.sh }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
    if self.setup then self:setup() end
    self:refresh()
end

-- Width available inside a full-width card.
function Page:cardWidth()
    return self.sw - 2 * U.MARGIN - 2 * (U.BORDER + U.PAD)
end

function Page:pageCount() return 1 end

function Page:buildFooter()
    local gap = scale(8)
    local side, close_w = scale(54), scale(92)
    local paged = self:pageCount() > 1
    local mid_w = self.sw - 2 * U.MARGIN - close_w - gap - (paged and 2 * (side + gap) or 0)
    local label = self.navLabel and self:navLabel() or (self.title or "")
    local hg = HorizontalGroup:new{ align = "center" }
    if paged then
        table.insert(hg, U.pill("‹", function() self:onPrevPage() end, { w = side, size = 18 }))
        table.insert(hg, HorizontalSpan:new{ width = gap })
    end
    local n = self:pageCount()
    local middle
    if U.cats and paged and n <= 6 and self.pageName then
        -- Paw prints for pages: a filled paw marks the one you are on.
        local paw = scale(15)
        middle = HorizontalGroup:new{
            align = "center",
            U.text(self:pageName(), 14, { max_width = mid_w - n * (paw + scale(4)) - scale(8) }),
            HorizontalSpan:new{ width = scale(8) },
        }
        for i = 1, n do
            if i > 1 then table.insert(middle, HorizontalSpan:new{ width = scale(4) }) end
            table.insert(middle, U.icon(i == self.page and "paw" or "paw-o", paw))
        end
    else
        middle = U.text(label, 14, { max_width = mid_w })
    end
    table.insert(hg, U.centered(middle, mid_w))
    if paged then
        table.insert(hg, HorizontalSpan:new{ width = gap })
        table.insert(hg, U.pill("›", function() self:onNextPage() end, { w = side, size = 18 }))
    end
    table.insert(hg, HorizontalSpan:new{ width = gap })
    table.insert(hg, U.pill(self.close_label or _("Close"), function() self:onClose() end, { w = close_w }))
    return hg
end

function Page:refresh()
    local footer = self:buildFooter()
    local footer_h = footer:getSize().h + scale(14)
    local body_h = self.sh - footer_h
    local ok, body = pcall(self.buildBody, self, body_h)
    if not ok then
        require("logger").warn("gibb: page failed:", body)
        body = U.textbox(_("Something went wrong drawing this page.") .. "\n" .. tostring(body), 13, self:cardWidth())
    end
    local holder
    if self.align_top then
        holder = TopContainer:new{
            dimen = Geom:new{ w = self.sw, h = body_h },
            VerticalGroup:new{ align = "center", U.vspan(10), U.centered(body, self.sw) },
        }
    else
        holder = CenterContainer:new{ dimen = Geom:new{ w = self.sw, h = body_h }, body }
    end
    -- A page may ask for squared paper behind it (usePaper()).
    local paper = self.usePaper and self:usePaper()
    local frame = FrameContainer:new{
        background = (not paper) and U.WHITE or nil, bordersize = 0, padding = 0, margin = 0,
        VerticalGroup:new{
            align = "center",
            holder,
            CenterContainer:new{ dimen = Geom:new{ w = self.sw, h = footer_h }, footer },
        },
    }
    self[1] = paper and GridPaper:new{ frame } or frame
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function Page:onNextPage()
    local n = self:pageCount()
    if n > 1 then
        self.page = self.page % n + 1
        self:refresh()
    end
    return true
end

function Page:onPrevPage()
    local n = self:pageCount()
    if n > 1 then
        self.page = (self.page - 2) % n + 1
        self:refresh()
    end
    return true
end

function Page:onSwipe(arg, ges)
    if ges.direction == "west" then return self:onNextPage() end
    if ges.direction == "east" then return self:onPrevPage() end
    -- Only a swipe that starts near the top edge pulls the quick panel down.
    if ges.direction == "south" and self.swipe_down and ges.pos and ges.pos.y < self.sh * 0.2 then
        self.swipe_down()
    end
    return true
end

function Page:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function Page:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function Page:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end
U.Page = Page

---------------------------------------------------------------------------
-- Pop-up. Subclasses provide build(inner_w). align = "center", "top" or
-- "bottom". Tapping outside closes it.
---------------------------------------------------------------------------
local Popup = InputContainer:extend{ align = "center", width_ratio = 0.9, modal_close = true }
Popup.paintTo = safePaint

function Popup:init()
    self.sw, self.sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.sw, h = self.sh }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events.TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } }
        self.ges_events.SwipeAny = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
    if self.setup then self:setup() end
    self:refresh(true)
end

function Popup:refresh(first)
    local w = math.floor(self.sw * self.width_ratio)
    local pad = scale(12)
    local inner_w = w - 2 * (U.BORDER + pad)
    local ok, content = pcall(self.build, self, inner_w)
    if not ok then
        require("logger").warn("gibb: pop-up failed:", content)
        content = U.textbox(tostring(content), 13, inner_w)
    end
    self.frame = FrameContainer:new{
        background = U.WHITE, radius = scale(14), bordersize = U.BORDER, padding = pad, margin = 0,
        U.centered(content, inner_w),
    }
    local fh = self.frame:getSize().h
    local full = Geom:new{ w = self.sw, h = self.sh }
    if self.align == "top" then
        self[1] = TopContainer:new{ dimen = full, U.centered(self.frame, self.sw, fh) }
    elseif self.align == "bottom" then
        self[1] = BottomContainer:new{ dimen = full, U.centered(self.frame, self.sw, fh) }
    else
        self[1] = CenterContainer:new{ dimen = full, self.frame }
    end
    if first then
        UIManager:setDirty(self, function() return "ui", self.dimen end)
    else
        -- The frame may have shrunk, so repaint what is underneath as well.
        UIManager:setDirty("all", function() return "ui", self.dimen end)
    end
end

function Popup:onTapOutside(arg, ges)
    if self.modal_close and self.frame and self.frame.dimen and ges.pos
        and ges.pos:notIntersectWith(self.frame.dimen) then
        self:onClose()
    end
    return true
end

function Popup:onSwipeAny(arg, ges)
    if (self.align == "top" and ges.direction == "north")
        or (self.align == "bottom" and ges.direction == "south") then
        self:onClose()
    end
    return true
end

function Popup:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function Popup:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function Popup:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end
U.Popup = Popup

return U
