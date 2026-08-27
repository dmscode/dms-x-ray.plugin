# -*- coding: utf-8 -*-
"""生成友好的中文 GitHub Release notes。

用法：
    python gen_release_notes.py --tag v0.2.0 [--out 输出.md] [--base 基版本]

依据 Git 提交历史（Conventional Commits）自动归类：
    - feat      → 「新增」
    - fix       → 「修复」
    - 其余类型（perf/refactor/docs 等）及无前缀标题 → 「优化与其他」
标题剥离 `类型(scope):` 前缀后中文展示。

版本对比区间：默认取「--tag 前一个 v* 标签 → --tag」；也可用 --base 显式指定。
若 --tag 是首个版本标签，则列出其全部提交。
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


def collect_commits(tag, base):
    """返回 (区间描述, 未分类 raw 列表 [(type, title)])。

    区间 = [base, tag]：base 缺省时取 tag 前一个 v* 标签；tag 本身是首个版本则列全部提交。
    """
    if base:
        rng, desc = f"{base}..{tag}", f"{base} → {tag}"
    else:
        tags = [t for t in git(["tag", "-l", "v*", "--sort=v:refname"]).splitlines() if t]
        # 取 tag 前面的上一个 v* 标签
        prev = None
        for i, t in enumerate(tags):
            if t == tag and i > 0:
                prev = tags[i - 1]
                break
        if prev:
            rng, desc = f"{prev}..{tag}", f"{prev} → {tag}"
        else:
            rng, desc = None, "全部提交"
    raw = git(["log", rng or tag, "--pretty=%s", "--no-merges"]) if rng else \
        git(["log", tag, "--pretty=%s", "--no-merges"])
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
    return desc, commits


def build_notes(tag, base):
    range_desc, commits = collect_commits(tag, base)
    buckets = {label: [] for _, label in TYPE_GROUPS}
    for ctype, title in commits:
        label = "优化与其他"
        for ctype_key, group_label in TYPE_GROUPS:
            if ctype == ctype_key:
                label = group_label
                break
        buckets[label].append(title)

    lines = [f"# X-Ray 插件 {tag}", ""]
    lines.append(f"本节为 {tag} 版本说明（对比 {range_desc}）。" if range_desc else
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
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tag", default="HEAD", help="当前标签，如 v0.2.0（缺省 HEAD）")
    ap.add_argument("--out", help="写入此文件（否则打印到 stdout）")
    ap.add_argument("--base", default="", help="对比基版本，缺省自动取 --tag 前一个 v* 标签")
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