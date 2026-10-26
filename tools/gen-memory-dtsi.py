#!/usr/bin/env python3
"""由 dts/memory-banks.json 生成 memory-banks.dtsi —— DTS 里不留硬编码内存数字。

用法:
  tools/gen-memory-dtsi.py dts/memory-banks.json -o <内核树>/arch/arm64/boot/dts/rockchip/memory-banks.dtsi
"""
import argparse
import json
import os
import sys


def cells(v):
    """64 位值拆成两个 32 位 cell（address-cells=2 / size-cells=2）。"""
    return "0x%x 0x%x" % ((v >> 32) & 0xFFFFFFFF, v & 0xFFFFFFFF)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json_path")
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()

    with open(a.json_path, encoding="utf-8") as f:
        d = json.load(f)

    banks = d.get("banks") or []
    if not banks:
        sys.exit("!! memory-banks.json 里没有 banks")
    for b in banks:
        if not isinstance(b.get("base"), int) or not isinstance(b.get("size"), int):
            sys.exit("!! 非法 bank: %r" % (b,))
        if b["size"] <= 0:
            sys.exit("!! bank size 必须 > 0: %r" % (b,))
    banks.sort(key=lambda b: b["base"])

    model = d.get("model", "?")
    src = os.path.basename(a.json_path)
    reg = ",\n\t\t      ".join(
        "<%s %s>" % (cells(b["base"]), cells(b["size"])) for b in banks
    )
    name = "memory@%x" % banks[0]["base"]
    total = sum(b["size"] for b in banks)

    txt = (
        "/* 自动生成，勿手改：来源 %s（model=%s）\n"
        " * %d banks / %.3f GiB\n"
        " */\n"
        "\t%s {\n"
        "\t\tdevice_type = \"memory\";\n"
        "\t\treg = %s;\n"
        "\t};\n"
    ) % (src, model, len(banks), total / 1024.0 ** 3, name, reg)

    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        f.write(txt)
    print("  生成 %s: %s, %d banks, %.3f GiB" % (a.out, name, len(banks), total / 1024.0 ** 3))


if __name__ == "__main__":
    main()
