-- legado 安卓 app Web 服务客户端(仅漫画所需接口)
local logger = require("logger")
local util = require("util")
local Screen = require("device").screen
local httpreq = require("comic/httpreq")
local settings = require("comic/settings")

local M = {}

local function tohex(raw)
    if type(raw) ~= "string" then return "" end
    if #raw == 64 then return raw end -- 已是 hex
    return (raw:gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end

-- legado app 鉴权: key = sha256("user:pwd") hex
-- 图片下载每张都要拼 URL, 而 user/pwd 很少变 → 结果缓存, 配置变动时失效
local _auth_cache_key, _auth_cache_val
function M.authKey()
    local user = tostring(settings.get("user") or "")
    local pwd = tostring(settings.get("pwd") or "")
    if user == "" then return nil end
    local sig = user .. "\0" .. pwd
    if _auth_cache_key == sig then return _auth_cache_val end
    local sha = require("ffi/sha2")
    local ok, digest = pcall(sha.sha256, user .. ":" .. pwd)
    if not ok or type(digest) ~= "string" or #digest == 0 then return nil end
    _auth_cache_key, _auth_cache_val = sig, tohex(digest)
    return _auth_cache_val
end

local function addKey(params)
    local key = M.authKey()
    if key then params.key = key end
    return params
end

function M.buildUrl(path, params)
    local base = tostring(settings.get("server") or ""):gsub("/+$", "")
    params = params or {} -- 不传 params 时也要带上鉴权 key(否则写进临时表被丢掉)
    local query = {}
    addKey(params)
    for k, v in pairs(params) do
        query[#query + 1] = k .. "=" .. util.urlEncode(tostring(v))
    end
    local q = #query > 0 and ("?" .. table.concat(query, "&")) or ""
    return base .. path .. q
end

-- 请求并解析 JSON, 返回 data 或 nil, err
function M.getJSON(path, params, timeout)
    local url = M.buildUrl(path, params)
    local ok, resp = httpreq.request({
        url = url,
        timeout = timeout or 10,
        maxtime = (timeout or 10) + 15,
    })
    if not ok then return nil, resp end
    local JSON = require("json")
    local okj, body = pcall(JSON.decode, resp.data)
    if not okj or type(body) ~= "table" then
        return nil, "返回内容不是有效 JSON"
    end
    if body.isSuccess == false then
        local msg = body.errorMsg or body.data or "请求失败"
        if type(msg) ~= "string" then msg = tostring(msg) end
        return nil, msg
    end
    return body.data
end

function M.getBookshelf()
    return M.getJSON("/getBookshelf", { refresh = 0, v = os.time() }, 10)
end

function M.getChapterList(bookUrl)
    return M.getJSON("/getChapterList", { url = bookUrl, v = os.time() }, 15)
end

function M.getBookContent(bookUrl, index)
    -- 正文 HTML 通常只有几十 KB。原来给 25s(timeout)/40s(maxtime) 过宽: 预取「下一章列表」
    -- 每 0.5s 一轮、最多重试 3 次, 弱网下最坏能把 UI 反复冻住两分钟。降到 12s/27s,
    -- 局域网内取正文绰绰有余, 而最坏冻结时间直接砍掉一半。
    return M.getJSON("/getBookContent", { url = bookUrl, index = index, v = os.time() }, 12)
end

-- ===== 章节索引换算 =====
-- 注意: /getBookContent 的 index 不是"目录第几项", 而是章节自身的 index 字段
-- (Legado 内部从 0 开始编号)。两者在多数书里恰好差 1, 但会随书源/刷新目录变化,
-- 所以一律以 /getChapterList 返回的 chapter.index 为准。
local chapter_index_map = {} -- bookUrl -> { [目录位置] = API index }
local chapter_pos_map = {}   -- bookUrl -> { [API index] = 目录位置 } (反向, 供 App 进度定位)
local chapter_title_map = {} -- bookUrl -> { [目录位置] = 章节标题 } (进度显示/同步用)

local function buildIndexMap(chapters)
    local map = {}
    if type(chapters) ~= "table" then return map end
    for i, ch in ipairs(chapters) do
        local api_index
        if type(ch) == "table" then api_index = tonumber(ch.index) end
        if api_index == nil then api_index = i - 1 end -- 兜底: Legado 索引从 0 开始
        map[i] = api_index
    end
    return map
end

-- 反向映射: API index(0-based) -> 目录位置(1-based)
-- 用于把 App 端 durChapterIndex 反向定位回 Kindle 的目录位置
local function buildPosMap(chapters)
    local map = {}
    if type(chapters) ~= "table" then return map end
    for i, ch in ipairs(chapters) do
        local api_index
        if type(ch) == "table" then api_index = tonumber(ch.index) end
        if api_index == nil then api_index = i - 1 end
        map[api_index] = i
    end
    return map
end

local function buildTitleMap(chapters)
    local map = {}
    if type(chapters) ~= "table" then return map end
    for i, ch in ipairs(chapters) do
        if type(ch) == "table" and ch.title ~= nil then map[i] = ch.title end
    end
    return map
end

-- 书架取到目录后调用, 把映射喂进来 (省掉阅读器再请求一次)
function M.seedChapterList(bookUrl, chapters)
    if type(bookUrl) ~= "string" or type(chapters) ~= "table" then return end
    local map = buildIndexMap(chapters)
    chapter_index_map[bookUrl] = map
    chapter_pos_map[bookUrl] = buildPosMap(chapters)
    chapter_title_map[bookUrl] = buildTitleMap(chapters)
    -- 诊断: 便于在设备日志里确认书源是否提供了 index 字段
    local has_index = type(chapters[1]) == "table" and tonumber(chapters[1].index) ~= nil
    logger.info("comic chapter map:", #chapters, "items | chapter.index field:",
        has_index and "yes" or "no", "| pos1 ->", map[1], "pos2 ->", map[2])
end

-- 目录第 position 项 -> /getBookContent 需要的 index
-- allow_fetch=false 时只查缓存, 不发网络请求 (用于退出时上报进度)
function M.toApiIndex(bookUrl, position, allow_fetch)
    position = tonumber(position) or 1
    local map = chapter_index_map[bookUrl]
    if not map and allow_fetch ~= false then
        local chapters = M.getChapterList(bookUrl)
        if type(chapters) == "table" then
            map = buildIndexMap(chapters)
            chapter_index_map[bookUrl] = map
            chapter_pos_map[bookUrl] = buildPosMap(chapters)
            chapter_title_map[bookUrl] = buildTitleMap(chapters)
        else
            logger.warn("comic: chapter list unavailable, fallback to 0-based index")
        end
    end
    if map and map[position] ~= nil then return map[position] end
    return position - 1
end

-- API index (0-based, /getBookContent 用的 index) -> 目录第几项 (1-based)
-- 用途: 把 App 端 durChapterIndex 反向定位回 Kindle 的目录位置, 供"续读"使用。
-- allow_fetch=false 时只查缓存, 不发网络请求。
function M.toPosition(bookUrl, api_index, allow_fetch)
    api_index = tonumber(api_index)
    if api_index == nil then return nil end
    local map = chapter_pos_map[bookUrl]
    if not map and allow_fetch ~= false then
        local chapters = M.getChapterList(bookUrl)
        if type(chapters) == "table" then
            chapter_index_map[bookUrl] = buildIndexMap(chapters)
            map = buildPosMap(chapters)
            chapter_pos_map[bookUrl] = map
            chapter_title_map[bookUrl] = buildTitleMap(chapters)
        end
    end
    if map and map[api_index] ~= nil then return map[api_index] end
    return api_index + 1 -- 兜底: 多数书 index = 位置-1
end

-- 目录第 position 项的标题 (1-based)。标题以 /getChapterList 为准 ——
-- /getBookContent 通常只回正文 html, 拿不到标题, 所以别指望它。
-- allow_fetch=false 时只查缓存。
function M.chapterTitle(bookUrl, position, allow_fetch)
    position = tonumber(position)
    if type(bookUrl) ~= "string" or position == nil then return nil end
    local map = chapter_title_map[bookUrl]
    if not map and allow_fetch ~= false then
        local chapters = M.getChapterList(bookUrl)
        if type(chapters) == "table" then
            chapter_index_map[bookUrl] = buildIndexMap(chapters)
            chapter_pos_map[bookUrl] = buildPosMap(chapters)
            map = buildTitleMap(chapters)
            chapter_title_map[bookUrl] = map
        end
    end
    local t = map and map[position]
    if type(t) == "string" then return t end
    return nil
end

-- 已缓存的目录长度(只查缓存, 不发网络请求)。
-- 「继续阅读」直达没带 total_ch, 用它兜底 —— 正常路径上 fetchImgList -> toApiIndex 已把目录喂进来了。
function M.chapterCount(bookUrl)
    local map = chapter_index_map[bookUrl]
    if type(map) ~= "table" then return nil end
    local n = 0
    for _ in pairs(map) do n = n + 1 end
    if n > 0 then return n end
    return nil
end

-- 从正文 html 提取图片地址
-- 旧正则 '<img[^>]-src%s*=%s*...' 有三个真实坑:
--  1) 标签名/属性名大小写: 有的站点输出 `<IMG SRC=...>` / `<Img Src=...>`, 旧写法只认小写
--     -> 整章被判"章节内没有图片";
--  2) 懒加载: 常见的 `<img data-src="真图" src="占位.gif">` 里, 旧写法会先撞上 data-src 中那段
--     "src"(属性名正好以 src 结尾), 抓回的是占位图。
-- 现在 ① 标签名与属性名都按大小写不敏感匹配(HTML 里它们本就不区分大小写);
--      ② 属性名前必须紧跟空白或 "/" —— 精确锚定"属性名就叫 src"(排除 data-src / xdata-src 之类);
--      ③ 一个 src 都没有时, 再退一步去认 data-src / data-original 这类懒加载属性。
local function ci(word) -- 把 ASCII 单词转成大小写不敏感的 pattern 片段
    local out = {}
    for i = 1, #word do
        local c = word:sub(i, i)
        if c:match("%a") then
            out[#out + 1] = "[" .. c:lower() .. c:upper() .. "]"
        else
            out[#out + 1] = "%" .. c -- 转义 "-" 等 pattern 元字符(否则会被当成懒惰量词)
        end
    end
    return table.concat(out)
end

local IMG_TAG_PREFIX = "<" .. ci("img") .. "[^>]-"
local IMG_SRC_PATTERN = IMG_TAG_PREFIX .. "[%s/]" .. ci("src") .. "%s*=%s*[\"']?([^\"'>%s]+)"
local LAZY_ATTRS = { "data-src", "data-original", "data-lazy-src", "data-echo" }
local LAZY_SRC_PATTERNS = {}
for _, attr in ipairs(LAZY_ATTRS) do
    LAZY_SRC_PATTERNS[#LAZY_SRC_PATTERNS + 1] =
        IMG_TAG_PREFIX .. "[%s/]" .. ci(attr) .. "%s*=%s*[\"']?([^\"'>%s]+)"
end

-- 还原 HTML 实体(图片 URL 里出现 `&amp;` 时, 不还原会让查询参数错乱甚至请求被截断)
local function decode_entities(s)
    if not s:find("&", 1, true) then return s end
    s = s:gsub("&amp;", "&")
    s = s:gsub("&#38;", "&")
    s = s:gsub("&#x26;", "&")
    return s
end

-- 把相对图片地址补成绝对地址(基于 bookUrl 的 scheme+host)。
-- 背景: 书源正文里常见 `src="/x.jpg"` 或 `src="//cdn/x.jpg"`。原样交给 httpreq 会因为
-- socket_url.parse 得到 scheme=nil 而返回"不支持的协议" -> **整章图片全失败**, 用户只看到
-- "页面加载失败"。
-- 只处理**能明确补全**的这两种; 路径相对的 `a/b.jpg` 基准是原站页面而不是 bookUrl,
-- 猜错比明确报错更糟, 所以原样返回交给上层报错。
local function make_absolute(src, base_url)
    if type(base_url) ~= "string" then return src end
    if src:sub(1, 2) == "//" then
        local scheme = base_url:match("^(%a[%w+.-]*)://") or "http"
        return scheme .. "://" .. src:sub(3)
    end
    if src:sub(1, 1) == "/" then
        local scheme, host = base_url:match("^(%a[%w+.-]*)://([^/]+)")
        if scheme and host then return scheme .. "://" .. host .. src end
    end
    return src
end

-- 提取正文里的图片地址。第二个参数(可选的 bookUrl)只用于补全相对地址。
function M.extractImageUrls(content, base_url)
    if type(content) ~= "string" then return {} end
    local urls = {}
    local function push(src)
        if src == "" then return end
        urls[#urls + 1] = make_absolute(decode_entities(src), base_url)
    end
    for src in content:gmatch(IMG_SRC_PATTERN) do push(src) end
    if #urls > 0 then return urls end
    for _, pattern in ipairs(LAZY_SRC_PATTERNS) do
        for src in content:gmatch(pattern) do push(src) end
        if #urls > 0 then return urls end
    end
    return urls
end

-- legado app 图片代理: 按屏幕宽度缩放, 大幅减少下载量
function M.proxyImageUrl(bookUrl, imgSrc)
    if settings.get("proxy_image") == false then return nil end
    local width = Screen:getWidth() or 800
    return M.buildUrl("/image", { url = bookUrl, path = imgSrc, width = width })
end

-- 下载图片(二进制), 带代理->直连回退 + 失败重试
-- 弱网/热点下偶发失败很常见, 重试 1 次能挡掉大部分"页面加载失败"
-- maxtime 是**单次请求的总时限**(socketutil:set_timeout(timeout, maxtime)): 服务端"连上但一直
-- 慢滴"时靠它兜底。取 30s —— 原来是 60s, 叠加"2 轮 × (代理+直连)"最坏能把 UI 冻 4 分钟,
-- 而代理图已按屏宽缩放(通常几百 KB), 30s 足够。
-- opts.budget: 本次下载的总时长预算(秒), 缺省 30。
--   后台预取传更短的值(见 reader.lua 的 PREFETCH_BUDGET_SECONDS): 这些请求是 UI 线程上的
--   同步 HTTP, 前台翻页等的是"这一张", 后台等的是"以后那几张", 两者不该用同一个预算。
function M.downloadImageData(bookUrl, imgSrc, opts)
    local candidates = {}
    local proxied = M.proxyImageUrl(bookUrl, imgSrc)
    if proxied and proxied ~= imgSrc then
        candidates[#candidates + 1] = proxied
    end
    candidates[#candidates + 1] = imgSrc

    -- 单次下载的总时长预算(秒): 2 轮 × (代理 + 直连), 默认 30s(前台), 后台可传更短。
    -- 这些请求全在 UI 线程上同步跑(翻页 / 预取), 所以必须有个**真能生效**的总闸:
    --   ① 每次发起请求**之前**先算剩余预算, 用尽就不再发 —— 旧写法是请求返回之后才检查,
    --      拦不住已经发出去的那一次, 最坏仍要 ~60s 才发现超预算;
    --   ② 剩余预算直接当单次请求的 maxtime, "连上但慢滴"的请求也不会跑满 30s 才被放弃。
    local BUDGET_SECONDS = tonumber(opts and opts.budget) or 30
    -- 再短就没意义了(连一次握手都不够), 夹一个下限防止调用方传进 0/负数
    if BUDGET_SECONDS < 3 then BUDGET_SECONDS = 3 end
    local last_err, last_status
    local started = os.time()
    for attempt = 1, 2 do
        for _, url in ipairs(candidates) do
            local remain = BUDGET_SECONDS - (os.time() - started)
            if remain <= 1 then
                logger.warn("comic image download budget exceeded:", imgSrc, last_err)
                return nil, tostring(last_err or "图片下载超时"), last_status
            end
            local ok, resp = httpreq.request({
                url = url,
                timeout = math.min(15, remain),
                maxtime = math.min(30, remain),
                is_pic = true,
            })
            if ok and type(resp.data) == "string" and #resp.data > 0 then
                return resp.data
            end
            last_err = resp
            -- 第 3 个返回值: HTTP 状态码。调用方靠它区分「403 = 签名过期」这类确定性失败
            -- (resp 形如 "服务器返回错误: HTTP/1.1 403 Forbidden", 取第一段三位数字)。
            last_status = tonumber(tostring(resp or ""):match("(%d%d%d)") or "")
        end
    end
    logger.warn("comic image download failed:", imgSrc, last_err)
    return nil, tostring(last_err or "图片下载失败"), last_status
end

-- 同步进度到 app (best-effort)
-- chapterIndex: 1-based 目录位置(toApiIndex 期望, 与 fetchImgList 一致); chapterPos: 章内位置(漫画=图片序号)
function M.saveBookProgress(book, chapterIndex, chapterTitle, chapterPos)
    if settings.get("sync_progress") == false then return end
    if not (type(book) == "table" and type(book.name) == "string" and type(book.bookUrl) == "string") then
        return
    end
    -- app 侧 /saveBookProgress 收的是 JSON body (Content-Type: application/json), 不是表单
    local api_index = M.toApiIndex(book.bookUrl, chapterIndex, false)
    local JSON = require("json")
    local body = JSON.encode({
        name = book.name,
        author = book.author or "",
        url = book.bookUrl,
        durChapterIndex = api_index,
        durChapterPos = chapterPos or 0,
        durChapterTitle = chapterTitle or "",
        durChapterTime = os.time() * 1000,
    })
    local ok, resp = httpreq.request({
        url = M.buildUrl("/saveBookProgress", { v = os.time() }),
        method = "POST",
        headers = { ["Content-Type"] = "application/json" },
        body = body,
        timeout = 6,
        maxtime = 10,
    })
    if not ok then
        logger.warn("comic saveBookProgress failed:", tostring(resp))
    else
        logger.info("comic saveBookProgress ->", book.name, "index", api_index)
    end
end

return M
