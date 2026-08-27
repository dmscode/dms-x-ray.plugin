--[[--
X-Ray 弹窗：ScrollHtmlWidget 底部浮层（移植自 weidu thought_popup 思路并精简）。

- MuPDF 渲染 HTML 片段，字体跟随正文（@font-face 注入书籍字体，失败回退 Noto Sans）
- 按内容自适应高度（getSinglePageHeight），默认上限 35% 屏高
- 单例池复用（_reopen 换内容不重建）
- 关闭：点空白 / 左右 / 下滑；关闭即销毁并回调 close_callback
--]] --

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local logger = require("logger")

-- ---------- 字体 CSS（书籍字体 → Noto Sans 回退） ----------

--- 取书籍字体 ttf 路径（cre 引擎；仅 regular，减少 MuPDF I/O）
local function getDocFontPath(font_name)
    if not font_name then return nil end
    local ok, cre = pcall(function()
        return require("document/credocument"):engineInit()
    end)
    if not ok or not cre or type(cre.getFontFaceFilenameAndFaceIndex) ~= "function" then
        return nil
    end
    local ok_path, path = pcall(cre.getFontFaceFilenameAndFaceIndex, cre, font_name, false, false)
    if ok_path and type(path) == "string" then return path end
    return nil
end

--- 组装弹窗 CSS：字体链 + 基础排版
local function buildCSS(font_name)
    local css = [[
body { margin: 0; padding: 0; line-height: 1.3;
  font-family: 'XRayMainFont', 'Noto Sans', sans-serif; }
p { margin: 0 0 0.3em 0; }
.xray-meta { color: #999; font-size: 0.85em; }
.xray-desc { color: #555; }
@page { margin: 0 12px 0 12px; }
]]
    local path = getDocFontPath(font_name)
    if path then
        css = css .. string.format(
            "\n@font-face { font-family: 'XRayMainFont'; src: url('%s') }\n", path)
    end
    return css
end

--- HTML 预处理：去 script/style、压缩空白（减少 MuPDF 解析量）
local function prepareHTML(html)
    html = html:gsub("<script[^>]*>.-</script>", "")
    html = html:gsub("<style[^>]*>.-</style>", "")
    html = html:gsub(">%s+<", "><")
    return html
end

-- ---------- 弹窗 Widget ----------

local XRayPopupWidget = InputContainer:extend{
    html = nil,           -- 内容 HTML 片段
    doc_font_name = nil,  -- 书籍字体名（跟随正文）
    doc_font_size = nil,  -- 字号（跟随正文，由 main 传入）
    height_ratio = 0.35,  -- 屏高占比上限
    close_callback = nil,
    dialog = nil,         -- 宿主 ReaderUI（setDirty 用）
}

function XRayPopupWidget:init()
    self.height_ratio = math.max(0.1, math.min(0.9, self.height_ratio or 0.35))
    self.width = Screen:getWidth()
    self.height = math.floor(Screen:getHeight() * self.height_ratio)
    -- 全屏手势区：tap 空白关闭 / swipe 左右下关闭
    if Device:isTouchDevice() then
        local range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
        self.ges_events = {
            TapClose = { GestureRange:new{ ges = "tap", range = range } },
            SwipeClose = { GestureRange:new{ ges = "swipe", range = range } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self.html = prepareHTML(self.html or "")
    self.css = buildCSS(self.doc_font_name)
    self:_buildWidget()
end

--- 构建 ScrollHtmlWidget 与整体布局
function XRayPopupWidget:_buildWidget()
    local padding_right = Screen:scaleBySize(10)
    local padding_top = Size.padding.large
    local padding_bottom = Size.padding.large
    local htmlwidget = ScrollHtmlWidget:new{
        html_body = self.html,
        is_xhtml = true,
        css = self.css,
        default_font_size = self.doc_font_size or Screen:scaleBySize(18),
        width = self.width - padding_right,
        height = self.height - padding_top - padding_bottom,
        scroll_bar_width = Screen:scaleBySize(6),
        text_scroll_span = Screen:scaleBySize(12),
        dialog = self.dialog,
    }
    self.htmlwidget = htmlwidget
    local vgroup = VerticalGroup:new{
        LineWidget:new{ dimen = Geom:new{ w = self.width, h = Size.line.thick } },
        VerticalSpan:new{ width = padding_top },
        htmlwidget,
        VerticalSpan:new{ width = padding_bottom },
    }
    -- 内容不足一页时收缩高度（按内容自适应）
    local single_page_height = htmlwidget:getSinglePageHeight()
    if single_page_height then
        local reduced = single_page_height + Size.line.thick + padding_top + padding_bottom
        vgroup = CenterContainer:new{
            dimen = Geom:new{ h = reduced, w = self.width },
            ignore = "height",
            vgroup,
        }
        self.height = reduced
    end
    self.container = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, margin = 0, padding = 0,
        vgroup,
    }
    self[1] = BottomContainer:new{ dimen = Screen:getSize(), self.container }
end

function XRayPopupWidget:onShow()
    UIManager:setDirty(self.dialog, function()
        return "partial", self.container.dimen
    end)
end

--- 单例复用：换内容重建 widget（不重建弹窗对象）
function XRayPopupWidget:_reopen(opts)
    self.html = prepareHTML(opts.html or "")
    self.doc_font_name = opts.doc_font_name or self.doc_font_name
    self.doc_font_size = opts.doc_font_size or self.doc_font_size
    self.height_ratio = math.max(0.1, math.min(0.9, opts.height_ratio or self.height_ratio))
    self.close_callback = opts.close_callback
    self.dialog = opts.dialog or self.dialog
    self.height = math.floor(Screen:getHeight() * self.height_ratio)
    if self.htmlwidget then
        self.htmlwidget:free()
        self.htmlwidget = nil
    end
    self.css = buildCSS(self.doc_font_name)
    self:clear()
    self:_buildWidget()
end

function XRayPopupWidget:onCloseWidget()
    UIManager:setDirty(self.dialog, function()
        return "partial", self.container.dimen
    end)
    if self.htmlwidget then
        self.htmlwidget:free()
        self.htmlwidget = nil
    end
    if self.close_callback then
        local cb = self.close_callback
        self.close_callback = nil
        cb(self.height)
    end
end

function XRayPopupWidget:onClose()
    UIManager:close(self)
    return true
end

--- 点弹窗外区域关闭；点弹窗内不处理（交由滚动组件）
function XRayPopupWidget:onTapClose(_, ges)
    if ges and self.container and ges.pos
        and ges.pos:notIntersectWith(self.container.dimen) then
        UIManager:close(self)
        return true
    end
    return false
end

--- 左右 / 下滑关闭；上滑交给滚动；横向滑动吞掉防误翻书
function XRayPopupWidget:onSwipeClose(_, ges)
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" or direction == "east" or direction == "south" then
        UIManager:close(self)
        return true
    end
    return false
end

-- ---------- 模块接口（单例池） ----------

local M = {}
local _pooled = nil

--- 显示弹窗（单例复用：第二次起 _reopen 换内容）
function M.show(opts)
    if type(opts.html) ~= "string" or opts.html == "" then
        logger.warn("xray popup: invalid html")
        return nil
    end
    if _pooled then
        _pooled:_reopen(opts)
        UIManager:show(_pooled)
        return _pooled
    end
    local popup = XRayPopupWidget:new{
        html = opts.html,
        doc_font_name = opts.doc_font_name,
        doc_font_size = opts.doc_font_size,
        height_ratio = opts.height_ratio,
        close_callback = opts.close_callback,
        dialog = opts.dialog,
    }
    _pooled = popup
    UIManager:show(popup)
    return popup
end

--- 关闭当前可见弹窗（若有）
function M.closeVisible()
    if _pooled then
        pcall(function() UIManager:close(_pooled) end)
    end
end

--- 彻底清理（书关闭时）：关弹窗 + 释放 widget + 清单例引用
function M.cleanup()
    if _pooled then
        pcall(function() UIManager:close(_pooled) end)
        if _pooled.htmlwidget then
            _pooled.htmlwidget:free()
            _pooled.htmlwidget = nil
        end
        _pooled:clear()
        _pooled = nil
    end
end

return M
