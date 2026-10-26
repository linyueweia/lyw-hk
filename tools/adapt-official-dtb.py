#!/usr/bin/env python3
"""把【飞牛官方基镜像自带的 H88K DTB】就地适配成与【官方内核】匹配的版本。

为什么需要这一步（2026-10-26 实测证据，全部来自官方镜像自身）：
  官方基镜像 BOOT 分区里 dtb/rockchip/rk3588-hinlink-h88k.dtb（sha256 c2162495…，
  与厂商 iNextOS 里的那份逐字节相同）是厂商 6.1 BSP 树编的，SoC 级用了厂商命名：
      rockchip,iommu-v2        × 21
  而官方内核二进制（vmlinuz-6.18.18.c1145-trim）的 of_match 表里：
      rockchip,iommu-v2        0 处
      rockchip,rk3588-iommu    2 处
  ⇒ 官方镜像这份 DTB 与它自己的内核就是错配的：IOMMU（VOP/VPU/RGA 的地址翻译）
    一个都不会 probe。本脚本把 DTB 改到与官方内核一致。

改造项（每一项都有上面的证据支撑，不做别的猜测性改动）：
  ① rockchip,iommu-v2  → rockchip,rk3588-iommu      （21 处；字符串不等长，走 dtc 往返）
  ② PMIC rk806 节点补 rockchip,system-power-controller（官方内核 rk8xx-core 靠它注册
     sys_off handler；不加则 poweroff 只 halt 不断电）
不做的事：不改 gmac / LED / PCIe / SATA / regulator 等任何板级数值；不删任何节点
  （mipi-dcphy ×2、hdmirx-ctrler ×1 官方内核虽无驱动，但保留节点也无害、便于后续内核升级）。

用法：
  python3 tools/adapt-official-dtb.py <dtb 路径> [--dry-run]
"""

import re
import shutil
import subprocess
import sys
import tempfile
import os

IOMMU_OLD = "rockchip,iommu-v2"
IOMMU_NEW = "rockchip,rk3588-iommu"
PMIC_COMPAT = 'compatible = "rockchip/rk806"'  # 仅用于定位，实际匹配下面两种写法
POWER_PROP = "rockchip,system-power-controller"


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    dtb = sys.argv[1]
    dry = "--dry-run" in sys.argv
    if not os.path.isfile(dtb):
        print(f"✗ 找不到 {dtb}")
        return 2

    for tool in ("dtc",):
        if shutil.which(tool) is None:
            print(f"✗ 需要 {tool}")
            return 2

    with tempfile.TemporaryDirectory() as td:
        dts = os.path.join(td, "in.dts")
        out = os.path.join(td, "out.dtb")
        r = run(["dtc", "-I", "dtb", "-O", "dts", "-o", dts, dtb])
        if r.returncode != 0:
            print("✗ dtc 反编译失败:", r.stderr[:400])
            return 2
        text = open(dts, encoding="utf-8").read()

        n_iommu = text.count(IOMMU_OLD)
        if n_iommu == 0 and IOMMU_NEW in text:
            print(f"  （已适配过：{IOMMU_NEW} 已在位，跳过 ①）")
        else:
            text = text.replace(IOMMU_OLD, IOMMU_NEW)
            print(f"  ① {IOMMU_OLD} → {IOMMU_NEW}：{n_iommu} 处")

        # ② PMIC：在兼容 rk806 的节点里补断电属性（若尚无）
        if POWER_PROP in text:
            print("  （已适配过：PMIC 断电属性已在位，跳过 ②）")
        else:
            lines = text.splitlines(keepends=True)
            out_lines, inserted = [], False
            in_rk806 = False
            depth = 0
            for ln in lines:
                out_lines.append(ln)
                if not in_rk806 and re.search(r'compatible = "rockchip,rk806"', ln):
                    in_rk806 = True
                    out_lines.append(f'\t\t\t/* adapt-official-dtb: 主线 rk8xx-core 凭此注册 sys_off */\n')
                    out_lines.append(f'\t\t\t{POWER_PROP};\n')
                    inserted = True
                    continue
                if in_rk806:
                    depth += ln.count("{") - ln.count("}")
                    if depth < 0 or (depth == 0 and ln.strip() == "};"):
                        in_rk806 = False
            text = "".join(out_lines)
            print(f"  ② PMIC 补 {POWER_PROP}：{'已插入' if inserted else '未找到 rk806 节点（跳过）'}")

        open(dts, "w", encoding="utf-8").write(text)
        r = run(["dtc", "-q", "-I", "dts", "-O", "dtb", "-o", out, dts])
        if r.returncode != 0:
            print("✗ dtc 回编失败:", r.stderr[:600])
            return 2

        # 断言
        r2 = run(["dtc", "-I", "dtb", "-O", "dts", "-o", "-", out])
        back = r2.stdout
        n_new = back.count(IOMMU_NEW)
        n_old = back.count(IOMMU_OLD)
        ok = True

        def chk(cond, msg):
            nonlocal ok
            print(("  ✓ " if cond else "  ✗ ") + msg)
            ok = ok and cond

        print("---- 适配后断言 ----")
        chk(n_new == 21, f"{IOMMU_NEW} = {n_new} 处（期望 21）")
        chk(n_old == 0, f"{IOMMU_OLD} 残留 = {n_old} 处（期望 0）")
        chk('model = "HINLINK H88K"' in back, 'model 仍为 HINLINK H88K')
        chk("hlink,h88k" in back or "hinlink,h88k" in back, "compatible 仍含 h88k")
        chk(POWER_PROP in back, f"PMIC 带 {POWER_PROP}")
        chk('phy-mode = "rgmii-rxid"' in back, "gmac0 仍是 rgmii-rxid")
        chk("linux,cma-default" not in back, "无 cma 固定区（CMA 走 cmdline）")
        if not ok:
            return 1
        if dry:
            print("（--dry-run：未写回）")
            return 0
        shutil.copyfile(out, dtb)
        print(f"✓ 已写回 {dtb}（{os.path.getsize(dtb)} B）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
