-- legado 安卓 app Web 服务客户端(仅漫画所需接口)
local logger = require("logger")
local util = require("util")
local socket_url = require("socket.url")
local Screen = require("device").screen
local httpreq = require("comic/httpreq")
local settings = require("comic/settings")

local M = {}

local function tohex(raw)
    if type(raw) ~= "string" then return "" end
    if #raw == 64 then return raw end -- 已是 hex
    return (raw:gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end

-- legado app 鉴权: key = sha256("user:pwd") hex
function M.authKey()
    local user = tostring(settings.get("user") or "")
    local pwd = tostring(settings.get("pwd") or "")
    if user == "" then return nil end
    local sha = require("ffi/sha2")
    local ok, digest = pcall(sha.sha256, user .. ":" .. pwd)
    if not ok or type(digest) ~= "string" or #digest == 0 then return nil end
    return tohex(digest)
end

local function addKey(params)
    local key = M.authKey()
    if key then params.key = key end
    return params
end

function M.buildUrl(path, params)
    local base = tostring(settings.get("server") or ""):gsub("/+$", "")
    local query = {}
    addKey(params or {})
    for k, v in pairs(params or {}) do
        query[#query + 1] = k .. "=" .. util.urlEncode(tostring(v))
    end
    local q = #query > 0 and ("?" .. table.concat(query, "&")) or ""
    return base .. path .. q
end

-- 请求并解析 JSON, 返回 data 或 nil, err
function M.getJSON(path, params, timeout)
    local url = M.buildUrl(path, params)
    local ok, resp = httpreq.request({
        url = url,
        timeout = timeout or 10,
        maxtime = (timeout or 10) + 15,
    })
    if not ok then return nil, resp end
    local JSON = require("json")
    local okj, body = pcall(JSON.decode, resp.data)
    if not okj or type(body) ~= "table" then
        return nil, "返回内容不是有效 JSON"
    end
    if body.isSuccess == false then
        local msg = body.errorMsg or body.data or "请求失败"
        if type(msg) ~= "string" then msg = tostring(msg) end
        return nil, msg
    end
    return body.data
end

function M.getBookshelf()
    return M.getJSON("/getBookshelf", { refresh = 0, v = os.time() }, 10)
end

function M.getChapterList(bookUrl)
    return M.getJSON("/getChapterList", { url = bookUrl, v = os.time() }, 15)
end

function M.getBookContent(bookUrl, index)
    return M.getJSON("/getBookContent", { url = bookUrl, index = index, v = os.time() }, 25)
end

-- ===== 章节索引换算 =====
-- 注意: /getBookContent 的 index 不是"目录第几项", 而是章节自身的 index 字段
-- (Legado 内部从 0 开始编号)。两者在多数书里恰好差 1, 但会随书源/刷新目录变化,
-- 所以一律以 /getChapterList 返回的 chapter.index 为准。
local chapter_index_map = {} -- bookUrl -> { [目录位置] = API index }

local function buildIndexMap(chapters)
    local map = {}
    if type(chapters) ~= "table" then return map end
    for i, ch in ipairs(chapters) do
        local api_index
        if type(ch) == "table" then api_index = tonumber(ch.index) end
        if api_index == nil then api_index = i - 1 end -- 兜底: Legado 索引从 0 开始
        map[i] = api_index
    end
    return map
end

-- 书架取到目录后调用, 把映射喂进来 (省掉阅读器再请求一次)
function M.seedChapterList(bookUrl, chapters)
    if type(bookUrl) ~= "string" or type(chapters) ~= "table" then return end
    local map = buildIndexMap(chapters)
    chapter_index_map[bookUrl] = map
    -- 诊断: 便于在设备日志里确认书源是否提供了 index 字段
    local has_index = type(chapters[1]) == "table" and tonumber(chapters[1].index) ~= nil
    logger.info("comic chapter map:", #chapters, "items | chapter.index field:",
        has_index and "yes" or "no", "| pos1 ->", map[1], "pos2 ->", map[2])
end

-- 目录第 position 项 -> /getBookContent 需要的 index
-- allow_fetch=false 时只查缓存, 不发网络请求 (用于退出时上报进度)
function M.toApiIndex(bookUrl, position, allow_fetch)
    position = tonumber(position) or 1
    local map = chapter_index_map[bookUrl]
    if not map and allow_fetch ~= false then
        local chapters = M.getChapterList(bookUrl)
        if type(chapters) == "table" then
            map = buildIndexMap(chapters)
            chapter_index_map[bookUrl] = map
        else
            logger.warn("comic: chapter list unavailable, fallback to 0-based index")
        end
    end
    if map and map[position] ~= nil then return map[position] end
    return position - 1
end

-- 从正文 html 提取图片地址
function M.extractImageUrls(content)
    local img_sources = {}
    if type(content) ~= "string" then return img_sources end
    local pattern = '<img[^>]-src%s*=%s*["\']?([^"\'>%s]+)["\']?[^>]*>'
    for src in content:gmatch(pattern) do
        if src and src ~= "" then
            table.insert(img_sources, src)
        end
    end
    return img_sources
end

-- legado app 图片代理: 按屏幕宽度缩放, 大幅减少下载量
function M.proxyImageUrl(bookUrl, imgSrc)
    if settings.get("proxy_image") == false then return nil end
    local width = Screen:getWidth() or 800
    return M.buildUrl("/image", { url = bookUrl, path = imgSrc, width = width })
end

-- 下载图片(二进制), 带代理->直连回退
function M.downloadImageData(bookUrl, imgSrc)
    local candidates = {}
    local proxied = M.proxyImageUrl(bookUrl, imgSrc)
    if proxied and proxied ~= imgSrc then
        candidates[#candidates + 1] = proxied
    end
    candidates[#candidates + 1] = imgSrc

    local last_err
    for _, url in ipairs(candidates) do
        local ok, resp = httpreq.request({
            url = url,
            timeout = 15,
            maxtime = 60,
            is_pic = true,
        })
        if ok and type(resp.data) == "string" and #resp.data > 0 then
            return resp.data
        end
        last_err = resp
    end
    logger.warn("comic image download failed:", imgSrc, last_err)
    return nil, tostring(last_err or "图片下载失败")
end

-- 同步进度到 app (best-effort)
function M.saveBookProgress(book, chapterIndex, chapterTitle)
    if settings.get("sync_progress") == false then return end
    if not (type(book) == "table" and type(book.name) == "string" and type(book.bookUrl) == "string") then
        return
    end
    local url = M.buildUrl("/saveBookProgress", { v = os.time() })
    -- app 侧的 durChapterIndex 用的是章节 index 体系(从 0 开始), 不是目录位置
    local api_index = M.toApiIndex(book.bookUrl, chapterIndex, false)
    local body = "name=" .. util.urlEncode(book.name)
        .. "&author=" .. util.urlEncode(book.author or "")
        .. "&durChapterPos=0"
        .. "&durChapterIndex=" .. tostring(api_index)
        .. "&durChapterTime=" .. tostring(os.time() * 1000)
        .. "&durChapterTitle=" .. util.urlEncode(chapterTitle or "")
        .. "&index=" .. tostring(api_index)
        .. "&url=" .. util.urlEncode(book.bookUrl)
    httpreq.request({
        url = url,
        method = "POST",
        body = body,
        timeout = 6,
        maxtime = 10,
    })
end

return M
