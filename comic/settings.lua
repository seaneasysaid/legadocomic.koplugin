-- 轻量设置: LuaSettings 封装
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

local M = {}
local _instance = nil

local DEFAULTS = {
    server = "http://192.168.1.8:1122",
    user = "",
    pwd = "",
    prefetch = 5,       -- 预取张数
    proxy_image = true, -- 走 legado app /image 代理(按屏宽缩放, 省流量)
    sync_progress = true, -- 关闭阅读器时同步进度到 app
    auto_clear_chapter = true, -- 换章后自动删除前两章之前的缓存
    comic_only = true,   -- 书架只显示漫画(默认开, 小说源太多时很有用); 开关在书架列表顶部
}

function M.open(path)
    if _instance and not path then return _instance end
    local p = path
    if not p then
        local DataStorage = require("datastorage")
        p = DataStorage:getDataDir() .. "/settings/legadocomic.lua"
    end
    local s = LuaSettings:open(p)
    for k, v in pairs(DEFAULTS) do
        if s:readSetting(k) == nil then
            s:saveSetting(k, v)
        end
    end
    if not path then _instance = s end
    return s
end

function M.get(key)
    return M.open():readSetting(key)
end

function M.set(key, value)
    M.open():saveSetting(key, value):flush()
end

return M
