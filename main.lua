local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Shelf = require("comic/shelf")
local settings = require("comic/settings")

local LegadoComic = WidgetContainer:extend{
    name = "Legado漫画",
}

function LegadoComic:init()
    settings.open() -- 预热默认值
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
    menu_items.legadocomic = {
        text = "Legado 漫画",
        sorting_hint = "search",
        callback = function()
            Shelf:show()
        end,
    }
end

return LegadoComic
