-- 阻塞式 HTTP (luasocket), 改写自 legado.koplugin Helper/Http.lua, 精简为漫画所需
local logger = require("logger")

local default_headers = {
    ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
}

-- 允许跟随的重定向跳数(3 跳足够: 漫画 CDN 一般是 1 跳签名地址)
local MAX_REDIRECTS = 3

local function is_redirect(code)
    return code == 301 or code == 302 or code == 303 or code == 307 or code == 308
end

local M = {}

-- options: url, method, body, headers, timeout, maxtime, is_pic
-- 返回: true, {data, ext, headers} | nil, err_msg
function M.request(options)
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")

    local timeout = options.timeout or 10
    local maxtime = options.maxtime or (timeout + 20)
    local is_pic = options.is_pic

    local url = options.url
    local last_err

    -- ⭐ 重定向必须**自己跟**, 不能交给底层库。原因(设备源码实证, common/ssl/https.lua:126):
    --     elseif url.redirect then return nil, "redirect not supported"
    -- https 走的是 ssl.https, 它**只要看到 request.redirect 就立刻返回错误**, 连请求都不发。
    -- 而漫画 CDN 基本都是 https + 302 跳签名地址 -> 原实现「关掉图片代理后整章白图」,
    -- 日志里就是 `HTTP no headers: redirect not supported` + `无法连接服务器`。
    -- (走 Legado 的 /image 代理时是 http, socket.http 能自动跟随, 所以这个坑一直被掩盖。)
    for hop = 0, MAX_REDIRECTS do
        local parsed = socket_url.parse(url)
        if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
            return nil, "不支持的协议"
        end

        -- https 必须走 ssl.https: 只 require socket.http 的话, https 链接会被当成**明文**
        -- 打到 443 端口, 表现为"连不上服务器/返回乱码", 而不是明确告诉用户"不支持 https"。
        local http
        if parsed.scheme == "https" then
            local ok_ssl, ssl = pcall(require, "ssl.https")
            if not ok_ssl or type(ssl) ~= "table" then
                return nil, "当前环境不支持 https"
            end
            http = ssl
        else
            http = require("socket.http")
        end

        local sink = {}
        local req_headers = {}
        for k, v in pairs(default_headers) do req_headers[k] = v end
        if options.headers then
            for k, v in pairs(options.headers) do req_headers[k] = v end
        end
        if is_pic and not req_headers["Accept"] then
            req_headers["Accept"] = "image/png, image/jpeg, image/webp, image/bmp;q=0.9, image/*;q=0.7"
        end

        local source = nil
        if options.body then
            req_headers["Content-Type"] = req_headers["Content-Type"] or "application/x-www-form-urlencoded"
            req_headers["Content-Length"] = tostring(#options.body)
            source = ltn12.source.string(options.body)
        end

        socketutil:set_timeout(timeout, maxtime)

        -- ⚠️ maxtime(total_timeout) 只有走 socketutil 的自定义 sink 才真正生效 —— 而且这个 sink
        -- **必须在 set_timeout 之后**构造: socketutil.table_sink 是在**创建时**读
        -- socketutil.total_timeout 决定要不要包超时逻辑的(frontend/socketutil.lua:98-101),
        -- 顺序反了就拿不到带总时限的那个 sink。
        -- 为什么非用它不可: 裸 ltn12.sink.table 时总时限只剩 socket 层的 "t" 超时, 而 LuaSocket
        -- 每收到一块数据就用 timeout_markstart **重置**它(见 socketutil.lua:41-43 的注释), 于是
        -- 服务端"连上但慢滴"时永远撞不到总时限 -> 预算形同虚设。
        -- socketutil.table_sink 从收到第一块数据起计时, 超时返回 SINK_TIMEOUT_CODE,
        -- 正好被下面的超时分支接住。
        local sink_fn
        if type(socketutil.table_sink) == "function" then
            sink_fn = socketutil.table_sink(sink)
        else
            sink_fn = ltn12.sink.table(sink)
        end

        local request = {
            url = url,
            method = options.method or "GET",
            headers = req_headers,
            sink = sink_fn,
            source = source,
            -- ⚠️ 这里**绝对不能**写 redirect = true: ssl.https 见到它直接失败(见上面的注释)。
            -- 重定向由本函数外层的 for hop 循环手动跟随, http/https 两条路行为一致。
            redirect = false,
        }

        -- 用 pcall 兜住: luasocket 在部分异常(非法 URL / socket 被提前关闭 / 重定向环)
        -- 会**抛错**而不是返回。异常一旦穿出去就会跳过下面的 reset_timeout(), 让 socketutil
        -- 的超时/deadline 状态残留、污染后续所有请求; 预取那条路径还会把异常抛进
        -- UIManager 的定时器回调(整屏报错 + 预取链断掉)。这里统一转成 (nil, err)。
        local ok_call, code, headers, status = pcall(function()
            return socket.skip(1, http.request(request))
        end)
        socketutil:reset_timeout()
        if not ok_call then
            logger.warn("HTTP request raised:", tostring(code))
            return nil, "请求异常: " .. tostring(code)
        end

        if code == socketutil.TIMEOUT_CODE or code == socketutil.SSL_HANDSHAKE_CODE or code == socketutil.SINK_TIMEOUT_CODE then
            return nil, "请求超时: " .. tostring(code)
        end
        if headers == nil then
            logger.warn("HTTP no headers:", status or code or "network unreachable")
            return nil, "无法连接服务器"
        end

        if is_redirect(code) then
            -- socket.http 返回的 header 名统一是小写
            local location = headers["location"]
            if type(location) ~= "string" or location == "" then
                return nil, "服务器返回错误: " .. tostring(status or code)
            end
            if hop == MAX_REDIRECTS then
                logger.warn("HTTP too many redirects:", options.url)
                return nil, "重定向次数过多"
            end
            -- Location 可能是相对地址 -> 按 RFC 2396 相对原 URL 解析
            url = socket_url.absolute(url, location) or location
            last_err = "重定向到 " .. url
            logger.info("HTTP redirect", code, "->", url)
        else
            if type(code) ~= "number" or code < 200 or code > 299 then
                return nil, "服务器返回错误: " .. tostring(status or code)
            end

            local content = table.concat(sink)
            if headers["content-length"] then
                local content_length = tonumber(headers["content-length"])
                if content_length and #content ~= content_length then
                    return nil, "响应不完整"
                end
            end
            return true, { data = content, headers = headers }
        end
    end

    return nil, tostring(last_err or "重定向失败")
end

return M
