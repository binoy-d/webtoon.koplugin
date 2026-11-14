--[[ webtoon.koplugin: panel-snap scrolling for webtoons in KOReader.

For CBZs made by kowebtoon (they carry kowebtoon.json, a map of the gaps between panels):
  * first open switches the book to continuous view, page-width zoom, no page gap, and skips
    the title cover
  * a page-turn tap/key glides (a couple of fast frames, then one clean refresh) so the last
    gap still on screen lands at the top: you always start on a whole panel
  * the strips just below the screen are pre-rendered while you read, so the next tap is quick
  * at the end of an episode the next .cbz in the folder opens
Optionally (Settings > "Glide on any tall comic") plain webtoon CBZs get the glide too, with
fixed steps instead of panel snapping. Everything else is untouched, and any error falls back to
KOReader's normal page turn.

https://github.com/binoy-d/webtoon.koplugin
]]
local Archiver = require("ffi/archiver")
local Event = require("ui/event")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local MIN_STEP = 0.2        -- never snap less than this fraction of a screen
local GOOD_STEP = 0.4       -- ...and prefer gaps that move at least this far
local FALLBACK_STEP = 0.85  -- no gap on screen (tall panel): scroll this much, keeping overlap
local BREATHING = 0.025     -- land this fraction of a screen above the next panel's top
local ANALYSIS_W = 320      -- px width for on-device panel detection of map-less webtoons

local DEFAULTS = { frames = 2, flash_every = 20, auto_next = true, glide_tall = true, margin = 0.05,
                   day_mode = true, preload = 2 }

-- set when going back from the top of an episode: open that file at its end
local open_at_end

-- make this plugin's own modules (wt_*.lua) requireable, also from download subprocesses
local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
if plugin_dir and not package.path:find(plugin_dir, 1, true) then
    package.path = plugin_dir .. "/?.lua;" .. package.path
end

local Dispatcher = require("dispatcher")

local Webtoon = WidgetContainer:extend{
    name = "webtoon",
    is_doc_only = false,          -- the library/downloader is reachable from the file browser too
}

function Webtoon:init()
    self.active = false
    self.ui.menu:registerToMainMenu(self)
    Dispatcher:registerAction("webtoon_library", { category = "none", event = "WebtoonLibrary",
        title = _("Webtoons: library"), general = true })
    Dispatcher:registerAction("webtoon_check_new", { category = "none", event = "WebtoonCheckNew",
        title = _("Webtoons: check for new episodes"), general = true })
    Dispatcher:registerAction("webtoon_next_panel", { category = "none", event = "WebtoonNextPanel",
        title = _("Webtoons: next panel"), reader = true })
    Dispatcher:registerAction("webtoon_prev_panel", { category = "none", event = "WebtoonPrevPanel",
        title = _("Webtoons: previous panel"), reader = true })
    -- KOReader was quit while a webtoon was open: give night mode back in the file browser
    if not self.ui.document and G_reader_settings:isTrue("webtoon_restore_night") then
        UIManager:nextTick(function()
            if G_reader_settings:isTrue("webtoon_restore_night") then
                G_reader_settings:delSetting("webtoon_restore_night")
                UIManager:broadcastEvent(Event:new("SetNightMode", true))
            end
        end)
    end
end

function Webtoon:library() return require("wt_library") end
function Webtoon:onWebtoonLibrary() self:library():showHome(); return true end
function Webtoon:onWebtoonCheckNew() self:library():checkNew(); return true end
function Webtoon:onWebtoonNextPanel() if self.active then pcall(self.glide, self, 1) end return true end
function Webtoon:onWebtoonPrevPanel() if self.active then pcall(self.glide, self, -1) end return true end

function Webtoon:cfg(key)
    local s = G_reader_settings:readSetting("webtoon") or {}
    if s[key] == nil then return DEFAULTS[key] end
    return s[key]
end

function Webtoon:setCfg(key, value)
    local s = G_reader_settings:readSetting("webtoon") or {}
    s[key] = value
    G_reader_settings:saveSetting("webtoon", s)
end

-- kowebtoon.json from inside the CBZ, or nil
local function readMap(file)
    if not file:lower():match("%.cbz$") then return nil end
    local arc = Archiver.Reader:new()
    if not arc:open(file) then return nil end
    local data
    for entry in arc:iterate() do
        if entry.path == "kowebtoon.json" then
            data = arc:extractToMemory(entry.path)
            break
        end
    end
    arc:close()
    if not data then return nil end
    local ok, map = pcall(json.decode, data)
    if ok and type(map) == "table" and type(map.gaps) == "table" then return map end
end

-- a plain webtoon CBZ: most pages much taller than wide
local function looksTall(doc)
    local n, tall = math.min(doc:getPageCount(), 12), 0
    for p = 1, n do
        local d = doc:getNativePageDimensions(p)
        if d and d.h > d.w * 1.6 then tall = tall + 1 end
    end
    return n > 0 and tall >= n * 0.6
end

function Webtoon:onReaderReady()
    local doc = self.ui.document
    if not doc or not doc.file or not self.ui.paging then return end
    local ok, map = pcall(readMap, doc.file)
    if not ok then logger.warn("webtoon: reading map failed:", map); map = nil end
    if not map and not (self:cfg("glide_tall") and looksTall(doc)) then return end

    self.file, self.glides, self.cache = doc.file, 0, nil
    if not map then
        -- a webtoon from elsewhere: detect panels on the device, in the background, cached per book
        local saved = self.ui.doc_settings:readSetting("webtoon_auto_map")
        map = (type(saved) == "table" and saved.v == ANALYSIS_W) and saved or { v = ANALYSIS_W, gaps = {}, done = {} }
        self.auto = true
    end
    self.map = map
    self.active = true
    self:dayMode()
    self:firstOpenSetup()
    self:hookPaging()
    if self.auto then UIManager:scheduleIn(1, function() self:analyzeStep() end) end
    if open_at_end == doc.file then
        open_at_end = nil
        UIManager:scheduleIn(0.3, function() self:jumpToEnd() end)
    end
    logger.info("webtoon: active,", #map.gaps, "panel gaps", self.auto and "(detecting on device)" or "")
end

function Webtoon:jumpToEnd()
    local doc = self.ui.document
    self.ui:handleEvent(Event:new("GotoPage", doc:getPageCount()))
    UIManager:nextTick(function()
        local L = self:layout()
        local view = self.ui.view
        local top = view.page_states and view.page_states[1]
        if not top then return end
        local T = L.tops[top.page] + (top.visible_area.y - top.page_area.y)
        local max_top = math.max(0, L.total - view.visible_area.h)
        if max_top > T then self.ui.paging:onScrollPanRel(math.floor(max_top - T)) end
        UIManager:setDirty(view.dialog, "full")
    end)
end

-- On-device panel detection for webtoons without a kowebtoon map: render a page small, find
-- blank row runs (every pixel within a few grey levels), record {page, centre, page, next-start}.
-- Runs a page or two at a time between taps, nearest pages first, and caches the result.
function Webtoon:analyzePage(p)
    local Blitbuffer = require("ffi/blitbuffer")
    local ffi = require("ffi")
    local doc = self.ui.document
    local d = doc:getNativePageDimensions(p)
    if not d or d.w <= 0 then return end
    local zoom = ANALYSIS_W / d.w
    local tile = doc:renderPage(p, nil, zoom, 0, 1.0)
    if not tile or not tile.bb then return end
    local src = tile.bb
    local bb = src
    if src:getType() ~= Blitbuffer.TYPE_BB8 then
        bb = Blitbuffer.new(src:getWidth(), src:getHeight(), Blitbuffer.TYPE_BB8)
        bb:blitFrom(src)
    end
    local w, h = bb:getWidth(), bb:getHeight()
    local base, stride = ffi.cast("uint8_t*", bb.data), tonumber(bb.stride)
    local min_run = math.max(3, math.floor(w / 60))
    local y = 0
    while y < h do
        local row, lo, hi, blank = base + y * stride, 255, 0, true
        for x = 0, w - 1 do
            local v = row[x]
            if v < lo then lo = v end
            if v > hi then hi = v end
            if hi - lo > 6 then blank = false; break end
        end
        if blank then
            local s = y
            repeat
                y = y + 1
                if y >= h then break end
                row, lo, hi = base + y * stride, 255, 0
                local still = true
                for x = 0, w - 1 do
                    local v = row[x]
                    if v < lo then lo = v end
                    if v > hi then hi = v end
                    if hi - lo > 6 then still = false; break end
                end
            until not still
            if y - s >= min_run then
                table.insert(self.map.gaps, { p, ((s + y) / 2) / h, p, math.min(y, h - 1) / h })
            end
        end
        y = y + 1
    end
    if bb ~= src then bb:free() end
end

function Webtoon:analyzeStep()
    if not self.active or not self.auto then return end
    local doc, map = self.ui.document, self.map
    local n = doc:getPageCount()
    local cur = self.ui.paging and self.ui.paging.current_page or 1
    local todo
    for d = 0, n do                          -- nearest unanalysed page, ahead first
        for _, p in ipairs({ cur + d, cur - d }) do
            if p >= 1 and p <= n and not map.done[tostring(p)] then todo = p; break end
        end
        if todo then break end
    end
    if not todo then
        self.ui.doc_settings:saveSetting("webtoon_auto_map", map)
        logger.info("webtoon: on-device panel detection done,", #map.gaps, "gaps")
        return
    end
    local ok, err = pcall(self.analyzePage, self, todo)
    if not ok then logger.warn("webtoon: analysing page", todo, "failed:", err) end
    map.done[tostring(todo)] = true
    table.sort(map.gaps, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
    self.cache = nil
    UIManager:scheduleIn(0.15, function() self:analyzeStep() end)
end

-- Night mode inverts the art, so webtoons read in day mode (setting "day_mode", on by default).
-- Night mode comes back when you leave; going straight to the next episode keeps day mode, so the
-- screen doesn't flip twice. The pending restore lives at module level to survive document switches.
local pending_restore

local function restoreNight()
    pending_restore = nil
    if G_reader_settings:isTrue("webtoon_restore_night") then
        G_reader_settings:delSetting("webtoon_restore_night")
        UIManager:broadcastEvent(Event:new("SetNightMode", true))
    end
end

function Webtoon:dayMode()
    if pending_restore then UIManager:unschedule(pending_restore); pending_restore = nil end
    if not self:cfg("day_mode") then return end
    if G_reader_settings:isTrue("night_mode") then
        G_reader_settings:saveSetting("webtoon_restore_night", true)
        UIManager:broadcastEvent(Event:new("SetNightMode", false))
    end
end

function Webtoon:onCloseDocument()
    if not self.active then return end
    self.active = false
    if self.auto and self.map then self.ui.doc_settings:saveSetting("webtoon_auto_map", self.map) end
    if G_reader_settings:isTrue("webtoon_restore_night") then
        pending_restore = restoreNight
        UIManager:scheduleIn(1.5, restoreNight)
    end
end

function Webtoon:firstOpenSetup()
    local ds = self.ui.doc_settings
    if ds:isTrue("webtoon_setup_done") then return end
    ds:saveSetting("webtoon_setup_done", true)
    local doc, view = self.ui.document, self.ui.view
    doc.configurable.page_gap_height = 0
    if view.page_gap then view.page_gap.height = 0 end
    self.ui:handleEvent(Event:new("SetZoomMode", "pagewidth"))
    doc.configurable.page_scroll = 1
    self.ui:handleEvent(Event:new("SetScrollMode", true))
    local first = self.map and self.map.first_page
    if first and first > 1 then
        UIManager:nextTick(function() self.ui:handleEvent(Event:new("GotoPage", first)) end)
    end
end

function Webtoon:hookPaging()
    local paging = self.ui.paging
    if paging._webtoon_orig then return end
    local orig = paging.onGotoViewRel
    paging._webtoon_orig = orig
    paging.onGotoViewRel = function(p, diff, no_page_turn)
        if self.active and p.view.page_scroll and no_page_turn ~= true and type(diff) == "number" then
            local ok, handled = pcall(self.glide, self, diff)
            if ok and handled then return true end
            if not ok then logger.warn("webtoon: glide failed, normal turn:", handled) end
        end
        return orig(p, diff, no_page_turn)
    end
end

-- absolute (screen-px) layout at the current zoom: page tops, total height, gaps
function Webtoon:layout()
    local view = self.ui.view
    local zoom, rot = view.state.zoom, view.state.rotation
    local c = self.cache
    if c and c.zoom == zoom and c.rot == rot then return c end
    local doc = self.ui.document
    local gap = view.page_gap and view.page_gap.height or 0
    local tops, heights, acc = {}, {}, 0
    for p = 1, doc:getPageCount() do
        tops[p] = acc
        heights[p] = doc:getPageDimensions(p, zoom, rot).h
        acc = acc + heights[p] + gap
    end
    -- each gap: centre (for "have I seen everything above it?") and land (just above the next
    -- panel's top, so long blank stretches don't fill the screen)
    local abs = {}
    for _, g in ipairs(self.map and self.map.gaps or {}) do
        local p, frac = g[1], g[2]
        if tops[p] then
            local centre = tops[p] + frac * heights[p]
            local land = centre
            if g[3] and tops[g[3]] then
                land = math.max(centre, tops[g[3]] + g[4] * heights[g[3]] - BREATHING * view.visible_area.h)
            end
            table.insert(abs, { centre = centre, land = land })
        end
    end
    self.cache = { zoom = zoom, rot = rot, tops = tops, total = acc - gap, gaps = abs }
    return self.cache
end

function Webtoon:glide(diff)
    local t0 = time.now()
    local view = self.ui.view
    local top = view.page_states and view.page_states[1]
    if not top then return false end
    local L = self:layout()
    local H = view.visible_area.h
    local T = L.tops[top.page] + (top.visible_area.y - top.page_area.y)
    local first_top = (self.map and self.map.first_page and L.tops[self.map.first_page]) or 0
    local max_top = math.max(0, L.total - H)

    local target
    if diff > 0 then
        if T >= max_top - 2 then return self:neighbourEpisode(1) end
        -- the last gap whose centre is still on screen: everything above it has been seen.
        -- Prefer one that moves a decent amount; settle for a short hop over cutting a panel.
        local good, short
        for _, g in ipairs(L.gaps) do
            if g.centre <= T + H then
                if g.land > T + GOOD_STEP * H then good = g.land
                elseif g.land > T + MIN_STEP * H then short = g.land end
            end
        end
        target = math.min(good or short or (T + FALLBACK_STEP * H), max_top)
    else
        if T <= first_top + 2 then return self:neighbourEpisode(-1) end
        for _, g in ipairs(L.gaps) do          -- earliest landing within one screen above
            if g.land >= T - H and g.land < T - MIN_STEP * H then target = g.land; break end
        end
        target = math.max(target or (T - FALLBACK_STEP * H), first_top)
    end
    local delta = math.floor(target - T + 0.5)
    if delta == 0 then return true end

    -- glide: intermediate frames as fast refreshes, then one clean one
    local paging = self.ui.paging
    local frames = math.max(1, self:cfg("frames"))
    local orig_setDirty = UIManager.setDirty
    local done = 0
    for i = 1, frames do
        local step = math.floor(delta * i / frames + 0.5) - done
        done = done + step
        if i < frames then
            UIManager.setDirty = function(um, w, mode, ...) return orig_setDirty(um, w, "fast", ...) end
        end
        local ok, err = pcall(paging.onScrollPanRel, paging, step)
        UIManager.setDirty = orig_setDirty
        if not ok then error(err) end
        if i < frames then UIManager:forceRePaint() end
    end
    self.glides = self.glides + 1
    local flash_every = self:cfg("flash_every")
    UIManager:setDirty(view.dialog, (flash_every > 0 and self.glides % flash_every == 0) and "full" or "ui")
    paging:setPagePosition(paging:getTopPage(), paging:getTopPosition())
    logger.dbg("webtoon: glide", delta, "px in", time.to_ms(time.since(t0)), "ms")
    UIManager:scheduleIn(0.4, function() self:prefetch() end)
    return true
end

-- render the next strips into KOReader's cache while the reader is looking at this screen
function Webtoon:prefetch()
    local view, doc = self.ui.view, self.ui.document
    local states = view.page_states
    if not (states and #states > 0 and doc.hintPage) then return end
    local last = states[#states].page
    for p = last + 1, math.min(doc:getPageCount(), last + self:cfg("preload")) do
        pcall(doc.hintPage, doc, p, view.state.zoom, view.state.rotation, view.state.gamma)
    end
end

--- step = 1: next episode from its start; step = -1: previous episode, opened at its end
function Webtoon:neighbourEpisode(step)
    if not self:cfg("auto_next") then return true end
    local dir, name = util.splitFilePathName(self.file)
    local files = {}
    for f in lfs.dir(dir) do
        if f:lower():match("%.cbz$") then table.insert(files, f) end
    end
    table.sort(files)
    for i, f in ipairs(files) do
        if f == name then
            local other = files[i + step]
            if not other then
                UIManager:show(Notification:new{ text = step > 0 and _("That was the last downloaded episode.")
                    or _("This is the first downloaded episode.") })
                return true
            end
            local label = other:gsub("%.cbz$", ""):gsub("^%d+%s*%-%s*", "")
            UIManager:show(Notification:new{ text = T(step > 0 and _("Next: %1") or _("Back to: %1"), label) })
            local path = dir .. other
            if step < 0 then open_at_end = path end
            UIManager:nextTick(function() self.ui:switchDocument(path) end)
            return true
        end
    end
    return true
end

function Webtoon:addToMainMenu(menu_items)
    menu_items.webtoon = {
        text = _("Webtoons"),
        sorting_hint = self.ui.document and "typeset" or "tools",
        sub_item_table = {
            { text = _("Library"), callback = function() self:library():showHome() end },
            { text = _("Search webtoons…"), callback = function() self:library():askSearch() end },
            { text = _("Check for new episodes"), callback = function() self:library():checkNew() end,
              separator = true },
            {
                text_func = function()
                    return T(_("Side margin for new downloads: %1%"), math.floor(self:cfg("margin") * 100 + 0.5))
                end,
                help_text = _("Blank space left and right of each panel in episodes downloaded on this device. Tap to cycle 0 / 3 / 5 / 8 %."),
                keep_menu_open = true,
                callback = function(tm)
                    local nxt = { [0] = 0.03, [3] = 0.05, [5] = 0.08, [8] = 0 }
                    self:setCfg("margin", nxt[math.floor(self:cfg("margin") * 100 + 0.5)] or 0.05)
                    if tm then tm:updateItems() end
                end,
            },
            {
                text_func = function() return T(_("Glide frames: %1"), self:cfg("frames")) end,
                help_text = _("Fast frames per tap. Fewer = snappier and less blinky; more = smoother motion."),
                keep_menu_open = true,
                callback = function(tm)
                    local f = self:cfg("frames") % 4 + 1
                    self:setCfg("frames", f)
                    if tm then tm:updateItems() end
                end,
            },
            {
                text_func = function()
                    local n = self:cfg("flash_every")
                    return n > 0 and T(_("Clean flash every %1 taps"), n) or _("Clean flash: off")
                end,
                help_text = _("A full black-white flash clears e-ink ghosting. Tap to cycle 10 / 20 / 40 / off."),
                keep_menu_open = true,
                callback = function(tm)
                    local nxt = { [10] = 20, [20] = 40, [40] = 0, [0] = 10 }
                    self:setCfg("flash_every", nxt[self:cfg("flash_every")] or 20)
                    if tm then tm:updateItems() end
                end,
            },
            {
                text_func = function() return T(_("Pre-render ahead: %1 strips"), self:cfg("preload")) end,
                help_text = _("Strips drawn in the background below the screen. More = quicker taps, more memory. Tap to cycle 1–4."),
                keep_menu_open = true,
                callback = function(tm)
                    self:setCfg("preload", self:cfg("preload") % 4 + 1)
                    if tm then tm:updateItems() end
                end,
            },
            {
                text = _("Turn off night mode for webtoons"),
                help_text = _("Webtoon art reads best un-inverted. Night mode comes back when you leave the episode."),
                checked_func = function() return self:cfg("day_mode") end,
                callback = function() self:setCfg("day_mode", not self:cfg("day_mode")) end,
            },
            {
                text = _("Open next episode at the end"),
                checked_func = function() return self:cfg("auto_next") end,
                callback = function() self:setCfg("auto_next", not self:cfg("auto_next")) end,
            },
            {
                text = _("Smart scrolling for any webtoon CBZ"),
                help_text = _("Webtoon CBZs from other tools get the glide too; panels are detected on the device in the background and remembered per book. Applies when a book is opened."),
                checked_func = function() return self:cfg("glide_tall") end,
                callback = function() self:setCfg("glide_tall", not self:cfg("glide_tall")) end,
            },
        },
    }
end

return Webtoon
