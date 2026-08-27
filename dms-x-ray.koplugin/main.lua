--[[--
X-Ray 划词插件主入口。

- 划词工具栏注入「X-Ray」按钮（addToHighlightDialog，被动注册不拦截 tap）
- 首次点击懒加载 <书>.sdr/xray.json → 四级匹配（精确/包含/模糊）→ 弹窗
- 主菜单：人物/地点/事件/术语/组织列表 + 章节校准（首章/尾章）+ 设置
- 章节校准：纯手动（弹窗三行对比：预期标题/预期内容/当前标题，用户肉眼判断；
  无自动识别——多部曲/裸数字标题书上唯一标题匹配不成立，见《章节偏移校准设计.md》v2）
- 资源策略：onReaderReady 仅 stat 探测；onCloseDocument 全释放
--]] --

local XRayData = require("lib.xray_data")
local XRayCalib = require("lib.xray_calibration")
local XRayChapter = require("lib.xray_chapter")
local XRayPopup = require("ui.xray_popup")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template
local logger = require("logger")

local Screen = Device.screen

local XRay = WidgetContainer:extend{
    name = "dms-x-ray",
    is_doc_only = true, -- 仅阅读器内启用
}

-- 类型列表（菜单顺序与需求 FR5 一致）
local TYPE_LIST = {
    { "characters", _("人物") },
    { "locations", _("地点") },
    { "events", _("事件") },
    { "terms", _("术语") },
    { "organizations", _("组织") },
}

-- ---------- HTML 组装 ----------

--- HTML 转义
local function esc(s)
    s = tostring(s or "")
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--- 单条结果组装为弹窗 HTML 片段
local function entryHtml(r)
    local e = r.entry
    local parts = { '<div class="xray-entry">' }
    parts[#parts + 1] = '<p><strong>' .. esc(e.name) .. '</strong>'
    local label = XRayData.typeLabel(e.type)
    if label then
        parts[#parts + 1] = "（" .. esc(label) .. "）"
    end
    if type(e.chapters) == "table" and e.chapters[1] and e.chapters[2] then
        parts[#parts + 1] = T(_(" · 第%1–%2章"), e.chapters[1], e.chapters[2])
    end
    parts[#parts + 1] = "</p>"
    -- 正文优先级：当前阶段文本（渐进式）> 摘要 > 完整描述
    local body = r.stage or e.summary
    if body then
        parts[#parts + 1] = "<p>" .. esc(body) .. "</p>"
    end
    if e.description and e.description ~= body then
        parts[#parts + 1] = '<p class="xray-desc">' .. esc(e.description) .. "</p>"
    end
    if e.first_appearance then
        parts[#parts + 1] = '<p class="xray-meta">'
            .. T(_("首次出现：%1"), esc(e.first_appearance)) .. "</p>"
    end
    parts[#parts + 1] = "</div>"
    return table.concat(parts)
end

-- ---------- 初始化与生命周期 ----------

function XRay:onDispatcherRegisterActions()
    Dispatcher:registerAction("xray_lookup", {
        category = "none", event = "XRayLookup",
        title = _("X-Ray lookup"), general = true,
    })
end

function XRay:init()
    if not self.ui or not self.ui.highlight or not self.ui.menu then
        return
    end
    self.settings = G_reader_settings:readSetting("xray", {})
    self.has_data = false
    self.calib = nil -- 章节校准状态缓存（{offset, fuzzy, stored}）
    -- 划词工具栏按钮：key 11_xray（10_user_dict 与 12_search 之间；
    -- 避开 Android 的 08_share_text）。被动注册，不拦截任何 tap。
    self.ui.highlight:addToHighlightDialog("11_xray", function(this)
        return {
            text = _("X-Ray"),
            -- 无数据书籍隐藏按钮（零资源承诺的一部分）
            show_in_highlight_dialog_func = function()
                return self.has_data
            end,
            callback = function()
                local text = this and this.selected_text
                    and this.selected_text.text or ""
                self:onLookup(text)
            end,
        }
    end)
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

--- 开书：仅 stat 探测数据存在性（零解析，未划词/未点菜单的书不再有任何加载）
function XRay:onReaderReady()
    if not self.ui or not self.ui.document then return end
    self.has_data = XRayData.probe(self.ui.document.file)
    if self.has_data then
        logger.info("xray: data found, lazy load on first use")
    end
end

--- 关书：释放数据索引与弹窗（全部资源归还）
function XRay:onCloseDocument()
    XRayData.release()
    XRayCalib.reset()
    XRayPopup.cleanup()
    self.has_data = false
    self.calib = nil
end

-- ---------- 查询链路 ----------

--- 同步章节校准状态（缓存 + 数据层 fuzzy 放宽；幂等轻量，每次查询前调用）
function XRay:_syncCalib()
    self.calib = XRayCalib.get(self.ui)
    XRayData.setCalibration(self.calib.fuzzy)
end

--- 当前基准章号（应用校准偏移后的 xray 章号；无 TOC 返回 nil）
function XRay:_currentChapter()
    return XRayChapter.current(self.ui, self.calib and self.calib.offset or 0)
end

--- 取当前页所在章节标题（校准弹窗并排比对用；失败返回 nil）
function XRay:_currentTocTitle()
    local toc = self.ui and self.ui.toc
    if not toc or type(toc.getTocTitleByPage) ~= "function" then return nil end
    local ok, page = pcall(function() return self.ui.document:getCurrentPage() end)
    if not ok or type(page) ~= "number" then return nil end
    local ok2, title = pcall(toc.getTocTitleByPage, toc, page)
    if ok2 and type(title) == "string" and title ~= "" then return title end
    return nil
end

--- 取弹窗布局参数（字体/字号跟随正文，方式同 KOReader 脚注弹窗）
function XRay:_popupParams()
    local font_face = self.ui.font and self.ui.font.font_face
    if not font_face then
        font_face = G_reader_settings:readSetting("cre_font")
    end
    local font_size
    local doc_font_size = (self.ui.document.configurable
        and self.ui.document.configurable.font_size) or 18
    font_size = Screen:scaleBySize(doc_font_size)
        + (G_reader_settings:readSetting("footnote_popup_relative_font_size") or -2)
    return {
        doc_font_name = font_face,
        doc_font_size = font_size,
        dialog = self.ui,
        height_ratio = 0.35,
    }
end

--- 懒加载数据（幂等）；失败给出原因提示
function XRay:_ensureData()
    if XRayData.loaded() then return true end
    local ok, err = XRayData.load(self.ui.document.file)
    if not ok then
        self.has_data = false
        local msg = {
            nofile = _("X-Ray：未找到数据文件"),
            invalid = _("X-Ray：数据文件无效，请重新生成"),
            unsupported = _("X-Ray：数据格式版本不受支持"),
            toolarge = _("X-Ray：数据过大（超过 2MB 预算），请精简后重试"),
        }
        UIManager:show(Notification:new{ text = msg[err] or _("X-Ray：数据加载失败") })
        return false
    end
    return true
end

--- 弹出单条详情
function XRay:_showEntry(r)
    local params = self:_popupParams()
    params.html = entryHtml(r)
    XRayPopup.show(params)
end

--- 多条命中：选择列表 → 详情
function XRay:_showChoices(results)
    local MAX_SHOW = 12
    local buttons = {}
    local dialog
    for i, r in ipairs(results) do
        if i > MAX_SHOW then break end
        local r2 = r
        local label = r.entry.name
        local tl = XRayData.typeLabel(r.entry.type)
        if tl then
            label = label .. "（" .. tl .. "）"
        end
        buttons[#buttons + 1] = {{
            text = label,
            callback = function()
                UIManager:close(dialog)
                self:_showEntry(r2)
            end,
        }}
    end
    if #results > MAX_SHOW then
        buttons[#buttons + 1] = {{
            text = T(_("还有 %1 条未显示"), #results - MAX_SHOW),
            callback = function() end,
        }}
    end
    local dialog
    dialog = ButtonDialog:new{
        title = _("X-Ray：多个条目匹配"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- 划词查询入口（划词工具栏按钮 / Dispatcher 动作共用）
function XRay:onLookup(text)
    if not self.ui or not self.ui.document then return end
    if not self.has_data then return end
    if not self:_ensureData() then return end
    self:_syncCalib()
    local chapter = self:_currentChapter()
    local results = XRayData.lookup(text, chapter, self.settings.fuzzy)
    if not results then return end
    if #results == 0 then
        UIManager:show(Notification:new{ text = _("X-Ray：未找到相关条目") })
    elseif #results == 1 then
        self:_showEntry(results[1])
    else
        self:_showChoices(results)
    end
end

--- Dispatcher 动作（非触屏设备）：取最近一次划词文本查询
function XRay:onXRayLookup()
    local hl = self.ui.highlight
    local text = hl and hl.selected_text and hl.selected_text.text
    if not text or text == "" then
        UIManager:show(Notification:new{ text = _("X-Ray：请先长按选择文字") })
        return
    end
    self:onLookup(text)
end

-- ---------- 主菜单 ----------

--- 校准错误码 → 提示文本
local function calibErrText(err)
    local msg = {
        nochapter = _("X-Ray：无法识别当前章节（无目录或 PDF）"),
        nofirst = _("X-Ray：请先完成首章校准"),
        nolast = _("X-Ray：数据未含 chapter_last / chapter_count，无法尾章校准"),
    }
    return msg[err]
end

--- 校准确认弹窗：预期标题/预期内容/当前标题三行对比，用户肉眼判断后确认
--- （无自动比对；当前章正文就在屏幕上，无需抓取当前内容）
function XRay:_calibConfirmDialog(base_title, base_text, what, on_confirm)
    local cur = self:_currentTocTitle()
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("%1\n\n预期章节标题：\n%2\n\n预期章节内容：\n%3\n\n当前章节标题：\n%4"),
            T(_("X-Ray：请翻到正文%1再校准"), what),
            base_title or _("（未记录）"),
            base_text or _("（未记录）"),
            cur or _("（无章节标题）")),
        buttons = {{
            {
                text = _("确认校准"),
                callback = function()
                    UIManager:close(dialog)
                    on_confirm()
                end,
            },
            {
                text = _("取消"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

--- 首章校准菜单流程：弹三行对比，用户确认后执行
function XRay:_calibFirstFlow()
    if not self:_ensureData() then return end
    local meta = XRayData.meta() or {}
    if type(meta.chapter_first) ~= "number" then
        UIManager:show(Notification:new{
            text = _("X-Ray：该数据未含校准信息，请用新版工具重新生成") })
        return
    end
    self:_calibConfirmDialog(meta.chapter_first_title, meta.chapter_first_text,
        _("第一章"), function()
            self:_doCalibFirst(meta)
        end)
end

--- 执行首章校准（覆盖旧值，旧 fuzzy 清零需重做）
function XRay:_doCalibFirst(meta)
    local offset, err = XRayCalib.calibrateFirst(self.ui, meta)
    if offset == nil then
        UIManager:show(Notification:new{ text = calibErrText(err) })
        return
    end
    self:_syncCalib()
    local text = T(_("X-Ray：首章校准完成（偏移 %1）"), offset)
    if err == "nowrite" then
        text = text .. _("，未能保存，仅本次有效")
    end
    UIManager:show(Notification:new{ text = text })
end

--- 尾章校准菜单流程：依赖首章校准；弹三行对比，用户确认后执行
function XRay:_calibLastFlow()
    if not self:_ensureData() then return end
    local meta = XRayData.meta() or {}
    local c = XRayCalib.get(self.ui)
    if not c.stored then
        UIManager:show(Notification:new{ text = calibErrText("nofirst") })
        return
    end
    if type(meta.chapter_last) ~= "number" and type(meta.chapter_count) ~= "number" then
        UIManager:show(Notification:new{ text = calibErrText("nolast") })
        return
    end
    self:_calibConfirmDialog(meta.chapter_last_title, meta.chapter_last_text,
        _("最后一章（不含番外）"), function()
            self:_doCalibLast(meta)
        end)
end

--- 执行尾章校准（residual=中段净差 → fuzzy 模糊区间）
function XRay:_doCalibLast(meta)
    local fuzzy, err, residual = XRayCalib.calibrateLast(self.ui, meta)
    if fuzzy == nil then
        UIManager:show(Notification:new{ text = calibErrText(err) })
        return
    end
    self:_syncCalib()
    local text
    if residual == 0 then
        text = _("X-Ray：尾章校准完成，章节数一致")
    else
        text = T(_("X-Ray：尾章校准完成，中段差异 %1 章，模糊区间 %2"), residual, fuzzy)
    end
    if err == "nowrite" then
        text = text .. _("，未能保存，仅本次有效")
    end
    UIManager:show(Notification:new{ text = text })
end

--- 弹出某类型条目列表（Menu 自带分页，长列表安全）
function XRay:_showList(etype, label)
    if not self:_ensureData() then return end
    self:_syncCalib()
    -- 列表范围：设置"全书"关闭时按当前章过滤（渐进式防剧透同样生效）
    local chapter = self.settings.show_all and nil or self:_currentChapter()
    local list = XRayData.listEntries(etype, chapter)
    if not list or #list == 0 then
        UIManager:show(Notification:new{ text = _("X-Ray：该分类暂无可见条目") })
        return
    end
    local title = T(_("X-Ray · %1"), label)
    if chapter and chapter >= 1 then
        title = title .. T(_("（第%1章）"), chapter)
    end
    local items = {}
    for _, e in ipairs(list) do
        local e2 = e
        items[#items + 1] = {
            text = e.name,
            callback = function()
                self:_showEntry({
                    entry = e2,
                    kind = 1,
                    stage = XRayData.matchStage(e2.stages, chapter),
                })
            end,
        }
    end
    local menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
    }
    UIManager:show(menu)
end

--- 设置子菜单（持久化到 G_reader_settings "xray"）
function XRay:_settingsMenu()
    local function save()
        G_reader_settings:saveSetting("xray", self.settings)
    end
    return {
        {
            text = _("模糊匹配（编辑距离纠错）"),
            checked_func = function()
                return self.settings.fuzzy == true
            end,
            callback = function()
                self.settings.fuzzy = not self.settings.fuzzy or nil
                save()
            end,
            help_text = _("中文通常无需开启；英文拼写容错时启用"),
        },
        {
            text = _("列表显示全书条目"),
            checked_func = function()
                return self.settings.show_all == true
            end,
            callback = function()
                self.settings.show_all = not self.settings.show_all or nil
                save()
            end,
            help_text = _("关闭时列表仅显示当前章节范围内可见的条目（防剧透）"),
        },
        {
            text_func = function()
                local st = XRayData.stats()
                if not st.loaded then
                    return _("X-Ray 数据：未加载")
                end
                return T(_("X-Ray 数据：%1 条目 / %2 别名 / %3 KB"),
                    st.entries, st.aliases, math.floor(st.size / 1024))
            end,
            keep_menu_open = true,
            callback = function() end,
        },
    }
end

function XRay:addToMainMenu(menu_items)
    local sub = {}
    for _, t in ipairs(TYPE_LIST) do
        local etype, label = t[1], t[2]
        sub[#sub + 1] = {
            text = label,
            keep_menu_open = true,
            callback = function()
                self:_showList(etype, label)
            end,
        }
    end
    -- separator 是附加在菜单项上的属性（该项下方画线，touchmenu.lua:696），
    -- 独立的 {separator=true} 项会被渲染成空白行
    sub[#sub].separator = true
    -- 章节校准：两项同级菜单（首章必须/推荐，尾章可选），不做额外引导提示
    sub[#sub + 1] = {
        text_func = function()
            local c = self.calib or XRayCalib.get(self.ui)
            if c and c.stored then
                return T(_("首章校准（偏移 %1）"), c.offset)
            end
            return _("首章校准")
        end,
        callback = function()
            self:_calibFirstFlow()
        end,
        help_text = _("翻到本书正文第一章（不含目录/序言/广告）后执行；弹窗比对预期标题与正文开头，确认后校准"),
    }
    sub[#sub + 1] = {
        text_func = function()
            local c = self.calib or XRayCalib.get(self.ui)
            if c and c.stored and c.fuzzy > 0 then
                return T(_("尾章校准（模糊 %1）"), c.fuzzy)
            end
            return _("尾章校准")
        end,
        callback = function()
            self:_calibLastFlow()
        end,
        help_text = _("翻到本书正文最后一章（不含番外）后执行；用于检测中段章节差异"),
        separator = true, -- 在该项（尾章校准）下方画线，与设置项分组
    }
    sub[#sub + 1] = {
        text = _("X-Ray 设置"),
        sub_item_table = self:_settingsMenu(),
    }
    menu_items.xray = {
        text = _("X-Ray"),
        sorting_hint = "tools",
        enabled_func = function()
            return self.has_data
        end,
        sub_item_table = sub,
    }
end

return XRay
