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
local About = require("comic/about")

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

-- 收藏管理里的书目标签: ⭐(已收藏)/☆(未收藏) + 书名 · 作者 + 可选后缀
local function fav_label(book, suffix)
    local label = (Favs.has(book) and "⭐ " or "☆ ") .. book.name
    if book.author ~= "" then label = label .. "  ·  " .. book.author end
    if suffix then label = label .. suffix end
    return label
end

-- 关闭 Shelf 打开过的所有菜单, 防止叠层导致 X 要点多次。
-- 注: 菜单栏入口 (原生 sub_item_table_func) 不需要这里管, KOReader 自己会收;
-- 这里只管自绘窗口: _cust_menu(自绘页) / _chapter_menu(章节) / _fav_menu(收藏管理)。
function Shelf:closeAllMenus()
    for _, k in ipairs({ "_cust_menu", "_chapter_menu", "_fav_menu" }) do
        local m = self[k]
        if m then
            pcall(function() UIManager:close(m) end)
            self[k] = nil
        end
    end
    self._cust_reopen = nil
end

function Shelf:openChapterDialog(book)
    -- 分级导航: 保留书架在下层, X 逐层退
    if self._chapter_menu then
        pcall(function() UIManager:close(self._chapter_menu) end)
        self._chapter_menu = nil
    end
    -- 必须把"要继续做的事"作为回调传进去: willRerunWhenConnected(callback) 在断网时会去
    -- 开 Wi-Fi 并**重跑 callback**; 不传回调 = 用户的点击被默默丢掉(弹出"是否打开 Wi-Fi" ->
    -- 连上后什么都没发生, 得再点一次)。
    if NetworkMgr:willRerunWhenConnected(function() Shelf:openChapterDialog(book) end) then return end
    UI.loading("获取章节列表", function()
        local chapters, err = Api.getChapterList(book.bookUrl)
        if not chapters or type(chapters) ~= "table" then
            -- 只返回 2 个值: UI.loading 只转发前两个返回值(err 放第 3 位会被丢掉,
            -- 用户在提示里就只能看到兜底文案, 看不到真实原因)
            return nil, err or "获取章节列表失败"
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
                    -- 关掉后必须把引用置空: 否则退出阅读器回到这里时, openChapterDialog 开头那句
                    -- "关掉旧菜单"会对一个**已经关掉**的控件再 close 一次 —— UIManager:close 是不管
                    -- 控件还在不在栈上的, 会再发一遍 CloseWidget/FlushSettings。
                    UIManager:close(self._chapter_menu)
                    self._chapter_menu = nil
                    self:openReader(book, resume.ch, resume.img, #chapters)
                end,
            })
        end

        for i, ch in ipairs(chapters) do
            -- 按「字符数」截断(UTF-8 安全): 原来的 title:sub(1,40) 是按字节切,
            -- 中文一个字 3 字节 -> 第 40 字节常常落在字的中间, 菜单里出现半个字/乱码
            local title = UI.ellipsize(ch.title or ("第 " .. i .. " 话"), 40)
            local idx = i
            table.insert(items, {
                text = string.format("%d. %s", idx, title),
                callback = function()
                    -- 同「继续阅读」项: 关掉后置空引用, 避免退出阅读器时二次 close
                    UIManager:close(self._chapter_menu)
                    self._chapter_menu = nil
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
                    -- 只关自己: 下面的「⭐ 收藏夹」页(原生页或自绘页)还开着, 关掉就看见了
                    if self._fav_menu then
                        UIManager:close(self._fav_menu)
                        self._fav_menu = nil
                    end
                end,
            },
        }
        if degraded then
            table.insert(items, { text = "(书架里没有可显示的书, 以下仅列出已收藏的)", enabled = false })
        end
        -- 「已删书籍」区块前置: 紧跟返回按钮, 条目再多也在第一页, 不会跑到第二页取消不掉
        local gone_books, shelf_books = {}, {}
        for _, book in ipairs(all) do
            if book.gone then gone_books[#gone_books + 1] = book else shelf_books[#shelf_books + 1] = book end
        end
        if #gone_books > 0 then
            table.insert(items, { text = "── 已删书籍 (书架已无) ──", enabled = false })
            for _, book in ipairs(gone_books) do
                table.insert(items, {
                    text = fav_label(book, "  (书架已无)"),
                    callback = function()
                        Shelf:toggleFavorite(book)
                        if self._fav_menu then
                            UIManager:close(self._fav_menu)
                        end
                        render()
                    end,
                })
            end
            if #shelf_books > 0 then
                table.insert(items, { text = "── 书架书籍 ──", enabled = false })
            end
        end
        for _, book in ipairs(shelf_books) do
            table.insert(items, {
                text = fav_label(book),
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

-- ================= 菜单内容 (KOReader 原生菜单项) =================
-- 一级「Legado 漫画」由 main.lua 注册 (sub_item_table_func), 点开就是 mainMenuItems();
-- 「☰ 漫画书架」「⭐ 收藏夹」不挂 sub_item_table_func (不做成原生三级菜单): 点一下直接开
-- 自绘窗口, 和遥控器/手势入口同一个观感; 只有「⚙ 设置」继续往下走原生子菜单,
-- 「关于」排在它下面, 点一下弹 InfoMessage。
-- 遥控器/手势入口 (Shelf:show) 走文件末尾的自绘适配, 内容用的是同一批 builder。

-- 上次刷新缓存下来的书架(list); 各页共用, 只读本地不联网
local function cached_shelf_books()
    local cached = settings.open():readSetting("shelf_cache")
    return (type(cached) == "table") and cached.books or nil
end

-- 自绘页适配器定义在文件下方, 这里先声明 —— mainMenuItems 里的回调要用到它
local open_custom_page

-- 二级页: 「▶ 继续阅读」(有本机进度时) + ☰漫画书架 / ⭐收藏夹 / ⚙设置 / 关于
-- 入口文字不带本数: 「几本 / 隐藏几本」在各自的列表页里更清楚, 这里保持短行。
function Shelf:mainMenuItems()
    local items = {}

    -- 「继续阅读」直达: 有本机进度时置顶, 一键回到上次那张, 省去 进书架→选书→选章 三步
    local latest = Progress.latest()
    if type(latest) == "table" and type(latest.bookUrl) == "string" then
        local label = "▶  继续阅读: " .. tostring(latest.name or latest.bookUrl)
        if latest.ch then label = label .. "   [第" .. tostring(latest.ch) .. "话]" end
        local cont_book = {
            name = latest.name, author = latest.author or "",
            bookUrl = latest.bookUrl, origin = latest.origin,
        }
        table.insert(items, {
            text = label,
            callback = function()
                -- 第 4 参传总章数(进度记录里存过): 末章边界提示与预取末章保护才生效
                Shelf:openReader(cont_book, tonumber(latest.ch) or 1,
                    tonumber(latest.img) or 1, tonumber(latest.total))
            end,
        })
    end

    -- 入口上不显示本数/隐藏数: 数字在书架页里看得更全, 二级菜单保持短一行, 一屏看清所有入口。
    table.insert(items, {
        text = "☰  漫画书架",
        -- 直接开自绘窗口: keep_menu_open 让原生二级菜单留在下层, 关掉窗口就回到这里;
        -- custom_page 是给自绘路径(遥控器/手势)看的 —— 那边翻成"开新页 + ← 返回"
        keep_menu_open = true,
        callback = function()
            Shelf:openShelfWindow()
        end,
        custom_page = function(parent)
            Shelf:openShelfWindow(parent)
        end,
    })
    table.insert(items, {
        text = "⭐  收藏夹",
        keep_menu_open = true,
        callback = function()
            Shelf:openFavWindow()
        end,
        custom_page = function(parent)
            Shelf:openFavWindow(parent)
        end,
    })
    -- 只有「设置」继续走原生子菜单(三级), 里面有四级子菜单
    table.insert(items, {
        text = "⚙  设置",
        sub_item_table_func = function()
            return Shelf:settingsItems()
        end,
    })
    -- 「关于」: 排在「设置」下面的独立弹窗(InfoMessage), 介绍插件 + 版本号 + 当前状态。
    -- keep_menu_open: 原生路径下二级菜单留在弹窗下层, 关掉弹窗回到这里;
    -- 自绘路径(遥控器/手势)没这个概念, 但同一份 builder 会被翻成普通 callback, 行为一致。
    table.insert(items, {
        text = "关于",
        keep_menu_open = true,
        callback = function()
            About.show()
        end,
    })
    return items
end

-- 「☰ 漫画书架」/「⭐ 收藏夹」: 开自绘窗口。
-- parent: 遥控器/手势的自绘导航需要(会补「← 返回」); 从原生菜单进来不传 —— 原生菜单
--         留在下层(项上带 keep_menu_open), 关掉窗口即回到二级菜单。
function Shelf:openShelfWindow(parent)
    open_custom_page("☰ 漫画书架",
        function() return Shelf:shelfListItems(cached_shelf_books()) end, parent)
end

function Shelf:openFavWindow(parent)
    open_custom_page("⭐ 收藏夹",
        function() return Shelf:favListItems(cached_shelf_books()) end, parent)
end

-- 「☰ 漫画书架」页: 只看漫画开关 / 刷新书架 / 全部书(点开进章节列表)
function Shelf:shelfListItems(books)
    local all, hidden = apply_comic_filter(books)
    local filter_on = settings.get("comic_only") ~= false
    local items = {}

    table.insert(items, {
        -- 别用 emoji: KOReader 的字体里没有字形, 会显示成空白/豆腐块, 用几何符号
        text = "只看漫画 (隐藏非漫画书)",
        checked_func = function() return settings.get("comic_only") ~= false end,
        -- 开关会改变下面整个列表, 所以要留在本页就地换掉 item_table;
        -- 不设 keep_menu_open 的话 onMenuSelect 回调完就把菜单关了, 换页也就看不见了。
        keep_menu_open = true,
        callback = function(tm)
            settings.set("comic_only", settings.get("comic_only") == false)
            if tm then
                tm.item_table = Shelf:shelfListItems(cached_shelf_books())
                tm:updateItems()
            end
        end,
    })
    table.insert(items, {
        text = "⟳  刷新书架",
        keep_menu_open = true,
        callback = function(tm)
            Shelf:refreshShelf(tm)
        end,
    })

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
            keep_menu_open = true,
            callback = function(tm)
                settings.set("comic_only", false)
                if tm then
                    tm.item_table = Shelf:shelfListItems(cached_shelf_books())
                    tm:updateItems()
                end
            end,
        })
    end

    return items
end

-- 「⭐ 收藏夹」页: 收藏管理入口 + 我的收藏(不过滤, 已收藏的书永远可达)
function Shelf:favListItems(books)
    local favs = valid_books(Favs.list())
    local enrich = enrich_from_shelf(books)
    for _, f in ipairs(favs) do enrich(f) end

    local items = {
        {
            text = "✎  收藏管理 (点击书名切换收藏)",
            -- 收藏管理是自绘的勾选列表(点一下要就地重画), 让本页留在下面, 关掉它就回来了
            keep_menu_open = true,
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

    return items
end

function Shelf:openReader(book, ch, img, total_ch)
    -- 同 openChapterDialog: 传回调, 断网时连上 Wi-Fi 后自动继续打开
    if NetworkMgr:willRerunWhenConnected(function() Shelf:openReader(book, ch, img, total_ch) end) then return end
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
function Shelf:toggleFavorite(book)
    local is_fav = Favs.toggle(book)
    UI.info(is_fav and ("⭐ 已加入收藏: " .. book.name) or ("已取消收藏: " .. book.name), 2)
end

-- ================= 自绘菜单适配 (遥控器 / 手势入口) =================
-- 菜单栏入口走 KOReader 原生菜单 (sub_item_table_func), 遥控器/手势入口没法调原生菜单,
-- 就用自绘 Menu 把同一份 builder 画出来。原生项里的 sub_item_table_func 自绘控件不认识,
-- 这里翻成"点开另一个自绘窗口"; 开关类项(item.checked_func)点完原地重画, 让 ◉/○ 跟着变。

local function close_custom_page()
    if Shelf._cust_menu then
        pcall(function() UIManager:close(Shelf._cust_menu) end)
        Shelf._cust_menu = nil
    end
end

local function custom_page_text(it)
    local t = it.text_func and it.text_func() or (it.text or "")
    -- 自绘 Menu 没有勾选框, 把状态画进文本里
    if it.checked_func then
        t = (it.checked_func() and "◉  " or "○  ") .. t
    end
    return t
end

-- title: 本层标题; build: function() -> 原生项表; parent: { title=, build=, parent= } 或 nil
open_custom_page = function(title, build, parent)
    close_custom_page()
    local items = build()
    local entries = {}

    for _, it in ipairs(items) do
        local enabled = it.enabled
        if it.enabled_func then enabled = it.enabled_func() end
        local text = custom_page_text(it)

        if enabled == false then
            entries[#entries + 1] = { text = text, enabled = false }
        elseif it.custom_page then
            -- 显式声明"点开另一个自绘页"的项(如 漫画书架/收藏夹 / 服务器设置 的入口)
            entries[#entries + 1] = {
                text = text,
                callback = function()
                    it.custom_page({ title = title, build = build, parent = parent })
                end,
            }
        elseif it.sub_item_table_func or it.sub_item_table then
            local sub_build = it.sub_item_table_func
                or (function() local sub = it.sub_item_table; return sub end)
            entries[#entries + 1] = {
                text = text,
                callback = function()
                    open_custom_page(text, sub_build,
                        { title = title, build = build, parent = parent })
                end,
            }
        else
            entries[#entries + 1] = {
                text = text,
                callback = function()
                    if it.callback then it.callback() end
                    if it.checked_func and Shelf._cust_reopen then Shelf._cust_reopen() end
                end,
            }
        end
    end

    if parent then
        table.insert(entries, 1, {
            text = "←  返回",
            callback = function()
                open_custom_page(parent.title, parent.build, parent.parent)
            end,
        })
    end

    Shelf._cust_reopen = function() open_custom_page(title, build, parent) end
    Shelf._cust_menu = showMenu(title, entries)
end

-- 遥控器 / 手势入口: 一级「Legado 漫画」→ 二级 漫画书架 / 收藏夹 / 设置
function Shelf:show()
    -- 传回调: 断网时先开 Wi-Fi, 连上后自动把菜单弹出来(不传回调则这次点击丢失)
    if NetworkMgr:willRerunWhenConnected(function() Shelf:show() end) then return end
    self:closeAllMenus()
    open_custom_page("Legado 漫画", function() return Shelf:mainMenuItems() end, nil)
end

-- 手动刷新书架 (从「☰ 漫画书架」页点进来, 刷完留在这一页)
-- tm: 原生菜单实例(可选)。传了就地换掉整页, 不传(自绘路径)则重画当前自绘页。
function Shelf:refreshShelf(tm)
    -- 刷新是纯网络操作: 断网时先开 Wi-Fi, 连上后自动重跑
    -- (没有回调的话, 用户在断网时点"刷新书架"只会看到一句"获取书架失败")
    if NetworkMgr:willRerunWhenConnected(function() Shelf:refreshShelf(tm) end) then return end
    UI.loading("获取书架", function()
        local books, err = Api.getBookshelf()
        if not books then return nil, err end
        return books
    end, function(ok, books, err)
        if ok and type(books) == "table" then
            settings.set("shelf_cache", { books = books, ts = os.time() })
            if tm then
                tm.item_table = Shelf:shelfListItems(cached_shelf_books())
                tm:updateItems()
            elseif Shelf._cust_reopen then
                Shelf._cust_reopen()
            end
        else
            -- 刷新失败也别把人踢出书架层, 用缓存继续展示
            UI.error(err or "获取书架失败, 请检查设置")
            if tm then
                tm.item_table = Shelf:shelfListItems(cached_shelf_books())
                tm:updateItems()
            elseif Shelf._cust_reopen then
                Shelf._cust_reopen()
            end
        end
    end)
end

-- 「⚙ 设置」页 (三级): 服务器 / 预下载 各收进一个四级子菜单, 其余项在本页直接改
function Shelf:settingsItems()
    -- 原生路径: 换掉整页让数值/开关跟着刷新; 自绘路径: 重画当前自绘页
    local function reopen(tm)
        if tm then
            tm.item_table = Shelf:settingsItems()
            tm:updateItems()
        elseif Shelf._cust_reopen then
            Shelf._cust_reopen()
        end
    end

    local items = {
        {
            text = "服务器设置",
            sub_item_table_func = function() return Shelf:serverItems() end,
        },
        {
            text = "预下载",
            sub_item_table_func = function() return Shelf:prefetchItems() end,
        },
        {
            text = string.format("缓存上限: %dMB", tonumber(settings.get("cache_limit")) or 300),
            keep_menu_open = true,
            callback = function(tm)
                UI.input("缓存上限MB (50-2000)", tostring(tonumber(settings.get("cache_limit")) or 300), "超过后自动清理最久未看的图片", function(v)
                    local n = tonumber(v)
                    if n then
                        n = math.max(50, math.min(2000, math.floor(n)))
                        settings.set("cache_limit", n)
                        reopen(tm)
                        UI.info("已保存", 1)
                    end
                end)
            end,
        },
        {
            text = "自动删除旧章节缓存 (隔两章)",
            checked_func = function() return settings.get("auto_clear_chapter") ~= false end,
            keep_menu_open = true,
            callback = function()
                settings.set("auto_clear_chapter", settings.get("auto_clear_chapter") == false)
            end,
        },
        {
            text = "图片代理缩放",
            checked_func = function() return settings.get("proxy_image") ~= false end,
            keep_menu_open = true,
            callback = function()
                settings.set("proxy_image", settings.get("proxy_image") == false)
            end,
        },
        {
            text = "退出时同步进度到APP",
            checked_func = function() return settings.get("sync_progress") ~= false end,
            keep_menu_open = true,
            callback = function()
                settings.set("sync_progress", settings.get("sync_progress") == false)
            end,
        },
    }
    -- 注: 「只看漫画」开关在「☰ 漫画书架」页顶部, 这里不重复放

    local total, count = require("comic/cache").usage()
    table.insert(items, {
        text = string.format("清空图片缓存 (%.1fMB / %d张)", total / 1024 / 1024, count),
        keep_menu_open = true,
        callback = function(tm)
            UI.confirm("确定清空所有已缓存图片?", function(ok)
                if ok then
                    require("comic/cache").clear()
                    -- 先重建本页(重算 usage), 再弹提示: 反过来的话提示会被全屏菜单盖住;
                    -- 不重建的话那行"清空图片缓存 (12.3MB / 40张)"会一直停在旧数字。
                    reopen(tm)
                    UI.info("缓存已清空")
                end
            end)
        end,
    })

    return items
end

-- 四级「服务器设置」: 服务器地址 + 用户名 + 密码 (Legado Web 服务验证, 可留空)
function Shelf:serverItems()
    local function reopen(tm)
        if tm then
            tm.item_table = Shelf:serverItems()
            tm:updateItems()
        elseif Shelf._cust_reopen then
            Shelf._cust_reopen()
        end
    end

    return {
        {
            -- 下面这些都会弹输入框: 本页必须留在下层, 不然存完就无家可归了
            text = "服务器地址: " .. tostring(settings.get("server")),
            keep_menu_open = true,
            callback = function(tm)
                UI.input("服务器地址", settings.get("server"), "http://192.168.1.8:1122", function(v)
                    if v and v ~= "" then
                        settings.set("server", v)
                        reopen(tm)
                        UI.info("已保存", 1)
                    end
                end)
            end,
        },
        {
            text = "用户名 (Web服务验证, 可空): " .. tostring(settings.get("user")),
            keep_menu_open = true,
            callback = function(tm)
                UI.input("用户名", settings.get("user"), "可留空", function(v)
                    settings.set("user", v or "")
                    reopen(tm)
                    UI.info("已保存", 1)
                end)
            end,
        },
        {
            text = "密码 (Web服务验证, 可空)",
            keep_menu_open = true,
            callback = function(tm)
                UI.input("密码", settings.get("pwd"), "可留空", function(v)
                    settings.set("pwd", v or "")
                    reopen(tm)
                    UI.info("已保存", 1)
                end, true)
            end,
        },
    }
end

-- 四级「预下载」: 预取张数(翻页提前下几张) + 整章预下载(进章后后台下完本章)
function Shelf:prefetchItems()
    local function reopen(tm)
        if tm then
            tm.item_table = Shelf:prefetchItems()
            tm:updateItems()
        elseif Shelf._cust_reopen then
            Shelf._cust_reopen()
        end
    end

    return {
        {
            text = "预取张数: " .. tostring(settings.get("prefetch")),
            keep_menu_open = true,
            callback = function(tm)
                UI.input("预取张数 (0-20)", tostring(settings.get("prefetch")), "翻页提前下载的张数", function(v)
                    local n = tonumber(v)
                    if n then
                        n = math.max(0, math.min(20, math.floor(n)))
                        settings.set("prefetch", n)
                        reopen(tm)
                        UI.info("已保存", 1)
                    end
                end)
            end,
        },
        {
            text = "整章预下载 (进章后后台下完本章)",
            checked_func = function() return settings.get("prefetch_whole_chapter") == true end,
            keep_menu_open = true, -- 勾选框自己会刷新, 不用重画整页
            callback = function()
                settings.set("prefetch_whole_chapter", settings.get("prefetch_whole_chapter") ~= true)
            end,
        },
    }
end

return Shelf
