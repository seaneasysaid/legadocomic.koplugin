-- KOReaderStatisticsBridge: 把漫画阅读时长/页数写入 KOReader 原生 statistics.sqlite3
-- 参考 jnjnnjzch/leko-reader 的 Leko/KOReaderStatisticsBridge.lua (AGPL-3.0)
-- 只操作公开 schema: 校验 user_version == 20221111, 写 book / page_stat_data
local DataStorage = require("datastorage")
local logger = require("logger")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")

local M = {}

local SCHEMA_VERSION = 20221111
local VIRTUAL_PAGE_COUNT = 10000 -- 漫画无固定总页数, 用足够大的虚拟页数
local MIN_SECONDS, MAX_SECONDS = 5, 120
local CHECKPOINT_SECONDS = 60    -- 每 60 秒落一条统计(翻页快慢不影响计时长)

local function md5hex(str)
    local sha = require("ffi/sha2")
    local ok, digest = pcall(sha.md5, str)
    if ok and digest then return digest end
    return nil
end

function M.identityForBook(book)
    return md5hex("legadocomic\0" .. tostring(book and book.bookUrl or "")) or tostring(book and book.bookUrl or "")
end

function M:_open()
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(path, "mode") ~= "file" then
        return nil, "statistics.sqlite3 不存在 (KOReader 阅读统计插件未启用?)"
    end
    local ok, db = pcall(SQ3.open, path)
    if not ok or not db then return nil, "无法打开统计数据库" end
    local version = tonumber(db:rowexec("PRAGMA user_version;"))
    local book = db:rowexec("SELECT name FROM sqlite_master WHERE type='table' AND name='book';")
    local data = db:rowexec("SELECT name FROM sqlite_master WHERE type='table' AND name='page_stat_data';")
    if version ~= SCHEMA_VERSION or not book or not data then
        pcall(db.close, db)
        return nil, "统计库 schema 版本不受支持: " .. tostring(version)
    end
    return db
end

function M:_getOrCreateBook(book, md5, now)
    local db, err = self:_open()
    if not db then return nil, err end
    local stmt
    local ok, result = pcall(function()
        stmt = db:prepare("SELECT id FROM book WHERE md5 = ? ORDER BY id LIMIT 1;")
        local row = stmt:reset():bind(md5):step()
        local id = row and tonumber(row[1])
        pcall(stmt.close, stmt); stmt = nil
        if id then return id end
        db:exec("BEGIN IMMEDIATE;")
        stmt = db:prepare([[INSERT INTO book
            (title, authors, notes, last_open, highlights, pages, series, language, md5, total_read_time, total_read_pages)
            VALUES (?, ?, 0, ?, 0, ?, 'N/A', 'N/A', ?, 0, 0);]])
        stmt:reset():bind(tostring(book.name or "漫画"), tostring(book.author or "N/A"), now, VIRTUAL_PAGE_COUNT, md5):step()
        pcall(stmt.close, stmt); stmt = nil
        id = tonumber(db:rowexec("SELECT last_insert_rowid();"))
        db:exec("COMMIT;")
        return id
    end)
    pcall(stmt.close, stmt)
    if not ok then pcall(db.exec, db, "ROLLBACK;") end
    pcall(db.close, db)
    return ok and result or nil, ok and nil or tostring(result)
end

function M:_writePeriods(id, periods, now)
    if not id or #periods == 0 then return true end
    local db, err = self:_open()
    if not db then return nil, err end
    local stmt
    local ok, result = pcall(function()
        db:exec("BEGIN IMMEDIATE;")
        stmt = db:prepare([[INSERT OR IGNORE INTO page_stat_data
            (id_book, page, start_time, duration, total_pages) VALUES (?, ?, ?, ?, ?);]])
        for _, p in ipairs(periods) do
            stmt:reset():bind(id, p.page, p.start_time, p.duration, p.total_pages or VIRTUAL_PAGE_COUNT):step()
        end
        pcall(stmt.close, stmt); stmt = nil
        local count, seconds = db:rowexec(string.format(
            "SELECT count(DISTINCT page), sum(duration) FROM page_stat WHERE id_book = %d;", id))
        stmt = db:prepare("UPDATE book SET pages=?, last_open=?, total_read_time=?, total_read_pages=? WHERE id=?;")
        stmt:reset():bind(VIRTUAL_PAGE_COUNT, now, tonumber(seconds) or 0, tonumber(count) or 0, id):step()
        pcall(stmt.close, stmt); stmt = nil
        db:exec("COMMIT;")
        return true
    end)
    pcall(stmt.close, stmt)
    if not ok then pcall(db.exec, db, "ROLLBACK;") end
    pcall(db.close, db)
    if not ok then logger.warn("legadocomic stats write failed:", tostring(result)) end
    return ok and result or nil
end

-- book = {name, author, bookUrl}; 失败静默降级, 绝不影响阅读
function M:start(book)
    if self._closed then self._closed = nil end
    if not self.enabled then return false end
    local now = os.time()
    local id, err = self:_getOrCreateBook(book, M.identityForBook(book), now)
    if not id then
        logger.warn("legadocomic stats bridge unavailable:", err)
        return false
    end
    self.book_id = id
    self.book = book
    self.current_page = 1
    self.period_start = now
    self.period_origin = now
    self.period_elapsed = 0
    self.periods = {}
    return true
end

function M:_finish(now)
    if not self.period_start then return end
    local elapsed = (self.period_elapsed or 0) + math.max(0, now - self.period_start)
    if elapsed >= MIN_SECONDS then
        self.periods[#self.periods + 1] = {
            page = self.current_page or 1,
            start_time = self.period_origin,
            duration = math.min(elapsed, MAX_SECONDS),
            total_pages = VIRTUAL_PAGE_COUNT,
        }
    end
    self.period_start, self.period_origin, self.period_elapsed = nil, nil, 0
end

-- 页变化: (跨章也调) 结束当前时段, 记新页
function M:onPageChanged(page)
    if not self.book_id then return end
    local now = os.time()
    self:_finish(now)
    self.current_page = math.max(1, tonumber(page) or self.current_page or 1)
    self.period_start, self.period_origin = now, now
end

-- 定期落盘: 累计时段 >= CHECKPOINT_SECONDS 时切一条并写库
function M:checkpoint()
    if not self.book_id or not self.period_start then return end
    local now = os.time()
    local elapsed = (self.period_elapsed or 0) + (now - self.period_start)
    if elapsed < CHECKPOINT_SECONDS then return end
    self:_finish(now)
    if #self.periods > 0 then
        self:_writePeriods(self.book_id, self.periods, now)
        self.periods = {}
    end
    -- 空档期继续计
    self.period_start, self.period_origin = now, now
end

-- 阅读器关闭: 收尾
function M:close()
    if not self.book_id then return end
    local now = os.time()
    self:_finish(now)
    if #self.periods > 0 then
        self:_writePeriods(self.book_id, self.periods, now)
        self.periods = {}
    end
    self.book_id = nil
end

M.enabled = true -- TODO: 接设置项
return M
