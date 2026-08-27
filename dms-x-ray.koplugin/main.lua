--[[--
X-Ray 划词插件主入口。

- 划词工具栏注入「X-Ray」按钮（addToHighlightDialog，被动注册不拦截 tap）
- 首次点击懒加载 <书>.sdr/xray.json → 四级匹配（精确/包含/模糊）→ 弹窗
- 主菜单：人物/地点/事件/术语/组织列表 + 设置
- 资源策略：onReaderReady 仅 stat 探测；onCloseDocument 全释放
--]] --

local XRayData = require("lib.xray_data")
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

--- 开书：仅 stat 探测数据存在性（零解析，满足"未触发零消耗"）
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
    XRayPopup.cleanup()
    self.has_data = false
end

-- ---------- 查询链路 ----------

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
    local chapter = XRayChapter.current(self.ui)
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

--- 弹出某类型条目列表（Menu 自带分页，长列表安全）
function XRay:_showList(etype, label)
    if not self:_ensureData() then return end
    -- 列表范围：设置"全书"关闭时按当前章过滤（渐进式防剧透同样生效）
    local chapter = self.settings.show_all and nil or XRayChapter.current(self.ui)
    local list = XRayData.listEntries(etype, chapter)
    if not list or #list == 0 then
        UIManager:show(Notification:new{ text = _("X-Ray：该分类暂无可见条目") })
        return
    end
    local title = T(_("X-Ray · %1"), label)
    if chapter then
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
    sub[#sub + 1] = { separator = true }
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
