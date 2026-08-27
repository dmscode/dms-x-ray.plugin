# -*- coding: utf-8 -*-
"""X-Ray 数据层逻辑测试：用 lupa(LuaJIT) 执行真实 xray_data.lua。

mock 掉 KOReader 依赖（json/docsettings/lfs/util/logger），
用手工 fixture 验证：加载、精确/别名/包含匹配、章节过滤（防剧透）、
stages 分阶段、一词多义多结果、模糊编辑距离、列表、释放。
用法：venv python test_xray_data.py
"""
import json
import os
import sys
import tempfile

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(HERE, "..", "dms-x-ray.koplugin", "lib", "xray_data.lua")

# ---------- 测试数据（含 chapters / stages / 一词多义） ----------
ENTRIES = [
    {"id": "c1", "name": "亚瑟·邓特", "type": "characters",
     "aliases": ["亚瑟·邓特", "亚瑟", "邓特"],
     "summary": "地球人，本书主角。", "first_appearance": "第1章",
     "chapters": [1, 40]},
    {"id": "l1", "name": "地球", "type": "locations",
     "aliases": ["地球"],
     "summary": "亚瑟的母星。", "chapters": [1, 8]},
    {"id": "l2", "name": "地球（重建版）", "type": "locations",
     "aliases": ["地球", "地球2.0"],
     "summary": "重建的地球。",
     "chapters": [38, 40],
     "stages": [{"chapters": [38, 39], "text": "重建中。"},
                {"chapters": [40, 40], "text": "完工。"}]},
    {"id": "t1", "name": "无限不可能性引擎", "type": "terms",
     "aliases": ["无限不可能性引擎", "不可能性引擎"],
     "summary": "黄金之心号的引擎。",
     "stages": [{"chapters": [1, 20], "text": "初登场。"}]},
    {"id": "o1", "name": "沃贡人", "type": "organizations",
     "aliases": ["沃贡人", "沃贡"],
     "summary": "银河系最令人讨厌的种族之一。",
     "description": "以糟糕的诗歌和官僚主义著称。"},
]


def py_to_lua_source(obj, indent=0):
    """Python 数据递归转 Lua 源码（return 表字面量）。"""
    pad = "  " * indent
    if isinstance(obj, dict):
        if not obj:
            return "{}"
        items = []
        for k, v in obj.items():
            key = "[%s]" % lua_str(k) if not k.isidentifier() else k
            items.append("%s  %s = %s," % (pad, key, py_to_lua_source(v, indent + 1)))
        return "{\n" + "\n".join(items) + "\n" + pad + "}"
    if isinstance(obj, list):
        if not obj:
            return "{}"
        items = ["%s  %s," % (pad, py_to_lua_source(v, indent + 1)) for v in obj]
        return "{\n" + "\n".join(items) + "\n" + pad + "}"
    if isinstance(obj, bool):
        return "true" if obj else "false"
    if obj is None:
        return "nil"
    if isinstance(obj, (int, float)):
        return str(obj)
    return lua_str(obj)


def lua_str(s):
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n") + "'"


def main():
    # 准备临时数据目录：xray.json（io.open 用）+ fixture.lua（json.decode 用）
    tmp = tempfile.mkdtemp(prefix="xray_test_")
    data = {"format": 1, "meta": {"title": "测试书"}, "entries": ENTRIES}
    json_path = os.path.join(tmp, "xray.json")
    fixture_path = os.path.join(tmp, "fixture.lua")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    with open(fixture_path, "w", encoding="utf-8") as f:
        f.write("return " + py_to_lua_source(data))
    size = os.path.getsize(json_path)

    lua = LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g._XRAY_FIXTURE = fixture_path
    g._XRAY_DIR = tmp
    g._XRAY_SIZE = size

    # mock KOReader 依赖（json/docsettings/lfs/util/logger）
    lua.execute(r"""
        package.preload['json'] = function()
            return { decode = function(_) return dofile(_XRAY_FIXTURE) end }
        end
        package.preload['docsettings'] = function()
            return { getSidecarDir = function(_, _, _) return _XRAY_DIR end }
        end
        package.preload['libs/libkoreader-lfs'] = function()
            return { attributes = function(_, what)
                if what == 'mode' then return 'file' end
                if what == 'size' then return _XRAY_SIZE end
                return nil
            end }
        end
        package.preload['util'] = function()
            return { cleanupSelectedText = function(t) return t end }
        end
        package.preload['logger'] = function()
            local noop = function() end
            return { info = noop, warn = noop, dbg = noop, err = noop }
        end
    """)

    xd = lua.eval("dofile(%r)" % PLUGIN.replace("\\", "/"))
    if xd is None:
        sys.exit("FAIL: 模块加载返回 nil")

    passed, failed = 0, 0

    def check(name, cond, detail=""):
        nonlocal passed, failed
        if cond:
            passed += 1
            print("PASS -", name)
        else:
            failed += 1
            print("FAIL -", name, detail)

    def lua_list(t):
        """lupa 的 table 迭代给键（pairs），按数组索引取值转 python 列表。"""
        out = []
        if t is None:
            return out
        i = 1
        while t[i] is not None:
            out.append(t[i])
            i += 1
        return out

    def lookup(text, chapter=None, fuzzy=None):
        """统一处理 lupa unpack 模式的返回（单值 table / 双值 tuple）。"""
        res = xd.lookup(text, chapter, fuzzy)
        if isinstance(res, tuple):
            res = res[0]
        return lua_list(res)

    # 1. 探测与加载
    check("probe 存在", bool(xd.probe("test.epub")))
    check("加载成功", xd.load("test.epub") is True or bool(xd.load("test.epub")))
    st = dict(xd.stats())
    check("统计：5 条目 / 10 别名", st["entries"] == 5 and st["aliases"] == 10, str(st))

    # 2. 精确 + 别名
    r = lookup("亚瑟·邓特")
    check("精确命中 1 条", len(r) == 1 and r[0]["entry"]["id"] == "c1", str(len(r)))
    check("精确 kind=1", r and r[0]["kind"] == 1)
    r = lookup("亚瑟")
    check("别名命中", len(r) == 1 and r[0]["entry"]["id"] == "c1")
    r = lookup("Oolon")
    check("英文小写化后未命中（无该别名）", len(r) == 0)

    # 3. 选词容错（clean 层）
    r = lookup("亚瑟·邓特。")
    check("尾部句号剥离后命中", len(r) == 1 and r[0]["entry"]["id"] == "c1")
    r = lookup("，亚瑟。")
    check("首尾标点剥离后命中", len(r) == 1)
    r = lookup("  亚瑟  ")
    check("空白清理后命中", len(r) == 1)

    # 4. 包含匹配（L2）
    r = lookup("了亚瑟·邓特和")
    check("选词超集（多划前后文）", len(r) == 1 and r[0]["entry"]["id"] == "c1", str(len(r)))
    r = lookup("亚瑟·邓")
    check("选词子集（少划尾巴）", len(r) == 1 and r[0]["entry"]["id"] == "c1", str(len(r)))
    r = lookup("亚瑟和福特")
    check("含间隔词不误配（亚瑟是精确子串但整体无别名命中）", len(r) == 1, str(len(r)))

    # 5. 章节过滤（防剧透）+ 一词多义
    r = lookup("地球", 1)
    check("第1章地球→l1", len(r) == 1 and r[0]["entry"]["id"] == "l1")
    r = lookup("地球", 39)
    check("第39章地球→l2", len(r) == 1 and r[0]["entry"]["id"] == "l2")
    r = lookup("地球", 20)
    check("第20章地球→无（剧透保护）", len(r) == 0, str(len(r)))
    r = lookup("地球")
    check("全书模式地球→2 条", len(r) == 2, str(len(r)))

    # 6. stages 分阶段
    r = lookup("地球（重建版）", 39)
    check("stage 命中第38-39段", len(r) == 1 and r[0]["stage"] == "重建中。",
          str(dict(r[0]) if r else {}))
    r = lookup("地球（重建版）", 40)
    check("stage 命中第40段", len(r) == 1 and r[0]["stage"] == "完工。")
    r = lookup("无限不可能性引擎", 1)
    check("stage 无命中章回退 summary", len(r) == 1 and r[0]["stage"] == "初登场。")

    # 7. 模糊（L3，显式开启）。
    # 注："亚瑟邓特"（漏·）会在 L2 被子串别名"亚瑟"包含命中（kind=2，更快的正确路径），
    # 专测 L3 需用与全部别名无包含关系的词："无限不可能引擎"（漏"性"，编辑距离 1）
    r = lookup("无限不可能引擎", None, True)
    check("L3 编辑距离1命中（fuzzy 开）", len(r) == 1 and r[0]["entry"]["id"] == "t1", str(len(r)))
    check("L3 kind=3", len(r) == 1 and r[0]["kind"] == 3,
          str(dict(r[0]) if r else {}))
    r = lookup("无限不可能引擎", None, False)
    check("fuzzy 关时不命中", len(r) == 0, str(len(r)))

    # 8. 列表
    lst = lua_list(xd.listEntries("locations", 1))
    check("地点列表（第1章）只 l1", len(lst) == 1 and lst[0]["id"] == "l1")
    lst = lua_list(xd.listEntries("locations", None))
    check("地点列表全书 l1+l2", len(lst) == 2)
    # 排序：人物>地点>术语>组织>事件
    r = lookup("地球", None)
    check("多结果按类型排序（location 唯一）", len(r) == 2)

    # 9. 释放
    xd.release()
    raw = xd.lookup("亚瑟", None, None)
    check("释放后 lookup 返回 nil",
          raw is None or (isinstance(raw, tuple) and raw[0] is None))

    print()
    print("=== %d passed, %d failed ===" % (passed, failed))
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
