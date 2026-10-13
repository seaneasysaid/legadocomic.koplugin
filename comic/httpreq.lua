-- 阻塞式 HTTP (luasocket), 改写自 legado.koplugin Helper/Http.lua, 精简为漫画所需
local logger = require("logger")

local default_headers = {
    ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
}

local M = {}

-- options: url, method, body, headers, timeout, maxtime, is_pic
-- 返回: true, {data, ext, headers} | nil, err_msg
function M.request(options)
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")

    local url = options.url
    local timeout = options.timeout or 10
    local maxtime = options.maxtime or (timeout + 20)
    local is_pic = options.is_pic

    local parsed = socket_url.parse(url)
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return nil, "不支持的协议"
    end

    -- https 必须走 ssl.https: 只 require socket.http 的话, https 链接会被当成**明文**
    -- 打到 443 端口, 表现为"连不上服务器/返回乱码", 而不是明确告诉用户"不支持 https"。
    -- ssl.https 与 socket.http 是同一套 API(request/sink/redirect 都一样)。
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
        redirect = true,
    }

    -- 用 pcall 兜住: luasocket 在部分异常(非法 URL / socket 被提前关闭 / redirect 环)
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

return M
