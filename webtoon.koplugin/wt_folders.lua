--[[ Series folders in the file browser (CoverBrowser mosaic view).

A folder holding a .kowebtoon-series.json shows the series poster (fetched once in the background
while Wi-Fi is on, cached as .kowebtoon-cover.jpg) with the name under it, and a "continue" pill at the bottom of its tile showing
the episode you're on and how far in you are ("▶ Ep. 12 · 40%"). Tapping the pill opens that
episode where you left off (or the next one if it's finished); tapping the rest of the tile opens
the folder as usual. "Current" = the episode in that folder you opened most recently.

CoverBrowser keeps its tile class private, so we wrap MosaicMenu._updateItemsBuildUI and decorate
the built folder items. Any error leaves the stock tile alone.
]]
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local ffiutil = require("ffi/util")
local json = require("json")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local SERIES_FILE = ".kowebtoon-series.json"
local COVER_FILE = ".kowebtoon-cover.jpg"
local FACE = { "infont", 15 } -- same face CoverBrowser uses for a folder's item count
local TAP_ZONE = 0.35         -- bottom fraction of the tile that counts as "continue"

local Folders = {}
local art_cache = {}   -- "<path>|<w>x<h>" -> scaled BB, kept for the session (a few series, small)
local fetching = {}    -- dir -> os.time() of the last poster fetch attempt

local function inset() return 2 * Screen:scaleBySize(5) + Size.border.thick end

-- Fetch the poster in a subprocess (network can be slow); redraw the folder view when it lands.
local function fetchCover(dir)
    -- no connectivity check: NetworkMgr's can be wrong while the Kindle framework is stopped, and an
    -- offline attempt just fails fast in the subprocess. Retry at most every 10 minutes.
    if fetching[dir] and os.time() - fetching[dir] < 600 then return end
    fetching[dir] = os.time()
    local f = io.open(dir .. "/" .. SERIES_FILE)
    local ok, meta = pcall(json.decode, f and f:read("*a") or "")
    if f then f:close() end
    if not ok or type(meta) ~= "table" or not meta.url then return end
    local out = dir .. "/" .. COVER_FILE
    local pid = ffiutil.runInSubProcess(function()
        local data = require("wt_source").seriesCover(meta.url)
        if data and #data > 1000 then
            local w = io.open(out .. ".part", "wb")
            if w then w:write(data); w:close(); os.rename(out .. ".part", out) end
        end
    end)
    if not pid then return end
    local function poll()
        if not ffiutil.isSubProcessDone(pid) then return UIManager:scheduleIn(1, poll) end
        if lfs.attributes(out, "mode") ~= "file" then return end
        local FileManager = require("apps/filemanager/filemanager")
        local fc = FileManager.instance and FileManager.instance.file_chooser
        if fc then fc:refreshPath() end
    end
    UIManager:scheduleIn(1, poll)
end

-- The poster scaled to fill w x h (cropping the overflow), or nil.
local function art(path, w, h)
    local key = path .. "|" .. w .. "x" .. h
    if art_cache[key] == nil then
        art_cache[key] = false
        local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, path, false)
        if ok and bb then
            local s = math.max(w / bb:getWidth(), h / bb:getHeight())
            local nw, nh = math.ceil(bb:getWidth() * s), math.ceil(bb:getHeight() * s)
            local scaled = RenderImage:scaleBlitBuffer(bb, nw, nh, true)
            local out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
            out:blitFrom(scaled, 0, 0, math.floor((nw - w) / 2), math.floor((nh - h) / 2), w, h)
            scaled:free()
            art_cache[key] = out
        end
    end
    return art_cache[key] or nil
end

local function progress(file)
    local ok, BookList = pcall(require, "ui/widget/booklist")
    if not ok or not BookList.hasBookBeenOpened(file) then return 0, nil end
    local ds = BookList.getDocSettings(file)
    local summary = ds:readSetting("summary") or {}
    return ds:readSetting("percent_finished") or 0, summary.status
end

--- { label, target } for a series folder, or nil if `dir` isn't one.
function Folders.seriesInfo(dir)
    dir = dir:gsub("/$", "")
    if lfs.attributes(dir .. "/" .. SERIES_FILE, "mode") ~= "file" then return end
    local eps, index = {}, {}
    for f in lfs.dir(dir) do
        local no = f:match("^(%d+) %- .*%.cbz$")
        if no then table.insert(eps, { no = tonumber(no), file = dir .. "/" .. f }) end
    end
    if #eps == 0 then return end
    local cover = dir .. "/" .. COVER_FILE
    if lfs.attributes(cover, "mode") ~= "file" then fetchCover(dir); cover = nil end
    table.sort(eps, function(a, b) return a.no < b.no end)
    for i, e in ipairs(eps) do index[e.file] = i end

    local cur
    for __, h in ipairs(require("readhistory").hist) do -- newest first
        if index[h.file] then cur = index[h.file]; break end
    end
    if not cur then
        return { label = T(_("▶ Start Ep. %1"), eps[1].no), target = eps[1].file, cover = cover }
    end
    local pct, status = progress(eps[cur].file)
    if status == "complete" or pct >= 0.99 then
        local nxt = eps[cur + 1]
        if not nxt then return { label = T(_("✓ Caught up · Ep. %1"), eps[cur].no), cover = cover } end
        return { label = T(_("▶ Ep. %1"), nxt.no), target = nxt.file, cover = cover }
    end
    return { label = T(_("▶ Ep. %1 · %2%"), eps[cur].no, math.floor(pct * 100)), target = eps[cur].file,
        cover = cover }
end

local function open(file)
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:openFile(file)
    else
        require("apps/reader/readerui"):showReader(file)
    end
end

-- Where CoverBrowser draws a folder's bottom line: frame margin + border + padding in from the edge.
local function pill(item, x, y)
    local w = item._wt.w
    local th = item._wt.h
    local i = inset()
    local hpad, vpad = Screen:scaleBySize(10), Screen:scaleBySize(2) -- keep clear of the tile border
    local pw = math.min(w + 2 * hpad, item.width - 2 * i)
    return math.floor(x + (item.width - pw) / 2), y + item.height - i - th - vpad, pw, th + 2 * vpad
end

local function decorate(item)
    local info = Folders.seriesInfo(item.entry.path)
    if not info then return end
    local tw = TextWidget:new{ text = info.label, face = Font:getFace(FACE[1], FACE[2]) }
    local size = tw:getSize()
    tw:free()
    info.w, info.h = size.w, size.h
    item._wt = info
    item.mandatory = info.label
    if info.cover then
        info.name = item.text:gsub("/$", "")
        item.text = "" -- we draw the name under the poster ourselves
    end
    item:update()

    local orig_paint, orig_tap = item.paintTo, item.onTapSelect
    item.paintTo = function(self, bb, x, y)
        orig_paint(self, bb, x, y)
        local wt = self._wt
        local px, py, pw, ph = pill(self, x, y)
        if wt.cover then
            -- poster on top, series name between it and the pill
            local i = inset()
            local name = TextWidget:new{ text = wt.name, face = Font:getFace("cfont", 17), bold = true,
                max_width = self.width - 2 * i }
            local nh = name:getSize().h
            local gap = Screen:scaleBySize(4)
            local aw, ah = self.width - 2 * i, py - gap - nh - gap - (y + i)
            local img = ah > 20 and art(wt.cover, aw, ah)
            if img then bb:blitFrom(img, x + i, y + i, 0, 0, aw, ah) end
            name:paintTo(bb, math.floor(x + (self.width - name:getSize().w) / 2), py - gap - nh)
            name:free()
        end
        if wt.target then bb:invertRect(px, py, pw, ph) end
    end
    item.onTapSelect = function(self, arg, ges)
        local d = self.dimen
        if self._wt.target and ges and ges.pos and d and ges.pos.y >= d.y + d.h * (1 - TAP_ZONE) then
            local target = self._wt.target
            UIManager:nextTick(function() open(target) end)
            return true
        end
        return orig_tap(self, arg, ges)
    end
end

local function decorateMenu(menu)
    for __, row in ipairs(menu.layout or {}) do
        for __, item in ipairs(row) do
            if item.is_directory and not item._wt and item.entry and item.entry.path then
                local ok, err = pcall(decorate, item)
                if not ok then logger.warn("webtoon: folder tile failed", item.entry.path, err) end
            end
        end
    end
end

function Folders.hook()
    local ok, MosaicMenu = pcall(require, "mosaicmenu")
    if not ok or type(MosaicMenu) ~= "table" or MosaicMenu._wt_hooked then return end
    MosaicMenu._wt_hooked = true
    local orig = MosaicMenu._updateItemsBuildUI
    local wrapped = function(self, ...)
        local ret = orig(self, ...)
        decorateMenu(self)
        return ret
    end
    MosaicMenu._updateItemsBuildUI = wrapped
    -- CoverBrowser copies the function onto FileChooser when it sets up the view, which already
    -- happened (it loads before us); swap that copy too, and redraw whatever is on screen.
    local FileChooser = require("ui/widget/filechooser")
    if FileChooser._updateItemsBuildUI == orig then FileChooser._updateItemsBuildUI = wrapped end
    UIManager:nextTick(function()
        local FileManager = require("apps/filemanager/filemanager")
        local fc = FileManager.instance and FileManager.instance.file_chooser
        if fc and fc._updateItemsBuildUI == wrapped then fc:refreshPath() end
    end)
    logger.info("webtoon: series folder tiles on")
end

return Folders
