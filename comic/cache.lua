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

M.key = function(url) return md5hex(url) end

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

function M.put(key, data)
    ensure_dir()
    local tmp = M.path(key) .. ".tmp"
    if not util.writeToFile(data, tmp, true) then return false end
    os.remove(M.path(key))
    local ok = os.rename(tmp, M.path(key))
    if not ok then logger.warn("cache rename failed:", key) end
    if ok then maybePrune() end
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
        if entry:match("%.img$") then
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
function M.pruneBefore(ts, keep_keys)
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
        if entry:match("%.img$") then
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
