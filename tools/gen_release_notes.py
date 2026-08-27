# -*- coding: utf-8 -*-
"""生成友好的中文 GitHub Release notes。

用法：
    python gen_release_notes.py [--out 输出.md] [基版本]

依据 Git 提交历史（Conventional Commits）自动归类：
    - feat      → 「新增」
    - fix       → 「修复」
    - perf/refactor/docs/chore/test/build/ci 归类到「优化与其他」
    - 无前缀提交标题也归入「优化与其他」
标题剥离 `类型(scope):` 前缀后中文展示。

版本对比区间：若指定基版本则用它；否则用「上一个 v* 标签 → 当前 HEAD」。
若没有任何历史版本（首个发布），列出全部提交。
"""
import argparse
import os
import re
import subprocess

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 提交类型 → 中文分组，顺序决定分组在 note 中的排列；
# 匹配不到的类型（perf/refactor/docs 等）一律归入"优化与其他"
TYPE_GROUPS = [
    ("feat", "新增"),
    ("fix", "修复"),
    ("other", "优化与其他"),
]
# 匹配 "type(scope): 描述" 或 "type: 描述"
CONV_RE = re.compile(r"^([a-z]+)(?:\([^)]*\))?:\s*(.*)$")


def git(args):
    out = subprocess.run(["git", "-C", REPO] + args,
                         capture_output=True, text=True, check=False)
    return out.stdout.strip()


def collect_commits(base):
    """返回 (区间描述, 未分类 raw 列表 [(type, title)])。"""
    scope = base if base else ("首个版本" if not git(["tag", "-l", "v*"]) else "")
    if base:
        raw = git(["log", f"{base}..HEAD", "--pretty=%s", "--no-merges"])
        range_desc = f"{base} → HEAD"
    else:
        # 无基版本：找上一个 v* 标签
        tags = [t for t in git(["tag", "-l", "v*", "--sort=v:refname"]).splitlines() if t]
        if not tags:
            raw = git(["log", "HEAD", "--pretty=%s", "--no-merges"])
            range_desc = "全部提交"
        else:
            raw = git(["log", f"{tags[-1]}..HEAD", "--pretty=%s", "--no-merges"])
            range_desc = f"{tags[-1]} → HEAD"
    commits = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        m = CONV_RE.match(line)
        if m:
            commits.append((m.group(1), m.group(2).strip()))
        else:
            commits.append(("other", line))
    return range_desc, commits


def build_notes(tag, base):
    range_desc, commits = collect_commits(base)
    buckets = {label: [] for _, label in TYPE_GROUPS}
    for ctype, title in commits:
        label = "优化与其他"
        for ctype_key, group_label in TYPE_GROUPS:
            if ctype == ctype_key:
                label = group_label
                break
        buckets[label].append(title)

    lines = [f"# X-Ray 插件 {tag}", ""]
    lines.append(f"本节为 {tag} 版本说明（对比 {range_desc}）。" if base or range_desc else
                 f"本节为 {tag} 版本说明。")
    lines.append("")

    for _, label in TYPE_GROUPS:
        items = buckets[label]
        if not items:
            continue
        lines.append(f"## {label}")
        for it in items:
            lines.append(f"- {it}")
        lines.append("")

    if not commits:
        lines.append("（本版本无提交历史，或为基础数据生成。）")
    else:
        lines.append(f"共 {len(commits)} 条提交。")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("tag", help="当前发布标签，如 v0.2.0")
    ap.add_argument("--out", help="写入此文件（否则打印到 stdout）")
    ap.add_argument("base", nargs="?", default="", help="对比基版本，缺省自动找上一 v* 标签")
    args = ap.parse_args()

    text = build_notes(args.tag, args.base)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"已写入 {args.out}")
    else:
        print(text)


if __name__ == "__main__":
    main()