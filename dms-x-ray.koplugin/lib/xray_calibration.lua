--[[--
X-Ray 章节偏移校准：跨版本书籍的章节序号对齐（纯手动，无自动识别）。

- 基准锚点：xray.json meta 的 chapter_first / chapter_last（+ 两章标题与正文前 50 字摘录）
- 偏移 offset = 当前书正文首章序号 − 基准首章号；查询时 x = p − offset
- 模糊 fuzzy = ceil(|residual|/2)：尾章校准检测中段净差，仅放宽条目终点（起点防剧透绝不放宽）
- 识别靠用户：校准弹窗三行对比（预期标题/预期内容/当前标题），用户肉眼判断后确认
- 存储：DocSettings key "dms_xray_calibration"（设备本地、随书实例；不写 xray.json，见设计文档附录 A）
- 覆盖语义：任何新校准总是覆盖旧值；换设备/版本无此数据 → 重新校准即适配
--]] --

local XRayChapter = require("lib.xray_chapter")
local logger = require("logger")

local XRayCalib = {}

-- DocSettings 存储 key（带插件前缀，避免与其他模块冲突）
local DS_KEY = "dms_xray_calibration"

-- 模块级缓存：{ ds=doc_settings对象, offset, fuzzy, stored }；reset() 清空
local cache

--- 读校准数据（带缓存；同一 doc_settings 只读一次 DocSettings）
local function load(ui)
    local ds = ui and ui.doc_settings
    if not ds then return nil end
    if cache and cache.ds == ds then return cache end
    local ok, saved = pcall(function() return ds:readSetting(DS_KEY) end)
    local t = ok and type(saved) == "table" and saved or nil
    cache = {
        ds = ds,
        offset = t and type(t.offset) == "number" and t.offset or 0,
        fuzzy = t and type(t.fuzzy) == "number" and t.fuzzy or 0,
        stored = t and t.offset ~= nil or false, -- 有 offset 键 = 校准过（含 offset=0）
    }
    return cache
end

--- 保存校准数据到 DocSettings 并立即 flush
--- 返回 true=持久化成功；false=写失败（缓存已更新，本次会话内存生效）
local function save(ui, data)
    local ds = ui and ui.doc_settings
    if not ds then return false end
    local ok, err = pcall(function()
        ds:saveSetting(DS_KEY, data)
        ds:flush()
    end)
    if not ok then
        logger.warn("xray: calibration save failed (session only):", err)
    end
    -- 无论写盘成败，缓存（内存态）总是最新
    cache = {
        ds = ds,
        offset = data.offset or 0,
        fuzzy = data.fuzzy or 0,
        stored = data.offset ~= nil,
    }
    return ok
end

--- 当前校准状态 {offset, fuzzy, stored}（无 doc_settings 时全默认）
function XRayCalib.get(ui)
    local c = load(ui)
    if c then return c end
    return { offset = 0, fuzzy = 0, stored = false }
end

--- 手动首章校准：当前页所在章视为正文第一章 → offset
--- 返回 offset, err（err: "nochapter" 无法识别章节 / "nowrite" 未能持久化）
--- 重新首章校准会清零旧 fuzzy（residual 基于旧 offset，需重做尾章校准）
function XRayCalib.calibrateFirst(ui, meta)
    local n1 = XRayChapter.current(ui)
    if not n1 then return nil, "nochapter" end
    local first = type(meta.chapter_first) == "number" and meta.chapter_first or 1
    local offset = n1 - first
    local ok = save(ui, { offset = offset, fuzzy = 0 })
    logger.info("xray: manual first-chapter calibrated, offset =", offset)
    -- 注意：不能写 ok and nil or "nowrite"（nil 是 falsy，or 恒走右支）
    return offset, not ok and "nowrite" or nil
end

--- 手动尾章校准：当前页所在章视为正文末章 → fuzzy
--- 返回 fuzzy, err, residual（err: "nofirst" 未做首章 / "nochapter" / "nolast" 无基准末章 / "nowrite"）
function XRayCalib.calibrateLast(ui, meta)
    local c = load(ui)
    if not c or not c.stored then return nil, "nofirst" end
    local n2 = XRayChapter.current(ui)
    if not n2 then return nil, "nochapter" end
    -- 基准末章：chapter_last 优先，缺省用 chapter_count
    local last = type(meta.chapter_last) == "number" and meta.chapter_last
        or type(meta.chapter_count) == "number" and meta.chapter_count or nil
    if not last then return nil, "nolast" end
    local residual = (n2 - c.offset) - last
    local fuzzy = residual == 0 and 0 or math.ceil(math.abs(residual) / 2)
    local ok = save(ui, { offset = c.offset, fuzzy = fuzzy })
    logger.info("xray: manual last-chapter calibrated, residual =", residual, "fuzzy =", fuzzy)
    return fuzzy, not ok and "nowrite" or nil, residual
end

--- 释放会话缓存（关书时调用；DocSettings 持久数据不受影响）
function XRayCalib.reset()
    cache = nil
end

return XRayCalib
