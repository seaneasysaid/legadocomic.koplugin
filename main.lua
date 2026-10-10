local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Shelf = require("comic/shelf")
local settings = require("comic/settings")

-- 入口位置：菜单栏「工具」(扳手) tab 里**直接列三项** —— 漫画书架 / 收藏夹 / 设置。
-- 三项排在微信读书、番茄小说之后（即这两家之后的连续三项）；两家都没装时锚点找不到，
-- 从该顺序表第 2 位起（紧跟 read_timer）。
--
-- KOReader 的 MenuSorter 只按 ui/elements/{filemanager,reader}_menu_order 的 tools
-- 顺序表定位菜单项；不在表里的项会被追加到该菜单**末尾**（sorting_hint 只决定挂在哪个
-- 菜单下，不决定顺序）。所以这里沿用 weread / fanqie 的做法：直接改写这份顺序表。
--
-- 插件按 path 字母序加载：fanqie → legadocomic → weread。weread 最后加载时会把自己插到
-- 第 1 位，因此模块加载时先摆一次，插件 init 时（三家都已加载完）再校正一次。
local MENU_IDS = { "legadocomic_shelf", "legadocomic_fav", "legadocomic_settings" }
local MENU_ORDER_MODULES = {
    "ui/elements/filemanager_menu_order",
    "ui/elements/reader_menu_order",
}

local function ensure_menu_position()
    for _, module in ipairs(MENU_ORDER_MODULES) do
        local ok, order = pcall(require, module)
        if ok and type(order) == "table" and type(order.tools) == "table" then
            local tools = order.tools
            -- 先摘掉自己（可能被重复插入），再按锚点放回，避免索引互相干扰
            for i = #tools, 1, -1 do
                local mine = false
                for _, id in ipairs(MENU_IDS) do
                    if tools[i] == id then
                        mine = true
                        break
                    end
                end
                if mine then table.remove(tools, i) end
            end
            local anchor
            for i, id in ipairs(tools) do
                if (id == "weread" or id == "fanqie") and (not anchor or i > anchor) then
                    anchor = i
                end
            end
            -- 三项依次插入。位置必须夹在 [1, #tools+1] 内: 用户自定义的 *_menu_order.lua
            -- 整体覆盖同名 section 时, order.tools 可能被换成空表, 那时 pos 越界会让
            -- table.insert 抛错 —— 而这段不在 pcall 里, 插件会在加载阶段直接挂掉。
            for k, id in ipairs(MENU_IDS) do
                local pos = math.min(math.max((anchor or 1) + k, 1), #tools + 1)
                table.insert(tools, pos, id)
            end
        end
    end
end

ensure_menu_position()

local LegadoComic = WidgetContainer:extend{
    name = "Legado漫画",
}

function LegadoComic:init()
    settings.open() -- 预热默认值
    -- 此时 weread / fanqie 都已加载，重新校正入口位置
    ensure_menu_position()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:onDispatcherRegisterActions()
end

function LegadoComic:onDispatcherRegisterActions()
    Dispatcher:registerAction("legadocomic_shelf", {
        category = "none",
        event = "ShowLegadoComicShelf",
        title = _("Legado 漫画书架"),
        filemanager = true,
        reader = true,
    })
end

function LegadoComic:onShowLegadoComicShelf()
    UIManager:nextTick(function()
        Shelf:show()
    end)
end

function LegadoComic:addToMainMenu(menu_items)
    if not (self.ui and menu_items) then return end
    -- 菜单栏「工具」tab 里直接列三项, 不用再点进聚合层
    menu_items.legadocomic_shelf = {
        text = "☰  漫画书架",
        -- text_func 带实时本数(零参; KOReader touchmenu 里 text_func 优先于 text)
        text_func = function() return Shelf:shelfEntryText() end,
        sorting_hint = "tools",
        callback = function() Shelf:showShelf() end,
    }
    menu_items.legadocomic_fav = {
        text = "⭐  收藏夹",
        text_func = function() return Shelf:favEntryText() end,
        sorting_hint = "tools",
        callback = function() Shelf:showFavs() end,
    }
    menu_items.legadocomic_settings = {
        text = "⚙  设置 (服务器/预取/缓存)",
        sorting_hint = "tools",
        callback = function() Shelf:openSettings() end,
    }
end

return LegadoComic
