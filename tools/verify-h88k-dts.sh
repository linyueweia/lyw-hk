#!/usr/bin/env bash
#==========================================================================
# H88K DTB 完整性门禁（对齐 xck-nas 的 verify-t68m-* 规格）
#
# 用法： bash tools/verify-h88k-dts.sh <dtb> [更多 dtb ...]
#        默认验 dist/rk3588-hlink-h88k.dtb
# 设计：可以一次传多份（现编产物 / dist 拷贝 / 镜像里实际使用的那份），
#       防止"改了源但镜像用的还是旧 DTB"（xck-nas 踩过：uboot 拷贝陈旧没人管）。
#
# 判据来源（全部来自官方材料，2026-10-26）：
#   · 板级：飞牛内核树 rk3588-hlink.dtsi + 厂商三镜像交叉核对
#     （LED blue:net/amber:sata/green:user/red:work、gmac0 rgmii-rxid + tx_delay=0x44、
#       PMIC rk806、stdout serial2:1500000n8）
#   · SoC 级：官方内核 vmlinuz-6.18.18.c1145-trim 的 of_match —— iommu 必须
#     rockchip,rk3588-iommu（iommu-v2 在官方内核里 0 处）
#==========================================================================
set -euo pipefail
fail() { echo "✗ $*" >&2; exit 1; }
ok()   { echo "  ✓ $*"; }

command -v dtc    >/dev/null || fail "需要 device-tree-compiler (dtc)"
command -v fdtget >/dev/null || fail "需要 fdtget"

DTBS=("${@:-}")
[[ -z "${DTBS[0]:-}" ]] && DTBS=("dist/rk3588-hlink-h88k.dtb")

for DTB in "${DTBS[@]}"; do
    [[ -f "$DTB" ]] || fail "找不到 $DTB"
    echo
    echo "==================== $DTB ($(stat -c%s "$DTB") B) ===================="
    TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
    dtc -I dtb -O dts -o "$TMP" "$DTB" 2>/dev/null || fail "dtc 反编译失败: $DTB"

    echo "-- 1) 板级身份 --"
    MODEL="$(fdtget -t s "$DTB" / model 2>/dev/null || true)"
    case "$MODEL" in "Hlink H88K"|"HINLINK H88K") ok "model = $MODEL";; *) fail "model 异常: '$MODEL'";; esac
    COMPAT="$(fdtget -t s "$DTB" / compatible 2>/dev/null || true)"
    [[ "$COMPAT" == *h88k* ]] || fail "compatible 缺 h88k: $COMPAT"
    [[ "$COMPAT" == *rockchip,rk3588* ]] || fail "compatible 缺 rockchip,rk3588"
    ok "compatible = $COMPAT"
    SP="$(fdtget -t s "$DTB" /chosen stdout-path 2>/dev/null || true)"
    [[ "$SP" == "serial2:1500000n8" ]] || fail "stdout-path 应为 serial2:1500000n8，实际 '$SP'"
    ok "stdout-path = serial2:1500000n8（串口 ttyS2 @1.5M）"

    echo "-- 2) 板载存储（eMMC / SD）--"
    # RK3588: sdhci=eMMC@fe2e0000、sdmmc=SD@fe2c0000、sdio=SDIO@fe2d0000（H88K 无 SDIO 设备，保持 disabled）
    for n in /mmc@fe2e0000 /mmc@fe2c0000; do
        [[ "$(fdtget -t s "$DTB" "$n" status 2>/dev/null)" == "okay" ]] || fail "$n 应为 okay（eMMC/SD）"
    done
    ok "eMMC(fe2e0000) + SD(fe2c0000) 均 okay"
    fdtget -t i "$DTB" /mmc@fe2e0000 bus-width >/dev/null 2>&1 && ok "eMMC bus-width 已定义"
    ALIAS0="$(fdtget -t s "$DTB" /aliases mmc0 2>/dev/null || true)"
    ALIAS1="$(fdtget -t s "$DTB" /aliases mmc1 2>/dev/null || true)"
    echo "     aliases: mmc0=$ALIAS0  mmc1=$ALIAS1（树内定义 mmc0=SD、mmc1=eMMC）"

    echo "-- 3) 网口时序（厂商三镜像一致值）--"
    [[ "$(fdtget -t s "$DTB" /ethernet@fe1b0000 phy-mode 2>/dev/null)" == "rgmii-rxid" ]] \
        || fail "gmac0 phy-mode 应为 rgmii-rxid"
    [[ "$(fdtget -t i "$DTB" /ethernet@fe1b0000 tx_delay 2>/dev/null)" == "68" ]] \
        || fail "gmac0 tx_delay 应为 68(0x44)"
    for p in snps,reset-gpio snps,reset-active-low snps,reset-delays-us; do
        fdtget "$DTB" /ethernet@fe1b0000 "$p" >/dev/null 2>&1 || fail "gmac0 缺 $p（复位归属必须在 MAC 侧）"
    done
    ok "gmac0 rgmii-rxid + tx_delay=0x44 + MAC 侧复位三件套"

    echo "-- 4) LED 四灯 --"
    [[ "$(fdtget -t s "$DTB" /gpio-leds/net  label 2>/dev/null)" == "blue:net"   ]] || fail "LED net 命名不符"
    [[ "$(fdtget -t s "$DTB" /gpio-leds/sata label 2>/dev/null)" == "amber:sata" ]] || fail "LED sata 命名不符"
    [[ "$(fdtget -t s "$DTB" /gpio-leds/user label 2>/dev/null)" == "green:user" ]] || fail "LED user 命名不符"
    [[ "$(fdtget -t s "$DTB" /gpio-leds/work label 2>/dev/null)" == "red:work"   ]] || fail "LED work 命名不符"
    ok "LED = blue:net / amber:sata / green:user / red:work"

    echo "-- 5) PMIC (rk806) 与断电属性 --"
    PMIC="$(fdtget -t s "$DTB" /spi@feb20000/pmic@0 compatible 2>/dev/null || true)"
    [[ "$PMIC" == *rk806* ]] || fail "PMIC 节点 compatible 不是 rk806（实际 '$PMIC'）"
    grep -q 'rockchip,system-power-controller' "$TMP" || fail "PMIC 缺 rockchip,system-power-controller（poweroff 只 halt）"
    CNT_REG="$(grep -c 'regulator-name' "$TMP" || true)"
    [[ "${CNT_REG:-0}" -ge 8 ]] || fail "PMIC 稳压器数量异常（regulator-name 仅 ${CNT_REG:-0} 个）"
    ok "PMIC rk806 + 断电属性 + $CNT_REG 路稳压器"

    echo "-- 6) IOMMU 命名必须与官方内核一致（本仓核心判据）--"
    N_NEW="$(grep -c 'compatible = "rockchip,rk3588-iommu"' "$TMP" || true)"
    N_OLD="$(grep -c 'rockchip,iommu-v2' "$TMP" || true)"
    [[ "${N_NEW:-0}" -ge 10 ]] || fail "iommu 命名不是官方内核认的 rockchip,rk3588-iommu（仅 ${N_NEW:-0} 处）"
    [[ "${N_OLD:-0}" -eq 0 ]] || fail "DTB 仍有 rockchip,iommu-v2（${N_OLD} 处）—— 官方内核 of_match 里 0 处"
    ok "rk3588-iommu ×$N_NEW，iommu-v2 残留 0"

    echo "-- 7) PCIe / PHY（NVMe + 双 2.5G 的前提）--"
    for n in /pcie@fe150000 /pcie@fe160000 /pcie@fe170000 /pcie@fe180000 /pcie@fe190000; do
        st="$(fdtget -t s "$DTB" "$n" status 2>/dev/null || true)"
        [[ "$st" == "okay" ]] || fail "$n 应为 okay（实际 '${st:-缺失}'）"
    done
    ok "PCIe fe15/fe16/fe17/fe18/fe19 全 okay"

    echo "-- 8) 板载 SATA / 其它外设 --"
    grep -q 'sata@' "$TMP" || fail "缺 SATA 节点"
    grep -q 'pwm-fan' "$TMP" || fail "缺风扇节点（pwm-fan）"
    grep -q 'hym8563' "$TMP" || fail "缺 RTC 节点（hym8563）"
    ok "SATA / 风扇 / RTC 节点齐全"

    echo "-- 9) 改造项与残留检查 --"
    if fdtget "$DTB" /reserved-memory/cma reg >/dev/null 2>&1; then
        fail "reserved-memory/cma 固定区仍在（会把 CMA 压死在 256M，cmdline cma=2G 无效）"
    fi
    ok "无 cma 固定区（CMA 由 cmdline cma=2G 决定）"
    for bad in "rockchip,iommu-v2" "rockchip,mipi-dcphy" "rockchip,rk3588-hdmirx-ctrler"; do
        if grep -q "$bad" "$TMP"; then
            echo "  ⚠ 保留 $bad（官方内核无对应驱动，节点保留无害，仅提示）"
        fi
    done
    ok "无致命残留"
done

echo
echo "==== H88K DTB 门禁全部通过（${#DTBS[@]} 份）===="
