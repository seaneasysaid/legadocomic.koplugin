-- 本地阅读进度: bookUrl -> {ch, img, title, ts}
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local logger = require("logger")

local M = {}
local path = DataStorage:getDataDir() .. "/settings/legadocomic_progress.lua"

-- 只打开一次并复用: resolveResume 会对每本书调 get(), 每次重开等于每本书读一遍文件
local _instance = nil
local function open()
    if not _instance then _instance = LuaSettings:open(path) end
    return _instance
end

local function bookKey(book)
    if type(book) ~= "table" then return nil end
    return tostring(book.name or "") .. "|" .. tostring(book.author or "") .. "|" .. tostring(book.bookUrl or "")
end

function M.get(book)
    local key = bookKey(book)
    if not key then return nil end
    local p = open():readSetting(key)
    if type(p) == "table" then return p end
    return nil
end

-- total_ch: 总章数(可选)。存下来供书架顶层「继续阅读」直达时补 total_ch, 末章边界提示才生效
function M.save(book, ch, img, title, total_ch)
    local key = bookKey(book)
    if not key then return end
    open():saveSetting(key, {
        ch = ch, img = img, title = title or "", total = total_ch, ts = os.time(),
        name = book.name, author = book.author, bookUrl = book.bookUrl, origin = book.origin,
    }):flush()
end

function M.delete(book)
    local key = bookKey(book)
    if key then open():delSetting(key):flush() end
end

-- 最近一条阅读进度(按 ts 取最新), 供书架顶层「继续阅读」直达使用。
-- 返回记录副本(含 name/author/bookUrl/ch/img/title/ts) 或 nil。
function M.latest()
    local data = open().data
    if type(data) ~= "table" then return nil end
    local best
    for _, v in pairs(data) do
        if type(v) == "table" and type(v.bookUrl) == "string" and v.bookUrl ~= "" then
            if not best or (tonumber(v.ts) or 0) > (tonumber(best.ts) or 0) then
                best = v
            end
        end
    end
    if not best then return nil end
    local copy = {}
    for k, v in pairs(best) do copy[k] = v end
    return copy
end

return M
