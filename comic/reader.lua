-- 漫画流式阅读器: 跨章无缝翻页 + 预取 + 磁盘缓存
-- 结构参考 legado.koplugin StreamImageView, 修复其章节切换时误用旧图片列表的 bug,
-- 并加入预取/缓存/进度记忆
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local RenderImage = require("ui/renderimage")
local ImageViewer = require("ui/widget/imageviewer")
local logger = require("logger")

local Api = require("comic/api")
local Cache = require("comic/cache")
local Progress = require("comic/progress")
local StatBridge = require("comic/statbridge")

-- 按键诊断日志: 记录阅读器收到的原始按键名
local DataStorage = require("datastorage")
local KEYLOG = DataStorage:getDataDir() .. "/legadocomic_keys.log"
local function logKey(line)
    local f = io.open(KEYLOG, "a")
    if f then f:write(os.date("%H:%M:%S "), line, "\n") f:close() end
end

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
}

local PLACEHOLDER = nil -- 懒加载占位图

local function placeholder_bb()
    if not PLACEHOLDER then
        PLACEHOLDER = RenderImage:renderImageFile("resources/koreader.png", false)
    end
    return PLACEHOLDER
end

function M:fetchImgList(ch_index)
    local data, err = Api.getBookContent(self.book.bookUrl, ch_index)
    if not data then
        return nil, err or "获取章节内容失败"
    end
    -- data 可能是字符串(html) 或 table
    local content = data
    if type(data) == "table" then
        content = data.data or data.content or ""
        self.chapter_title = data.title or self.chapter_title
    end
    local urls = Api.extractImageUrls(content)
    if #urls == 0 then
        return nil, "章节内没有图片 (可能不是漫画, 或换源后内容为空)"
    end
    return urls
end

function M:loadImage(ch_index, img_index, imglist)
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

-- 实体翻页键双保险 1: 覆盖 key_events
function M:show()
    self.key_events = {
        ShowNextImage = { { "RPgFwd", "LPgFwd", "PageDown" }, event = "ShowNextImage" },
        ShowPrevImage = { { "RPgBack", "LPgBack", "PageUp" }, event = "ShowPrevImage" },
    }
    UIManager:show(self)
    -- KOReader 原生统计桥接: 开始记录
    pcall(function()
        StatBridge:start(self.book)
        StatBridge:onPageChanged(self.cur_img or 1)
    end)
    -- 首屏渲染完成后启动预取
    self:schedulePrefetch()
end

-- 双保险 2: 单图分支会把翻页键映射成 Zoom, 直接劫持缩放处理器为翻页
-- (双指缩放手势不受影响, 只有按键触发的 ZoomIn/ZoomOut 被转成翻页)
function M:onZoomIn() self:turnPage(1) return true end
function M:onZoomOut() self:turnPage(-1) return true end

-- 直接拦截按键: 按名字模式匹配翻页, 其余交回 ImageViewer
function M:onKeyPress(key)
    local name = tostring(key.key or key.text or "?")
    logKey("key=" .. name .. " text=" .. tostring(key.text))
    local n = name:lower()
    if n:find("pgfwd") or n == "pagedown" then
        self:turnPage(1)
        return true
    end
    if n:find("pgback") or n == "pageup" then
        self:turnPage(-1)
        return true
    end
    if type(ImageViewer.onKeyPress) == "function" then
        return ImageViewer.onKeyPress(self, key)
    end
    return false
end

-- 初始化并打开: options = {book, start_ch, start_img, on_close_callback}
-- 兼容点号/冒号两种调用方式
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
        local list, err = M.fetchImgList(v, start_ch)
        if not list then
            return nil, err
        end
        v.cur_ch = start_ch
        v.imglist = list
        v.cur_img = options.start_img or 1
        if v.cur_img > #list then v.cur_img = #list end
        local bb = M.loadImage(v, start_ch, v.cur_img, list) or placeholder_bb()
        -- 多图模式构造, 启用 ImageViewer 内建翻页手势 -> onShowNextImage/onShowPrevImage
        viewer = M:new{
            book = options.book,
            cur_ch = start_ch,
            imglist = list,
            cur_img = v.cur_img,
            total_ch = options.total_ch,
            chapter_title = v.chapter_title,
            on_close_callback = options.on_close_callback,
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
    return viewer
end

function M:onClose()
    self._closed = true
    if self._prefetch_timer then
        UIManager:unschedule(self._prefetch_timer)
        self._prefetch_timer = nil
    end
    -- 保存进度并同步; 统计收尾
    if self.book and self.imglist and #self.imglist > 0 then
        pcall(function()
            Progress.save(self.book, self.cur_ch, self.cur_img, self.chapter_title)
            Api.saveBookProgress(self.book, self.cur_ch - 1, self.chapter_title)
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
    if direction == "south" and ges.pos.x >= w / 8 and ges.pos.x <= w * 7 / 8 and (self.scale_factor or 0) == 0 then
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
        if type(ImageViewer.onTap) == "function" then
            return ImageViewer.onTap(self, nil, ges) -- 中间: 菜单
        end
    end
    return true
end

function M:onShowNextImage()
    self:turnPage(1)
end

function M:onShowPrevImage()
    self:turnPage(-1)
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
        if self.total_ch and self.cur_ch >= self.total_ch then
            UI.info("已经是最后一章")
            return
        end
        target_ch = target_ch + 1
        target_img = 1
    end

    self:gotoPage(target_ch, target_img, step)
end

-- 绝对定位到 (ch, img); img == -1 表示该章末页
-- 跨章且列表未就绪时异步加载(显示提示), 就绪则立即切页
function M:gotoPage(ch_index, img_index, direction)
    direction = direction or (ch_index >= self.cur_ch and 1 or -1)

    if ch_index == self.cur_ch then
        return self:_applyPage(ch_index, img_index, self.imglist, nil, direction)
    end
    if ch_index == self.next_list_ch and self.next_list then
        return self:_applyPage(ch_index, img_index, self.next_list, self.next_title, direction)
    end
    -- 列表未预取到: 后台拉取, 显示"换章中"
    UI.loading("加载章节", function()
        return self:fetchImgList(ch_index)
    end, function(ok, list, err)
        if ok and list then
            self:_applyPage(ch_index, img_index, list, self.chapter_title, direction)
        else
            UI.error(err or "章节图片列表获取失败")
        end
    end)
end

function M:_applyPage(ch_index, img_index, list, title, direction)
    if self.image and self.image.free then
        pcall(function() self.image:free() end)
        self.image = nil
    end

    if img_index == -1 then
        img_index = #list
        if img_index < 1 then img_index = 1 end
    end
    if img_index < 1 then img_index = 1 end
    if img_index > #list then img_index = #list end

    local bb = self:loadImage(ch_index, img_index, list)
    if not bb then
        UI.info("页面加载失败, 请重试")
        return
    end

    self.cur_ch = ch_index
    self.imglist = list
    self.cur_img = img_index
    if title then self.chapter_title = title end
    if ch_index ~= (self._last_ch or ch_index) then
        -- 跨章后旧预取失效(下一章列表若匹配则已在 gotoPage 中消费)
        self.next_list = nil
        self.next_list_ch = nil
        self.next_title = nil
    end
    self._last_ch = ch_index

    if not self.images_keep_pan_and_zoom then
        self._center_x_ratio = 0.5
        self._center_y_ratio = 0.5
        self.scale_factor = self._images_orig_scale_factor or 1
    end

    self.image = bb
    self:update()
    pcall(function()
        Progress.save(self.book, self.cur_ch, self.cur_img, self.chapter_title)
    end)
    -- 统计桥接: 页变化 + 定期落盘
    pcall(function()
        StatBridge:onPageChanged(self.cur_img)
        StatBridge:checkpoint()
    end)
    self:schedulePrefetch()
end

-- 取任意章节图片列表(相邻章优先用预取)
function M:_chapterList(ch_index)
    if ch_index == self.next_list_ch and self.next_list then
        local l = self.next_list
        self.next_list = nil
        self.next_list_ch = nil
        return l
    end
    local list, err = self:fetchImgList(ch_index)
    if not list then
        logger.warn("fetch img list failed:", ch_index, err)
        return nil
    end
    return list
end

---------- 预取 ----------
function M:schedulePrefetch()
    if self._closed or self._prefetch_pending then return end
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
    if self._closed then return end

    -- 确保"下一章列表"已就绪(提前取, 跨章翻页零等待); 与图片预取数无关
    if not self.next_list and not (self.total_ch and self.cur_ch >= self.total_ch) then
        local list, err = self:fetchImgList(self.cur_ch + 1)
        if list then
            self.next_list = list
            self.next_list_ch = self.cur_ch + 1
            self.next_title = self.chapter_title
        else
            logger.dbg("prefetch next chapter failed:", err)
        end
    end

    local downloaded = false
    if n > 0 and count < n + 2 then
        for offset = 1, n do
            local src = self:_lookaheadSrc(offset)
            if src then
                local k = Cache.key(src)
                if not Cache.has(k) then
                    local data = Api.downloadImageData(self.book.bookUrl, src)
                    if data and #data > 0 then
                        Cache.put(k, data)
                    end
                    downloaded = true
                    break -- 每次 tick 只下一张, 避免卡 UI
                end
            else
                break
            end
        end
    end

    -- 还有缺口则继续调度
    if not self._closed then
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
                    self:prefetchStep(downloaded and 0 or count + 1)
                end
            end)
        end
    end
end

return M
