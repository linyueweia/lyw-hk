#!/usr/bin/env python3
"""
本地预检（不依赖 fdtget/dtc/loop 挂载）：
用纯 Python 解析 DTB，把 tools/verify-h88k-dts.sh 与 tools/verify-image.sh 里
所有"对 DTB 的断言"照抄一遍先跑。目的：不要再把门禁脚本的错推到 CI 上试错。

用法：python tools/preflight-dtb.py <某.dtb>
退出码 0 = 全过；1 = 有不符（逐条打印 expected/actual）
"""
import struct
import sys


class Dtb:
    def __init__(self, path):
        b = open(path, 'rb').read()
        (_, _, off_struct, off_strings, _, _, _, _, size_struct, _) = struct.unpack('>10I', b[:40])
        self.raw = b
        self.sb = b[off_strings:off_strings + struct.unpack('>I', b[32:36])[0]]
        self.nodes = {}
        pos, stack = off_struct, []
        while pos + 4 <= len(b):
            tok = struct.unpack('>I', b[pos:pos + 4])[0]
            pos += 4
            if tok == 1:
                e = b.index(b'\x00', pos)
                nm = b[pos:e].decode('utf-8', 'replace')
                pos = (e + 1 + 3) & ~3
                stack.append(nm)
                p = '/' + '/'.join(x for x in stack if x)
                self.nodes.setdefault(p, {})
            elif tok == 2:
                if stack:
                    stack.pop()
            elif tok == 3:
                ln, no = struct.unpack('>II', b[pos:pos + 8])
                pos += 8
                val = b[pos:pos + ln]
                pos = (pos + ln + 3) & ~3
                p = '/' + '/'.join(x for x in stack if x)
                self.nodes.setdefault(p, {})[self._name(no)] = val
            elif tok == 9:
                break
            else:
                break

    def _name(self, o):
        e = self.sb.index(b'\x00', o)
        return self.sb[o:e].decode('utf-8', 'replace')

    def has(self, path):
        return path in self.nodes

    def s(self, path, prop):
        v = self.nodes.get(path, {}).get(prop)
        return None if v is None else v.rstrip(b'\x00').decode('utf-8', 'replace')

    def i(self, path, prop):
        v = self.nodes.get(path, {}).get(prop)
        return None if v is None or len(v) < 4 else struct.unpack('>i', v[:4])[0]

    def exists_prop(self, path, prop):
        return prop in self.nodes.get(path, {})


CHECKS = []            # (说明, 判断函数, 失败时打印实际值函数)


def chk(desc, fn, actual=lambda: ''):
    CHECKS.append((desc, fn, actual))


def build(d):
    # ── 身份 ──
    chk("model 含 H88K", lambda: 'h88k' in (d.s('/', 'model') or '').lower(), lambda: d.s('/', 'model'))
    chk("compatible 含 h88k", lambda: 'h88k' in (d.s('/', 'compatible') or '').lower(),
        lambda: (d.s('/', 'compatible') or '').split('\x00')[0])

    # ── 内存：与官方 T6 一致，不写 /memory ──
    chk("无 device_type=\"memory\"（内存由 u-boot 注入）",
        lambda: not any('memory' in (n.get('device_type') or b'').decode(errors='replace')
                        for n in d.nodes.values()))

    # ── LED 四灯（节点名 gpio-leds，兼容 leds） ──
    def led(nm, want):
        for base in ('/gpio-leds', '/leds'):
            v = d.s(f'{base}/{nm}', 'label')
            if v:
                return v == want
        return False
    for nm, want in (('net', 'blue:net'), ('sata', 'amber:sata'),
                     ('user', 'green:user'), ('work', 'red:work')):
        chk(f"LED {nm} = {want}", (lambda nm=nm, want=want: led(nm, want)),
            lambda nm=nm: d.s(f'/gpio-leds/{nm}', 'label') or d.s(f'/leds/{nm}', 'label') or '(缺)')

    # ── gmac ──
    G = '/ethernet@fe1b0000'
    chk("gmac 无 label（否则 stmmac -17 撞名）", lambda: not d.s(G, 'label'), lambda: d.s(G, 'label') or '(无)')
    chk("gmac phy-mode=rgmii-rxid", lambda: d.s(G, 'phy-mode') == 'rgmii-rxid', lambda: d.s(G, 'phy-mode'))
    chk("gmac tx_delay=0x44(68)", lambda: d.i(G, 'tx_delay') == 68, lambda: d.i(G, 'tx_delay'))
    for p in ('snps,reset-gpio', 'snps,reset-delays-us', 'snps,reset-active-low'):
        chk(f"gmac 具备 {p}（复位必须在 MAC 侧）", (lambda p=p: d.exists_prop(G, p) or d.exists_prop(G, 'snps,reset-gpios')))

    # ── PMIC ──
    chk("PMIC rk806", lambda: 'rk806' in (d.s('/spi@feb20000/pmic@0', 'compatible') or ''),
        lambda: d.s('/spi@feb20000/pmic@0', 'compatible'))
    chk("PMIC 带 system-power-controller", lambda: d.exists_prop('/spi@feb20000/pmic@0', 'rockchip,system-power-controller'))

    # ── PCIe / PHY ──
    for n in ('/pcie@fe150000', '/pcie@fe170000', '/pcie@fe180000', '/pcie@fe190000'):
        chk(f"{n} okay", (lambda n=n: d.s(n, 'status') == 'okay'), lambda n=n: d.s(n, 'status') or '(缺)')
    for n in ('/phy@fee00000', '/phy@fee10000', '/phy@fee20000'):
        chk(f"{n} okay", (lambda n=n: d.s(n, 'status') == 'okay'), lambda n=n: d.s(n, 'status') or '(缺)')
    chk("fe190000 有 reset-gpios（第二块 2.5G 复位）", lambda: d.exists_prop('/pcie@fe190000', 'reset-gpios'))

    # ── 多媒体（对齐 T6） ──
    for n in ('/gpu@fb000000', '/vop@fdd90000', '/hdmi@fde80000', '/hdmi@fde80000'.replace('fde80000', 'fde80000')):
        pass
    for n in ('/gpu@fb000000', '/vop@fdd90000', '/hdmi@fde80000', '/hdmi@fdea0000'):
        chk(f"{n} okay（同 T6）", (lambda n=n: d.s(n, 'status') == 'okay'), lambda n=n: d.s(n, 'status') or '(缺)')
    # 加速器：按飞牛树外驱动的 of_match 命名（2026-10-27 实机定案）
    chk("mpp-srv = rockchip,mpp-service",
        lambda: 'rockchip,mpp-service' in (d.s('/mpp-srv', 'compatible') or ''),
        lambda: d.s('/mpp-srv', 'compatible') or '(缺)')
    chk("mpp-srv okay", lambda: (d.s('/mpp-srv', 'status') or 'okay') == 'okay')
    chk("GPU compatible=mali-csf", lambda: 'rockchip,rk3588-mali-csf' in (d.s('/gpu@fb000000', 'compatible') or ''),
        lambda: d.s('/gpu@fb000000', 'compatible'))
    chk("GPU compatible 含 arm,mali-valhall", lambda: 'arm,mali-valhall' in (d.s('/gpu@fb000000', 'compatible') or ''))
    chk("GPU clock-names 含 clk_mali", lambda: 'clk_mali' in (d.s('/gpu@fb000000', 'clock-names') or ''),
        lambda: d.s('/gpu@fb000000', 'clock-names'))
    chk("GPU 有 mali-supply", lambda: d.exists_prop('/gpu@fb000000', 'mali-supply'))
    chk("GPU okay", lambda: d.s('/gpu@fb000000', 'status') == 'okay')
    chk("NPU compatible=rk3588-rknpu", lambda: 'rockchip,rk3588-rknpu' in (d.s('/npu@fdab0000', 'compatible') or ''),
        lambda: d.s('/npu@fdab0000', 'compatible'))
    chk("NPU okay", lambda: d.s('/npu@fdab0000', 'status') == 'okay')
    chk("NPU interrupt-names 含 npu0_irq", lambda: 'npu0_irq' in (d.s('/npu@fdab0000', 'interrupt-names') or ''))
    for n in ('/npu@fdac0000', '/npu@fdad0000'):
        chk(f"{n} disabled（三核合一）", (lambda n=n: d.s(n, 'status') == 'disabled'), lambda n=n: d.s(n, 'status') or '(缺)')
    for n, want in (('/rga@fdb60000', 'rga3_core0'), ('/rga@fdb70000', 'rga3_core1'), ('/rga@fdb80000', 'rga2_core0')):
        chk(f"{n} = {want}", (lambda n=n, w=want: w in (d.s(n, 'compatible') or '')), lambda n=n: d.s(n, 'compatible'))
        chk(f"{n} okay", (lambda n=n: d.s(n, 'status') == 'okay'), lambda n=n: d.s(n, 'status') or '(缺)')
    chk("rkvdec0 compatible=rkv-decoder-v2（MPP）",
        lambda: 'rockchip,rkv-decoder-v2' in (d.s('/video-codec@fdc38000', 'compatible') or ''),
        lambda: d.s('/video-codec@fdc38000', 'compatible'))
    chk("rkvdec0 有 rockchip,srv", lambda: d.exists_prop('/video-codec@fdc38000', 'rockchip,srv'))
    chk("rkvdec0 有 rockchip,taskqueue-node", lambda: d.exists_prop('/video-codec@fdc38000', 'rockchip,taskqueue-node'))

    # ── iommu 命名 ──
    txt = d.raw
    chk("rk3588-iommu 出现 ≥10 次", lambda: txt.count(b'rockchip,rk3588-iommu') >= 10,
        lambda: txt.count(b'rockchip,rk3588-iommu'))
    chk("rockchip,iommu-v2 残留 0 次", lambda: txt.count(b'rockchip,iommu-v2') == 0,
        lambda: txt.count(b'rockchip,iommu-v2'))
    # 编码链：逐节点照官方 T6 DTB（2026-10-27 从 refs/t6-official.dtb 原文核对）
    chk("vepu@fdb50000 = vpu-encoder-v2 且 disabled（官方 T6 就是关的）",
        lambda: 'rockchip,vpu-encoder-v2' in (d.s('/vepu@fdb50000', 'compatible') or '')
        and d.s('/vepu@fdb50000', 'status') == 'disabled',
        lambda: f"{d.s('/vepu@fdb50000', 'compatible')} / {d.s('/vepu@fdb50000', 'status')}")
    chk("vdpu@fdb50400 = vpu-decoder-v2 且 okay",
        lambda: 'rockchip,vpu-decoder-v2' in (d.s('/vdpu@fdb50400', 'compatible') or '')
        and d.s('/vdpu@fdb50400', 'status') == 'okay',
        lambda: f"{d.s('/vdpu@fdb50400', 'compatible')} / {d.s('/vdpu@fdb50400', 'status')}")
    for n in ('/rkvenc-core@fdbd0000', '/rkvenc-core@fdbe0000'):
        chk(f"{n} = rkv-encoder-v2-core 且 okay",
            (lambda n=n: 'rockchip,rkv-encoder-v2-core' in (d.s(n, 'compatible') or '')
             and d.s(n, 'status') == 'okay'),
            lambda n=n: f"{d.s(n, 'compatible')} / {d.s(n, 'status')}")
        chk(f"{n} 有 venc-supply（缺它报 no regulator (venc) found）",
            (lambda n=n: d.exists_prop(n, 'venc-supply')))
        chk(f"{n} 有 operating-points-v2",
            (lambda n=n: d.exists_prop(n, 'operating-points-v2')))
    for n in ('/iommu@fdbdf000', '/iommu@fdbef000'):
        chk(f"{n} okay", (lambda n=n: d.s(n, 'status') == 'okay'), lambda n=n: d.s(n, 'status') or '(缺)')
    chk("有 venc-opp-table", lambda: 'operating-points-v2' in (d.s('/venc-opp-table', 'compatible') or ''))
    chk("有 rkvenc-ccu", lambda: 'rkv-encoder-v2-ccu' in (d.s('/rkvenc-ccu', 'compatible') or ''))

    # opp-microvolt 必须是 6 值（2 个 supply × min/target/max）；3 值会让
    # _parse_named_prop 报 "Invalid number of elements in microvolt property (3) with supplies (2)"
    # → _of_add_opp_table_v2: Failed to add OPP, -22 → devfreq 不建。
    def _mv6(path):
        v = d.nodes.get(path, {}).get('opp-microvolt')
        return v is not None and len(v) == 24

    chk("GPU opp microvolt 6 值（mali+mem supply）", lambda: _mv6('/gpu-opp-table-h88k/opp-1000000000'))
    chk("venc opp microvolt 6 值（venc+mem supply）", lambda: _mv6('/venc-opp-table/opp-800000000'))
    chk("NPU opp microvolt 6 值（rknpu+mem supply）", lambda: _mv6('/npu-opp-table/opp-300000000'))

    # ── eMMC / SD / 串口 / 其它外设 ──
    for n in ('/mmc@fe2e0000', '/mmc@fe2c0000'):
        chk(f"{n} okay", (lambda n=n: d.s(n, 'status') == 'okay'), lambda n=n: d.s(n, 'status') or '(缺)')
    chk("eMMC bus-width 已定义", lambda: d.i('/mmc@fe2e0000', 'bus-width') is not None)
    chk("/aliases 有 mmc0", lambda: d.s('/aliases', 'mmc0') is not None, lambda: d.s('/aliases', 'mmc0'))
    chk("/aliases 有 mmc1", lambda: d.s('/aliases', 'mmc1') is not None, lambda: d.s('/aliases', 'mmc1'))
    chk("stdout-path 走 serial2", lambda: 'serial2' in (d.s('/chosen', 'stdout-path') or ''),
        lambda: d.s('/chosen', 'stdout-path'))
    chk("有 sata 节点", lambda: any('sata@' in p for p in d.nodes))
    chk("有 pwm-fan 节点", lambda: any('pwm-fan' in p for p in d.nodes))
    chk("有 hym8563（RTC）", lambda: b'hym8563' in txt)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    d = Dtb(sys.argv[1])
    build(d)
    bad = 0
    for desc, fn, actual in CHECKS:
        try:
            ok = bool(fn())
        except Exception as e:                                  # noqa: BLE001
            ok, desc = False, desc + f'（断言异常: {e}）'
        if ok:
            print(f"  ✓ {desc}")
        else:
            bad += 1
            try:
                shown = actual()
            except Exception:                                   # noqa: BLE001
                shown = '?'
            print(f"  ✗ {desc}   实际: {shown}")
    print()
    print(f"共 {len(CHECKS)} 条断言，失败 {bad} 条")
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
