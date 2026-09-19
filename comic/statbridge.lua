-- KOReaderStatisticsBridge: 把漫画阅读时长/页数写入 KOReader 原生 statistics.sqlite3
-- 只操作公开 schema: 校验 user_version == 20221111, 写 book / page_stat_data
-- 漫画适配: 翻页快, 单页常不足 5s, 不按页计时; 改为会话累计, 每 60s 落一条
local DataStorage = require("datastorage")
local logger = require("logger")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")

local M = {}

local SCHEMA_VERSION = 20221111
local VIRTUAL_PAGE_COUNT = 10000 -- 漫画无固定总页数, 用足够大的虚拟页数
local FLUSH_INTERVAL = 60        -- 每 60s 落一条统计
local MIN_TAIL_SECONDS = 5       -- 退出时剩余时长 >= 5s 才补一条

local function md5hex(str)
    local sha = require("ffi/sha2")
    local ok, digest = pcall(sha.md5, str)
    if ok and digest then return digest end
    return nil
end

function M.identityForBook(book)
    return md5hex("legadocomic\0" .. tostring(book and book.bookUrl or "")) or tostring(book and book.bookUrl or "")
end

local function _createSchema(db)
    -- 与 statistics.koplugin 的 createDB 相同的官方 schema (schema 20221111)
    db:exec("BEGIN IMMEDIATE;")
    db:exec([[CREATE TABLE IF NOT EXISTS book
        (
            id integer PRIMARY KEY autoincrement,
            title text,
            authors text,
            notes      integer,
            last_open  integer,
            highlights integer,
            pages      integer,
            series text,
            language text,
            md5 text,
            total_read_time  integer,
            total_read_pages integer
        );]])
    db:exec([[CREATE TABLE IF NOT EXISTS page_stat_data
        (
            id_book     integer,
            page        integer NOT NULL DEFAULT 0,
            start_time  integer NOT NULL DEFAULT 0,
            duration    integer NOT NULL DEFAULT 0,
            total_pages integer NOT NULL DEFAULT 0,
            UNIQUE (id_book, page, start_time),
            FOREIGN KEY(id_book) REFERENCES book(id)
        );]])
    db:exec("CREATE INDEX IF NOT EXISTS book_title_authors_md5 ON book(title, authors, md5);")
    db:exec("CREATE INDEX IF NOT EXISTS page_stat_data_start_time ON page_stat_data(start_time);")
    db:exec([[CREATE TABLE IF NOT EXISTS numbers
        (
            number INTEGER PRIMARY KEY
        );]])
    db:exec("WITH RECURSIVE counter AS (SELECT 1 as N UNION ALL SELECT N + 1 FROM counter WHERE N < 1000) INSERT INTO numbers SELECT N AS number FROM counter;")
    db:exec([[CREATE VIEW IF NOT EXISTS page_stat AS
        SELECT id_book, first_page + idx - 1 AS page, start_time, duration / (last_page - first_page + 1) AS duration
        FROM (
            SELECT id_book, page, total_pages, pages, start_time, duration,
                ((page - 1) * pages) / total_pages + 1 AS first_page,
                max(((page - 1) * pages) / total_pages + 1, (page * pages) / total_pages) AS last_page,
                idx
            FROM page_stat_data
            JOIN book ON book.id = id_book
            JOIN (SELECT number as idx FROM numbers) AS N ON idx <= (last_page - first_page + 1)
        );]])
    db:exec("PRAGMA user_version=20221111;")
    db:exec("COMMIT;")
end

function M:_open()
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local mode = lfs.attributes(path, "mode")
    local need_init = false
    if mode ~= "file" then
        -- 库文件不存在: 直接新建并初始化官方 schema
        need_init = true
    end
    local ok, db = pcall(SQ3.open, path)
    if not ok or not db then return nil, "无法打开统计数据库" end
    if need_init then
        local okc = pcall(_createSchema, db)
        if not okc then pcall(db.close, db); return nil, "初始化统计库失败" end
        logger.info("legadocomic: initialized new statistics.sqlite3")
        return db
    end
    local version = tonumber(db:rowexec("PRAGMA user_version;"))
    local book = db:rowexec("SELECT name FROM sqlite_master WHERE type='table' AND name='book';")
    local data = db:rowexec("SELECT name FROM sqlite_master WHERE type='table' AND name='page_stat_data';")
    if not book and not data and (version == 0 or version == nil) then
        -- 空库 (0 张表, user_version 0): 原地初始化 schema
        local okc = pcall(_createSchema, db)
        if not okc then pcall(db.close, db); return nil, "初始化统计库失败" end
        logger.info("legadocomic: initialized empty statistics.sqlite3")
        return db
    end
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
    if stmt then pcall(stmt.close, stmt) end
    if not ok then pcall(db.exec, db, "ROLLBACK;") end
    pcall(db.close, db)
    return ok and result or nil, ok and nil or tostring(result)
end

function M:_flushSpan(end_now)
    -- 把 [last_flush, end_now) 这段时间记到当前页
    if not self.book_id or not self._anchor then return true end
    local duration = end_now - self._anchor
    if duration < MIN_TAIL_SECONDS then
        -- 太短: 滚动累计到下一段 (起点不动, 但把时间并入 pending)
        self._pending = (self._pending or 0) + duration
        self._anchor = end_now
        if (self._pending or 0) < FLUSH_INTERVAL then return true end
        duration = self._pending
        self._pending = 0
    end
    local row = {
        page = self.current_page or 1,
        start_time = end_now - duration,
        duration = duration,
        total_pages = VIRTUAL_PAGE_COUNT,
    }
    local db, err = self:_open()
    if not db then logger.warn("legadocomic stats unavailable:", err); return nil end
    logger.info("legadocomic stats: flushing", duration, "s (page", row.page, "book", self.book_id, ")")
    local stmt
    local ok, result = pcall(function()
        db:exec("BEGIN IMMEDIATE;")
        stmt = db:prepare([[INSERT OR IGNORE INTO page_stat_data
            (id_book, page, start_time, duration, total_pages) VALUES (?, ?, ?, ?, ?);]])
        stmt:reset():bind(self.book_id, row.page, row.start_time, row.duration, row.total_pages):step()
        pcall(stmt.close, stmt); stmt = nil
        local count, seconds = db:rowexec(string.format(
            "SELECT count(DISTINCT page), sum(duration) FROM page_stat WHERE id_book = %d;", self.book_id))
        stmt = db:prepare("UPDATE book SET pages=?, last_open=?, total_read_time=?, total_read_pages=? WHERE id=?;")
        stmt:reset():bind(VIRTUAL_PAGE_COUNT, end_now, tonumber(seconds) or 0, tonumber(count) or 0, self.book_id):step()
        pcall(stmt.close, stmt); stmt = nil
        db:exec("COMMIT;")
    end)
    if stmt then pcall(stmt.close, stmt) end
    if not ok then pcall(db.exec, db, "ROLLBACK;") end
    pcall(db.close, db)
    if ok then
        self._anchor = end_now
    else
        logger.warn("legadocomic stats write failed:", tostring(result))
    end
    return ok
end

-- book = {name, author, bookUrl}; 失败静默降级, 绝不影响阅读
function M:start(book)
    logger.info("legadocomic stats: start called for", tostring(book and book.name))
    if self._closed then self._closed = nil end
    local now = os.time()
    local id, err = self:_getOrCreateBook(book, M.identityForBook(book), now)
    if not id then
        logger.warn("legadocomic stats bridge unavailable:", err)
        return false
    end
    self.book_id = id
    self.book = book
    self.current_page = 1
    self._anchor = now
    self._pending = 0
    logger.info("legadocomic stats: start ok, book_id=", id)
    return true
end

-- 页变化(含跨章): 只更新当前页号, 不重置计时
function M:onPageChanged(page)
    if not self.book_id then return end
    self.current_page = math.max(1, tonumber(page) or self.current_page or 1)
end

-- 翻页时顺带检查: 满 60s 落一条
function M:checkpoint()
    if not self.book_id or not self._anchor then return end
    local now = os.time()
    if now - self._anchor >= FLUSH_INTERVAL or (self._pending or 0) >= FLUSH_INTERVAL then
        self:_flushSpan(now)
    end
end

-- 阅读器关闭: 把剩余时长(>=5s)补上
function M:close()
    if not self.book_id then
        logger.info("legadocomic stats: close without book_id, skip")
        return
    end
    logger.info("legadocomic stats: close, flushing tail")
    pcall(self._flushSpan, self, os.time())
    self.book_id = nil
    self._pending = 0
    self._closed = true
end

return M
