--[[ On-device webtoon library: search, your series, episode lists, background downloads.

Series live in <download folder>/<Series>/ with a .kowebtoon-series.json (url, title, author);
episodes are "<NNN> - <title>.cbz" next to it. Downloads run in a subprocess one queue at a
time; the UI polls a small status file and shows a notification as each episode lands.
]]
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Device = require("device")
local ffiutil = require("ffi/util")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template
local Source = require("wt_source")

local SERIES_FILE = ".kowebtoon-series.json"
local MAX_BATCH = 10

local Library = {
    queue = {},       -- pending { series = {...}, dir = ..., ep = {...} }
    job = nil,        -- running { pid, status_file, items, reported }
}

local function readJSON(p)
    local f = io.open(p, "r"); if not f then return end
    local d = f:read("*a"); f:close()
    local ok, v = pcall(json.decode, d)
    return ok and v or nil
end

local function writeJSON(p, v)
    local f = io.open(p, "w"); if not f then return end
    f:write(json.encode(v)); f:close()
end

function Library:root()
    local s = G_reader_settings:readSetting("webtoon") or {}
    if s.download_dir then return s.download_dir end
    local home = G_reader_settings:readSetting("home_dir") or DataStorage:getDataDir()
    return home .. "/Webtoons"
end

function Library:seriesDir(title)
    return self:root() .. "/" .. Source.safeName(title)
end

--- followed/downloaded series: { {title, author, url, dir}, ... }
function Library:allSeries()
    local out, root = {}, self:root()
    if lfs.attributes(root, "mode") ~= "directory" then return out end
    for name in lfs.dir(root) do
        local dir = root .. "/" .. name
        local meta = name:sub(1, 1) ~= "." and readJSON(dir .. "/" .. SERIES_FILE)
        if meta and meta.url then
            meta.dir = dir
            meta.title = meta.title or name
            table.insert(out, meta)
        end
    end
    table.sort(out, function(a, b) return a.title:lower() < b.title:lower() end)
    return out
end

--- downloaded episode files of a series dir, by episode number
local function downloaded(dir)
    local files = {}
    if lfs.attributes(dir, "mode") ~= "directory" then return files end
    for f in lfs.dir(dir) do
        local no = f:match("^(%d+) %- .*%.cbz$")
        if no then files[tonumber(no)] = dir .. "/" .. f end
    end
    return files
end

local function readState(path)
    if not DocSettings:hasSidecarFile(path) then return nil end
    local ds = DocSettings:open(path)
    local summary = ds:readSetting("summary") or {}
    local pct = ds:readSetting("percent_finished") or 0
    if summary.status == "complete" or pct >= 0.97 then return "done" end
    if pct > 0.02 then return math.floor(pct * 100) end
    return nil
end

-- run fn in a subprocess behind a dismissable "please wait" message
local function fetch(msg, fn)
    local done, a, b = Trapper:dismissableRunInSubprocess(fn, msg)
    if not done then return nil, "cancelled" end
    return a, b
end

---------------------------------------------------------------- UI

function Library:openMenu(title, items)
    if self.menu then UIManager:close(self.menu) end
    self.menu = Menu:new{
        title = title,
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        single_line = true,
        onMenuHold = function(_, item) if item.hold_callback then item.hold_callback() end return true end,
        close_callback = function() UIManager:close(self.menu); self.menu = nil end,
    }
    UIManager:show(self.menu)
end

function Library:showHome()
    local items = {
        { text = _("🔍  Search webtoons…"), callback = function() self:askSearch() end },
        { text = _("🔄  Check for new episodes"), callback = function() self:checkNew() end },
    }
    if self.job or #self.queue > 0 then
        table.insert(items, { text = _("⬇  Downloads"), mandatory = self:statusText(), callback = function() self:showStatus() end })
    end
    for __, s in ipairs(self:allSeries()) do
        local n = 0
        for __ in pairs(downloaded(s.dir)) do n = n + 1 end
        table.insert(items, { text = s.title, mandatory = T(_("%1 downloaded"), n),
            callback = function() self:showSeries(s) end })
    end
    self:openMenu(_("Webtoons"), items)
end

function Library:askSearch()
    local dialog
    dialog = InputDialog:new{
        title = _("Search webtoons"),
        input_hint = _("Series name"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local q = dialog:getInputText()
                UIManager:close(dialog)
                if q and q:match("%S") then self:search(q) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Library:search(q)
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local results, err = fetch(T(_("Searching for “%1”…"), q), function() return Source.search(q) end)
            if not results then
                if err ~= "cancelled" then UIManager:show(InfoMessage:new{ text = T(_("Search failed: %1"), err) }) end
                return
            end
            if #results == 0 then
                UIManager:show(InfoMessage:new{ text = _("No webtoons found.") })
                return
            end
            local items = {}
            for __, r in ipairs(results) do
                table.insert(items, { text = r.title, mandatory = r.canvas and (r.author .. " · Canvas") or r.author,
                    callback = function() self:showSeries({ title = r.title, author = r.author, url = r.url,
                        dir = self:seriesDir(r.title) }) end })
            end
            self:openMenu(T(_("Results for “%1”"), q), items)
        end)
    end)
end

function Library:showSeries(series)
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local title, eps = fetch(T(_("Loading %1…"), series.title), function() return Source.episodes(series.url) end)
            if not title then
                if eps ~= "cancelled" then UIManager:show(InfoMessage:new{ text = T(_("Couldn't load episodes: %1"), eps) }) end
                return
            end
            series.title = series.title or title
            series.eps = eps
            self:renderSeries(series)
        end)
    end)
end

function Library:renderSeries(series)
    local have = downloaded(series.dir)
    local queued = {}
    for __, q in ipairs(self.queue) do if q.dir == series.dir then queued[q.ep.no] = true end end
    for __, it in ipairs(self.job and self.job.items or {}) do if it.dir == series.dir then queued[it.ep.no] = true end end

    local function unread_after()
        local list, last_read = {}, 0
        for no, path in pairs(have) do if readState(path) == "done" then last_read = math.max(last_read, no) end end
        for __, ep in ipairs(series.eps) do
            if ep.no > last_read and not have[ep.no] and not queued[ep.no] then table.insert(list, ep) end
        end
        return list
    end

    local items = {
        { text = T(_("⬇  Download next %1 unread"), 5), callback = function()
            self:enqueue(series, { unpack(unread_after(), 1, 5) })
        end },
        { text = _("⬇  Download a range…"), callback = function() self:askRange(series) end },
    }
    for i = #series.eps, 1, -1 do       -- newest first, like the site
        local ep = series.eps[i]
        local path = have[ep.no]
        local mark
        if path then
            local st = readState(path)
            mark = st == "done" and "✓" or (st and (st .. "%")) or "↓"
        elseif queued[ep.no] then
            mark = "…"
        end
        table.insert(items, {
            text = ep.title, mandatory = mark,
            callback = function()
                if path then self:openBook(path) else self:enqueue(series, { ep }) end
            end,
        })
    end
    self:openMenu(series.title, items)
end

function Library:askRange(series)
    local first, last = series.eps[1].no, series.eps[#series.eps].no
    local dialog
    dialog = InputDialog:new{
        title = T(_("Episodes %1–%2"), first, last),
        input_hint = "e.g. 4-10",
        description = T(_("Up to %1 at a time."), MAX_BATCH),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Download"), is_enter_default = true, callback = function()
                local a, b = (dialog:getInputText() or ""):match("^%s*(%d+)%s*%-?%s*(%d*)%s*$")
                UIManager:close(dialog)
                a = tonumber(a); b = tonumber(b) or a
                if not a then return end
                local list = {}
                for __, ep in ipairs(series.eps) do if ep.no >= a and ep.no <= b then table.insert(list, ep) end end
                self:enqueue(series, list)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Library:openBook(path)
    if self.menu then UIManager:close(self.menu); self.menu = nil end
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then ReaderUI.instance:switchDocument(path)
    else ReaderUI:showReader(path) end
end

---------------------------------------------------------------- downloads

function Library:enqueue(series, eps)
    if not eps or #eps == 0 then
        UIManager:show(Notification:new{ text = _("Nothing new to download.") })
        return
    end
    lfs.mkdir(self:root())
    lfs.mkdir(series.dir)
    writeJSON(series.dir .. "/" .. SERIES_FILE, { url = series.url, title = series.title, author = series.author })
    local n = 0
    for __, ep in ipairs(eps) do
        if n >= MAX_BATCH then break end
        table.insert(self.queue, { series = { title = series.title, url = series.url }, dir = series.dir, ep = ep })
        n = n + 1
    end
    UIManager:show(Notification:new{ text = T(_("Downloading %1 episode(s) in the background"), n) })
    if self.menu and series.eps then self:renderSeries(series) end
    NetworkMgr:runWhenOnline(function() self:startJob() end)
end

function Library:statusText()
    if not self.job then return T(_("%1 queued"), #self.queue) end
    local st = readJSON(self.job.status_file) or {}
    return T(_("%1/%2 · %3%"), (st.i or 1), #self.job.items, math.floor((st.frac or 0) * 100))
end

function Library:showStatus()
    local lines = {}
    if self.job then
        local st = readJSON(self.job.status_file) or {}
        for i, it in ipairs(self.job.items) do
            local mark = (st.done and st.done[tostring(i)]) and "✓" or (st.errors and st.errors[tostring(i)]) and "✗"
                or (st.i == i) and (math.floor((st.frac or 0) * 100) .. "%") or "…"
            table.insert(lines, mark .. "  " .. it.series.title .. " · " .. it.ep.title)
        end
    end
    for __, it in ipairs(self.queue) do table.insert(lines, "…  " .. it.series.title .. " · " .. it.ep.title) end
    UIManager:show(InfoMessage:new{ text = #lines > 0 and table.concat(lines, "\n") or _("No downloads.") })
end

function Library:startJob()
    if self.job or #self.queue == 0 then return end
    local items = self.queue
    self.queue = {}
    local status_file = DataStorage:getDataDir() .. "/cache/kowebtoon-status.json"
    os.remove(status_file)
    local screen = Device.screen
    local page_w = math.min(screen:getWidth(), screen:getHeight())
    local page_h = math.max(screen:getWidth(), screen:getHeight())
    local margin = (G_reader_settings:readSetting("webtoon") or {}).margin or 0.05

    local pid = ffiutil.runInSubProcess(function()
        local Builder = require("wt_builder")
        local st = { done = {}, errors = {}, paths = {} }
        for i, it in ipairs(items) do
            st.i, st.frac = i, 0
            writeJSON(status_file, st)
            local ok, path, err = pcall(Builder.build, it.ep, it.dir, {
                page_w = page_w, page_h = page_h, margin = margin, series = it.series.title,
                progress = function(a, b) st.frac = a / b; writeJSON(status_file, st) end,
            })
            if ok and path then
                st.done[tostring(i)] = true; st.paths[tostring(i)] = path
            else
                st.errors[tostring(i)] = tostring(ok and err or path)
            end
            writeJSON(status_file, st)
        end
        st.finished = true
        writeJSON(status_file, st)
    end)
    if not pid then
        UIManager:show(InfoMessage:new{ text = _("Couldn't start the download.") })
        return
    end
    self.job = { pid = pid, status_file = status_file, items = items, reported = {} }
    UIManager:scheduleIn(2, function() self:poll() end)
end

function Library:poll()
    local job = self.job
    if not job then return end
    local st = readJSON(job.status_file) or {}
    for i, it in ipairs(job.items) do
        local k = tostring(i)
        if not job.reported[k] and (st.done and st.done[k] or st.errors and st.errors[k]) then
            job.reported[k] = true
            if st.done[k] then
                UIManager:show(Notification:new{ text = T(_("Ready: %1 · %2"), it.series.title, it.ep.title) })
            else
                logger.warn("webtoon: download failed", it.ep.title, st.errors[k])
                UIManager:show(Notification:new{ text = T(_("Failed: %1 (%2)"), it.ep.title, st.errors[k]) })
            end
        end
    end
    if ffiutil.isSubProcessDone(job.pid) then
        self.job = nil
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then FileManager.instance:onRefresh() end
        if #self.queue > 0 then return self:startJob() end
        return
    end
    UIManager:scheduleIn(2, function() self:poll() end)
end

--- for every series: queue episodes newer than the newest downloaded one (up to MAX_BATCH)
function Library:checkNew()
    local all = self:allSeries()
    if #all == 0 then
        UIManager:show(InfoMessage:new{ text = _("No webtoons yet. Search for one first.") })
        return
    end
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local found = 0
            for __, s in ipairs(all) do
                local newest = 0
                for no in pairs(downloaded(s.dir)) do newest = math.max(newest, no) end
                local __, eps = fetch(T(_("Checking %1…"), s.title), function() return Source.episodes(s.url, newest) end)
                if type(eps) == "table" then
                    local fresh = {}
                    for __, ep in ipairs(eps) do if ep.no > newest then table.insert(fresh, ep) end end
                    if #fresh > 0 then
                        found = found + #fresh
                        self:enqueue(s, fresh)
                    end
                end
            end
            if found == 0 then UIManager:show(InfoMessage:new{ text = _("You're all caught up."), timeout = 3 }) end
        end)
    end)
end

return Library
