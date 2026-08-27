--[[--
X-Ray 章节换算：当前页码 → 压平 TOC 顺序章节号（1 起）。

依据 ReaderToc:getTocTicksFlattened(true) 返回的全层级压平去重页码数组（升序），
章节号 = 满足 ticks[i] <= 当前页 的最大 i。ticks 由 ReaderToc 内部缓存，
本模块每次只做一次 O(n) 线性遍历（n = 章节数，几十到几百，微秒级）。
单层目录书该序号即顶层章顺序号；多卷两级目录书中个别卷级页码可能混入计数
（中段偏差），由章节偏移校准机制吸收（见《章节偏移校准设计.md》§4.5）。
校准偏移由调用方传入：x = p - offset（校准模块与 main 负责取值，避免循环依赖）。
PDF 无稳定 EPUB 章节映射，返回 nil（全书模式，需求 FR4 降级）。
--]] --

local XRayChapter = {}

--- 内部：取压平 ticks 数组（无 TOC / PDF / 异常返回 nil）
local function tocTicks(ui)
    if not ui or not ui.document then return nil end
    -- PDF（has_pages）无 TOC ticks 稳定映射
    if ui.document.info and ui.document.info.has_pages then return nil end
    local toc = ui.toc
    if not toc or type(toc.getTocTicksFlattened) ~= "function" then return nil end
    local ok, ticks = pcall(toc.getTocTicksFlattened, toc, true)
    if not ok or type(ticks) ~= "table" or #ticks == 0 then return nil end
    return ticks
end

--- 当前页 → 压平序号（第一章之前的内容归第 1 章）
--- offset 为校准偏移（可选，默认 0）：返回 x = p - offset（可为 0/负，由过滤层自然处理）
function XRayChapter.current(ui, offset)
    if not ui or not ui.document then return nil end
    local ok, page = pcall(function() return ui.document:getCurrentPage() end)
    if not ok or type(page) ~= "number" then return nil end
    local ticks = tocTicks(ui)
    if not ticks then return nil end
    local n = 0
    for i, p in ipairs(ticks) do
        if p <= page then
            n = i
        else
            break
        end
    end
    local chapter = n > 0 and n or 1
    if type(offset) == "number" and offset ~= 0 then
        return chapter - offset
    end
    return chapter
end

return XRayChapter