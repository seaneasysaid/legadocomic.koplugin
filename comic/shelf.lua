-- 书架 / 章节列表 对话框
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local NetworkMgr = require("ui/network/manager")
local Menu = require("ui/widget/menu")
local logger = require("logger")

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

-- 过滤出有效书籍条目(名称为非空字符串), 统一成 {name, author, bookUrl, origin, type, ...}
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
                    type = b.type, -- Legado 位标记, 判漫画要用(见 is_comic)
                    -- App 侧阅读进度(来自 /getBookshelf), 供打开时续读
                    durChapterIndex = b.durChapterIndex,
                    durChapterPos = b.durChapterPos,
                    durChapterTitle = b.durChapterTitle,
                    durChapterTime = b.durChapterTime,
                }
            end
        end
    end
    return out
end

-- ===== 漫画识别 =====
-- Legado 的 Book.type 是位标记(不是枚举)。本机实测 100 本的取值分布:
--   8   = 文本小说 (书山聚合 / 笔趣阁 / 蚂蚁阅读 ...)
--   24  = 8+16    (三五文学 / 文墨中文 / 雅谷中文 ..., 同为小说)
--   64  = 图片=漫画 (禁漫天堂, kind 标签为"全彩/韩漫/剧情向")
--   264 = 8+256   (本地导入的 epub)
-- 结论: 判漫画只看位 64。注意接口里没有 bookSourceType 字段, 别去找它。
local TYPE_IMAGE_BIT = 64

-- KOReader 可能是 Lua 5.1(没有 & 位运算符), 用取模判断某一位是否置位(b 必须是 2 的幂)
local function has_bit(v, b)
    if type(v) ~= "number" or v < 0 then return false end
    return v % (b * 2) >= b
end

-- 是不是漫画: 只看 type 的图片位。
-- 实测(100 本真机数据): 位 64 的 3 本全部来自漫画源且零漏判, 所以不再做书源白名单兜底。
local function is_comic(book)
    if type(book) ~= "table" then return false end
    local t = tonumber(book.type)
    -- 接口没给 type 就别乱滤(宁可多显示), 否则某些 App 版本会整架书消失
    if t == nil then return true end
    return has_bit(t, TYPE_IMAGE_BIT)
end

-- 按「只看漫画」开关过滤书架。返回 (要展示的书, 被隐藏的本数)。
-- 「☰ 书架」和「✎ 收藏管理」(勾选列表) 都走这里。
-- 例外:「⭐ 收藏」视图不过滤——已收藏的书必须永远可达, 否则开着过滤就再也取消不掉收藏了。
local function apply_comic_filter(books)
    local all = valid_books(books)
    if settings.get("comic_only") == false then return all, 0 end
    local out, hidden = {}, 0
    for _, b in ipairs(all) do
        if is_comic(b) then out[#out + 1] = b else hidden = hidden + 1 end
    end
    return out, hidden
end

-- 计算"续读点": 取 本机进度 与 App 进度(durChapter*) 中较新的一份。
-- 本机 ts 是秒; App durChapterTime 可能是毫秒(13位)或秒(10位), 统一成秒后再比。
-- 返回 { ch = 目录位置(1-based), img = 章内位置, title = 章节标题, from_app = bool } 或 nil。
local function resolveResume(book)
    if type(book) ~= "table" then return nil end
    local local_p = Progress.get(book)

    local app_ch, app_img, app_title, app_ts
    if book.durChapterIndex ~= nil then
        local pos = Api.toPosition(book.bookUrl, book.durChapterIndex, false)
        if pos then
            app_ch = pos
            app_img = tonumber(book.durChapterPos) or 1
            if app_img < 1 then app_img = 1 end
            app_title = book.durChapterTitle
            app_ts = tonumber(book.durChapterTime)
            if app_ts and app_ts > 1e11 then app_ts = app_ts / 1000 end -- ms -> s
        end
    end

    local local_ts = local_p and tonumber(local_p.ts) or nil
    local use_app = false
    if app_ch then
        if not (local_p and local_p.ch) then
            use_app = true                                  -- 只有 App 有进度
        elseif app_ts and local_ts and app_ts > local_ts then
            use_app = true                                  -- App 更新
        end
    end

    if use_app then
        return { ch = app_ch, img = app_img or 1, title = app_title, from_app = true }
    end
    if local_p and local_p.ch then
        return { ch = local_p.ch, img = local_p.img or 1, title = local_p.title, from_app = false }
    end
    return nil
end

-- 用书架缓存里的 App 进度字段补齐书条目(收藏条目自身不存这些字段, 需要时从书架取)
local function enrich_from_shelf(books)
    local by_url = {}
    if type(books) == "table" then
        for _, b in ipairs(books) do
            if type(b) == "table" and b.bookUrl then by_url[b.bookUrl] = b end
        end
    end
    return function(book)
        if type(book) == "table" and book.bookUrl and book.durChapterIndex == nil then
            local src = by_url[book.bookUrl]
            if src then
                book.durChapterIndex = src.durChapterIndex
                book.durChapterPos = src.durChapterPos
                book.durChapterTitle = src.durChapterTitle
                book.durChapterTime = src.durChapterTime
            end
        end
        return book
    end
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

        local resume = resolveResume(book)
        -- 越界保护: App 进度可能指向本地目录里不存在的章节(目录未同步/更新不一致),
        -- 此时不显示续读项, 避免点进去加载不存在的章节。用户仍可从下面正常选章节。
        if resume and (resume.ch < 1 or resume.ch > #chapters) then
            logger.warn("comic resume out of range:", book.name, "ch", resume.ch, "/", #chapters)
            resume = nil
        end
        local items = {}

        if resume then
            table.insert(items, {
                text = string.format("▶ 继续阅读: 第%d话 %s [%s]", resume.ch,
                    resume.title or "", resume.from_app and "APP" or "本机"),
                callback = function()
                    UIManager:close(self._chapter_menu)
                    self:openReader(book, resume.ch, resume.img, #chapters)
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
                    self:openReader(book, idx, 1, #chapters)  -- 传总章数, 最后一章边界提示才生效
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

    -- 和书架一样受「只看漫画」开关约束: 这里列的是可勾选的书架条目
    local all = apply_comic_filter(books)
    -- 退化标记只看书架本身有没有书, 不能被下面补进来的收藏掩盖
    local degraded = #all == 0
    -- 补上「已收藏、但书架里已经没有的书」: 否则书一从 App 书架删掉, 这里就再也取消不掉收藏了
    local seen = {}
    for _, b in ipairs(all) do
        if b.bookUrl ~= nil then seen[tostring(b.bookUrl)] = true end
    end
    for _, f in ipairs(valid_books(Favs.list())) do
        local k = tostring(f.bookUrl or "")
        if k ~= "" and not seen[k] then
            f.gone = true
            all[#all + 1] = f
        end
    end
    if #all == 0 then
        UI.info("书架为空, 无法管理收藏")
        return
    end

    local function render()
        local items = {
            {
                text = "←  返回收藏",
                callback = function()
                    if self._fav_menu then
                        UIManager:close(self._fav_menu)
                        self._fav_menu = nil
                    end
                    Shelf:openFavList(books)
                end,
            },
        }
        if degraded then
            table.insert(items, { text = "(书架里没有可显示的书, 以下仅列出已收藏的)", enabled = false })
        end
        for _, book in ipairs(all) do
            local is_fav = Favs.has(book)
            local label = (is_fav and "⭐ " or "☆ ") .. book.name
            if book.author ~= "" then label = label .. "  ·  " .. book.author end
            if book.gone then label = label .. "  (书架已无)" end
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
    local enrich = enrich_from_shelf(books)
    for _, f in ipairs(favs) do enrich(f) end
    local items = {
        {
            text = "←  返回",
            callback = function()
                if self._favlist_menu then
                    UIManager:close(self._favlist_menu)
                    self._favlist_menu = nil
                end
                Shelf:show()
            end,
        },
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
            local r = resolveResume(f)
            if r then
                label = label .. "  [读到第" .. tostring(r.ch) .. "话]"
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

    local all, hidden = apply_comic_filter(books)
    local filter_on = settings.get("comic_only") ~= false
    local items = {
        {
            text = "←  返回",
            callback = function()
                if self._list_menu then
                    UIManager:close(self._list_menu)
                    self._list_menu = nil
                end
                Shelf:show()
            end,
        },
        {
            -- 别用 emoji: KOReader 的字体里没有字形, 会显示成空白/豆腐块, 用几何符号
            text = filter_on and "◉  只看漫画: 开" or "○  只看漫画: 关 (显示全部书)",
            callback = function()
                settings.set("comic_only", not filter_on)
                Shelf:openShelfList(books)
            end,
        },
        {
            text = "⟳  刷新书架",
            callback = function()
                Shelf:refreshShelf()
            end,
        },
    }

    if #all > 0 then
        table.insert(items, { text = filter_on and "── 漫画 ──" or "── 全部书籍 ──", enabled = false })
        for _, book in ipairs(all) do
            local label = book.name
            if book.author ~= "" then label = label .. "  ·  " .. book.author end
            local r = resolveResume(book)
            if r then
                label = label .. "  [读到第" .. tostring(r.ch) .. "话]"
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
    elseif hidden > 0 then
        table.insert(items, { text = string.format("(没识别到漫画, 已隐藏 %d 本其它书)", hidden), enabled = false })
    else
        table.insert(items, { text = "(书架为空, 请检查服务器设置)", enabled = false })
    end

    if hidden > 0 then
        table.insert(items, {
            text = string.format("»  已隐藏 %d 本非漫画 · 点此显示全部", hidden),
            callback = function()
                settings.set("comic_only", false)
                Shelf:openShelfList(books)
            end,
        })
    end

    self._list_menu = showMenu(string.format(filter_on and "☰ 漫画书架 (%d 本)" or "☰ 书架 (%d 本)", #all), items)
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
    local shown, hidden = apply_comic_filter(books)

    local items = {
        {
            text = string.format("⭐  收藏 (%d 本)", #valid_books(Favs.list())),
            callback = function()
                Shelf:openFavList(books)
            end,
        },
        {
            text = (hidden > 0)
                and string.format("☰  漫画书架 (%d 本 · 隐藏 %d)", #shown, hidden)
                or string.format("☰  书架 (%d 本)", #shown),
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
    -- 注: 「只看漫画」开关在书架列表顶部, 这里不重复放

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
