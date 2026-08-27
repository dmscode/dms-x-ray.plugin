# -*- coding: utf-8 -*-
"""X-Ray 数据层真实数据性能压测：385 条目真实 xray.json。

用 lupa(LuaJIT) 跑真实 load + 各级 lookup 计时。
PC LuaJIT 结果 × 20 作为墨水屏设备估算上限（需求 FR7：热查询 <5ms）。
用法：venv python perf_check.py [xray.json 路径]
"""
import json
import os
import sys
import tempfile
import time

from lupa import LuaRuntime
from test_xray_data import py_to_lua_source  # 复用转换器

DEFAULT_JSON = (r"F:/WorkSpace/ForAI/KOReader/银河系搭车客指南5部曲/"
                r"银河系搭车客指南5部曲（X-Ray）.sdr/xray.json")


def main():
    json_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_JSON
    if not os.path.exists(json_path):
        sys.exit("错误：数据文件不存在：%s" % json_path)

    # fixture：真实 JSON → Lua 表字面量；xray.json 本体也放入 mock sdr 目录
    data = json.load(open(json_path, encoding="utf-8"))
    tmp = tempfile.mkdtemp(prefix="xray_perf_")
    fixture = os.path.join(tmp, "fixture.lua")
    with open(fixture, "w", encoding="utf-8") as f:
        f.write("return " + py_to_lua_source(data))
    with open(os.path.join(tmp, "xray.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    size = os.path.getsize(json_path)

    lua = LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g._XRAY_FIXTURE = fixture
    g._XRAY_DIR = tmp
    g._XRAY_SIZE = size
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
    plugin = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "..", "dms-x-ray.koplugin", "lib", "xray_data.lua")
    xd = lua.eval("dofile(%r)" % plugin.replace("\\", "/"))

    # 冷启动：load 建索引
    t0 = time.perf_counter()
    res = xd.load("book.epub")
    if isinstance(res, tuple):
        res = res[0]
    load_ms = (time.perf_counter() - t0) * 1000
    st = dict(xd.stats())
    print("数据: %d 条目 / %d 别名 / %d KB" % (st["entries"], st["aliases"], size // 1024))
    print("冷启动 load+建索引: %.1f ms（墨水屏估算 ×20 = %.0f ms，目标 <100ms）"
          % (load_ms, load_ms * 20))
    assert res, "load 失败"

    # 热查询：精确命中
    def bench(name, text, n, chapter=None, fuzzy=None):
        t0 = time.perf_counter()
        for _ in range(n):
            xd.lookup(text, chapter, fuzzy)
        ms = (time.perf_counter() - t0) / n * 1000
        print("%s: %.3f ms/次（墨水屏估算 %.2f ms，目标 <5ms）"
              % (name, ms, ms * 20))

    bench("L1 精确命中（亚瑟）", "亚瑟", 200)
    bench("L1 精确+clean（亚瑟·邓特。）", "亚瑟·邓特。", 100)
    bench("L2 包含命中（了亚瑟·邓特和）", "了亚瑟·邓特和", 50)
    bench("全 miss（走完 L1+L2 全表扫）", "这句话里没有任何已知词汇出现", 50)

    # 真实词条抽查
    for w in ("福特", "沃贡人", "黄金之心", "42"):
        res = xd.lookup(w, None, None)
        cnt = 0
        i = 1
        if res and not isinstance(res, tuple):
            while res[i] is not None:
                cnt += 1
                i += 1
        print("抽查 %-6s -> %d 条命中" % (w, cnt))


if __name__ == "__main__":
    main()
