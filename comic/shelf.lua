-- 书架 / 章节列表 对话框
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local NetworkMgr = require("ui/network/manager")
local Menu = require("ui/widget/menu")

local Api = require("comic/api")
local Progress = require("comic/progress")
local UI = require("comic/ui")
local settings = require("comic/settings")
local Favs = require("comic/favs")

local Shelf = {}

local function showMenu(title, items)
    local menu = Menu:new{
        title = title,
        item_table = items,
        show_parent = nil,
        is_borderless = true,
        is_popout = false,
        fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        items_per_page = 14,
        single_line = true,
    }
    UIManager:show(menu)
    return menu
end

-- 过滤出有效书籍条目(名称为非空字符串), 统一成 {name, author, bookUrl, origin}
local function valid_books(books)
    local out = {}
    if type(books) == "table" then
        for _, b in ipairs(books) do
            if type(b) == "table" and type(b.name) == "string" and b.name ~= "" then
                out[#out + 1] = {
                    name = b.name,
                    author = b.author or "",
                    bookUrl = b.bookUrl,
                    origin = b.origin,
                }
            end
        end
    end
    return out
end

-- 关闭 Shelf 打开过的所有菜单, 防止叠层导致 X 要点多次
function Shelf:closeAllMenus()
    for _, k in ipairs({
        "_shelf_menu",     -- 顶层
        "_list_menu",      -- ☰ 书架
        "_favlist_menu",   -- ⭐ 收藏
        "_chapter_menu",   -- 章节列表
        "_settings_menu",  -- 设置
        "_fav_menu",       -- 收藏管理
    }) do

        local m = self[k]
        if m then
            pcall(function() UIManager:close(m) end)
            self[k] = nil
        end
    end
end

function Shelf:openChapterDialog(book)
    -- 分级导航: 保留书架在下层, X 逐层退
    if self._chapter_menu then
        pcall(function() UIManager:close(self._chapter_menu) end)
        self._chapter_menu = nil
    end
    if NetworkMgr:willRerunWhenConnected() then return end
    UI.loading("获取章节列表", function()
        local chapters, err = Api.getChapterList(book.bookUrl)
        if not chapters or type(chapters) ~= "table" then
            return nil, nil, err or "获取章节列表失败"
        end
        return chapters
    end, function(ok, chapters, err)
        if not ok or type(chapters) ~= "table" or #chapters == 0 then
            UI.error(err or "章节列表为空")
            return
        end
        -- 喂给 index 映射表: 目录位置 -> Legado 章节 index
        Api.seedChapterList(book.bookUrl, chapters)

        local p = Progress.get(book)
        local items = {}

        if p and p.ch then
            table.insert(items, {
                text = string.format("▶ 继续阅读: 第%d话 %s", p.ch, p.title or ""),
                callback = function()
                    UIManager:close(self._chapter_menu)
                    self:openReader(book, p.ch or 1, p.img or 1)
                end,
            })
        end

        for i, ch in ipairs(chapters) do
            local title = tostring(ch.title or ("第 " .. i .. " 话"))
            if #title > 40 then title = title:sub(1, 40) .. "…" end
            local idx = i
            table.insert(items, {
                text = string.format("%d. %s", idx, title),
                callback = function()
                    UIManager:close(self._chapter_menu)
                    self:openReader(book, idx, 1)
                end,
            })
        end

        self._chapter_menu = showMenu(book.name .. "  (" .. tostring(book.author or "") .. ")", items)
    end)
end

-- 收藏管理: 纯点击切换收藏 (从「⭐ 收藏」菜单进入)
function Shelf:openFavManager(books)
    -- 分级导航: 保留「收藏」菜单在下层
    if self._fav_menu then
        pcall(function() UIManager:close(self._fav_menu) end)
        self._fav_menu = nil
    end

    local all = valid_books(books)
    local degraded = false
    if #all == 0 then
        -- 书架还没刷新过: 退化成"只能取消已有收藏", 而不是直接把人挡在门外
        all = valid_books(Favs.list())
        degraded = #all > 0
    end

    if #all == 0 then
        UI.info("书架为空, 无法管理收藏")
        return
    end

    local function render()
        local items = {}
        if degraded then
            table.insert(items, { text = "(书架未刷新, 仅列出已收藏的书)", enabled = false })
        end
        for _, book in ipairs(all) do
            local is_fav = Favs.has(book)
            local label = (is_fav and "⭐ " or "☆ ") .. book.name
            if book.author ~= "" then label = label .. "  ·  " .. book.author end
            table.insert(items, {
                text = label,
                callback = function()
                    Shelf:toggleFavorite(book)
                    -- 就地刷新列表
                    if self._fav_menu then
                        UIManager:close(self._fav_menu)
                    end
                    render()
                end,
            })
        end
        table.insert(items, {
            text = "←  返回收藏",
            callback = function()
                if self._fav_menu then
                    UIManager:close(self._fav_menu)
                    self._fav_menu = nil
                end
                Shelf:openFavList(books)
            end,
        })
        self._fav_menu = showMenu("收藏管理 (⭐=已收藏, 点击切换)", items)
    end
    render()
end

-- 「⭐ 收藏」菜单: 管理入口 + 我的收藏
function Shelf:openFavList(books)
    -- 分级导航: 保留顶层在下层
    if self._favlist_menu then
        pcall(function() UIManager:close(self._favlist_menu) end)
        self._favlist_menu = nil
    end

    local favs = valid_books(Favs.list())
    local items = {
        {
            text = "✎  收藏管理 (点击书名切换收藏)",
            callback = function()
                Shelf:openFavManager(books)
            end,
        },
    }

    if #favs > 0 then
        table.insert(items, { text = "── ⭐ 我的收藏 ──", enabled = false })
        for _, f in ipairs(favs) do
            local label = "⭐ " .. f.name
            if f.author ~= "" then label = label .. "  ·  " .. f.author end
            local p = Progress.get(f)
            if p and p.ch then
                label = label .. "  [第" .. tostring(p.ch) .. "话]"
            end
            table.insert(items, {
                text = label,
                callback = function()
                    Shelf:openChapterDialog(f)
                end,
            })
        end
    else
        table.insert(items, { text = "(还没有收藏, 点上方「✎ 收藏管理」添加)", enabled = false })
    end

    table.insert(items, {
        text = "←  返回",
        callback = function()
            if self._favlist_menu then
                UIManager:close(self._favlist_menu)
                self._favlist_menu = nil
            end
            Shelf:show()
        end,
    })

    self._favlist_menu = showMenu(string.format("⭐ 收藏 (%d 本)", #favs), items)
end

-- 「☰ 书架」菜单: 刷新入口 + 全部书籍
-- 已收藏的书加 ⭐ 前缀提示, 但仍在这里可点 (收藏是独立视图, 不再把书从书架里抽走)
function Shelf:openShelfList(books)
    -- 分级导航: 保留顶层在下层
    if self._list_menu then
        pcall(function() UIManager:close(self._list_menu) end)
        self._list_menu = nil
    end

    local all = valid_books(books)
    local items = {
        {
            text = "⟳  刷新书架",
            callback = function()
                Shelf:refreshShelf()
            end,
        },
    }

    if #all > 0 then
        table.insert(items, { text = "── 全部书籍 ──", enabled = false })
        for _, book in ipairs(all) do
            local label = book.name
            if book.author ~= "" then label = label .. "  ·  " .. book.author end
            local p = Progress.get(book)
            if p and p.ch then
                label = label .. "  [读到第" .. tostring(p.ch) .. "话]"
            end
            if Favs.has(book) then label = "⭐ " .. label end
            table.insert(items, {
                text = label,
                callback = function()
                    Shelf:openChapterDialog(book)
                end,
            })
        end
    elseif books == nil then
        table.insert(items, { text = "(尚无书架缓存, 点上方「⟳ 刷新书架」获取)", enabled = false })
    else
        table.insert(items, { text = "(书架为空, 请检查服务器设置)", enabled = false })
    end

    table.insert(items, {
        text = "←  返回",
        callback = function()
            if self._list_menu then
                UIManager:close(self._list_menu)
                self._list_menu = nil
            end
            Shelf:show()
        end,
    })

    self._list_menu = showMenu(string.format("☰ 书架 (%d 本)", #all), items)
end

function Shelf:openReader(book, ch, img, total_ch)
    if NetworkMgr:willRerunWhenConnected() then return end
    require("comic/reader").fetchAndShow({
        book = book,
        start_ch = ch or 1,
        start_img = img or 1,
        total_ch = total_ch,
        on_close_callback = function()
            -- 回到章节列表
            Shelf:openChapterDialog(book)
        end,
    })
end

-- 切换收藏状态(供收藏管理调用)
function Shelf:toggleFavorite(book, on_done)
    local is_fav = Favs.toggle(book)
    UI.info(is_fav and ("⭐ 已加入收藏: " .. book.name) or ("已取消收藏: " .. book.name), 2)
    if type(on_done) == "function" then on_done() end
end

-- 顶层: 只有 ⭐收藏 / ☰书架 / ⚙设置 三个固定入口.
-- 书全部收进「☰ 书架」子菜单、收藏收进「⭐ 收藏」子菜单,
-- 所以书架上有 3 本还是 300 本, 这一层的样子都不变.
function Shelf:show()
    if NetworkMgr:willRerunWhenConnected() then return end
    self:closeAllMenus()

    -- 顶层不列书, 只读上次缓存的书架算个数; 仍然不自动联网
    local cached = settings.open():readSetting("shelf_cache")
    local books = (type(cached) == "table") and cached.books or nil

    local items = {
        {
            text = string.format("⭐  收藏 (%d 本)", #valid_books(Favs.list())),
            callback = function()
                Shelf:openFavList(books)
            end,
        },
        {
            text = string.format("☰  书架 (%d 本)", #valid_books(books)),
            callback = function()
                Shelf:openShelfList(books)
            end,
        },
        {
            text = "⚙  设置 (服务器/预取/缓存)",
            callback = function()
                Shelf:openSettings()
            end,
        },
    }

    self._shelf_menu = showMenu("Legado 漫画书架", items)
    self._shelf_books = books
end

-- 手动刷新书架 (从「☰ 书架」菜单进入, 刷完留在这一层)
function Shelf:refreshShelf()
    Shelf:closeAllMenus()
    UI.loading("获取书架", function()
        local books, err = Api.getBookshelf()
        if not books then return nil, err end
        return books
    end, function(ok, books, err)
        if ok and type(books) == "table" then
            settings.set("shelf_cache", { books = books, ts = os.time() })
            Shelf._books = books
            Shelf:openShelfList(books)
        else
            -- 刷新失败也别把人踢出书架层, 用缓存继续展示
            local cached = settings.open():readSetting("shelf_cache")
            Shelf:openShelfList((type(cached) == "table") and cached.books or nil)
            UI.error(err or "获取书架失败, 请检查设置")
        end
    end)
end

function Shelf:openSettings()
    -- 分级导航: 保留书架在下层
    if self._settings_menu then
        pcall(function() UIManager:close(self._settings_menu) end)
        self._settings_menu = nil
    end

    local function reopen()
        self:openSettings()
    end

    local items = {
        {
            text = "(各项修改后即时保存, 点右上角 X 退出)",
            enabled = false,
        },
        {
            text = "服务器地址: " .. tostring(settings.get("server")),
            callback = function()
                UI.input("服务器地址", settings.get("server"), "http://192.168.1.8:1122", function(v)
                    if v and v ~= "" then
                        settings.set("server", v)
                        UI.info("已保存", 1)
                        reopen()
                    end
                end)
            end,
        },
        {
            text = "用户名 (Web服务验证, 可空): " .. tostring(settings.get("user")),
            callback = function()
                UI.input("用户名", settings.get("user"), "可留空", function(v)
                    settings.set("user", v or "")
                    UI.info("已保存", 1)
                    reopen()
                end)
            end,
        },
        {
            text = "密码 (Web服务验证, 可空)",
            callback = function()
                UI.input("密码", settings.get("pwd"), "可留空", function(v)
                    settings.set("pwd", v or "")
                    UI.info("已保存", 1)
                    reopen()
                end, true)
            end,
        },
        {
            text = "预取张数: " .. tostring(settings.get("prefetch")),
            callback = function()
                UI.input("预取张数 (0-20)", tostring(settings.get("prefetch")), "翻页提前下载的张数", function(v)
                    local n = tonumber(v)
                    if n then
                        n = math.max(0, math.min(20, math.floor(n)))
                        settings.set("prefetch", n)
                        UI.info("已保存", 1)
                        reopen()
                    end
                end)
            end,
        },
        {
            text = string.format("缓存上限: %dMB", tonumber(settings.get("cache_limit")) or 300),
            callback = function()
                UI.input("缓存上限MB (50-2000)", tostring(tonumber(settings.get("cache_limit")) or 300), "超过后自动清理最久未看的图片", function(v)
                    local n = tonumber(v)
                    if n then
                        n = math.max(50, math.min(2000, math.floor(n)))
                        settings.set("cache_limit", n)
                        UI.info("已保存", 1)
                        reopen()
                    end
                end)
            end,
        },
        {
            text = "自动删除旧章节缓存(隔两章): " .. ((settings.get("auto_clear_chapter") ~= false) and "开" or "关"),
            callback = function()
                settings.set("auto_clear_chapter", settings.get("auto_clear_chapter") == false)
                UI.info("已保存", 1)
                reopen()
            end,
        },
        {
            text = "图片代理缩放: " .. ((settings.get("proxy_image") ~= false) and "开" or "关"),
            callback = function()
                settings.set("proxy_image", settings.get("proxy_image") == false)
                UI.info("已保存", 1)
                reopen()
            end,
        },
        {
            text = "退出时同步进度到APP: " .. ((settings.get("sync_progress") ~= false) and "开" or "关"),
            callback = function()
                settings.set("sync_progress", settings.get("sync_progress") == false)
                UI.info("已保存", 1)
                reopen()
            end,
        },
    }

    local total, count = require("comic/cache").usage()
    table.insert(items, {
        text = string.format("清空图片缓存 (%.1fMB / %d张)", total / 1024 / 1024, count),
        callback = function()
            UI.confirm("确定清空所有已缓存图片?", function(ok)
                if ok then
                    require("comic/cache").clear()
                    UI.info("缓存已清空")
                end
            end)
        end,
    })
    table.insert(items, {
        text = "←  返回",
        callback = function()
            if self._settings_menu then
                UIManager:close(self._settings_menu)
                self._settings_menu = nil
            end
            Shelf:show()
        end,
    })

    self._settings_menu = showMenu("Legado 漫画 - 设置", items)
end

return Shelf
