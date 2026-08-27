-- X-Ray 插件元数据（KOReader 插件管理界面显示）
local _ = require("gettext")
return {
    name = "dms-x-ray",
    fullname = _("DMS X-Ray"),
    version = "0.2.0",
    description = _([[
划词查询随书 X-Ray 词条：在划词工具栏加入 X-Ray 按钮，模糊匹配书籍 sdr 目录下的 xray.json，弹出人物/地点/事件/术语/组织注释。支持章节作用范围（防剧透）与多结果选择。低资源设计：未使用零占用，查询后随书关闭释放。]]),
}
