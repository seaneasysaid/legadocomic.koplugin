local _ = require("gettext")

-- 版本号和描述统一从 comic/about.lua 读取, 避免「_meta 里一个版本号、关于弹窗里另一个」。
-- _meta.lua 由插件扫描阶段用 dofile 加载, 此时 package.path 已包含插件根目录,
-- 所以 require("comic/about") 可用; 但仍用 pcall + 硬编码兜底, 万一读取失败
-- 插件管理器里至少还有正确的名字和描述, 而不是整个插件消失。
local ok_about, about = pcall(require, "comic/about")
local version = (ok_about and about and about.version) or "1.0.5"
local description = (ok_about and about and about.description)
    or "仅阅读安卓开源阅读(legado)书库中的漫画, 流式加载+磁盘缓存"

return {
    title = "Legado 漫画流式阅读",
    description = description,
    version = version,
}