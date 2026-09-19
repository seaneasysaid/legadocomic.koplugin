-- 本地阅读进度: bookUrl -> {ch, img, title, ts}
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local logger = require("logger")

local M = {}
local path = DataStorage:getDataDir() .. "/settings/legadocomic_progress.lua"

local function open()
    return LuaSettings:open(path)
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

function M.save(book, ch, img, title)
    local key = bookKey(book)
    if not key then return end
    open():saveSetting(key, {
        ch = ch, img = img, title = title or "", ts = os.time(),
        name = book.name, author = book.author, bookUrl = book.bookUrl, origin = book.origin,
    }):flush()
end

function M.delete(book)
    local key = bookKey(book)
    if key then open():delSetting(key):flush() end
end

return M
