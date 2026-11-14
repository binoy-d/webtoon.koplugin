--[[ webtoons.com access for webtoon.koplugin: search, episode lists, image URLs, downloads.
Plain HTTP + Lua patterns, usable from the UI process and from download subprocesses.
Only free-to-read episodes are listed by the site's viewer pages.
]]
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local util = require("util")

local M = {}

local UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
local BASE = "https://www.webtoons.com"

local function request(url)
    local sink = {}
    socketutil:set_timeout(15, 120)
    local ok, code, _, status = pcall(function()
        return socket.skip(1, http.request{
            url = url,
            method = "GET",
            headers = { ["user-agent"] = UA, ["referer"] = BASE .. "/" },
            sink = ltn12.sink.table(sink),
            redirect = true,
        })
    end)
    socketutil:reset_timeout()
    if ok and code == 200 then return table.concat(sink) end
    return nil, (ok and (status or tostring(code))) or tostring(code)
end

--- GET with retries; returns body or nil, error.
function M.get(url)
    local body, err
    for attempt = 1, 3 do
        body, err = request(url)
        if body then return body end
        socket.sleep(attempt * 2)
    end
    return nil, err
end

local function utf8char(cp)
    if util.unicodeCodepointToUtf8 then return util.unicodeCodepointToUtf8(cp) end
    return cp < 128 and string.char(cp) or "?"
end

function M.unescape(s)
    if not s then return s end
    s = s:gsub("&#x(%x+);", function(h) return utf8char(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8char(tonumber(d)) end)
    s = s:gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&nbsp;", " ")
    s = s:gsub("&amp;", "&")
    return util.trim(s)
end

--- Search originals. Returns { {title, author, url}, ... } or nil, err.
function M.search(query)
    local body, err = M.get(BASE .. "/en/search?keyword=" .. socket_url.escape(query))
    if not body then return nil, err end
    local results, seen = {}, {}
    for href, title, author in body:gmatch(
            '<a href="([^"]-/list%?title_no=%d+)"%s+class="link _card_item".-<strong class="title">(.-)</strong>%s*<div class="author">(.-)</div>') do
        if not seen[href] then
            seen[href] = true
            table.insert(results, { title = M.unescape(title), author = M.unescape(author:gsub("<.->", "")), url = href,
                canvas = href:find("/canvas/", 1, true) ~= nil })
        end
    end
    -- official (Originals) series first, fan-made Canvas series after
    local ordered = {}
    for _, r in ipairs(results) do if not r.canvas then table.insert(ordered, r) end end
    for _, r in ipairs(results) do if r.canvas then table.insert(ordered, r) end end
    return ordered
end

--- Episodes of a series, oldest first: series title, { {no, title, url}, ... }.
-- With stop_at, paging stops once a page only has episodes <= stop_at (newest pages come first).
function M.episodes(list_url, stop_at)
    local base = list_url:gsub("&page=%d+", "")
    local eps, by_no, series = {}, {}, nil
    for page = 1, 200 do
        local body, err = M.get(base .. "&page=" .. page)
        if not body then
            if page == 1 then return nil, err end
            break
        end
        series = series or M.unescape(body:match('<meta property="og:title" content="([^"]+)"'))
        local new, lowest = 0, math.huge
        for no, href, subj in body:gmatch(
                '<li class="_episodeItem[^"]*"[^>]-data%-episode%-no="(%d+)".-href="([^"]+)".-<span class="subj"><span>(.-)</span>') do
            no = tonumber(no)
            lowest = math.min(lowest, no)
            if not by_no[no] then
                by_no[no] = true
                new = new + 1
                table.insert(eps, { no = no, title = M.unescape(subj), url = M.unescape(href) })
            end
        end
        if new == 0 or (stop_at and lowest <= stop_at) then break end
    end
    table.sort(eps, function(a, b) return a.no < b.no end)
    return series or "Webtoon", eps
end

--- Image strip URLs of one episode (empty if locked).
function M.images(viewer_url)
    local body, err = M.get(viewer_url)
    if not body then return nil, err end
    local urls = {}
    for u in body:gmatch('<img[^>]+class="_images"[^>]+data%-url="([^"]+)"') do
        table.insert(urls, M.unescape(u))
    end
    return urls
end

--- "Ep. 4 - Some Title" -> "Some Title"
function M.shortTitle(subj)
    return (subj:gsub("^Ep%.%s*%d+%s*[-:–]%s*", ""):gsub("^Episode%s*%d+%s*[-:–]%s*", ""))
end

function M.safeName(s)
    return util.trim((s:gsub('[\\/:*?"<>|]+', "")))
end

return M
