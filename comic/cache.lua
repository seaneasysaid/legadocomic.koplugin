-- 磁盘图片缓存: url -> md5 命名文件, LRU 限额清理
local util = require("util")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")

local M = {}
local cache_dir = DataStorage:getDataDir() .. "/cache/legadocomic"
local DEFAULT_LIMIT = 300 * 1024 * 1024 -- 300MB

local function md5hex(str)
    local sha = require("ffi/sha2")
    local ok, digest = pcall(sha.md5, str)
    if ok and type(digest) == "string" and #digest > 0 then
        if #digest == 32 then return digest end
        if #digest == 16 then
            return (digest:gsub(".", function(c)
                return string.format("%02x", c:byte())
            end))
        end
    end
    -- 兜底: 简单散列(仅降级时使用)
    local h = 0
    for i = 1, #str do h = (h * 131 + str:byte(i)) % 0xFFFFFFFF end
    return string.format("%08x", h)
end

-- 缓存 key: 除 url 外还要并入**变体维度**(是否走代理缩放、屏宽)。
-- 背景: 开启「图片代理」时缓存的其实是**被 Legado 按屏宽缩放过的**字节, 而 key 只取 url。
-- 于是关掉代理(或换设备/改屏宽)后 key 不变 -> 永久吐出旧的低清缩放图, 只能手动清缓存。
-- 这里把变体并进 key: 不同变体各自缓存, 互不污染。
-- ⚠️ reader.lua 算 keep_keys 用的也是本函数, 两边天然一致。
local function variant_tag()
    local ok, settings = pcall(require, "comic/settings")
    local proxy = true
    if ok and type(settings) == "table" and type(settings.get) == "function" then
        proxy = settings.get("proxy_image") ~= false
    end
    if not proxy then return "d" end -- direct: 直连原图, 与屏宽无关
    local ok_dev, Device = pcall(require, "device")
    local w = 800
    if ok_dev and Device and Device.screen and Device.screen.getWidth then
        w = Device.screen:getWidth() or 800
    end
    return "p" .. tostring(w)
end

M.key = function(url) return md5hex(variant_tag() .. "\0" .. tostring(url)) end

local put_count = 0
local function maybePrune()
    -- 每写入 20 张做一次限额清理, 避免无限增长
    put_count = put_count + 1
    if put_count % 20 == 0 then
        local settings = require("comic/settings")
        pcall(M.prune, (tonumber(settings.get("cache_limit")) or 300) * 1024 * 1024)
    end
end

M.path = function(key)
    return cache_dir .. "/" .. key .. ".img"
end

local function ensure_dir()
    util.makePath(cache_dir)
end

function M.has(key)
    return util.pathExists(M.path(key))
end

function M.get(key)
    local p = M.path(key)
    if not util.pathExists(p) then return nil end
    local f = io.open(p, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    -- 刷新访问时间(喂给 LRU)
    pcall(function() lfs.touch(p, os.time()) end)
    return data
end

-- 图片魔数校验: 只放行真正的图片字节。
-- Legado/代理偶发返回 200 + 一段 HTML(错误页/占位页)时, 旧代码会把它当图片写进缓存,
-- 之后 Cache.has 恒真 → 预取永远跳过、翻页永远拿到这张坏数据, 重试也救不回来,
-- 只能去设置里手动清缓存。宁可这次不缓存(下次还能重试), 也不要缓存坏数据。
local function looks_like_image(data)
    if type(data) ~= "string" or #data < 3 then return false end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return true end                       -- PNG
    if data:sub(1, 3) == "\255\216\255" then return true end                           -- JPEG
    if data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then return true end   -- GIF
    if data:sub(1, 2) == "BM" then return true end                                     -- BMP
    if #data >= 12 and data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return true end -- WebP
    return false
end

function M.put(key, data)
    if not looks_like_image(data) then
        logger.warn("cache: refuse non-image data, key=" .. tostring(key))
        return false
    end
    ensure_dir()
    local tmp = M.path(key) .. ".tmp"
    -- 第 3 参是 force_flush(fsync), 不是"检查空间"。缓存图本身是可再生的,
    -- 且下面还有 .tmp + rename 兜底, 每张都 fsync 只是白等 I/O(整章预下载时尤其明显)。
    if not util.writeToFile(data, tmp, false) then return false end
    os.remove(M.path(key))
    local ok = os.rename(tmp, M.path(key))
    if ok then
        maybePrune()
    else
        -- rename 失败必须自己清掉 .tmp: prune/clear 只匹配 .img, 否则这堆残留永远扫不到
        logger.warn("cache rename failed:", key)
        os.remove(tmp)
    end
    return ok
end

-- 下载(或读缓存)一张图片; bookUrl 用于代理回退
function M.fetch(bookUrl, imgSrc, downloader)
    local k = M.key(imgSrc)
    local data = M.get(k)
    if data then return data end
    data = downloader(bookUrl, imgSrc)
    if data and #data > 0 then
        M.put(k, data)
    end
    return data
end

function M.prune(limit_bytes)
    limit_bytes = tonumber(limit_bytes) or DEFAULT_LIMIT
    ensure_dir()
    local files = {}
    local total = 0
    for entry in lfs.dir(cache_dir) do
        -- 一并把残留的 .tmp(rename 失败的垃圾)算进来, 超限时顺手清掉
        if entry:match("%.img$") or entry:match("%.img%.tmp$") then
            local p = cache_dir .. "/" .. entry
            local attr = lfs.attributes(p)
            if attr and attr.mode == "file" then
                total = total + attr.size
                files[#files + 1] = { path = p, size = attr.size, atime = attr.access or attr.modification or 0 }
            end
        end
    end
    if total <= limit_bytes then return end
    table.sort(files, function(a, b) return a.atime < b.atime end)
    for _, f in ipairs(files) do
        if total <= limit_bytes then break end
        os.remove(f.path)
        total = total - f.size
    end
end

-- 删除单个 url 的缓存 (用于"自动删除已看完章节")
function M.remove(url)
    local p = M.path(M.key(url))
    if util.pathExists(p) then
        os.remove(p)
        return true
    end
    return false
end

-- 批量删除一组 url 的缓存; keep 为可选 url 集合(set), 命中的跳过
function M.removeUrls(urls, keep)
    local removed = 0
    for _, url in ipairs(urls or {}) do
        if not (keep and keep[url]) and M.remove(url) then
            removed = removed + 1
        end
    end
    return removed
end

-- 删除 keep_keys(md5 集合)之外、修改时间早于 ts 的缓存文件
-- 用于"隔章自动清理": 不依赖会话内记忆, 孤儿文件(上个会话遗留)也能清掉
--
-- ⚠️ 加节流: 本函数要遍历**整个**缓存目录并逐文件 stat, 上千张图时在 UI 线程上要几十~几百 ms。
-- 而它每翻一章都会被调用一次 -> 每章都卡一下。同一分钟内重复调用直接跳过
-- (清理本身是"删旧图"的惰性操作, 晚一分钟没有任何影响)。
local _last_prune_before = 0
function M.pruneBefore(ts, keep_keys)
    local now = os.time()
    if now - _last_prune_before < 60 then return 0 end
    _last_prune_before = now
    ensure_dir()
    local removed = 0
    for entry in lfs.dir(cache_dir) do
        if entry:match("%.img$") then
            local key = entry:sub(1, -5) -- 去掉 .img 后缀
            if not (keep_keys and keep_keys[key]) then
                local p = cache_dir .. "/" .. entry
                local attr = lfs.attributes(p)
                if attr and attr.mode == "file" and (attr.modification or 0) < ts then
                    os.remove(p)
                    removed = removed + 1
                end
            end
        end
    end
    return removed
end

function M.clear()
    ensure_dir()
    for entry in lfs.dir(cache_dir) do
        if entry:match("%.img$") or entry:match("%.img%.tmp$") then
            os.remove(cache_dir .. "/" .. entry)
        end
    end
end

function M.usage()
    ensure_dir()
    local total, count = 0, 0
    for entry in lfs.dir(cache_dir) do
        if entry:match("%.img$") then
            local attr = lfs.attributes(cache_dir .. "/" .. entry)
            if attr and attr.mode == "file" then
                total = total + attr.size
                count = count + 1
            end
        end
    end
    return total, count
end

return M
