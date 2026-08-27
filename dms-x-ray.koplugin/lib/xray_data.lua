--[[--
X-Ray 数据层：随书数据加载、内存索引、四级匹配查询、资源释放。

数据文件：<书籍>.sdr/xray.json（schema 见 xray-plugin/功能需求文档.md §4）。
索引：clean(别名) -> { 条目下标... }（同一别名允许多条目，一词多义）。
匹配管线：L1 精确哈希 → L2 双向包含 → L3 3-gram 剪枝 + Levenshtein(≤2)。
资源策略：probe 仅 stat；load 一次性建索引；release 全清 + GC。
--]] --

local JSON = require("json")
local DocSettings = require("docsettings")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local XRayData = {}

-- 内存预算：Lua 表开销按 JSON 字节数 × 1.5 粗估，上限 2MB（需求 FR7）
local MEM_BUDGET = 2 * 1024 * 1024
local MEM_FACTOR = 1.5
-- JSON 大于此值剥 description（长文本展示时不可用，仅保留 summary）
local DROP_DESC_THRESHOLD = 700 * 1024

-- 匹配方式（数值越小越可信）
local KIND_EXACT, KIND_CONTAIN, KIND_FUZZY = 1, 2, 3
-- 类型优先级与中文标签（人物>地点>术语>组织>事件）
local TYPE_ORDER = { characters = 1, locations = 2, terms = 3, organizations = 4, events = 5 }
local TYPE_LABEL = {
    characters = "人物", locations = "地点", terms = "术语",
    organizations = "组织", events = "事件",
}

-- 首尾标点剥离表：完整 UTF-8 字符逐一比对。
-- 不用 Lua pattern 字节集（[，。] 会按字节拆开导致切坏汉字）
local EDGE_PUNCT = {
    "。", "，", "、", "；", "：", "？", "！", "…", "—", "·", "～",
    "《", "》", "「", "」", "『", "』", "（", "）", "【", "】",
    "“", "”", "‘", "’",
    ".", ",", ";", ":", "?", "!", "\"", "'", "(", ")", "[", "]", "{", "}",
}

-- 模块级状态：插件实例生命周期内唯一，release() 清空
local S = {
    loaded = false,
    path = nil,
    meta = nil,           -- xray.json 的 meta（校准基准字段来源）
    fuzzy = 0,            -- 章节校准模糊区间（尾章校准产生；仅放宽条目终点）
    entries = nil,       -- 规整条目数组（下标即 eid）
    index = nil,         -- clean(alias) -> {eid, ...}
    sorted_alias = nil,  -- {{alias, eid}, ...} 按 alias 字节长降序（L2 线性扫）
    gram_index = nil,    -- 3-gram -> {alias=true,...}（L3 惰性构建）
    alias_count = 0,
    size = 0,
}

-- ---------- 内部工具 ----------

-- 首尾标点首字节快查表：构建索引时 977+ 次调用 clean，
-- 首尾都不是标点首字节可 O(1) 跳过逐字符慢路径（墨水屏冷启动优化）。
-- 快路径只会保守放行进慢路径，不会漏判（真标点首字节必在表内）。
local EDGE_FIRST_BYTES = {}
for _, p in ipairs(EDGE_PUNCT) do
    EDGE_FIRST_BYTES[string.byte(p, 1)] = true
end

--- 取字符串最后一个 UTF-8 字符的起始字节位置
local function lastCharStart(s)
    local n = #s
    if n == 0 then return nil end
    local i = n
    while i > 1 do
        local b = string.byte(s, i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return i
end

--- 剥离字符串首尾标点（每轮剥一个完整标点字符，直到不再是标点）
local function stripEdgePunct(s)
    if s == "" then return s end
    -- 快路径：首尾字符首字节均非标点首字节 → 直接返回
    local fb = string.byte(s, 1)
    local ls = lastCharStart(s)
    local lb = string.byte(s, ls)
    if not EDGE_FIRST_BYTES[fb] and not EDGE_FIRST_BYTES[lb] then
        return s
    end
    -- 慢路径：逐标点比对（正确处理完整 UTF-8 字符）
    local changed = true
    while changed do
        changed = false
        for _, p in ipairs(EDGE_PUNCT) do
            local n = #p
            if s:sub(1, n) == p then
                s = s:sub(n + 1)
                changed = true
                break
            end
            if s:sub(-n) == p then
                s = s:sub(1, -n - 1)
                changed = true
                break
            end
        end
    end
    return s
end

--- 规范化查询文本：清理空白 → 剥首尾标点 → 小写（英文场景；中文不受影响）
local function clean(text)
    if type(text) ~= "string" then return "" end
    text = util.cleanupSelectedText(text)
    text = stripEdgePunct(text)
    return text:lower()
end

--- UTF-8 rune（字符）切分，返回字符数组（模糊匹配按字符处理避免字节误切）
local function toRunes(s)
    local runes = {}
    local i, n = 1, #s
    while i <= n do
        local b = string.byte(s, i)
        local w = b < 0x80 and 1 or (b < 0xE0 and 2 or (b < 0xF0 and 3 or 4))
        runes[#runes + 1] = s:sub(i, i + w - 1)
        i = i + w
    end
    return runes
end

--- 生成字符串的 3-gram 集合（rune 级；返回 map gram->true）
local function gramsOf(s)
    local r = toRunes(s)
    local g = {}
    for i = 1, #r - 2 do
        g[table.concat(r, "", i, i + 2)] = true
    end
    return g
end

--- 章节是否在 [from, to+fuzzy] 作用范围内（无范围数据视为全书可见）
--- 终点放宽 fuzzy：吸收尾章校准检测到的中段增删章净差；
--- 起点绝不放宽：起点语义是"首次出现/防剧透"，放宽会提前泄露
local function inChapters(range, chapter)
    if not chapter or type(range) ~= "table" then return true end
    local a, b = range[1], range[2]
    if not a or not b then return true end
    return chapter >= a and chapter <= b + S.fuzzy
end

--- 取当前章节命中的 stage 文本（跟踪剧情发展；无命中返回 nil）
--- 多段同时命中（fuzzy 放宽终点后相邻段重叠）时取最后一段：最接近当前进度
local function matchStage(stages, chapter)
    if type(stages) ~= "table" or not chapter then return nil end
    local last
    for _, st in ipairs(stages) do
        if type(st) == "table" and inChapters(st.chapters, chapter) then
            last = st.text
        end
    end
    return last
end

-- Levenshtein 复用缓冲（模块级，避免高频分配引发 GC 停顿）
local lev_buf = {}

--- rune 级编辑距离（一维滚动数组 + 行剪枝），返回距离或 nil（超 2 剪枝）
local function levenshtein(a, b, max_dist)
    local la, lb = #a, #b
    if math.abs(la - lb) > max_dist then return nil end
    local buf = lev_buf
    for j = 0, lb do buf[j] = j end
    for i = 1, la do
        local diag = buf[0]
        buf[0] = i
        local row_min = i
        for j = 1, lb do
            local up = buf[j]
            local v = math.min(buf[j] + 1, buf[j - 1] + 1,
                diag + (a[i] == b[j] and 0 or 1))
            buf[j] = v
            diag = up
            if v < row_min then row_min = v end
        end
        if row_min > max_dist then return nil end -- 行最小值剪枝
    end
    return buf[lb]
end

-- ---------- 索引构建 ----------

--- 把别名加入索引（同 entry 重复别名去重；跨 entry 允许共用）
local function addIndex(alias, eid)
    if alias == "" then return end
    local eids = S.index[alias]
    if eids then
        for _, x in ipairs(eids) do
            if x == eid then return end
        end
        eids[#eids + 1] = eid
    else
        S.index[alias] = { eid }
        S.alias_count = S.alias_count + 1
        S.sorted_alias[#S.sorted_alias + 1] = { alias, eid }
    end
end

--- 解析并规整条目 + 构建索引（load 的主体）
local function buildIndex(data, drop_desc)
    S.entries = {}
    S.index = {}
    S.sorted_alias = {}
    S.alias_count = 0
    for i, e in ipairs(data.entries) do
        if type(e) == "table" and type(e.name) == "string" and e.name ~= "" then
            local entry = {
                id = e.id or tostring(i),
                name = e.name,
                type = TYPE_ORDER[e.type] and e.type or "terms",
                summary = e.summary,
                description = drop_desc and nil or e.description,
                chapters = type(e.chapters) == "table" and e.chapters or nil,
                stages = type(e.stages) == "table" and e.stages or nil,
                first_appearance = e.first_appearance,
            }
            S.entries[i] = entry
            addIndex(clean(e.name), i)
            if type(e.aliases) == "table" then
                for _, a in ipairs(e.aliases) do
                    if type(a) == "string" then
                        addIndex(clean(a), i)
                    end
                end
            end
        end
    end
    -- L2 按别名长度降序（长别名最具体，优先命中）
    table.sort(S.sorted_alias, function(x, y) return #x[1] > #y[1] end)
end

-- ---------- 匹配层 ----------

--- L2 双向包含匹配（选词多划了前后文 / 少划了尾巴）
local function containMatch(q)
    local found = {}
    local qlen = #q
    for _, rec in ipairs(S.sorted_alias) do
        local alias, eid = rec[1], rec[2]
        local alen = #alias
        -- 别名 ⊆ 选词：划多了；别名至少 3 字节（防单字符误配）
        if alen >= 3 and qlen > alen and q:find(alias, 1, true) then
            found[eid] = KIND_CONTAIN
            -- 选词 ⊆ 别名：划少了；选词至少 2 个汉字（6 字节）
        elseif qlen >= 6 and alen > qlen and alias:find(q, 1, true) then
            found[eid] = KIND_CONTAIN
        end
    end
    return found
end

--- L3：3-gram 倒排剪枝 → Top5 候选 → 编辑距离 ≤2（默认仅显式开启）
local function fuzzyMatch(q)
    -- 惰性构建 gram 倒排（首次模糊查询时）
    if not S.gram_index then
        S.gram_index = {}
        for alias in pairs(S.index) do
            for g in pairs(gramsOf(alias)) do
                local set = S.gram_index[g]
                if not set then
                    set = {}
                    S.gram_index[g] = set
                end
                set[alias] = true
            end
        end
    end
    -- 查询 gram 计数 → 候选别名按交集大小排序
    local counts = {}
    for g in pairs(gramsOf(q)) do
        local set = S.gram_index[g]
        if set then
            for alias in pairs(set) do
                counts[alias] = (counts[alias] or 0) + 1
            end
        end
    end
    local cands = {}
    for alias, c in pairs(counts) do
        cands[#cands + 1] = { alias, c }
    end
    if #cands == 0 then return nil end
    table.sort(cands, function(x, y) return x[2] > y[2] end)
    -- 仅对 Top5 候选做编辑距离
    local qr = toRunes(q)
    local found = {}
    for i = 1, math.min(5, #cands) do
        local alias = cands[i][1]
        local d = levenshtein(qr, toRunes(alias), 2)
        if d and d <= 2 then
            for _, eid in ipairs(S.index[alias]) do
                found[eid] = KIND_FUZZY
            end
        end
    end
    return found
end

--- 结果排序：匹配方式 → 类型优先级 → 名称字节序
local function sortResults(results)
    table.sort(results, function(x, y)
        if x.kind ~= y.kind then return x.kind < y.kind end
        local tx = TYPE_ORDER[x.entry.type] or 9
        local ty = TYPE_ORDER[y.entry.type] or 9
        if tx ~= ty then return tx < ty end
        return x.entry.name < y.entry.name
    end)
end

-- ---------- 公开 API ----------

--- 数据文件路径（书籍 sdr 目录下 xray.json）
function XRayData.dataFilePath(book_file)
    if type(book_file) ~= "string" or book_file == "" then return nil end
    local ok, dir = pcall(DocSettings.getSidecarDir, DocSettings, book_file, "doc")
    if not ok or type(dir) ~= "string" then return nil end
    return dir .. "/xray.json"
end

--- 探测数据是否存在（仅 stat，零解析，开书零成本）
function XRayData.probe(book_file)
    local path = XRayData.dataFilePath(book_file)
    if not path then return false end
    local ok, mode = pcall(lfs.attributes, path, "mode")
    return ok and mode == "file"
end

--- 数据是否已加载（供外部判断）
function XRayData.loaded()
    return S.loaded
end

--- 加载并建索引（幂等；失败返回 false + 原因码）
function XRayData.load(book_file)
    if S.loaded then return true end
    local path = XRayData.dataFilePath(book_file)
    if not path then return false, "nofile" end
    local ok, data
    do
        local f = io.open(path, "rb")
        if not f then return false, "nofile" end
        local content = f:read("*a")
        f:close()
        ok, data = pcall(JSON.decode, content)
    end
    if not ok or type(data) ~= "table" or type(data.entries) ~= "table" then
        logger.warn("xray: invalid data file:", path)
        return false, "invalid"
    end
    if (data.format or 0) ~= 1 then
        logger.warn("xray: unsupported format:", data.format)
        return false, "unsupported"
    end
    local size = lfs.attributes(path, "size") or 0
    if size * MEM_FACTOR > MEM_BUDGET then
        logger.warn("xray: data too large:", size, "bytes")
        return false, "toolarge"
    end
    buildIndex(data, size > DROP_DESC_THRESHOLD)
    S.loaded = true
    S.path = path
    S.size = size
    S.meta = type(data.meta) == "table" and data.meta or nil
    S.fuzzy = 0
    logger.info("xray: loaded", path, "entries:", #S.entries,
        "aliases:", S.alias_count, "bytes:", size)
    return true
end

--- 释放全部资源（书关闭时调用；清索引 + 强制 GC）
function XRayData.release()
    S.loaded = false
    S.path = nil
    S.meta = nil
    S.fuzzy = 0
    S.entries = nil
    S.index = nil
    S.sorted_alias = nil
    S.gram_index = nil
    S.alias_count = 0
    S.size = 0
    collectgarbage()
end

--- meta 元数据（校准基准字段 chapter_first/last 与标题在此；未加载返回 nil）
function XRayData.meta()
    return S.meta
end

--- 设置章节校准模糊区间（main 在校准状态变化时同步；默认 0 = 不放宽）
function XRayData.setCalibration(fuzzy)
    S.fuzzy = type(fuzzy) == "number" and fuzzy or 0
end

--- 查询：text 划词文本；chapter 当前章（nil=全书模式）；allow_fuzzy 开 L3
--- 返回结果数组 {{entry, kind, stage}, ...}，未加载返回 nil
function XRayData.lookup(text, chapter, allow_fuzzy)
    if not S.loaded then return nil, "notloaded" end
    local q = clean(text)
    if q == "" then return {} end
    local found = {}
    -- L1 精确（含别名）
    local eids = S.index[q]
    if eids then
        for _, eid in ipairs(eids) do found[eid] = KIND_EXACT end
    end
    -- L2 双向包含
    if not next(found) then
        found = containMatch(q)
    end
    -- L3 模糊（显式开启才跑；中文场景通常不需要）
    if not next(found) and allow_fuzzy then
        local fuzzy = fuzzyMatch(q)
        if fuzzy then
            for eid, kind in pairs(fuzzy) do found[eid] = kind end
        end
    end
    -- 章节过滤（防剧透）+ 组装
    local results = {}
    for eid, kind in pairs(found) do
        local e = S.entries[eid]
        if e and inChapters(e.chapters, chapter) then
            results[#results + 1] = { entry = e, kind = kind, stage = matchStage(e.stages, chapter) }
        end
    end
    sortResults(results)
    logger.dbg(string.format("xray: lookup %q -> %d results", q, #results))
    return results
end

--- 列出某类型条目（etype 为 nil 列全部；chapter 非 nil 时按作用范围过滤）
function XRayData.listEntries(etype, chapter)
    if not S.loaded then return nil, "notloaded" end
    local out = {}
    for _, e in ipairs(S.entries) do
        if (not etype or e.type == etype) and inChapters(e.chapters, chapter) then
            out[#out + 1] = e
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- 对外暴露的 stage 匹配（菜单列表点开详情用）
function XRayData.matchStage(stages, chapter)
    return matchStage(stages, chapter)
end

--- 类型中文标签
function XRayData.typeLabel(etype)
    return TYPE_LABEL[etype]
end

--- 缓存统计（设置页显示：条目数/别名数/数据体积）
function XRayData.stats()
    return {
        loaded = S.loaded,
        entries = S.entries and #S.entries or 0,
        aliases = S.alias_count,
        size = S.size,
    }
end

return XRayData
