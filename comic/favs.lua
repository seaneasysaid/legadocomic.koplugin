-- 收藏(书架快捷方式): 本地 LuaSettings 存储
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

local M = {}
local path = DataStorage:getDataDir() .. "/settings/legadocomic_favs.lua"

local function open()
    return LuaSettings:open(path)
end

function M.key(book)
    if type(book) ~= "table" then return nil end
    return tostring(book.name or "") .. "|" .. tostring(book.author or "") .. "|" .. tostring(book.bookUrl or "")
end

function M.has(book)
    local k = M.key(book)
    return k ~= nil and open():readSetting(k) ~= nil
end

function M.toggle(book)
    local k = M.key(book)
    if not k then return false end
    local s = open()
    if s:readSetting(k) then
        s:delSetting(k):flush()
        return false
    end
    s:saveSetting(k, {
        name = book.name, author = book.author or "",
        bookUrl = book.bookUrl, origin = book.origin,
        ts = os.time(),
    }):flush()
    return true
end

function M.list()
    local s = open()
    local out = {}
    for _, v in pairs(s.data) do
        if type(v) == "table" and type(v.name) == "string" and type(v.bookUrl) == "string" then
            out[#out + 1] = v
        end
    end
    table.sort(out, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
    return out
end

return M
