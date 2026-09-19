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
    local http = require("socket.http")
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

    local request = {
        url = url,
        method = options.method or "GET",
        headers = req_headers,
        sink = ltn12.sink.table(sink),
        source = source,
        redirect = true,
    }

    socketutil:set_timeout(timeout, maxtime)
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

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
