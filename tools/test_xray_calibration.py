# -*- coding: utf-8 -*-
"""X-Ray 章节校准模块测试：用 lupa(LuaJIT) 执行真实 xray_calibration.lua。

mock KOReader 依赖（logger/lib.xray_chapter/doc_settings/toc/document），
验证：手动首章/尾章校准计算（offset/residual/fuzzy）、覆盖语义、
错误路径（nofirst/nolast/nochapter）、存储数据形状。
（v2 已取消自动校准与标题比对，相关用例移除）
用法：venv python test_xray_calibration.py
"""
import os
import sys

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(HERE, "..", "dms-x-ray.koplugin", "lib").replace("\\", "/")


def main():
    lua = LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g._PLUGIN = PLUGIN

    # mock 层 + 场景与断言全在 Lua 侧（闭包构造 ui/doc_settings/toc 更自然）
    lua.execute(r"""
        -- ---------- mock KOReader 依赖 ----------
        package.preload['logger'] = function()
            local noop = function() end
            return { info = noop, warn = noop, dbg = noop, err = noop }
        end
        package.preload['lib.xray_chapter'] = function()
            return dofile(_PLUGIN .. "/xray_chapter.lua")
        end

        local Calib = dofile(_PLUGIN .. "/xray_calibration.lua")
        _G.RESULTS = {}

        local function check(name, cond, detail)
            table.insert(_G.RESULTS, { name = name, ok = cond and true or false,
                detail = cond and "" or tostring(detail) })
        end

        -- ---------- 场景构造工厂 ----------
        -- 构造"当前书"：前 prefix 条为前置物（广告/目录），正文 n_body 章，可选中段插 1 章番外
        -- ticks[i] = i*10（压平序号 i 起始页 10i，与 getTocTicksFlattened 一致）
        local function makeUI(prefix, n_body, extra_mid)
            local total = prefix + n_body + (extra_mid or 0)
            local store = {} -- DocSettings 持久层
            local cur_page = 0
            local ui = {
                doc_settings = {
                    readSetting = function(_, key) return store[key] end,
                    saveSetting = function(_, key, v) store[key] = v end,
                    flush = function() end,
                },
                document = {
                    info = {},
                    getCurrentPage = function() return cur_page end,
                },
                toc = {
                    getTocTicksFlattened = function(_, _)
                        local t = {}
                        for k = 1, total do t[k] = k * 10 end
                        return t
                    end,
                },
            }
            return ui, store, function(p) cur_page = p end, total
        end

        -- 基准 meta：正文 18 章
        local META = {
            chapter_first = 1, chapter_last = 18,
            chapter_first_title = "第1章 标题",
            chapter_last_title = "第18章 标题",
        }

        -- ---------- 1. 手动首章校准 ----------
        local ui, store, setpage = makeUI(2, 18)
        setpage(30) -- 正文第一章（TOC 第 3 条，序号 3）
        local offset, err = Calib.calibrateFirst(ui, META)
        check("手动首章 offset=3-1=2", offset == 2, offset)
        check("手动首章无错", err == nil, err)
        check("手动首章持久化", store["dms_xray_calibration"].offset == 2)
        local c = Calib.get(ui)
        check("手动首章 fuzzy 清零", c.fuzzy == 0 and c.stored == true)
        -- v2 存储形状：仅 offset/fuzzy，无 tried 残留
        local keys = {}
        for k in pairs(store["dms_xray_calibration"]) do keys[#keys + 1] = k end
        table.sort(keys)
        check("存储数据仅 offset/fuzzy", table.concat(keys, ",") == "fuzzy,offset",
            table.concat(keys, ","))

        -- ---------- 2. 手动尾章校准（依赖首章 offset=2） ----------
        -- 2a 章节数一致：正文末章 = TOC 第 20 条（序号 20）
        setpage(200)
        local fuzzy, err, residual = Calib.calibrateLast(ui, META)
        check("手动尾章 residual=0", residual == 0, residual)
        check("手动尾章 fuzzy=0", fuzzy == 0, fuzzy)
        -- 2b 中段多 1 章：重建场景（首章 offset=2，末章序号 21 → residual=1 → fuzzy=1）
        Calib.reset()
        local ui2, _, setpage2 = makeUI(2, 18, 1)
        setpage2(30)
        Calib.calibrateFirst(ui2, META)
        setpage2(210) -- 番外后正文末章 = TOC 第 21 条
        local fuzzy2, err2, residual2 = Calib.calibrateLast(ui2, META)
        check("手动尾章中段差异 residual=1", residual2 == 1, residual2)
        check("手动尾章中段差异 fuzzy=1", fuzzy2 == 1, fuzzy2)

        -- ---------- 3. 尾章前置校验 ----------
        Calib.reset()
        local ui3 = makeUI(2, 18)
        local f3, err3 = Calib.calibrateLast(ui3, META)
        check("未做首章校准 → nofirst", f3 == nil and err3 == "nofirst", tostring(err3))
        -- 数据无 chapter_last/count → nolast
        Calib.reset()
        local ui4, _, setpage4 = makeUI(2, 18)
        setpage4(30)
        Calib.calibrateFirst(ui4, META)
        local f4, err4 = Calib.calibrateLast(ui4, { chapter_first = 1 })
        check("无 chapter_last/count → nolast", f4 == nil and err4 == "nolast", tostring(err4))

        -- ---------- 4. 覆盖语义：重新首章校准覆盖旧值并清 fuzzy ----------
        Calib.reset()
        local uiA, _, setpageA = makeUI(2, 18)
        setpageA(30)
        Calib.calibrateFirst(uiA, META)
        setpageA(200)
        Calib.calibrateLast(uiA, META) -- fuzzy=0（一致）
        -- 换一本偏移不同的书（模拟换版本）：offset 应覆盖
        setpageA(50) -- TOC 第 5 条 → offset = 5-1 = 4
        local offsetA = Calib.calibrateFirst(uiA, META)
        check("重新校准覆盖旧值", offsetA == 4, offsetA)
        local cA = Calib.get(uiA)
        check("重新首章校准后 fuzzy 清零", cA.fuzzy == 0)

        -- ---------- 5. chapter_first 缺省（=1）时的手动校准 ----------
        Calib.reset()
        local uiB, _, setpageB = makeUI(2, 18)
        setpageB(30)
        local offsetB = Calib.calibrateFirst(uiB, { chapter_last = 18 })
        check("meta 缺 chapter_first 按 1 处理", offsetB == 2, offsetB)

        -- ---------- 6. 无 TOC 错误路径（PDF / 空 ticks） ----------
        Calib.reset()
        local uiC = {
            doc_settings = {
                readSetting = function() return nil end,
                saveSetting = function() end,
                flush = function() end,
            },
            document = { info = { has_pages = true }, getCurrentPage = function() return 1 end },
            toc = {},
        }
        local fC, errC = Calib.calibrateFirst(uiC, META)
        check("无 TOC → nochapter", fC == nil and errC == "nochapter", tostring(errC))
    """)

    passed, failed = 0, 0
    for r in g.RESULTS.values():
        if r["ok"]:
            passed += 1
            print("PASS -", r["name"])
        else:
            failed += 1
            print("FAIL -", r["name"], r["detail"])
    print()
    print("=== %d passed, %d failed ===" % (passed, failed))
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
