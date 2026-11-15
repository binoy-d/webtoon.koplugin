--[[ Builds one episode CBZ on the device (runs inside a download subprocess).

Same output as the desktop converter: [title cover] + strips sized to the screen width (with a
small side margin), greyscale JPEGs, plus kowebtoon.json with the gaps between panels.
]]
local Archiver = require("ffi/archiver")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local ffi = require("ffi")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Source = require("wt_source")

local M = {}

local BLANK = 6            -- a row is blank if all its pixels are within this many grey levels

local function readFile(p)
    local f = io.open(p, "rb"); if not f then return end
    local d = f:read("*a"); f:close(); return d
end

local function toGray(bb)
    if bb:getType() == Blitbuffer.TYPE_BB8 then return bb end
    local g = Blitbuffer.new(bb:getWidth(), bb:getHeight(), Blitbuffer.TYPE_BB8)
    g:blitFrom(bb)
    bb:free()
    return g
end

-- centre bb (freed) on a page_w-wide strip; each row's margins take the colour of that row's
-- edge pixels: white gutters get white margins, dark full-bleed scenes get dark ones
local function padSides(bb, page_w)
    local art_w, h = bb:getWidth(), bb:getHeight()
    local left = math.floor((page_w - art_w) / 2)
    local right = page_w - art_w - left
    local out = Blitbuffer.new(page_w, h, Blitbuffer.TYPE_BB8)
    out:blitFrom(bb, left, 0)
    bb:free()
    local base, stride = ffi.cast("uint8_t*", out.data), tonumber(out.stride)
    local k = math.min(3, art_w)
    for y = 0, h - 1 do
        local row = base + y * stride
        local l, r = 0, 0
        for i = 0, k - 1 do l = l + row[left + i]; r = r + row[left + art_w - 1 - i] end
        ffi.fill(row, left, math.floor(l / k))
        ffi.fill(row + left + art_w, right, math.floor(r / k))
    end
    return out
end

-- decode -> grey -> art width -> centred on a white page-width strip
local function prepareStrip(data, page_w, art_w)
    local bb = RenderImage:renderImageData(data, #data, false)
    if not bb then return nil, "could not decode image" end
    bb = toGray(bb)
    if bb:getWidth() ~= art_w then
        local h = math.max(1, math.floor(bb:getHeight() * art_w / bb:getWidth() + 0.5))
        bb = toGray(RenderImage:scaleBlitBuffer(bb, art_w, h, true))
    end
    if art_w == page_w then return bb end
    return padSides(bb, page_w)
end

-- one boolean per row: is it blank?
local function blankRows(bb, into)
    local w, h = bb:getWidth(), bb:getHeight()
    local base = ffi.cast("uint8_t*", bb.data)
    local stride = tonumber(bb.stride)
    for y = 0, h - 1 do
        local row = base + y * stride
        local lo, hi, blank = row[0], row[0], true
        for x = 1, w - 1 do
            local v = row[x]
            if v < lo then lo = v elseif v > hi then hi = v end
            if hi - lo > BLANK then blank = false; break end
        end
        into[#into + 1] = blank
    end
end

local function encodeJpeg(bb, tmp)
    bb:writeToFile(tmp, "jpg", 85, true)
    local d = readFile(tmp)
    os.remove(tmp)
    return d
end

-- the biggest panel in the middle 80% of the episode, as {start_row, end_row}
--- Top row of the cover-art window: art_h rows, full width, skipping the first 10% (title card) and
-- the last 5%. Prefers windows that are mostly drawn and start (and end) on a blank row, so panels
-- begin whole and speech bubbles aren't cut. Same idea as the desktop converter's pick_art_window.
local function pickArtWindow(blank, total, art_h)
    if total <= art_h then return 0 end
    local busy = { [0] = 0 }
    for y = 1, total do busy[y] = busy[y - 1] + (blank[y] and 0 or 1) end
    local lo = math.floor(total * 0.1)
    local hi = math.max(lo, math.floor(total * 0.95) - art_h)
    local best, best_t = -1, lo
    for t = lo, hi, 2 do
        local score = (busy[t + art_h] - busy[t]) / art_h
            * (1 + (blank[t + 1] and 2 or 0) + (blank[t + art_h] and 0.5 or 0))
        if score > best then best, best_t = score, t end
    end
    return best_t
end

local function drawCover(page_w, page_h, panel_bb, series, ep_no, ep_title)
    local cover = Blitbuffer.new(page_w, page_h, Blitbuffer.TYPE_BB8)
    cover:fill(Blitbuffer.COLOR_WHITE)
    local art_h = math.floor(page_h * 0.62)
    if panel_bb then
        -- zoom past "fit" (up to 1.6x, never past "fill") so the art fills the box but little of the
        -- panel (speech bubbles!) is cropped; overflow is trimmed keeping more of the panel's top
        local pw, ph = panel_bb:getWidth(), panel_bb:getHeight()
        local fit = math.min(page_w / pw, art_h / ph)
        local s = math.min(math.max(page_w / pw, art_h / ph), fit * 1.6)
        local nw, nh = math.max(1, math.floor(pw * s + 0.5)), math.max(1, math.floor(ph * s + 0.5))
        local scaled = toGray(RenderImage:scaleBlitBuffer(panel_bb, nw, nh, true))
        local w, h = math.min(nw, page_w), math.min(nh, art_h)
        cover:blitFrom(scaled, math.floor((page_w - w) / 2), math.floor((art_h - h) / 2),
            math.floor((nw - w) / 2), math.floor((nh - h) * 0.3), w, h)
        scaled:free()
    end
    cover:paintRect(0, art_h, page_w, math.max(3, math.floor(page_w / 250)), Blitbuffer.COLOR_BLACK)
    local m = math.floor(page_w * 0.07)
    local y = art_h + math.floor(page_h * 0.035)
    local scale = Device.screen:scaleBySize(1000) / 1000
    local px = function(v) return math.floor(v / scale + 0.5) end   -- getFace scales sizes by DPI
    local small = TextWidget:new{ text = "EPISODE " .. ep_no, face = Font:getFace("NotoSans-Bold.ttf", px(page_w * 0.042)), fgcolor = Blitbuffer.gray(0.8) }
    small:paintTo(cover, m, y); y = y + small:getSize().h + math.floor(page_w * 0.015)
    local big = TextBoxWidget:new{ text = series, face = Font:getFace("NotoSerif-Bold.ttf", px(page_w * 0.09)), width = page_w - 2 * m, height_adjust = true }
    big:paintTo(cover, m, y); y = y + big:getSize().h + math.floor(page_w * 0.02)
    local sub = TextBoxWidget:new{ text = ep_title, face = Font:getFace("NotoSerif-Regular.ttf", px(page_w * 0.06)), width = page_w - 2 * m, fgcolor = Blitbuffer.gray(0.9) }
    sub:paintTo(cover, m, y)
    small:free(); big:free(); sub:free()
    return cover
end

local FIT_REDUCTION = 0.12  -- shrink panels at most this much to fit them on one screen

--- Panels only slightly taller than the screen are shrunk to fit on one screen (like the desktop
-- converter). Works on the encoded strips: only strips that touch a fitted panel are decoded and
-- re-cut, the rest are kept as they are. Returns strips, heights, blank, panels_fitted.
local function fitPanels(strips, heights, blank, page_w, page_h, min_run, tmpjpg)
    local tops, total = {}, 0
    for i, h in ipairs(heights) do tops[i] = total; total = total + h end
    local target = math.floor(page_h * 0.97)            -- a sliver of breathing room
    local limit = target / (1 - FIT_REDUCTION)
    -- panels: [end of one blank run, start of the next)
    local fits, prev, y = {}, 0, 1
    local function consider(a, b)
        if b - a > target and b - a <= limit then table.insert(fits, { a, b }) end
    end
    while y <= total do
        if blank[y] then
            local st = y
            while y <= total and blank[y] do y = y + 1 end
            if y - st >= min_run then consider(prev, st - 1); prev = y - 1 end
        else
            y = y + 1
        end
    end
    consider(prev, total)
    if #fits == 0 then return strips, heights, blank, 0 end

    -- rows [a, b) of the episode as one buffer, decoding strips on demand (keeps the last two)
    local cache = {}
    local function strip(i)
        for __, c in ipairs(cache) do if c.i == i then return c.bb end end
        local bb = toGray(RenderImage:renderImageData(strips[i], #strips[i], false))
        table.insert(cache, 1, { i = i, bb = bb })
        if #cache > 2 then table.remove(cache).bb:free() end
        return bb
    end
    local function rows(a, b)
        local out = Blitbuffer.new(page_w, b - a, Blitbuffer.TYPE_BB8)
        for i = 1, #strips do
            local s0, s1 = tops[i], tops[i] + heights[i]
            if s1 > a and s0 < b then
                local from, to = math.max(a, s0), math.min(b, s1)
                out:blitFrom(strip(i), 0, from - a, 0, from - s0, page_w, to - from)
            end
        end
        return out
    end

    local new_strips, new_heights, new_blank = {}, {}, {}
    local function emit(bb, blank_from)
        local h = bb:getHeight()
        if blank_from then
            for r = 1, h do new_blank[#new_blank + 1] = blank[blank_from + r] end
        else
            blankRows(bb, new_blank)
        end
        new_heights[#new_heights + 1] = h
        new_strips[#new_strips + 1] = encodeJpeg(bb, tmpjpg)
        bb:free()
    end
    -- plain rows [a, b): whole strips are kept as-is, partial ones are cropped
    local function plain(a, b)
        for i = 1, #strips do
            local s0, s1 = tops[i], tops[i] + heights[i]
            if s1 > a and s0 < b then
                if s0 >= a and s1 <= b then
                    new_strips[#new_strips + 1] = strips[i]
                    new_heights[#new_heights + 1] = heights[i]
                    for r = s0 + 1, s1 do new_blank[#new_blank + 1] = blank[r] end
                else
                    local from, to = math.max(a, s0), math.min(b, s1)
                    emit(rows(from, to), from)
                end
            end
        end
    end
    local at = 0
    for __, f in ipairs(fits) do
        local a, b = f[1], f[2]
        if a > at then plain(at, a) end
        local panel = rows(a, b)
        local k = target / (b - a)
        local small = toGray(RenderImage:scaleBlitBuffer(panel, math.max(1, math.floor(page_w * k + 0.5)), target, true))
        emit(padSides(small, page_w))
        at = b
    end
    if at < total then plain(at, total) end
    for __, c in ipairs(cache) do c.bb:free() end
    return new_strips, new_heights, new_blank, #fits
end

--- Build `<dir>/<NNN> - <title>.cbz`.
-- opts: page_w, page_h, margin (fraction per side), series, progress(fn(done, total))
function M.build(ep, dir, opts)
    local urls, err = Source.images(ep.url)
    if not urls then return nil, err end
    if #urls == 0 then return nil, "locked or not free" end
    local page_w, page_h = opts.page_w, opts.page_h
    local art_w = math.floor(page_w * (1 - 2 * (opts.margin or 0)) + 0.5)
    local tmpdir = dir .. "/.kowebtoon-tmp"
    lfs.mkdir(tmpdir)
    local tmpjpg = tmpdir .. "/s.jpg"

    local strips, heights, blank = {}, {}, {}
    for i, u in ipairs(urls) do
        local data, e = Source.get(u)
        if not data then return nil, "download failed: " .. tostring(e) end
        local bb, e2 = prepareStrip(data, page_w, art_w)
        if not bb then return nil, e2 end
        blankRows(bb, blank)
        heights[i] = bb:getHeight()
        strips[i] = encodeJpeg(bb, tmpjpg)
        bb:free()
        if opts.progress then opts.progress(i, #urls) end
    end

    local min_run = math.max(8, math.floor(page_w / 60))
    if opts.fit ~= false then
        local fitted
        strips, heights, blank, fitted = fitPanels(strips, heights, blank, page_w, page_h, min_run, tmpjpg)
        if fitted > 0 then logger.info("webtoon: fitted", fitted, "panel(s) to the screen") end
    end

    -- gaps between panels: centres of long-enough blank runs, as {page, fraction}; page 1 = cover
    local tops, acc = {}, 0
    for i, h in ipairs(heights) do tops[i] = acc; acc = acc + h end
    local total = acc
    local gaps, y = {}, 1
    local function locate(g)
        local p = #tops
        while p > 1 and tops[p] > g do p = p - 1 end
        return p
    end
    while y <= total do
        if blank[y] then
            local s = y
            while y <= total and blank[y] do y = y + 1 end
            if y - s >= min_run then
                -- {page, fraction} of the gap's centre, then of where the next panel starts
                local g = math.floor((s + y) / 2) - 1
                local e = math.min(y - 1, total - 1)
                local p, pe = locate(g), locate(e)
                table.insert(gaps, { p + 1, math.floor((g - tops[p]) / heights[p] * 100000) / 100000,
                    pe + 1, math.floor((e - tops[pe]) / heights[pe] * 100000) / 100000 })
            end
        end
        y = y + 1
    end
    -- cover art: one screen-wide window of the episode, re-decoded from the strips it spans
    local art_h = math.floor(page_h * 0.62) -- keep in sync with drawCover
    local top = pickArtWindow(blank, total, art_h)
    local span = { top, math.min(total, top + art_h) }
    local panel_h = span[2] - span[1]
    local panel = Blitbuffer.new(page_w, math.max(1, panel_h), Blitbuffer.TYPE_BB8)
    panel:fill(Blitbuffer.COLOR_WHITE)
    for i = 1, #strips do
        local s0, s1 = tops[i], tops[i] + heights[i]
        if s1 > span[1] and s0 < span[1] + panel_h then
            local bb = RenderImage:renderImageData(strips[i], #strips[i], false)
            if bb then
                bb = toGray(bb)
                local from = math.max(0, span[1] - s0)
                local to_y = math.max(0, s0 - span[1])
                panel:blitFrom(bb, 0, to_y, 0, from, page_w, math.min(heights[i] - from, panel_h - to_y))
                bb:free()
            end
        end
    end
    local series = opts.series or "Webtoon"
    local cover = drawCover(page_w, page_h, panel, series, ep.no, Source.shortTitle(ep.title))
    panel:free()
    local cover_jpg = encodeJpeg(cover, tmpjpg)
    cover:free()

    local name = string.format("%03d - %s.cbz", ep.no, Source.safeName(ep.title))
    local path = dir .. "/" .. name
    local w = Archiver.Writer:new()
    if not w:open(path .. ".part", "zip") then return nil, "cannot write " .. path end
    w:setZipCompression("store")
    w:addFileFromMemory("001.jpg", cover_jpg)
    for i, d in ipairs(strips) do w:addFileFromMemory(string.format("%03d.jpg", i + 1), d) end
    local title = series .. " " .. ep.title
    w:addFileFromMemory("ComicInfo.xml", "<?xml version='1.0'?><ComicInfo><Title>"
        .. title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;") .. "</Title></ComicInfo>")
    w:addFileFromMemory("kowebtoon.json", json.encode({
        kowebtoon = 2, title = title, width = page_w, first_page = 2, gaps = gaps }))
    w:close()
    os.rename(path .. ".part", path)
    lfs.rmdir(tmpdir)
    return path
end

return M
