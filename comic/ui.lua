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
            M.error("出错: " .. tostring(res1))
            if done_fn then done_fn(false, nil) end
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
        input_type = is_password and "password" or "text",
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
