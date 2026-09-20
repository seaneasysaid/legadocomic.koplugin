# Legado 漫画 for KOReader (legadocomic.koplugin)

[![release](https://img.shields.io/github/v/release/seaneasysaid/legadocomic.koplugin?label=release&color=blue)](https://github.com/seaneasysaid/legadocomic.koplugin/releases)
[![downloads](https://img.shields.io/github/downloads/seaneasysaid/legadocomic.koplugin/total?label=downloads&color=yellow)](https://github.com/seaneasysaid/legadocomic.koplugin/releases)

一个 **只专注看漫画** 的 KOReader 插件：连接安卓「开源阅读」APP（Legado / 阅读 3.0）的 Web 服务，把书架里的漫画以**流式翻页**的方式在电纸书上阅读。

基于 [pengcw/legado.koplugin](https://github.com/pengcw/legado.koplugin) 的漫画流式阅读部分剥离重构而成，剔除了文本阅读/搜索/换源等功能，只保留「书架 → 章节 → 图片流」链路，并做了大量优化。

## 特性

- **流式翻页**：漫画按张加载、无缝跨话（章节），支持实体按键和触屏翻页
- **磁盘缓存**：图片按 URL 去重落盘，重看不耗流量；LRU 限额自动清理（默认 300MB，可调 50–2000MB）
- **隔话自动清缓存**：看到第 N 话自动删除第 N-2 话及更早的图片缓存，缓存体积恒定、不占空间（可开关）
- **智能预取**：显示当前页后自动后台预取后续图片（0–20 张可调），并提前拉取下一话图片列表——**翻页秒开、跨话基本零等待**
- **省流量代理**：默认走阅读 APP 的 `/image` 接口按屏幕宽度缩放，电纸书不用下载原图
- **进度记忆**：本地记住每本书读到「第几话第几张」（书架标注），退出时可同步回 APP
- **收藏快捷方式**：⭐ 收藏常用漫画，置顶显示，直达章节列表；「⭐ 收藏管理」纯点击切换，不依赖长按手势
- **计入原生阅读统计**：看漫画的时长/页数通过 KOReaderStatisticsBridge 写入 KOReader「阅读统计」（statistics.sqlite3），统计里能直接看到每本漫画
- **分级导航**：书架 → 章节 → 阅读器，逐层返回，操作路径清晰
- **书架本地缓存**：打开插件不自动联网，点「刷新书架」才拉取——对电纸书省电友好

## 环境要求

- KOReader（Kobo / Kindle / Android 等均可，实体按键设备已适配）
- 安卓手机上安装「开源阅读」APP（Legado 3.0），且**书架里有漫画源的书**
- KOReader 设备与手机在**同一局域网**

## 安装

1. 把整个 `legadocomic.koplugin` 文件夹复制到设备的 KOReader 插件目录：
   - **Kobo**：`.adds/koreader/plugins/`
   - **Kindle**：`koreader/plugins/`（或 `extensions/`，视安装方式）
   - **Android**：`koreader/plugins/`（内部存储）
2. 重启 KOReader

## 配置

### 1. 打开阅读 APP 的 Web 服务

阅读 APP → 右下角「我的」→ 「Web 服务」→ 启动。记下显示的地址，例如 `http://192.168.1.8:1122`。

> 如开启了 Web 服务鉴权，在插件设置里填上 APP 显示的用户名/密码即可（插件会自动计算签名）。

### 2. 插件里填服务器地址

KOReader → 打开插件菜单（文件管理器顶部「搜索」图标里找 **Legado 漫画**）→ `⚙ 设置`：

| 设置项 | 说明 | 默认 |
|---|---|---|
| 服务器地址 | 阅读 APP 的 Web 服务地址，如 `http://192.168.1.8:1122` | — |
| 用户名 / 密码 | 仅当 APP 的 Web 服务开启鉴权时需要 | 空 |
| 预取张数 | 当前页之后后台预下载的图片数，0–20；0 也会预取下一话列表 | 2 |
| 缓存上限 | 图片磁盘缓存上限（MB），超出按最久未访问清理 | 300MB |
| 自动删除旧章节缓存 | 隔两章自动清理：看第 N 话时删除第 N-2 话及更早的图片缓存（当前话、下一话预取、上一话回翻都保留） | 开 |
| 图片代理缩放 | 走 APP 按屏宽缩放，省流量；关闭则下载原图 | 开 |
| 退出同步进度 | 关闭阅读器时把进度写回阅读 APP | 开 |

所有设置**修改即保存**，无需确认。

## 使用

```
书架                     （首次使用点「⟳ 刷新书架」联网获取）
 ├── ⭐ 收藏区           收藏的书置顶直达（通过「⭐ 收藏管理」添加/取消）
 └── 书名 → 章节列表 → 点章节进入阅读器
```

### 阅读器操作

| 操作 | 效果 |
|---|---|
| 点屏幕**左 1/3** / 实体上一页键 | 上一张（第一章第一张会提示） |
| 点屏幕**右 1/3** / 实体下一页键 | 下一张（翻完自动进入下一话） |
| 点屏幕**中间 1/3** | 呼出菜单（原尺寸 / 旋转 / 关闭） |
| 双指缩放 | 缩放图片（按键翻页不受影响） |
| 屏幕中部**下滑** | 退出回章节列表 |

### 返回逻辑

`X` 逐层返回：阅读器 → 章节 → 书架；在书架层按 `X` 退出插件。

## 常见问题

**Q：书架是空的？**
先点「⟳ 刷新书架」。仍为空请检查：① 阅读 APP 的 Web 服务是否已启动；② 手机和阅读器是否同一局域网；③ 服务器地址是否带端口（`http://IP:1122`）。

**Q：手机 IP 变了连不上？**
阅读 APP 的 Web 服务地址含手机当前 IP，路由器重新分配后需在插件设置里更新。建议在路由器里给手机绑定静态 IP。

**Q：翻页时偶尔转圈？**
预取没跟上（网络慢或预取张数小）。把「预取张数」调大（建议 8–12）。

**Q：缓存会无限变大吗？**
不会。默认开启「自动删除旧章节缓存」：看第 N 话时自动删除第 N-2 话及更早的图片缓存，缓存恒定在「当前话 + 下一话预取 + 上一话」的量。另有「缓存上限」LRU 兜底（默认 300MB），也可在设置里一键「清空图片缓存」（显示当前用量）。

**Q：支持文本小说吗？**
不支持，本插件只处理图片型内容（章节内容含 `<img>` 即按漫画渲染）。文本阅读请用原版 [pengcw/legado.koplugin](https://github.com/pengcw/legado.koplugin)。

**Q：支持 reader3 / 轻阅读后端吗？**
当前仅支持官方「阅读 3.0」Web 服务 API。

## 阅读统计（KOReaderStatisticsBridge）

看漫画的时间会计入 KOReader 原生「阅读统计」：

- 直接读写 `statistics.sqlite3` 公开 schema（校验 schema 版本 20221111，操作 `book` / `page_stat_data` 表），不走 ReaderUI 文档管道
- 统计库不存在或为空（0 张表）时自动按官方 schema 初始化，全新设备也能正常记录
- 每本书按 `bookUrl` 的 md5 作为唯一键，在统计里显示书名/作者；时长按会话累计，每满 60 秒落一条、退出时补尾（≥5 秒）
- 页号使用全局唯一值（话号 × 100000 + 话内页号），因此每张看过的图都计为不同的一页，「已读页数」是真实张数
- 每次落盘会把这一段时间内**翻过的每一页**各记一行，时长在该段内按页均分（取整余数由最后一页吸收，总时长不受影响）——所以一分钟连翻 30 张就是 30 页，不会只算 1 页
- 需要 KOReader 的「阅读统计」插件已启用；写入失败时静默降级，不影响阅读
- 统计的是「从打开到退出阅读器的时长」，在中间菜单里停留的时间也会计入

## 致谢与许可

- 上游项目：[pengcw/legado.koplugin](https://github.com/pengcw/legado.koplugin)（流式漫画阅读的实现参考）
- 「开源阅读」：[LegadoTeam/legado](https://github.com/LegadoTeam/legado)
- 本插件仅供学习交流，请支持正版漫画。

## 免责声明

- 本插件仅供学习交流，本项目不存储、不分发任何漫画内容，所有漫画均通过用户自行配置的书源获取。
- 使用者应自行确认适用的授权条件并自行承担风险，请尊重版权、支持正版漫画。
- 如涉及侵权请联系删除。

MIT License

## 项目推荐

如果你也在电纸书上看书，这些是我维护的其他 KOReader 项目，欢迎一并试试：

| 插件 | 简介 |
| --- | --- |
| [readingstats.koplugin](https://github.com/seaneasysaid/readingstats.koplugin) | 轻量版阅读统计 · 阅读足迹 —— KOReader 插件：日历阅读统计 + GitHub 风格热力图 + 阅读分析（含年度/月度书籍排行） |
| [fanqie.koplugin-fixed](https://github.com/seaneasysaid/fanqie.koplugin-fixed) | KOReader 番茄小说插件非官方增强版：适配书山聚合 + 知秋段评，正文无广告，节点测速自动切换（非官方增强版，fork 自 hesan1232/fanqie.koplugin） |
| [leko-reader-fixed](https://github.com/seaneasysaid/leko-reader-fixed) | 全程本地运行的 KOReader 网络小说插件，支持 Legado 兼容书源，致力于让阅读轻快流畅 |
| [koreader-remote](https://github.com/seaneasysaid/koreader-remote) | KOReader Wi-Fi 无线控制网站：手机浏览器即可远程操作电纸书（[在线版](https://seaneasysaid.github.io/koreader-remote/)） |
