-- 漫画流式阅读器: 跨章无缝翻页 + 预取 + 磁盘缓存
-- 结构参考 legado.koplugin StreamImageView, 修复其章节切换时误用旧图片列表的 bug,
-- 并加入预取/缓存/进度记忆
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen
local RenderImage = require("ui/renderimage")
local ImageViewer = require("ui/widget/imageviewer")
local logger = require("logger")

local Api = require("comic/api")
local Cache = require("comic/cache")
local Progress = require("comic/progress")
local StatBridge = require("comic/statbridge")

local UI = require("comic/ui")
local settings = require("comic/settings")

local M = ImageViewer:extend{
    book = nil,
    cur_ch = 1,
    imglist = {},
    cur_img = 1,
    next_list = nil,        -- 预取的下一章图片列表
    next_list_ch = nil,     -- next_list 对应的章节号
    on_close_callback = nil,
    _closed = false,
    _prefetch_pending = false,
    _prefetch_timer = nil,
    _prefetch_fail = 0,     -- 预取连续失败计数(坏图/断网时到上限就停, 避免 0.5s 死循环)
    _nextlist_fail = 0,     -- 「下一章列表」连续取失败计数(同样的闸, 但它走的是网络接口)
}

-- 预取连续失败上限: 同一轮里连续失败这么多次就放弃本次预取
-- (翻页会重新 schedulePrefetch 并把计数清零, 所以不会永久卡住)
local PREFETCH_MAX_FAIL = 3

-- 占位图(首屏加载失败时顶上去的那张): **必须每次新建**, 不能缓存共享。
-- 它会被交给 ImageViewer(image_disposable=true), 换页时由 _applyPage、退出时由 onClose
-- 显式 :free() 释放; 而 BlitBuffer:free 只释放底层缓冲区、**不会**把 data 置 nil
-- (blitbuffer.lua:1472-1478)。缓存复用的写法会让模块变量继续指向那块已释放内存 ——
-- 下一次"首屏加载失败"再取出来画, 就是 use-after-free(花屏/崩溃)。
-- RenderImage:renderImageFile 本身没有内部缓存, 每次读盘生成新 BB, 直接返回即可。
local function placeholder_bb()
    return RenderImage:renderImageFile("resources/koreader.png", false)
end

-- 返回 (图片url列表, 章节标题) 或 (nil, 错误原因)
-- 注意: 这里**不要**写 self.chapter_title —— 预取下一章时会顺手把"当前章标题"冲成下一章的,
-- 导致本地进度和同步到 App 的章节标题整体错一章。标题交给调用方决定怎么用。
function M:fetchImgList(ch_index)
    -- 目录位置 -> Legado 的章节 index (从 0 开始), 否则会整体错位一章
    local api_index = Api.toApiIndex(self.book.bookUrl, ch_index)
    local data, err = Api.getBookContent(self.book.bookUrl, api_index)
    if not data then
        return nil, err or "获取章节内容失败"
    end
    -- data 可能是字符串(html) 或 table
    local content, title = data, nil
    if type(data) == "table" then
        content = data.data or data.content or ""
        title = data.title
    end
    -- 传 bookUrl 进去: 正文里的相对地址(src="/x.jpg"、src="//cdn/x.jpg")要靠它补成绝对地址,
    -- 否则 httpreq 会以"不支持的协议"整体失败 -> 整章无图。
    local urls = Api.extractImageUrls(content, self.book.bookUrl)
    if #urls == 0 then
        return nil, "章节内没有图片 (可能不是漫画, 或换源后内容为空)"
    end
    return urls, title
end

-- 取(或下载)该章第 img_index 张图并渲染成 BlitBuffer; 失败返回 nil
function M:loadImage(img_index, imglist)
    local src = imglist[img_index]
    if not src then return nil end
    local data = Cache.fetch(self.book.bookUrl, src, Api.downloadImageData)
    if not data then return nil end
    local bb = RenderImage:renderImageData(data, #data, false)
    if not bb then
        logger.warn("comic image render failed:", src)
        return nil
    end
    return bb
end

function M:show()
    -- 注意: 这里**不能**改写 self.key_events —— KOReader 的按键表是由父类
    -- InputContainer:onKeyPress 去遍历 self.key_events 才生效的(inputcontainer.lua:232),
    -- 而 ImageViewer:init 已经按机型建好了 Close(Back)/ZoomIn/ZoomOut/Pan* 那几张表
    -- (imageviewer.lua:87-101)。以前这里整体覆盖成翻页表, 两个后果:
    --   ① 覆盖用的写法本身也不合法: {"RPgFwd","LPgFwd","PageDown"} 会被 Key:match
    --      当成"这三个键同时按住"才命中(key.lua:60), 永远匹配不上 —— 纯死代码;
    --   ② 顺手把父类的 Close={Back} 冲掉了, 硬件/系统返回键(安卓返回键、遥控页的 Back)
    --      在漫画页彻底失灵。翻页键由下面的 M:onKeyPress 接管, 这里不需要动键表。
    UIManager:show(self)
    -- KOReader 原生统计桥接: 开始记录
    local ok_s, err_s = pcall(function()
        StatBridge:start(self.book)
        StatBridge:onPageChanged((self.cur_ch or 1) * 100000 + (self.cur_img or 1))
    end)
    if not ok_s then logger.warn("legadocomic statbridge start error:", tostring(err_s)) end
    -- 首屏渲染完成后启动预取
    self:schedulePrefetch()
end

-- 兜底: ImageViewer:init 在"单图(image 传的是 BlitBuffer)"分支把翻页键组映射成
--   ZoomIn  = { { Device.input.group.PgBack } }   -- PgBack = 上一页键
--   ZoomOut = { { Device.input.group.PgFwd } }    -- PgFwd  = 下一页键
-- (imageviewer.lua:94-97; 分组定义见 input.lua:117-118)
-- 所以方向必须对应成 onZoomIn -> 上一页、onZoomOut -> 下一页。以前写反了
-- (onZoomIn 翻下一页), 只是被上面 onKeyPress 的名字匹配先拦下才没暴露;
-- 真走到这条兜底就是"按下一页键反而倒退"。双指缩放手势走的是另一条路, 不受影响。
function M:onZoomIn() self:turnPage(-1) return true end
function M:onZoomOut() self:turnPage(1) return true end

-- 直接拦截按键: 按名字模式匹配翻页, 其余交回 ImageViewer
function M:onKeyPress(key)
    local name = tostring(key.key or key.text or "?")
    local n = name:lower()
    if n:find("pgfwd") or n == "pagedown" then
        self:turnPage(1)
        return true
    end
    if n:find("pgback") or n == "pageup" then
        self:turnPage(-1)
        return true
    end
    -- 返回键: 父类键表里那条 Close={Back} 是靠下面"回落父类"才生效的, 这里显式再兜一次,
    -- 保证即使父类没建键表(无实体键/无映射的机型)也能退出漫画页。
    if n == "back" or n == "esc" then
        self:onClose()
        return true
    end
    if type(ImageViewer.onKeyPress) == "function" then
        return ImageViewer.onKeyPress(self, key)
    end
    return false
end

-- 初始化并打开: options = {book, start_ch, start_img, on_close_callback}
-- 兼容点号/冒号两种调用方式
-- 注: 加载是异步的(UI.loading 内部 scheduleIn 0.1s), 这里无法返回 viewer
function M.fetchAndShow(a, b)
    local options = (a == M) and b or a
    if type(options) ~= "table" or type(options.book) ~= "table" then
        UI.error("参数错误")
        return
    end
    local viewer
    UI.loading("加载章节", function()
        -- 不经 :new 构造, 避免空 image 初始化; 仅作方法载体
        local v = { book = options.book }
        local start_ch = options.start_ch or 1
        -- 第二个返回值: 成功时是章节标题(/getBookContent 返回 table 且带 title 时), 失败时是错误原因
        local list, title_or_err = M.fetchImgList(v, start_ch)
        if not list then
            return nil, title_or_err
        end
        v.cur_ch = start_ch
        v.imglist = list
        v.cur_img = options.start_img or 1
        -- 下界也要夹: Lua 里 `0 or 1` 仍是 0(0 是 truthy), 任何 img=0/负数的进度记录
        -- 会让 loadImage 拿不到图 -> 首屏顶占位图, 还把非法 img 写回进度(自我延续)。
        if v.cur_img < 1 then v.cur_img = 1 end
        if v.cur_img > #list then v.cur_img = #list end
        local bb = M.loadImage(v, v.cur_img, list) or placeholder_bb()
        -- 多图模式构造, 启用 ImageViewer 内建翻页手势 -> onShowNextImage/onShowPrevImage
        viewer = M:new{
            book = options.book,
            cur_ch = start_ch,
            imglist = list,
            cur_img = v.cur_img,
            -- 总章数: 优先用调用方传入(章节目录已知); 否则用刚才 fetchImgList 顺带取到的目录长度兜底 ——
            -- 「继续阅读」直达这条路径没传 total_ch, 补上末章边界提示/预取保护才生效
            total_ch = options.total_ch or Api.chapterCount(options.book.bookUrl),
            -- 首章标题: 优先用内容接口带回的 title, 否则查目录(原写法读 v.chapter_title, 恒 nil)
            chapter_title = title_or_err or Api.chapterTitle(options.book.bookUrl, start_ch),
            on_close_callback = options.on_close_callback,
            _session_start = os.time(), -- 本次打开漫画的时间(隔章清理用)
            image = bb,
            fullscreen = true,
            with_title_bar = false,
            image_disposable = true,
            images_list_nb = 4,
            image_padding = 0,
        }
        return true
    end, function(ok, res, err)
        if viewer then
            viewer:show()
        else
            UI.error(err or "打开失败")
        end
    end)
end

function M:onClose()
    -- 重入保护: 硬件返回键与手势可能各触发一次 onClose, 没有这道闸
    -- on_close_callback 会跑两遍(退回书架时叠出两层章节列表), 进度/统计也重复上报。
    if self._closed then return end
    self._closed = true
    -- 目录弹层开着的话一并关掉, 免得退回章节目录后还叠着一层
    if self._toc_menu then
        pcall(function() UIManager:close(self._toc_menu) end)
        self._toc_menu = nil
    end
    if self._prefetch_timer then
        UIManager:unschedule(self._prefetch_timer)
        self._prefetch_timer = nil
    end
    -- 保存进度并同步; 统计收尾
    if self.book and self.imglist and #self.imglist > 0 then
        -- 本地进度同步写完(纯磁盘操作, 毫秒级); 回传 App 的请求是 **UI 线程上的同步 HTTP**
        -- (api.lua 里 timeout=6 / maxtime=10)。它原来排在 ImageViewer.onClose(-> UIManager:close)
        -- 之前, 弱网/服务端"连上不吐数据"时按返回键要卡 6~10 秒画面才真退出。
        -- 改为推到 widget 关掉之后再发(延迟 0.05s), 失败也不影响退出。
        local book, cur_ch, cur_img = self.book, self.cur_ch, self.cur_img
        local title, total_ch = self.chapter_title, self.total_ch
        -- img 要**双向**夹取: widget 可能是手工构造的(cur_img 为 nil), 也可能停在越界值上;
        -- 原样写进进度后, 下次续读会拿去当 start_img —— 虽然 _applyPage 会再夹一次,
        -- 但配置里长期存着非法页码本身就是脏数据。
        local n = #self.imglist
        local img = math.min(math.max(tonumber(cur_img) or 1, 1), math.max(n, 1))
        pcall(function()
            Progress.save(book, cur_ch, img, title, total_ch)
        end)
        UIManager:scheduleIn(0.05, function()
            pcall(function() Api.saveBookProgress(book, cur_ch, title, img) end)
        end)
    end
    pcall(function() StatBridge:close() end)
    if self.image and self.image.free then
        pcall(function() self.image:free() end)
        self.image = nil
    end
    ImageViewer.onClose(self)
    if type(self.on_close_callback) == "function" then
        self.on_close_callback()
    end
end

function M:onSwipe(_, ges)
    local direction = ges.direction
    local w = Screen:getWidth()
    -- 中部区域下滑关闭
    -- (与原生 ImageViewer 对齐: scale_factor == 0 即"铺满屏幕"未缩放时才关闭;
    --  已缩放时不关闭, 交给下面父类做平移, 免得误退)
    -- 注: 这里以前只 return true 吞掉手势、并没有真的关闭, 所以"中部下滑退出"一直是无效的
    if direction == "south" and ges.pos.x >= w / 8 and ges.pos.x <= w * 7 / 8 and (self.scale_factor or 0) == 0 then
        self:onClose()
        return true
    end
    if type(ImageViewer.onSwipe) == "function" then
        return ImageViewer.onSwipe(self, nil, ges)
    end
    return false
end

-- 单击分区翻页: 左1/3上一张, 右1/3下一张, 中间1/3呼出菜单
function M:onTap(_, ges)
    if (self.scale_factor or 0) ~= 0 then
        -- 缩放状态下交给 ImageViewer 原生处理
        if type(ImageViewer.onTap) == "function" then
            return ImageViewer.onTap(self, nil, ges)
        end
        return false
    end
    local w = Screen:getWidth()
    local x = ges.pos.x
    if x < w / 3 then
        self:turnPage(-1)
    elseif x > w * 2 / 3 then
        self:turnPage(1)
    else
        -- 中间 1/3: **不能**回落父类 —— 单图模式下 ImageViewer:onTap 的中间语义是
        -- `buttons_visible = not buttons_visible`(imageviewer.lua:544-548), 于是漫画页
        -- 点中间会弹出一整条缩放/旋转工具栏(还把图片压小), 完全不是我们要的"呼出菜单"。
        -- 漫画语义下中间=呼出目录, 与遥控页的「目录」按钮一致。
        self:showTocMenu()
    end
    return true
end

function M:onShowNextImage()
    self:turnPage(1)
end

function M:onShowPrevImage()
    self:turnPage(-1)
end

-- ==================== KOReader 事件接入（只接遥控页上有的按钮） ====================
-- 事件分发链: UIManager:sendEvent(ev) -> 逐层调 widget:handleEvent(ev)
--   -> 命中 self["on"..ev.name] 才调用, 返回 true 表示"已消费"。
-- 这个阅读器不是 ReaderUI, ReaderPaging / ReaderToc 那批事件处理器都不在场,
-- 所以 KOReader 的"翻页/目录"事件一路传到栈底也没人接、会被静默丢弃
-- (遥控网页的"上一页 / 下一页 / 目录"按钮发的就是这批事件名)。
-- 这里只按漫画语义补这两条 —— 遥控页上没有的东西不实现。
-- 注: 全刷 / 夜间 / 亮度 / 色温 这 4 个屏幕级按钮在漫画页没反应——
-- 它们由 DeviceListener 处理, 而 DeviceListener 只挂在标准
-- FileManager/ReaderUI 的 active_widgets 上, 这个自绘 widget 没注册它,
-- 所以 sendEvent 传不到这里 (被静默丢弃), 且要读硬件状态再写回, 暂不实现。
-- 本 widget 自己实现的事件 handler: 翻页(onGotoViewRel) / 目录(onShowToc) / 休眠(onRequestSuspend)。
-- 旋转曾实现过, 但 e-ink 局部刷新会留残影, 已按需求删除。

-- 相对翻 n 张 (n 可正可负, 覆盖 GotoViewRel/10 这类跳页)
function M:turnPages(n)
    n = tonumber(n) or 0
    if n == 0 then return end
    if n == 1 then return self:turnPage(1) end
    if n == -1 then return self:turnPage(-1) end

    local dir = n > 0 and 1 or -1
    local target_img = self.cur_img + n
    if target_img >= 1 and target_img <= #self.imglist then
        return self:gotoPage(self.cur_ch, target_img) -- 章内够翻
    end
    -- 跨章: 不做"多章累加"(那得把中间章节全拉下来数图), 直接落到相邻章首页/末页, 行为可预期
    if dir > 0 then
        if self:_atLastChapter() then
            UI.info("已经是最后一章")
            return
        end
        return self:gotoPage(self.cur_ch + 1, 1)
    end
    if self.cur_ch <= 1 then
        UI.info("已经是第一章")
        return
    end
    return self:gotoPage(self.cur_ch - 1, -1) -- -1 = 该章末页
end

-- 翻页: 遥控页"上一页 / 下一页"按钮发的是 GotoViewRel
-- (GotoViewRel/1 = 下一张, /-1 = 上一张)
function M:onGotoViewRel(diff)
    if not diff or diff == 0 then return true end
    self:turnPages(diff)
    return true
end

-- 休眠: 遥控页"休眠"按钮发 RequestSuspend。同样本 widget 收不到屏幕级事件,
-- 直接调框架挂起 (与 DeviceListener:onRequestSuspend 同逻辑)。
function M:onRequestSuspend()
    UIManager:suspend()
    return true
end

-- 目录: 在阅读器内弹出话目录, 选中即跳话 (不退出阅读器)
function M:onShowToc()
    self:showTocMenu()
    return true
end

function M:showTocMenu()
    if self._toc_menu then
        pcall(function() UIManager:close(self._toc_menu) end)
        self._toc_menu = nil
    end
    UI.loading("获取章节列表", function()
        return Api.getChapterList(self.book.bookUrl)
    end, function(ok, chapters, err)
        -- 取目录是异步的(scheduleIn 0.1s), 这期间用户可能已经退出阅读器;
        -- 不再弹菜单, 否则会在章节目录上凭空多出一层
        if self._closed then return end
        if not ok or type(chapters) ~= "table" or #chapters == 0 then
            UI.error(err or "章节列表为空")
            return
        end
        Api.seedChapterList(self.book.bookUrl, chapters) -- 供 index 换算
        local items = {}
        for i, ch in ipairs(chapters) do
            -- 按「字符数」截断(UTF-8 安全): 原来的 title:sub(1,40) 是按字节切,
            -- 中文一个字 3 字节 -> 第 40 字节常常落在字的中间, 菜单里出现半个字/乱码
            local title = UI.ellipsize(ch.title or ("第 " .. i .. " 话"), 40)
            local idx = i
            table.insert(items, {
                text = string.format("%s%d. %s", (i == self.cur_ch and "▸ " or ""), idx, title),
                callback = function()
                    if self._toc_menu then
                        UIManager:close(self._toc_menu)
                        self._toc_menu = nil
                    end
                    if idx ~= self.cur_ch then
                        self:gotoPage(idx, 1)
                    end
                end,
            })
        end
        local Menu = require("ui/widget/menu")
        self._toc_menu = Menu:new{
            title = "目录 · " .. tostring(self.book.name or ""),
            item_table = items,
            is_borderless = true,
            is_popout = false,
            fullscreen = true,
            width = Screen:getWidth(),
            height = Screen:getHeight(),
            items_per_page = 14,
            single_line = true,
            -- 弹层被它自己的路径关掉时(点弹层外 / 硬件 Back 键 -> Menu:onCloseAllMenus)
            -- 也要跟着收回引用, 否则 _toc_menu 悬空: 下次 ShowToc 会先去 close 一个
            -- 已经关掉的弹层
            close_callback = function() self._toc_menu = nil end,
        }
        UIManager:show(self._toc_menu)
    end)
end

-- 是否已经在最后一章。
-- total_ch 已知时直接比; 未知时(从「继续阅读」直达、目录映射还没建)退回用
-- Api.chapterCount 再探一次 —— 该函数只查映射缓存、不发网络请求, 零成本。
-- 原来只写 `self.total_ch and self.cur_ch >= self.total_ch`, total_ch 为 nil 时保护整体失效,
-- 会去请求一个不存在的下一章: 轻则弹"获取失败", 重则某些书源对越界 index 返回兜底内容 ->
-- 页码错乱。
function M:_atLastChapter()
    if not self.total_ch then
        self.total_ch = Api.chapterCount(self.book.bookUrl)
    end
    if not self.total_ch then return false end -- 仍然不知道总章数: 不拦, 交给空列表兜底
    return self.cur_ch >= self.total_ch
end

-- 方向翻页: step = ±1, 跨章无缝
function M:turnPage(step)
    local target_img = self.cur_img + step
    local target_ch = self.cur_ch

    if target_img == 0 then
        -- 回退到上一章末页
        if target_ch <= 1 then
            UI.info("已经是第一章")
            return
        end
        target_ch = target_ch - 1
        target_img = -1 -- 表示待获取上一章末页
    elseif target_img > #self.imglist then
        -- 前进到下一章
        if self:_atLastChapter() then
            UI.info("已经是最后一章")
            return
        end
        target_ch = target_ch + 1
        target_img = 1
    end

    self:gotoPage(target_ch, target_img)
end

-- 绝对定位到 (ch, img); img == -1 表示该章末页
-- 跨章且列表未就绪时异步加载(显示提示), 就绪则立即切页
function M:gotoPage(ch_index, img_index)
    if ch_index == self.cur_ch then
        return self:_applyPage(ch_index, img_index, self.imglist, nil)
    end
    if ch_index == self.next_list_ch and self.next_list then
        return self:_applyPage(ch_index, img_index, self.next_list, self.next_title)
    end
    -- 列表未预取到: 后台拉取, 显示"换章中"
    UI.loading("加载章节", function()
        return self:fetchImgList(ch_index)
    end, function(ok, list, title_or_err)
        -- 取章节内容是 UI 线程上的同步请求(最长 25s+ 的 getBookContent), 这期间用户完全可能
        -- 已经退出阅读器(返回键现在真的能用了)。不拦的话回调会对**已关闭**的 widget 继续
        -- _applyPage: 白下载一屏图(把界面卡住)、把进度写到用户已经离开的书上、还对着已关闭的
        -- 控件 setDirty。目录弹层那条路径早就加了这道闸, 这里补上。
        if self._closed then return end
        -- 第二个返回值: 成功时是章节标题, 失败时是错误原因
        if ok and list then
            self:_applyPage(ch_index, img_index, list, title_or_err)
        else
            UI.error(title_or_err or "章节图片列表获取失败")
        end
    end)
end

-- 自动清理: 进入第 N 章时, 删除第 N-2 章及更早章节的缓存图片
-- (当前章 + 下一章预取的图保留, 上一章保留方便回翻)
-- 双保险: 同时把"修改时间早于本次打开漫画"且不在保留集合里的文件一并删掉,
-- 这样跨会话的孤儿文件也能清掉, 不依赖会话内的章节记忆
function M:_autoClearOldChapters(new_ch)
    if settings.get("auto_clear_chapter") == false then return end
    local keep = {}
    for _, u in ipairs(self.imglist or {}) do keep[u] = true end
    if self.next_list then
        for _, u in ipairs(self.next_list) do keep[u] = true end
    end
    -- 1) 按会话内记录的章节 url 列表删
    local lists = self._loaded_lists or {}
    local removed = 0
    for ch, urls in pairs(lists) do
        if ch <= new_ch - 2 then
            removed = removed + Cache.removeUrls(urls, keep)
            lists[ch] = nil
        end
    end
    -- 2) 按时间删孤儿(早于本次打开漫画、且 key 不在保留集合)
    -- 保留集合 = 当前章 + 下一章 + 上一章。上一章必须显式保留: step 1 的删除阈值是 new_ch-2,
    -- 上一章本就要留, 但之前 keep_keys 漏了它, 会让「跨会话缓存的上-章图片」被 pruneBefore 误删,
    -- 与函数注释「上一章保留方便回翻」矛盾。
    --
    -- ⚠️ 时间基准要**往回退一个宽限期**: pruneBefore 是按 mtime 扫**整个**缓存目录的, 没有
    -- bookUrl 维度 —— 若直接用"本次打开漫画的时间", 用户在同一会话里换一本书看, 上一本书的
    -- 缓存(还有别的没读完的书)会因为 mtime 更早而被整片删掉。
    -- 退 7 天之后: 很久以前的孤儿照样清得掉, 而最近读过的书不会被误伤。
    local PRUNE_GRACE_SECONDS = 7 * 24 * 3600
    local keep_keys = {}
    for u in pairs(keep) do keep_keys[Cache.key(u)] = true end
    for _, u in ipairs(lists[new_ch - 1] or {}) do keep_keys[Cache.key(u)] = true end
    local cutoff = (self._session_start or os.time()) - PRUNE_GRACE_SECONDS
    removed = removed + Cache.pruneBefore(cutoff, keep_keys)
    if removed > 0 then
        logger.info("legadocomic auto-cleared", removed, "cached images (entering ch", new_ch, ")")
    end
end

function M:_applyPage(ch_index, img_index, list, title)
    if img_index == -1 then
        img_index = #list
        if img_index < 1 then img_index = 1 end
    end
    if img_index < 1 then img_index = 1 end
    if img_index > #list then img_index = #list end

    local bb = self:loadImage(img_index, list)
    if not bb then
        -- 失败时**不要**碰旧图: self.image 保持原样, 界面还能显示上一张, 用户重试即可。
        -- (修复前是"先 free 旧图再 load", 加载失败提前 return 时 self.image=nil, 但
        --  self._image_wg 里仍留着那张已释放的 bb —— ImageWidget 在不缩放时 _bb 就是同一个
        --  bb, 且父类拿到的是 image_disposable=false 不会接管释放, 于是之后任何重绘都在画
        --  已释放内存, 轻则花屏重则崩溃。)
        UI.info("页面加载失败, 请重试")
        return
    end

    -- 新图就绪后才释放旧图
    if self.image and self.image.free then
        pcall(function() self.image:free() end)
    end

    -- 先取旧章信息(此时 self.cur_ch / imglist 还是上一章的)
    -- 注: 用 self.cur_ch 而不是另设的 _last_ch —— 后者只在下面赋值, 「打开后第一次就跨章跳」
    -- 时还是 nil, 会让下面的隔章清理/记录判断落空; self.cur_ch 在此刻永远是上一章
    local old_ch, old_list = self.cur_ch, self.imglist

    self.cur_ch = ch_index
    self.imglist = list
    self.cur_img = img_index
    -- 标题: 优先用调用方传入的, 否则查目录(标题以 /getChapterList 为准)。
    -- ⚠️ 换章时标题必须**跟着换**: 解析不到就清空 —— 保留旧值会让本地进度和上报 App 的
    -- durChapterTitle 继续沿用上一章, 而 durChapterIndex 已经是新章("章节号对、标题错一章")。
    -- 同章内翻页时调用方不传标题(title 为 nil), 这时绝不能清, 否则每翻一页都会把
    -- 已经解析好的标题冲掉。
    if ch_index ~= old_ch then
        self.chapter_title = title or Api.chapterTitle(self.book.bookUrl, ch_index)
    elseif title then
        self.chapter_title = title
    end
    -- 总章数兜底: 目录已在映射缓存里时零成本(从「继续阅读」直达进来时 options.total_ch 为 nil)
    if not self.total_ch then self.total_ch = Api.chapterCount(self.book.bookUrl) end
    if ch_index ~= old_ch then
        -- 记住刚离开这一章的 url 列表(供隔章清理)
        self._loaded_lists = self._loaded_lists or {}
        if old_ch and old_list and #old_list > 0 then
            self._loaded_lists[old_ch] = old_list
        end
        -- ⚠️ 也要登记**新落到这一章**的列表: _autoClearOldChapters 用 lists[new_ch-1] 来
        -- "保留上一章", 而该表只在"离开某章"时才写入。TOC 从第1话直接跳到第5话时,
        -- 第4话从没被"离开"过 -> lists[4] 为空 -> 第4话的缓存会被 pruneBefore 按时间误删,
        -- 与函数注释「上一章保留方便回翻」矛盾。这里补登记后, 跳章场景也能正确保留上一章。
        if #list > 0 then
            self._loaded_lists[ch_index] = list
        end
        -- 跨章后旧预取失效(下一章列表若匹配则已在 gotoPage 中消费)
        self.next_list = nil
        self.next_list_ch = nil
        self.next_title = nil
        -- 隔两章清理: 删除第 N-2 章及更早的缓存
        self:_autoClearOldChapters(ch_index)
    end

    if not self.images_keep_pan_and_zoom then
        self._center_x_ratio = 0.5
        self._center_y_ratio = 0.5
        self.scale_factor = self._images_orig_scale_factor or 1
    end

    self.image = bb
    self:update()
    pcall(function()
        Progress.save(self.book, self.cur_ch, self.cur_img, self.chapter_title, self.total_ch)
    end)
    -- 统计桥接: 页变化 + 定期落盘 (页号用全局唯一值: 章号*100000+章内页号, 每张图都计为不同页)
    pcall(function()
        StatBridge:onPageChanged(ch_index * 100000 + img_index)
        StatBridge:checkpoint()
    end)
    self:schedulePrefetch()
end

---------- 预取 ----------
function M:schedulePrefetch()
    if self._closed or self._prefetch_pending then return end
    -- 新一页/新一轮预取: 失败计数清零, 给坏图/坏接口一次新的机会
    self._prefetch_fail = 0
    self._nextlist_fail = 0
    -- prefetch=0 时仍预取下一章"列表"(体积很小), 跨章才不卡
    self._prefetch_pending = true
    self._prefetch_timer = UIManager:scheduleIn(0.3, function()
        self._prefetch_pending = false
        self._prefetch_timer = nil
        if not self._closed then
            self:prefetchStep(0)
        end
    end)
end

-- lookahead: 距当前页的偏移, 返回图片 url 或 nil(没有更多)
-- 当前章剩余 + 已预取的下一章(仅支持跨一章)
function M:_lookaheadSrc(offset)
    if offset < 1 then return nil end
    local idx = self.cur_img + offset
    if idx <= #self.imglist then
        return self.imglist[idx]
    end
    if self.next_list_ch == self.cur_ch + 1 and self.next_list then
        idx = idx - #self.imglist
        if idx >= 1 and idx <= #self.next_list then
            return self.next_list[idx]
        end
    end
    return nil
end

-- 每次下载一张, 未满则继续调度
function M:prefetchStep(count)
    count = count or 0
    local n = tonumber(settings.get("prefetch")) or 2
    -- 「整章预下载」开启时, 把预取范围扩到覆盖本章剩余全部图片(仍逐张下, 不阻塞 UI)。
    -- ⚠️ 必须封顶: 每个 tick 只下一张(下面 break), tick 间隔 0.5s, 且下载本身是 UI 线程上的
    -- 同步 HTTP。200 张的章节按 `n = remain` 原样展开要 200+ 个 tick(≈100s 里界面反复被同步
    -- 请求占用), 表现为长时间卡顿。封顶之后每章最多的"主动预下载"就被限制在 60 张内,
    -- 剩下的图仍会在翻到时按需下载(不影响正确性, 只是不再提前囤)。
    local PREFETCH_WHOLE_MAX = 60
    if settings.get("prefetch_whole_chapter") == true and self.imglist then
        local remain = #self.imglist - self.cur_img + 1
        if remain > n then n = math.min(remain, PREFETCH_WHOLE_MAX) end
    end
    if self._closed then return end

    -- 确保"下一章列表"已就绪(提前取, 跨章翻页零等待); 与图片预取数无关。
    -- 失败也要计数: 这是 UI 线程上的同步请求(超时 25s), 不加闸的话每 0.5s 一个 tick 都会重发,
    -- 弱网下等于把界面反复冻住。翻页会 schedulePrefetch(把计数清零) -> 重新给机会。
    if not self.next_list and not self:_atLastChapter()
        and (self._nextlist_fail or 0) < PREFETCH_MAX_FAIL then
        local list, title_or_err = self:fetchImgList(self.cur_ch + 1)
        if list then
            self.next_list = list
            self.next_list_ch = self.cur_ch + 1
            self.next_title = title_or_err
            self._nextlist_fail = 0
        else
            self._nextlist_fail = (self._nextlist_fail or 0) + 1
            logger.dbg("prefetch next chapter failed:", title_or_err)
        end
    end

    local got_one = false -- 本轮是否真的下到一张(只有成功才重置 count/失败计数)
    if n > 0 and count < n + 2 then
        for offset = 1, n do
            local src = self:_lookaheadSrc(offset)
            if src then
                local k = Cache.key(src)
                if not Cache.has(k) then
                    local data = Api.downloadImageData(self.book.bookUrl, src)
                    if data and #data > 0 then
                        Cache.put(k, data)
                        self._prefetch_fail = 0
                        got_one = true
                    else
                        -- 下载失败: 累计失败次数。修复前这里也置 downloaded=true,
                        -- 导致每 0.5s 重试同一张坏图直到关阅读器(无限重试)。
                        self._prefetch_fail = (self._prefetch_fail or 0) + 1
                    end
                    break -- 每次 tick 只下一张, 避免卡 UI
                end
            else
                break
            end
        end
    end

    if self._closed then return end
    -- 连续失败到上限就放弃本轮(坏图/断网), 交给翻页时重新调度
    if (self._prefetch_fail or 0) >= PREFETCH_MAX_FAIL then
        logger.dbg("comic prefetch gave up after", self._prefetch_fail, "consecutive failures")
        return
    end

    -- 还有缺口则继续调度
    local need_more = false
    for offset = 1, n do
        local src = self:_lookaheadSrc(offset)
        if src and not Cache.has(Cache.key(src)) then
            need_more = true
            break
        end
    end
    if need_more then
        self._prefetch_pending = true
        self._prefetch_timer = UIManager:scheduleIn(0.5, function()
            self._prefetch_pending = false
            self._prefetch_timer = nil
            if not self._closed then
                self:prefetchStep(got_one and 0 or count + 1)
            end
        end)
    end
end

return M
