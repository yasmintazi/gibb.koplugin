--[[--
Gibb: a home dashboard, book pages with ratings and reviews, a
library, a highlights list, a reader menu, a swipe-down quick panel, header
and footer stats, and auto-highlight.

Nothing here runs in the background. Data is read when a screen opens.

@module koplugin.gibb
--]]--

local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

-- These must be loaded here, while KOReader still has this folder on its
-- search path. Loading them later, from inside a function, would fail.
local D = require("gibb_data")
local U = require("gibb_ui")
local V = require("gibb_views")
local R = require("gibb_reader")

local SETTINGS_KEY = "gibb"

local function defaults()
    local enabled, order = {}, {}
    for i = 1, #V.CARDS do
        enabled[V.CARDS[i].id] = true
        order[i] = V.CARDS[i].id
    end
    return {
        name = "",
        symbols = true,
        cats = true,
        critters = true,
        max_books = 3,
        max_authors = 5,
        max_reviews = 5,
        goal = 30,
        year_goal = 24,
        hl_every = 30,
        enabled = enabled,
        order = order,
        apps = { zlibrary = true, ao3 = true, storefront = true, crossword = true },
        open_on_start = true,
        reader_menu = true,
        quick_panel = true,
        quick_panel_tap = true,
        auto_highlight = true,
        auto_words = 5,
        rate_on_finish = true,
        airplane = false,
        lib_view = "shelf",
        home_style = "scrapbook",
        lib_sort = "recent",
        margins = {
            header = true,
            footer = true,
            size = "small",
            line = "chapters",
            top = { "progress", "clock", "battery" },
            bottom = { "chapter_time", "page", "book_time" },
        },
    }
end

local function fill(target, source)
    for key, value in pairs(source) do
        if target[key] == nil then
            target[key] = value
        elseif type(value) == "table" and type(target[key]) == "table" and #value == 0 then
            fill(target[key], value)
        end
    end
end

local Plugin = WidgetContainer:extend{
    name = "gibb",
    is_doc_only = false,
}

function Plugin:loadSettings()
    local settings = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(settings) ~= "table" then
        -- Carry over preferences saved under the plugin's first name.
        settings = G_reader_settings:readSetting("cutedashboard")
    end
    if type(settings) ~= "table" then settings = {} end
    -- Opening at startup became the default; switch it on once for settings
    -- saved before that. Turning it off afterwards sticks.
    if (settings.version or 1) < 2 then
        settings.open_on_start = true
        settings.version = 2
    end
    -- The Home page was rearranged (Continue reading added, highlights
    -- moved onto it), so start once from the new default order.
    if settings.version < 3 then
        settings.order = nil
        settings.version = 3
    end
    -- The scrapbook home and the bookshelf became the default look.
    if settings.version < 4 then
        settings.home_style = "scrapbook"
        settings.lib_view = "shelf"
        settings.version = 4
    end
    fill(settings, defaults())
    -- Keep the card order valid when cards are added in a newer version.
    local known, seen, order = {}, {}, {}
    for i = 1, #V.CARDS do known[V.CARDS[i].id] = true end
    for i = 1, #settings.order do
        local id = settings.order[i]
        if known[id] and not seen[id] then
            seen[id] = true
            order[#order + 1] = id
        end
    end
    for i = 1, #V.CARDS do
        if not seen[V.CARDS[i].id] then order[#order + 1] = V.CARDS[i].id end
    end
    settings.order = order
    self.settings = settings
    G_reader_settings:saveSetting(SETTINGS_KEY, settings)
    U.symbols = settings.symbols
    U.cats = settings.cats
    U.critters = settings.critters
end

function Plugin:save()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

function Plugin:init()
    local dir = self.path
    if not dir then
        local source = debug.getinfo(1, "S").source or ""
        dir = source:gsub("^@", ""):match("^(.*)/[^/]*$")
    end
    U.plugin_dir = dir
    self.views = {}
    self:loadSettings()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    -- While Aleph is on, leave the menus, highlights and margins to it, so
    -- nothing is drawn twice. The dashboard itself still works.
    self.aleph_on = self:alephIsOn()
    if self.ui and not self.ui.document then
        if not self.aleph_on then
            local ok, err = pcall(R.attach, self)
            if not ok then logger.warn("gibb: could not attach to file browser:", err) end
        end
        if self.settings.open_on_start then
            UIManager:scheduleIn(0.3, function()
                local ok2, FileManager = pcall(require, "apps/filemanager/filemanager")
                if ok2 and FileManager.instance == self.ui then self:showDashboard() end
            end)
        end
    end
end

function Plugin:onReaderReady()
    if self.aleph_on then return end
    local ok, err = pcall(R.attach, self)
    if not ok then logger.warn("gibb: could not attach to reader:", err) end
    local view = self.view or (self.ui and self.ui.view)
    if view and view.registerViewModule then
        pcall(view.registerViewModule, view, "gibb_margins", R.makeMargins(self))
    end
end

function Plugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("gibb_open", { category = "none", event = "GibbOpen", title = _("Gibb: open dashboard"), general = true })
    Dispatcher:registerAction("gibb_library", { category = "none", event = "GibbLibrary", title = _("Gibb: library"), general = true })
    Dispatcher:registerAction("gibb_highlights", { category = "none", event = "GibbHighlights", title = _("Gibb: all highlights"), general = true })
    Dispatcher:registerAction("gibb_panel", { category = "none", event = "GibbPanel", title = _("Gibb: quick panel"), general = true })
    Dispatcher:registerAction("gibb_book", { category = "none", event = "GibbBook", title = _("Gibb: this book's page"), reader = true })
    Dispatcher:registerAction("gibb_menu", { category = "none", event = "GibbMenu", title = _("Gibb: reader menu"), reader = true })
end

function Plugin:onGibbOpen() self:showDashboard() return true end
function Plugin:onGibbLibrary() self:showLibrary() return true end
function Plugin:onGibbHighlights() self:showHighlights() return true end
function Plugin:onGibbPanel() self:showQuickPanel() return true end
function Plugin:onGibbBook()
    if self.ui.document then self:showBookPage(self.ui.document.file) end
    return true
end
function Plugin:onGibbMenu() self:showReaderMenu() return true end

---------------------------------------------------------------------------
-- Opening screens
---------------------------------------------------------------------------

local function guarded(what, fn)
    local ok, err = pcall(fn)
    if not ok then
        logger.warn("gibb:", what, "failed:", err)
        UIManager:show(InfoMessage:new{
            text = _("Gibb hit a problem:") .. "\n" .. tostring(err),
        })
    end
end

-- Shows a page and remembers it, so that opening a book can close them all
-- and so the page underneath refreshes when this one closes.
function Plugin:push(view)
    table.insert(self.views, view)
    view.on_close = function()
        for i = #self.views, 1, -1 do
            if self.views[i] == view then table.remove(self.views, i) end
        end
        local top = self.views[#self.views]
        if top and top.reload and not self.closing_all then pcall(top.reload, top) end
    end
    UIManager:show(view)
    return view
end

function Plugin:closeAll()
    self.closing_all = true
    for i = #self.views, 1, -1 do UIManager:close(self.views[i]) end
    self.views = {}
    self.closing_all = false
end

function Plugin:showDashboard()
    guarded("dashboard", function()
        self:closeAll()
        -- The very first opening has to walk the library folder, which can
        -- take a few seconds, so say so instead of looking frozen.
        local note
        if not D.index then
            note = InfoMessage:new{ text = _("Opening your dashboard…") }
            UIManager:show(note)
            UIManager:forceRePaint()
        end
        local ok, view = pcall(function()
            return V.Dashboard:new{ plugin = self, swipe_down = function() self:showQuickPanel() end }
        end)
        if note then UIManager:close(note) end
        if not ok then error(view, 0) end
        self:push(view)
        if self.aleph_on and not Plugin.aleph_warned then
            Plugin.aleph_warned = true
            UIManager:show(InfoMessage:new{
                text = _("Aleph is still on, so the reader menu, quick panel, header and footer, and auto-highlight are paused to avoid doubles.\n\nTo switch over: Tools menu, Gibb, Turn Aleph off."),
            })
        end
    end)
end

function Plugin:showBookPage(file)
    if not file then return end
    guarded("book page", function() self:push(V.BookPage:new{ plugin = self, file = file }) end)
end

function Plugin:showLibrary(scope)
    guarded("library", function()
        scope = scope or {}
        local search = scope.search
        scope.search = nil
        local view = self:push(V.Library:new{ plugin = self, scope = scope })
        if search then view:promptSearch() end
    end)
end

function Plugin:showHighlights(scope)
    guarded("highlights", function()
        self:push(V.Highlights:new{ plugin = self, file = scope and scope.file })
    end)
end

function Plugin:showHighlight(item)
    guarded("highlight", function() self:push(V.HighlightView:new{ plugin = self, item = item }) end)
end

function Plugin:showRate(file, opts)
    guarded("rating", function()
        opts = opts or {}
        self:push(V.RateDialog:new{
            plugin = self, file = file,
            finishing = opts.finishing, on_skip = opts.on_skip, on_done = opts.on_done,
        })
    end)
end

function Plugin:showReaderMenu()
    if not self.ui.document then return end
    guarded("reader menu", function() UIManager:show(R.ReaderMenu:new{ plugin = self }) end)
end

function Plugin:showQuickPanel()
    guarded("quick panel", function() UIManager:show(R.QuickPanel:new{ plugin = self }) end)
end

function Plugin:showMarginsSettings()
    guarded("margins", function() UIManager:show(R.MarginsSettings:new{ plugin = self }) end)
end

-- Opens a book, optionally jumping to a highlight in it. Passing true as
-- the "seamless" flag asks KOReader not to show its "Opening file" notice
-- with the full path.
function Plugin:openBook(file, item)
    self:closeAll()
    local function jump()
        if not item or not item.page then return end
        pcall(function()
            local reader = require("apps/reader/readerui").instance
            if not reader then return end
            if reader.bookmark and reader.bookmark.gotoBookmark then
                reader.bookmark:gotoBookmark(item.page, item.pos0)
            elseif type(item.page) == "number" then
                reader:handleEvent(Event:new("GotoPage", item.page))
            else
                reader:handleEvent(Event:new("GotoXPointer", item.page, item.pos0))
            end
        end)
    end
    guarded("opening the book", function()
        local ui = self.ui
        if ui.document then
            if ui.document.file == file then
                jump()
            else
                ui:switchDocument(file, true, jump)
            end
        else
            require("apps/reader/readerui"):showReader(file, nil, true, nil, jump)
        end
    end)
end

---------------------------------------------------------------------------
-- App tiles
---------------------------------------------------------------------------

-- How each tile finds and opens its plugin. `folder` is the plugin's folder
-- name without ".koplugin"; matching on it keeps look-alikes apart (App Store
-- and Storefront both have a showBrowser function).
local APP_HOOKS = {
    zlibrary   = { folder = "zlibrary",      method = "onZlibrarySearch",        event = "ZlibrarySearch" },
    ao3        = { folder = "ao3downloader", method = "onOpenAO3DownloaderMenu", event = "OpenAO3DownloaderMenu" },
    storefront = { folder = "storefront",    method = "showBrowser" },
    crossword  = { folder = "crossword",     method = "showLibraryView" },
}

local function inFolder(path, folder)
    if type(path) ~= "string" then return false end
    local name = path:gsub("/+$", ""):match("([^/]+)$")
    return name ~= nil and name:lower() == folder .. ".koplugin"
end

-- Returns the running plugin (or nil) and whether KOReader has it enabled.
local function findPlugin(ui, hook)
    local ok_loader, PluginLoader = pcall(require, "pluginloader")
    local enabled, meta_name = false, nil
    if ok_loader and PluginLoader then
        pcall(function()
            local list = PluginLoader:loadPlugins()
            for _i, plugin in ipairs(list or {}) do
                if inFolder(plugin.path, hook.folder) then
                    enabled, meta_name = true, plugin.name
                end
            end
        end)
    end

    local function usable(candidate)
        if type(candidate) ~= "table" then return false end
        local ok, fn = pcall(function() return candidate[hook.method] end)
        return ok and type(fn) == "function"
    end
    local function pathOf(candidate)
        local ok, path = pcall(function() return candidate.path end)
        return ok and path or nil
    end

    -- 1. KOReader's own record of running plugins.
    if ok_loader and PluginLoader and PluginLoader.getPluginInstance then
        for _i, name in ipairs({ meta_name or false, hook.folder }) do
            if name then
                local ok, instance = pcall(PluginLoader.getPluginInstance, PluginLoader, name)
                if ok and usable(instance) then return instance, true end
            end
        end
    end
    -- 2. Anything registered with the menu or the window that lives in the right folder.
    local pools = { ui.menu and ui.menu.registered_widgets or {}, ui }
    for p = 1, #pools do
        for _key, candidate in pairs(pools[p]) do
            if candidate ~= ui and usable(candidate) and inFolder(pathOf(candidate), hook.folder) then
                return candidate, true
            end
        end
    end
    return nil, enabled
end

-- Lets other parts of Gibb look up a running plugin by its folder name
-- and a function it must have. Returns nil when it is not running.
function Plugin:findOther(folder, method)
    local ok, instance = pcall(findPlugin, self.ui, { folder = folder, method = method })
    return ok and instance or nil
end

function Plugin:launch(app)
    local ui = self.ui
    local hook = APP_HOOKS[app]
    if not hook then return end
    local opened = false
    local ok, err = pcall(function()
        local instance, enabled = findPlugin(ui, hook)
        if self.settings.airplane and app ~= "crossword" then
            UIManager:show(InfoMessage:new{ text = _("Airplane mode is on, so this will be offline."), timeout = 3 })
        end
        if not instance then
            -- Not found directly: ask the way a gesture would.
            if hook.event then
                if app == "ao3" then self:closeAll() end
                local handled = ui:handleEvent(Event:new(hook.event))
                opened = handled == true or enabled
            end
            return
        end
        if app == "zlibrary" then
            instance:onZlibrarySearch()
        elseif app == "ao3" then
            self:closeAll()
            instance:onOpenAO3DownloaderMenu()
        elseif app == "storefront" then
            instance:showBrowser()
        elseif app == "crossword" then
            instance:lazyInitialization()
            local resumed = pcall(function()
                local History, Puzzle = package.loaded["history"], package.loaded["puzzle"]
                local last = History:new{}:get()[1]
                instance:showGameView(Puzzle:loadById(last.puzzle_id))
            end)
            if not resumed then instance:showLibraryView() end
        end
        opened = true
    end)
    if not ok then
        logger.warn("gibb: app tile failed:", app, err)
        UIManager:show(InfoMessage:new{ text = _("That plugin could not be opened:") .. "\n" .. tostring(err) })
    elseif not opened then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Could not find a running plugin in a folder named %s.koplugin. Check it is turned on in Plugin management, or hide this tile in the dashboard settings."), hook.folder),
        })
    end
end

---------------------------------------------------------------------------
-- Updates through Storefront
---------------------------------------------------------------------------

local HOME_OWNER, HOME_REPO = "yasmintazi", "gibb.koplugin"

-- Storefront can follow any GitHub repository, but this version of it has no
-- button for linking a plugin by hand. This asks Storefront to link Gibb to
-- its own repository, using Storefront's own function for it.
function Plugin:linkToStorefront()
    local ok, err = pcall(function()
        local storefront = findPlugin(self.ui, APP_HOOKS.storefront)
        if not storefront or type(storefront.verifyAndMatchPluginWithManualRepo) ~= "function" then
            UIManager:show(InfoMessage:new{
                text = _("Storefront is not running, or this version of it cannot link a plugin to a repository."),
            })
            return
        end
        local dirname = (U.plugin_dir or ""):gsub("/+$", ""):match("([^/]+)$") or "gibb.koplugin"
        local version
        pcall(function() version = dofile(U.plugin_dir .. "/_meta.lua").version end)
        self:closeAll()
        storefront:verifyAndMatchPluginWithManualRepo(
            { dirname = dirname, name = "Gibb", version = version }, HOME_OWNER, HOME_REPO)
    end)
    if not ok then
        logger.warn("gibb: linking to Storefront failed:", err)
        UIManager:show(InfoMessage:new{ text = _("Could not link to Storefront:") .. "\n" .. tostring(err) })
    end
end

---------------------------------------------------------------------------
-- Aleph: both plugins replace the same menus, so only one should be on
---------------------------------------------------------------------------

function Plugin:alephIsOn()
    local on = false
    pcall(function()
        local list = require("pluginloader"):loadPlugins()
        for _i, plugin in ipairs(list or {}) do
            if inFolder(plugin.path, "aleph") then on = true end
        end
    end)
    return on
end

function Plugin:turnOffAleph()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Turn Aleph off and restart KOReader?\n\nNothing of Aleph's is deleted. You can turn it back on in Plugin management."),
        ok_text = _("Turn off and restart"),
        ok_callback = function()
            local disabled = G_reader_settings:readSetting("plugins_disabled")
            if type(disabled) ~= "table" then disabled = {} end
            disabled["aleph"] = true
            G_reader_settings:saveSetting("plugins_disabled", disabled)
            G_reader_settings:flush()
            UIManager:broadcastEvent(Event:new("Restart"))
        end,
    })
end

---------------------------------------------------------------------------
-- Settings menu (Tools > Dashboard)
---------------------------------------------------------------------------

function Plugin:spin(title, key, min, max, touchmenu)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = title,
        value = self.settings[key],
        value_min = min,
        value_max = max,
        value_step = 1,
        value_hold_step = 5,
        ok_text = _("Set"),
        callback = function(spin)
            self.settings[key] = spin.value
            self:save()
            if touchmenu then touchmenu:updateItems() end
        end,
    })
end

function Plugin:toggle(text, key, on_change)
    return {
        text = text,
        checked_func = function() return self.settings[key] == true end,
        callback = function()
            self.settings[key] = not self.settings[key]
            self:save()
            if on_change then on_change() end
        end,
    }
end

function Plugin:arrangeCards()
    local SortWidget = require("ui/widget/sortwidget")
    local labels = {}
    for i = 1, #V.CARDS do
        labels[V.CARDS[i].id] = V.PAGE_NAMES[V.CARDS[i].page] .. " · " .. V.CARDS[i].label
    end
    local items = {}
    for i = 1, #self.settings.order do
        local id = self.settings.order[i]
        items[i] = { text = labels[id] or id, card_id = id }
    end
    local widget
    widget = SortWidget:new{
        title = _("Arrange cards"),
        item_table = items,
        callback = function()
            local order = {}
            for i = 1, #widget.item_table do order[i] = widget.item_table[i].card_id end
            self.settings.order = order
            self:save()
        end,
    }
    UIManager:show(widget)
end

function Plugin:addToMainMenu(menu_items)
    local settings = self.settings

    local card_toggles = {}
    for i = 1, #V.CARDS do
        local card = V.CARDS[i]
        card_toggles[i] = {
            text = V.PAGE_NAMES[card.page] .. " · " .. card.label,
            checked_func = function() return settings.enabled[card.id] == true end,
            callback = function()
                settings.enabled[card.id] = not settings.enabled[card.id]
                self:save()
            end,
        }
    end

    local app_toggles = {}
    for i = 1, #V.APPS do
        local app = V.APPS[i]
        app_toggles[i] = {
            text = app.label,
            checked_func = function() return settings.apps[app.id] == true end,
            callback = function()
                settings.apps[app.id] = not settings.apps[app.id]
                self:save()
            end,
        }
    end

    -- How often the highlight card swaps its quote. Checked when the
    -- dashboard is drawn; nothing runs in between.
    local quote_choices = {}
    for _i, choice in ipairs({
        { 0, _("Every time the dashboard opens") },
        { 10, _("Every 10 minutes") },
        { 30, _("Every 30 minutes") },
        { 60, _("Every hour") },
        { 1440, _("Once a day") },
    }) do
        quote_choices[#quote_choices + 1] = {
            text = choice[2],
            radio = true,
            checked_func = function() return settings.hl_every == choice[1] end,
            callback = function()
                settings.hl_every = choice[1]
                self:save()
            end,
        }
    end

    local book_counts = {}
    for n = 2, 4 do
        book_counts[#book_counts + 1] = {
            text = tostring(n),
            radio = true,
            checked_func = function() return settings.max_books == n end,
            callback = function()
                settings.max_books = n
                self:save()
            end,
        }
    end

    local items = {}
    if self.aleph_on then
        items[#items + 1] = {
            text = _("Turn Aleph off (in-book features are paused while it is on)"),
            keep_menu_open = true,
            separator = true,
            callback = function() self:turnOffAleph() end,
        }
    end
    local main_items = {
        { text = _("Open dashboard"), callback = function() self:showDashboard() end },
        { text = _("Library"), callback = function() self:showLibrary() end },
        { text = _("All highlights"), callback = function() self:showHighlights() end },
        { text = _("Quick panel"), callback = function() self:showQuickPanel() end },
    }
    for i = 1, #main_items do items[#items + 1] = main_items[i] end
    if self.ui.document then
        items[#items + 1] = {
            text = _("This book's page"),
            callback = function() self:showBookPage(self.ui.document.file) end,
        }
        items[#items + 1] = {
            text = _("Rate and review this book"),
            callback = function() self:showRate(self.ui.document.file) end,
        }
    end
    items[#items].separator = true

    items[#items + 1] = {
        text = _("Dashboard settings"),
        sub_item_table = {
            {
                text_func = function()
                    return _("Your name: ") .. (settings.name ~= "" and settings.name or _("not set"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    V.editText(_("Your name"), settings.name, function(text)
                        settings.name = text
                        self:save()
                        if touchmenu then touchmenu:updateItems() end
                    end)
                end,
            },
            {
                text = _("Home page style"),
                sub_item_table = {
                    {
                        text = _("Scrapbook (squared paper, notes and critters)"),
                        radio = true,
                        checked_func = function() return settings.home_style == "scrapbook" end,
                        callback = function() settings.home_style = "scrapbook"; self:save() end,
                    },
                    {
                        text = _("Cards (the original list of cards)"),
                        radio = true,
                        checked_func = function() return settings.home_style ~= "scrapbook" end,
                        callback = function() settings.home_style = "cards"; self:save() end,
                    },
                },
            },
            { text = _("Show or hide cards"), sub_item_table = card_toggles },
            { text = _("Arrange cards"), keep_menu_open = true, callback = function() self:arrangeCards() end },
            {
                text_func = function() return _("Books shown on Home: ") .. settings.max_books end,
                sub_item_table = book_counts,
            },
            {
                text_func = function() return _("Daily page goal: ") .. settings.goal end,
                keep_menu_open = true,
                callback = function(touchmenu) self:spin(_("Daily page goal"), "goal", 1, 500, touchmenu) end,
            },
            {
                text_func = function() return _("Yearly book goal: ") .. settings.year_goal end,
                keep_menu_open = true,
                callback = function(touchmenu) self:spin(_("Yearly book goal"), "year_goal", 1, 500, touchmenu) end,
            },
            { text = _("App tiles"), sub_item_table = app_toggles },
            { text = _("New highlight quote"), sub_item_table = quote_choices },
            self:toggle(_("Show my critters (pictures in the critters folder)"), "critters", function() U.critters = settings.critters end),
            self:toggle(_("Cat theme (paws, whiskers and fish)"), "cats", function() U.cats = settings.cats end),
            self:toggle(_("Cute symbols (♥ ✿ ★)"), "symbols", function() U.symbols = settings.symbols end),
            self:toggle(_("Open the dashboard when KOReader starts"), "open_on_start"),
        },
    }
    items[#items + 1] = {
        text = _("In-book settings"),
        sub_item_table = {
            self:toggle(_("Reader menu when tapping the bottom"), "reader_menu"),
            self:toggle(_("Quick panel when swiping down from the top"), "quick_panel"),
            self:toggle(_("Quick panel when tapping the top"), "quick_panel_tap"),
            self:toggle(_("Auto-highlight long selections"), "auto_highlight"),
            {
                text_func = function()
                    return string.format(_("Counts as long: %d words or more"), settings.auto_words)
                end,
                keep_menu_open = true,
                callback = function(touchmenu) self:spin(_("Words needed to auto-highlight"), "auto_words", 2, 40, touchmenu) end,
            },
            self:toggle(_("Ask to rate when I finish a book"), "rate_on_finish"),
            { text = _("Header and footer"), callback = function() self:showMarginsSettings() end },
        },
    }
    items[#items + 1] = {
        text = _("Rescan library folder"),
        callback = function()
            UIManager:show(InfoMessage:new{ text = _("Scanning your library…"), timeout = 1 })
            UIManager:nextTick(function()
                local ok, err = pcall(D.rebuild, self.ui, settings)
                UIManager:show(InfoMessage:new{
                    text = ok and string.format(_("Found %d books."), #(D.index or {})) or (_("The scan failed: ") .. tostring(err)),
                    timeout = 3,
                })
            end)
        end,
    }

    items[#items + 1] = {
        text = _("Get updates through Storefront"),
        keep_menu_open = true,
        callback = function() self:linkToStorefront() end,
    }

    menu_items.gibb = {
        text = _("Gibb"),
        sorting_hint = "tools",
        sub_item_table = items,
    }
end

return Plugin
