-- 轻量 UI 辅助: loading 包装 / 提示 / 确认 / 输入
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")

local M = {}

function M.info(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 3,
    })
end

function M.error(text)
    M.info(text, 5)
end

-- UTF-8 安全截断: 按「字符数」截断, 超出才加省略号。
-- 注意: 不能用 string.sub(s, 1, n) —— 中文一个字 3 字节, 按字节切会把某个字切成半个,
-- 菜单里就显示成乱码/豆腐块(第 40 字节未必落在字符边界上)。
function M.ellipsize(text, max_chars, ellipsis)
    local s = tostring(text or "")
    local n = tonumber(max_chars)
    if not n or n <= 0 then return s end
    local count, i, len = 0, 1, #s
    while i <= len do
        local b = s:byte(i)
        count = count + 1
        if count > n then return s:sub(1, i - 1) .. (ellipsis or "…") end
        -- 按 UTF-8 首字节推断该字符占几个字节(1/2/3/4)
        i = i + (b < 0x80 and 1 or (b < 0xE0 and 2 or (b < 0xF0 and 3 or 4)))
    end
    return s
end

-- 阻塞工作包装: 显示提示 -> 后台 tick 执行 -> 回调
function M.loading(text, work_fn, done_fn)
    local dialog
    dialog = InfoMessage:new{
        text = text .. " …",
        dismissable = false,
    }
    UIManager:show(dialog)
    UIManager:scheduleIn(0.1, function()
        local ok, res1, res2 = pcall(work_fn)
        UIManager:close(dialog)
        if not ok then
            -- 工作函数抛异常: 把异常当作错误原因交给回调统一提示。
            -- 若这里自己再 M.error 一次, 回调里的兜底提示会叠成两条(修复前就是这样)。
            if done_fn then done_fn(false, nil, "出错: " .. tostring(res1)) end
            return
        end
        if done_fn then done_fn(res1 ~= nil, res1, res2) end
    end)
end

function M.confirm(text, callback)
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = "确定",
        cancel_text = "取消",
        ok_callback = function() callback(true) end,
        cancel_callback = function() callback(false) end,
    })
end

function M.input(title, value, hint, callback, is_password)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = value or "",
        input_hint = hint,
        -- KOReader 的输入掩码参数是 text_type="password"(inputtext.lua:568
        -- is_password_type = text_type == "password"); 以前写成 input_type 是无效的,
        -- 密码在设置页是明文显示的。input_type 只用于 "number"(数字键盘布局), 这里不传。
        text_type = is_password and "password" or nil,
        buttons = {{
            {
                text = "取消",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "保存",
                is_enter_default = true,
                callback = function()
                    local v = dialog:getInputText()
                    UIManager:close(dialog)
                    callback(v)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return M
