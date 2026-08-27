--[[--
X-Ray 章节换算：当前页码 → TOC 顺序章节号（1 起）。

依据 ReaderToc:getTocTicksFlattened(true) 返回的章节起始页数组（升序），
章节号 = 满足 ticks[i] <= 当前页 的最大 i。ticks 由 ReaderToc 内部缓存，
本模块每次只做一次 O(n) 线性遍历（n = 章节数，几十到几百，微秒级）。
PDF 无稳定 EPUB 章节映射，返回 nil（全书模式，需求 FR4 降级）。
--]] --

local XRayChapter = {}

--- 取当前章节号（1 起）；无 TOC / PDF / 异常时返回 nil
function XRayChapter.current(ui)
    if not ui or not ui.document then return nil end
    -- PDF（has_pages）无 TOC ticks 稳定映射，直接全书模式
    if ui.document.info and ui.document.info.has_pages then return nil end
    local toc = ui.toc
    if not toc or type(toc.getTocTicksFlattened) ~= "function" then return nil end
    local ok, page = pcall(function() return ui.document:getCurrentPage() end)
    if not ok or type(page) ~= "number" then return nil end
    local ok_ticks, ticks = pcall(toc.getTocTicksFlattened, toc, true)
    if not ok_ticks or type(ticks) ~= "table" or #ticks == 0 then return nil end
    local chapter = 0
    for i, p in ipairs(ticks) do
        if p <= page then
            chapter = i
        else
            break
        end
    end
    return chapter > 0 and chapter or 1
end

return XRayChapter
