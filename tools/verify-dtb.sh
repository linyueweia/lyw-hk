#!/usr/bin/env bash
#==========================================================================
# H88K DTB 门禁（对【飞牛内核树编译出来】的成品断言）
#
# 判据来源（2026-10-26 定案）：
#   · 板级值（model / gmac / LED）来自厂商板级 DTS + 三份厂商镜像交叉核对；
#   · SoC 级命名必须与飞牛内核树一致：飞牛树 rk3588-base.dtsi 里
#     rockchip,rk3588-iommu ×14、rockchip,iommu-v2 ×0。用厂商 6.1 树编的
#     DTB 会写成 iommu-v2 → 内核不 probe，这就是"DTB 与内核不配套"的本体。
#   · 改造项：删 reserved-memory/cma（CMA 走 cmdline cma=2G）、
#     PMIC 加 rockchip,system-power-controller（poweroff 才真断电）。
#==========================================================================
set -euo pipefail
fail() { echo "✗ $*" >&2; exit 1; }
ok()   { echo "  ✓ $*"; }

DTB="${DTB:-dist/rk3588-hlink-h88k.dtb}"
[[ -f "$DTB" ]] || fail "缺 $DTB（先跑 bash build-dtb.sh 在飞牛内核树里编译）"
command -v dtc    >/dev/null || fail "需要 device-tree-compiler (dtc)"
command -v fdtget >/dev/null || fail "需要 fdtget (device-tree-compiler)"

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
dtc -I dtb -O dts -o "$TMP" "$DTB" 2>/dev/null || fail "dtc 反编译失败"
echo "  产物: $DTB ($(stat -c%s "$DTB") B)"

echo
echo "== 1) 板级身份 =="
MODEL="$(fdtget -t s "$DTB" / model 2>/dev/null)"
[[ "$MODEL" == "Hlink H88K" || "$MODEL" == "HINLINK H88K" ]] || fail "model 不是 Hlink H88K（实际 $MODEL）"
ok "model = $MODEL"
fdtget -t s "$DTB" / compatible 2>/dev/null | grep -qE 'hlink,h88k' || fail "compatible 缺 hlink,h88k"
ok "compatible 含 hlink,h88k"

echo
echo "== 2) 网口（厂商三镜像一致值）=="
[[ "$(fdtget -t s "$DTB" /ethernet@fe1b0000 phy-mode 2>/dev/null)" == "rgmii-rxid" ]] || fail "gmac0 phy-mode 应为 rgmii-rxid"
ok "gmac0 phy-mode = rgmii-rxid"
[[ "$(fdtget -t i "$DTB" /ethernet@fe1b0000 tx_delay 2>/dev/null)" == "68" ]] || fail "gmac0 tx_delay 应为 68(0x44)"
ok "gmac0 tx_delay = 0x44"

echo
echo "== 3) LED 四灯 =="
[[ "$(fdtget -t s "$DTB" /leds/net  label 2>/dev/null)" == "blue:net"   ]] || fail "LED net 命名不符"
[[ "$(fdtget -t s "$DTB" /leds/sata label 2>/dev/null)" == "amber:sata" ]] || fail "LED sata 命名不符"
[[ "$(fdtget -t s "$DTB" /leds/user label 2>/dev/null)" == "green:user" ]] || fail "LED user 命名不符"
[[ "$(fdtget -t s "$DTB" /leds/work label 2>/dev/null)" == "red:work"   ]] || fail "LED work 命名不符"
ok "LED = blue:net / amber:sata / green:user / red:work"

echo
echo "== 4) 改造①：cma 固定区已删 =="
if fdtget "$DTB" /reserved-memory/cma reg >/dev/null 2>&1; then
    fail "reserved-memory/cma 仍在（会把 CMA 压死在 256M，cmdline cma=2G 无效）"
fi
ok "reserved-memory/cma 已删（CMA 由 fnEnv/extraargs cma=2G 决定）"

echo
echo "== 5) 改造②：PMIC 断电属性 =="
grep -q 'rockchip,system-power-controller' "$TMP" || fail "PMIC 缺 rockchip,system-power-controller（poweroff 退化为 halt）"
ok "PMIC 带 rockchip,system-power-controller（关机真断电）"

echo
echo "== 6) SoC 级命名必须与飞牛内核树一致（本仓核心判据）=="
N_IOMMU="$(grep -c 'compatible = "rockchip,rk3588-iommu"' "$TMP" || true)"
N_V2="$(grep -c 'rockchip,iommu-v2' "$TMP" || true)"
echo "  rockchip,rk3588-iommu = ${N_IOMMU:-0} 处 / rockchip,iommu-v2 = ${N_V2:-0} 处"
[[ "${N_IOMMU:-0}" -ge 10 ]] || fail "iommu 命名不是飞牛树的 rockchip,rk3588-iommu（仅 ${N_IOMMU:-0} 处）—— DTB 不是在这棵树里编的？"
[[ "${N_V2:-0}" -eq 0 ]]     || fail "DTB 仍有厂商命名 rockchip,iommu-v2（${N_V2} 处）→ 与飞牛 6.18 内核不配套"
ok "IOMMU 命名与飞牛内核树一致（rk3588-iommu ×$N_IOMMU，无 iommu-v2 残留）"

echo
echo "== 7) PCIe 四控制器 =="
for n in /pcie@fe150000 /pcie@fe170000 /pcie@fe180000 /pcie@fe190000; do
    [[ "$(fdtget -t s "$DTB" "$n" status 2>/dev/null)" == "okay" ]] || fail "$n 应为 okay"
done
ok "PCIe fe15/fe17/fe18/fe19 全 okay（NVMe + WiFi + 2.5G×2）"

echo
echo "== DTB 门禁全部通过 =="
