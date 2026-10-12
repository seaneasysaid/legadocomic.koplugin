-- 「关于」弹窗: 插件简介 + 版本号 + 上手步骤 + 当前状态 + 开源信息
--
-- 版本号唯一来源就在这里: _meta.lua 通过 pcall(require, "comic/about") 读取,
-- 插件菜单里的关于弹窗也读这里 —— 避免两处版本号各写各的, 升级时漏改一处。
--
-- 文案里刻意不用 emoji: KOReader 自带字体没有 emoji 字形, 会显示成空白/豆腐块,
-- 只用「·」「──」这类几何字符(与插件菜单里的 ☰ ⚙ ⭐ 同源)。段落也不要手动折行,
-- 交给 TextBoxWidget 按屏宽自己排(手动折行在不同字号/分辨率下会参差不齐)。

local M = {}

-- 插件版本号 (唯一来源: _meta.lua 也从这里读)
M.version = "1.0.6"

-- 插件描述 (_meta.lua 的 description 字段使用)
M.description = "仅阅读安卓开源阅读(legado)书库中的漫画, 流式加载+磁盘缓存"

M.repo = "github.com/seaneasysaid/legadocomic.koplugin"
M.upstream = "github.com/pengcw/legado.koplugin"

-- 图片缓存用量, 形如 "12.3MB / 40 张"; 取不到就返回 nil(关于弹窗少一行不影响主体)
local function cache_line()
    local ok, cache = pcall(require, "comic/cache")
    if not ok or type(cache) ~= "table" or type(cache.usage) ~= "function" then return nil end
    local ok2, total, count = pcall(cache.usage)
    if not ok2 or type(total) ~= "number" then return nil end
    return string.format("%.1fMB / %d 张", total / 1024 / 1024, tonumber(count) or 0)
end

-- 当前服务器地址; 空值提示去哪里填, 顺带把「连不上先看这里」说清楚
local function server_line()
    local ok, settings = pcall(require, "comic/settings")
    if not ok or type(settings) ~= "table" then return nil end
    local ok2, server = pcall(settings.get, "server")
    if not ok2 or type(server) ~= "string" or server == "" then
        return "未设置 (在「设置 → 服务器设置」里填)"
    end
    return server
end

-- 运行环境: KOReader 版本 + 设备型号。取不到就整行省略(有助于反馈问题时定位)
local function env_line()
    local ko
    local ok_v, Version = pcall(require, "version")
    if ok_v and type(Version) == "table" and Version.getShortVersion then
        local ok2, v = pcall(function() return Version:getShortVersion() end)
        if ok2 and type(v) == "string" and v ~= "" and v ~= "unknown" then
            ko = "KOReader " .. v
        end
    end
    local model
    local ok_d, Device = pcall(require, "device")
    if ok_d and type(Device) == "table" and Device.info then
        local ok3, m = pcall(function() return Device:info() end)
        if ok3 and type(m) == "string" and m ~= "" then model = m end
    end
    if ko and model then return ko .. " · " .. model end
    return ko or model
end

-- 组装关于文案。每次打开都重新算状态行(服务器/缓存可能刚改过), 所以不做缓存。
function M.build_text()
    local lines = {
        "Legado 漫画  v" .. M.version,
        "只专注看漫画的 KOReader 插件",
        "",
        "连接安卓「开源阅读」(Legado) 的 Web 服务, 把书架里的漫画按张流式加载到电纸书上阅读。不读小说、不搜索换源, 只做「书架 → 章节 → 图片流」这一条链路。",
        "",
        "── 能做什么 ──",
        "· 流式翻页: 按张加载、无缝跨话, 实体按键与触屏均可翻页",
        "· 磁盘缓存: 图片按 URL 去重落盘, 重看不耗流量, 超出上限自动清理最久未看的",
        "· 智能预取: 后台预取后续图片并提前拉下一话目录, 翻页几乎零等待",
        "· 省流量: 默认走阅读 APP 代理按屏宽缩放, 电纸书不下载原图",
        "· 进度同步: 本机与 APP 进度取较新的一份, 退出阅读器时写回 APP",
        "· 收藏夹: 常用漫画加星, 独立入口直达章节",
        "· 只看漫画: 按书架类型标记自动隐藏小说, 可一键切回显示全部",
        "· 阅读统计: 时长与张数计入 KOReader 原生「阅读统计」",
        "",
        "── 怎么开始 ──",
        "1. 手机「开源阅读」→ 我的 → Web 服务 → 启动, 记下地址",
        "2. 本插件「设置 → 服务器设置」填入该地址 (需与手机同一局域网)",
        "3. 「漫画书架 → 刷新书架」, 点书名即可开始阅读",
        "",
        "── 当前状态 ──",
        "版本: v" .. M.version,
    }

    local server = server_line()
    if server then lines[#lines + 1] = "服务器: " .. server end
    local cache = cache_line()
    if cache then lines[#lines + 1] = "图片缓存: " .. cache end
    local env = env_line()
    if env then lines[#lines + 1] = "运行环境: " .. env end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "── 关于项目 ──"
    lines[#lines + 1] = "基于 " .. M.upstream .. " 的漫画流式阅读部分剥离重构"
    lines[#lines + 1] = "上游「开源阅读」: github.com/LegadoTeam/legado"
    lines[#lines + 1] = "项目主页: " .. M.repo
    lines[#lines + 1] = "MIT License · 仅供学习交流, 请支持正版漫画"
    lines[#lines + 1] = "本插件不存储、不分发任何漫画内容, 所有漫画均通过用户自行配置的书源获取"

    return table.concat(lines, "\n")
end

-- 弹出「关于」窗口。
-- 用 KOReader 原生的 InfoMessage(不设 timeout): 与菜单栏「帮助 → 关于」同款观感,
-- 点一下/按任意键即关。给了 height 才会变成可滚动区(不给则会自动缩小字号硬塞)。
-- 文案比一屏长, 所以这里按屏高给个上限, 让普通字号滚动显示, 而不是把字压小。
function M.show()
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    local ok_msg, InfoMessage = pcall(require, "ui/widget/infomessage")
    local ok_dev, Device = pcall(require, "device")
    if not (ok_ui and ok_msg and ok_dev) then return false end

    local text = M.build_text()
    UIManager:show(InfoMessage:new{
        text = text,
        icon = "notice-info",
        -- 0.7 屏高: 再高会被 FrameContainer 的边距顶出屏幕; 留白也让「下方还有内容」看得出来
        height = math.floor(Device.screen:getHeight() * 0.7),
        dismissable = true,
    })
    return true
end

return M