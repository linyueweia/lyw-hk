#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lyw-hk 最终 DTB 可复现生成器（金标准 = 厂商实机 iNextOS DTB）

输入: 厂商实机 /boot/dtb/rockchip/rk3588-hinlink-h88k.dtb
      (md5 37193036099ba80b945c792f741afb3e, 270355 B)
输出: dist/rk3588-hinlink-h88k.dtb —— 恰好 7 行改造:
      ① 删 /reserved-memory/cma（固定 256M 区会把 CMA 压死，
         CMA 改由 fnEnv extraargs=cma=2G 决定；K1 同款 fnOS 内核实机验证路线）
      ② /spi@feb20000/rk806single@0 加 rockchip,system-power-controller
         （主线 rk8xx-spi 靠它注册 sys_off 断电 handler；厂商原版无 → poweroff 只 halt；
          源码依据: drivers/mfd/rk8xx-core.c device_property_read_bool 两种写法都认）
      其余一律原样（model/gmac0 rgmii-rxid+tx_delay=0x44/LED/PCIe/PMIC 全保留）。

用法: python3 tools/make-final-dtb.py [实机.dtb] [输出.dtb]
依赖: pyfdt (pip install pyfdt)
"""
import sys, os, hashlib

def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "refs/rk3588-hinlink-h88k-live-inextos.dtb"
    dst = sys.argv[2] if len(sys.argv) > 2 else "dist/rk3588-hinlink-h88k.dtb"
    from pyfdt.pyfdt import FdtBlobParse, FdtProperty

    with open(src, "rb") as fh:
        raw = fh.read()
    md5 = hashlib.md5(raw).hexdigest()
    print(f"底本: {src}  {len(raw)} B  md5 {md5}")
    if md5 != "37193036099ba80b945c792f741afb3e":
        print("⚠ 底本 md5 与金标准不符（若确认是同源新版可继续，否则停）")
        if "--force" not in sys.argv:
            sys.exit(1)

    fdt = FdtBlobParse(open(src, "rb")).to_fdt()

    # ① 删 cma 固定区
    paths = [p for p, _ in fdt.get_rootnode().walk()]
    if "/reserved-memory/cma" in paths:
        fdt.resolve_path("/reserved-memory").remove("cma")
        print("  ① 已删 /reserved-memory/cma")
    else:
        print("  ① 底本无 cma 节点（跳过）")

    # ② PMIC 断电属性
    pmic = fdt.resolve_path("/spi@feb20000/rk806single@0")
    names = [p.name for p in pmic.subdata if hasattr(p, "name")]
    if not any("system-power-controller" in n for n in names):
        pmic.append(FdtProperty("rockchip,system-power-controller"))
        print("  ② 已加 rockchip,system-power-controller")
    else:
        print("  ② 已存在（跳过）")

    data = fdt.to_dtb()
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    with open(dst, "wb") as fh:
        fh.write(data)
    print(f"输出: {dst}  {len(data)} B  sha256 {hashlib.sha256(data).hexdigest()}")

    # 回读断言
    with open(dst, "rb") as fh:
        dts = FdtBlobParse(fh).to_fdt().to_dts()
    checks = {
        "cma 已删": "/reserved-memory/cma" not in [p for p, _ in FdtBlobParse(open(dst, "rb")).to_fdt().get_rootnode().walk()],
        "power-ctrl": "rockchip,system-power-controller;" in dts,
        "model": 'model = "HINLINK H88K"' in dts,
        "gmac": 'phy-mode = "rgmii-rxid"' in dts and "tx_delay = <0x00000044>" in dts,
        "leds": all(x in dts for x in ('label = "blue:net"', 'label = "amber:sata"',
                                       'label = "green:user"', 'label = "red:work"')),
    }
    for k, v in checks.items():
        print(("  ✓ " if v else "  ✗ ") + k)
    if not all(checks.values()):
        sys.exit(1)
    print("== 生成 + 断言通过 ==")

if __name__ == "__main__":
    main()
