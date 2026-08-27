# X-Ray 划词插件（dms-x-ray.koplugin）

KOReader 插件：长按划词 → 工具栏「X-Ray」按钮 → 从随书 `xray.json` 模糊查询
人物 / 地点 / 事件 / 术语 / 组织词条并弹窗展示。支持章节作用范围（防剧透）、
分阶段描述（跟踪剧情）、一词多义多结果、编辑距离纠错（英文）。为低算力墨水屏设备设计：
**未使用零占用、查询极低消耗、关书全释放**。

## 文档索引

| 文档 | 内容 |
|---|---|
| `功能需求文档.md` | 详细需求（FR1–FR8）、匹配算法、资源指标、已验证的 KOReader 源码依据 |
| `xray.json格式规范.md` | 数据文件 schema、渐进式标注、AI 生成指南（独立格式规范） |
| `开发路线图.md` | 各阶段实现进度与验收汇总 |

## 安装

把 `dms-x-ray.koplugin/` 整个目录拷到 KOReader 插件目录（任选其一）：

```
<koreader>/plugins/dms-x-ray.koplugin/          # 随程序
<用户数据目录>/plugins/dms-x-ray.koplugin/       # 随用户数据（推荐）
```

重启 KOReader（插件管理中可见「X-Ray」）。

## 数据文件

位置：书籍同目录 `<书名去扩展名>.sdr/xray.json`（由 `DocSettings:getSidecarDir(doc, "doc")`
得到，与 KOReader 的 sidecar 目录一致，拷贝书 + 同名 .sdr 目录即可携带数据）。

**生成方式**：详尽格式规范与 AI 生成指南见 `xray.json格式规范.md`（含 schema、
`chapters`/`stages` 渐进式与非剧透说明、AI 工具生成流程与校验清单）。

如已有符合 `{"entities": {类型: [条目...]}}` 结构的实体数据，可用转换器
`../xray-data-tools/build_xray.py` 一键转换（v2，自动从 entities 同级的
`work_notes/raw/*_entities.json` 的 `_chapters` 推算渐进式章节范围）：

```bash
python ../xray-data-tools/build_xray.py <书>.entities.json -o <书>.epub
# -o 传书籍文件时自动写入 <书名去扩展名>.sdr/xray.json
```

`-o` 也可直接传 `.json` 输出路径；`--raw-dir` / `--chapter-index` 可覆盖默认探测位置。
转换器会打印条目分型统计、渐进式覆盖数、跨条目共用别名数与体积。

## 使用

1. 开书（需已生成数据：`onReaderReady` 会 stat 探测，存在时划词工具栏才出现 X-Ray 按钮）
2. 长按划词 → 点「X-Ray」→ 弹出词条（命中 1 条直出详情；多条先出选择列表）
3. 主菜单 → X-Ray：人物 / 地点 / 事件 / 术语 / 组织列表（默认按当前章过滤）+ 设置
4. 设置：模糊匹配（编辑距离纠错）开关、列表显示全书/当前章、数据缓存统计
5. 非触屏设备：已注册 Dispatcher 动作 `X-Ray lookup`（`XRayLookup`），可绑定键位/手势兜底，
   取最近一次划词文本查询

## 匹配算法（lib/xray_data.lua）

```
输入划词文本
  ↓ L0 规范化 clean：清理空白 → 剥首尾标点（UTF-8 字符表）→ 英文小写
  ↓ L1 精确哈希命中（含全部 aliases，O(1)）── 覆盖大多数场景
  ↓ 未中  L2 双向包含（选词⊇别名多划 / 别名⊇选词少划，防误配限长）
  ↓ 未中  L3 N-gram 剪枝 → Top5 候选 → 编辑距离 ≤2（默认关闭，中文无需）
  ↓ 命中集 → 按当前章节过滤（chapters 作用范围 + 命中 stages 文本）
      → 排序（命中方式 精确>包含>模糊；类型 人物>地点>术语>组织>事件）
      → 1 条 → 详情弹窗；多条 → 选择列表 → 详情弹窗
```

- 索引：`clean(别名) -> 条目下标[]`，同一别名可对应多条目（一词多义）
- 内存预算 2MB：数据估算超预算拒绝加载；>700KB 自动剥 `description` 只留 `summary`
- 完整 `description` 仅展示时才取用、索引期不载入（保持索引轻量）

## 章节作用范围（lib/xray_chapter.lua）

- 当前页码 → TOC 顺序章节号（1 起）：用 `ReaderToc:getTocTicksFlattened()` 的章节起始页
  数组线性定位；无 TOC / PDF（`has_pages`）时返回 nil → 全书模式（忽略章节过滤）

## 弹窗（ui/xray_popup.lua）

- `ScrollHtmlWidget` 底部浮层，MuPDF 渲染 HTML
- **字体跟随正文**：`@font-face` 注入书籍字体，失败回退 Noto Sans；字号由正文尺寸换算
- **按内容自适应高度**：不足一页自动收缩，默认上限 35% 屏高
- **单例池复用**：多次点选复用同一 widget，`_reopen` 换内容不重建
- 关闭：点弹窗外空白 / 左右下滑 / Back 键；关闭即释放 widget

## 性能实测（385 条目 / 977 别名 / 197KB，含渐进式 chapters）

| 指标 | PC(LuaJIT) | 墨水屏估算* | 目标 |
|---|---|---|---|
| 冷启动（首次点击 load+建索引） | 14.3 ms | 0.14–0.3 s（一次性） | <100ms |
| L1 精确/别名命中 | 0.01 ms | <0.5 ms | <5ms ✅ |
| L2 包含命中 | 0.27 ms | ~2.7 ms | <5ms ✅ |
| 全 miss（L1+L2 全表扫） | 0.29 ms | ~2.9 ms | <5ms ✅ |

\* 按 CPU 主频折算 7–20 倍区间估算；测试脚本 `tools/perf_check.py`、
逻辑测试 `tools/test_xray_data.py`（lupa 执行真实 Lua，27 用例）。

资源约束：未触发零占用（开书仅一次 stat）；书打开期间索引常驻 ≤2MB
（197KB 数据 → Lua 内存约 0.3MB）；关书 `onCloseDocument` 全释放（清索引 + 弹窗清理 + GC）。

## 模块结构

```
xray-plugin/
├── README.md                # 本说明
├── 功能需求文档.md           # 需求、算法与性能指标
├── xray.json格式规范.md     # 数据格式规范（独立）
├── 开发路线图.md            # 分阶段进度与验证汇总
├── tools/
│   ├── perf_check.py        # 真实数据性能压测（lupa 跑真实 Lua）
│   └── test_xray_data.py    # 数据层逻辑测试（lupa，27 用例）
└── dms-x-ray.koplugin/
    ├── _meta.lua            # 插件元数据（插件管理界面显示）
    ├── main.lua             # 入口：划词按钮(11_xray)/主菜单/Dispatcher/生命周期
    ├── lib/xray_data.lua    # 数据层：加载/三级匹配/索引/2MB预算/释放
    ├── lib/xray_chapter.lua # 章节换算（TOC ticks → 章节号；PDF 降级全书）
    └── ui/xray_popup.lua    # 弹窗：ScrollHtmlWidget 底部浮层/单例池/字体跟随

# 配套转换器（独立于插件）
xray-data-tools/build_xray.py  # entities.json + raw/_chapters → 渐进式 xray.json
```

## 已知限制

- 冷启动为一次性成本（约 0.1–0.3s 估算）；当前版本无后台预载，保持「未触发零占用」
  原则；后续版本可加可选预热
- 划词工具栏按钮依赖 ReaderHighlight（PDF 无文本选择时不出现，可用 Dispatcher 动作
  `X-Ray lookup` 绑定键位/手势兜底）
- 渐进式 `chapters` 已由转换器 v2 从 `work_notes/raw/*` 的 `_chapters` 字段生成
  （374/385 条目有范围；主角等贯穿全书的为全书可见）。`stages`（分阶段描述）当前
  测试数据未生成，schema 与插件端过滤逻辑已支持
- 一个别名对应多词条时全部列出（按匹配方式/类型排序）；词条极多（>12）时选择列表截断，
  提示剩余条数