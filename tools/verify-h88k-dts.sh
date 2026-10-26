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
# ERR trap：set -e 静默退出时至少告诉我们死在哪一行（踩过：grep 无匹配 + pipefail → 无声 exit 1）
trap 'echo "  ✗ 命令失败退出 @行 $LINENO（set -e / pipefail）" >&2' ERR
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

    # 内存：不写 /memory 节点，与官方 T6 DT 完全一致；内存由 u-boot 注入
    # （实测本板 u-boot 注入 0x00200000+0xefe00000 / 0x1_00000000+0x1_00000000 /
    #   0x2_f0000000+0x10000000，MemTotal 8123084 kB）
    if grep -q 'device_type = "memory"' "$TMP"; then
        fail "DTB 不应自带 /memory 节点（官方 T6 也没有，由 u-boot 注入）"
    fi
    ok "无 /memory 节点（与 T6 一致，内存由 u-boot 注入）"

    # 多媒体：GPU/VOP/HDMI 必须启用（官方 T6 DTB 同为 okay；关掉会无 /dev/dri、HDMI 全黑、vdd_gpu 断电）
    for n in /gpu@fb000000 /vop@fdd90000 /hdmi@fde80000; do
        st="$(fdtget -t s "$DTB" "$n" status 2>/dev/null || true)"
        [[ "$st" == "okay" ]] || fail "$n 应为 okay（官方 T6 是 okay；实际 '${st:-缺失}'）"
    done
    ok "GPU(gpu@fb000000) + VOP(vop@fdd90000) + HDMI(hdmi@fde80000) 均 okay"

    # gmac 节点不能带 label：stmmac 会用 label 当网卡名，和 r8169 的 ethN 撞名 → probe -17 直接放弃
    # （实测：带 label="eth0" 时千兆口整个不出现，DHCP 地址跟着漂）
    LBL="$(fdtget -t s "$DTB" /ethernet@fe1b0000 label 2>/dev/null || true)"
    [[ -z "$LBL" ]] || fail "/ethernet@fe1b0000 不能有 label（现为 '$LBL'）—— stmmac 会撞名报 -17"
    ok "gmac 无 label（避免 stmmac 与 r8169 撞网卡名）"

    # 加速器必须按【飞牛内核树外驱动】的 of_match 命名（2026-10-27 实机定案，旧口径已推翻）：
    #   GPU  rockchip,rk3588-mali-csf + arm,mali-valhall + clock-names clk_mali  (rkgpu_bifrost_csf.ko)
    #   NPU  rockchip,rk3588-rknpu（三核合一）                                   (rknpu.ko)
    #   VPU  顶层 /mpp-srv = rockchip,mpp-service                                (rk_vcodec.ko)
    #   RGA  rockchip,rga3_core0 / rga3_core1 / rga2_core0                       (rga3.ko)
    # 旧口径「NPU/RGA 一律 disabled」源自 refs/t6-official.dtb 被换成了主线树编的 DTB；
    # 真件（官方 T6 镜像 p1，sha256 09425cc7…）里 NPU okay、有 mpp-srv、rga3 全开。
    MV="$(fdtget -t s "$DTB" /mpp-srv compatible 2>/dev/null || true)"
    [[ "$MV" == *rockchip,mpp-service* ]] || fail "缺顶层 /mpp-srv（rockchip,mpp-service）—— /dev/mpp_service 不会出现"
    [[ "$(fdtget -t s "$DTB" /mpp-srv status 2>/dev/null || echo okay)" == "okay" ]] || fail "/mpp-srv 应为 okay"
    ok "mpp-srv = rockchip,mpp-service（okay）"

    GCOMP="$(fdtget -t s "$DTB" /gpu@fb000000 compatible 2>/dev/null || true)"
    [[ "$GCOMP" == *rockchip,rk3588-mali-csf* ]] || fail "GPU compatible 应为 rockchip,rk3588-mali-csf（BSP kbase），实际 '$GCOMP'"
    [[ "$GCOMP" == *arm,mali-valhall* ]] || fail "GPU compatible 缺 arm,mali-valhall，实际 '$GCOMP'"
    GCLK="$(fdtget -t s "$DTB" /gpu@fb000000 clock-names 2>/dev/null | tr '\n' ' ' || true)"
    [[ "$GCLK" == *clk_mali* ]] || fail "GPU clock-names 缺 clk_mali（BSP kbase 按名取时钟），实际 '$GCLK'"
    [[ "$(fdtget -t s "$DTB" /gpu@fb000000 status 2>/dev/null)" == "okay" ]] || fail "/gpu@fb000000 应为 okay"
    fdtget "$DTB" /gpu@fb000000 mali-supply >/dev/null 2>&1 || fail "GPU 缺 mali-supply（kbase probe 需要）"
    ok "GPU = rockchip,rk3588-mali-csf + arm,mali-valhall（clk_mali / mali-supply 齐）"

    NCOMP="$(fdtget -t s "$DTB" /npu@fdab0000 compatible 2>/dev/null || true)"
    [[ "$NCOMP" == *rockchip,rk3588-rknpu* ]] || fail "NPU compatible 应为 rockchip,rk3588-rknpu，实际 '$NCOMP'"
    [[ "$(fdtget -t s "$DTB" /npu@fdab0000 status 2>/dev/null)" == "okay" ]] || fail "/npu@fdab0000 应为 okay"
    NIRQ="$(fdtget -t s "$DTB" /npu@fdab0000 interrupt-names 2>/dev/null | tr '\n' ' ' || true)"
    [[ "$NIRQ" == *npu0_irq* ]] || fail "NPU interrupt-names 缺 npu0_irq，实际 '$NIRQ'"
    for n in /npu@fdac0000 /npu@fdad0000; do
        [[ "$(fdtget -t s "$DTB" "$n" status 2>/dev/null || true)" == "disabled" ]] \
            || fail "$n 应保持 disabled（BSP 驱动把三核当一个设备）"
    done
    ok "NPU = rockchip,rk3588-rknpu（三核合一，npu0_irq 就位）"

    for pair in "/rga@fdb60000:rockchip,rga3_core0" "/rga@fdb70000:rockchip,rga3_core1" "/rga@fdb80000:rockchip,rga2_core0"; do
        n="${pair%%:*}"; want="${pair#*:}"
        got="$(fdtget -t s "$DTB" "$n" compatible 2>/dev/null || true)"
        [[ "$got" == *"$want"* ]] || fail "$n compatible 应为 $want，实际 '$got'"
        [[ "$(fdtget -t s "$DTB" "$n" status 2>/dev/null)" == "okay" ]] || fail "$n 应为 okay"
    done
    ok "RGA = rga3_core0 / rga3_core1 / rga2_core0（均 okay）"

    # 解码核必须按 MPP 新 BSP 命名（rk_vcodec.ko 只认 rkv-decoder-v2，不认 rk3588-vdec）
    VDCOMP="$(fdtget -t s "$DTB" /video-codec@fdc38000 compatible 2>/dev/null || true)"
    [[ "$VDCOMP" == *rockchip,rkv-decoder-v2* ]] || fail "/video-codec@fdc38000 compatible 应为 rockchip,rkv-decoder-v2（MPP），实际 '$VDCOMP'"
    [[ "$(fdtget -t s "$DTB" /video-codec@fdc38000 status 2>/dev/null || echo okay)" == "okay" ]] || fail "/video-codec@fdc38000 应为 okay（硬件解码核）"
    fdtget "$DTB" /video-codec@fdc38000 rockchip,srv >/dev/null 2>&1 || fail "rkvdec0 缺 rockchip,srv（MPP 挂不到 mpp-srv）"
    fdtget "$DTB" /video-codec@fdc38000 rockchip,taskqueue-node >/dev/null 2>&1 || fail "rkvdec0 缺 rockchip,taskqueue-node"
    ok "VPU 解码核 = rockchip,rkv-decoder-v2（rockchip,srv + taskqueue-node 齐）"

    # 编解码核（物理块命名沿用内核树，MPP 经 mpp-srv 汇总）
    # 编解码核：MPP 新 BSP 命名（2026-10-27 实机编解码全通；老 rk3588-vpu121/vepu121 不被驱动识别）
    N_VENC2="$( { grep -o 'rockchip,vpu-encoder-v2' "$TMP" || true; } | wc -l | tr -d ' ')"
    N_RKVENC="$( { grep -o 'rockchip,rkv-encoder-v2-core' "$TMP" || true; } | wc -l | tr -d ' ')"
    N_RKVDEC="$( { grep -o 'rockchip,rkv-decoder-v2' "$TMP" || true; } | wc -l | tr -d ' ')"
    [[ "${N_RKVDEC:-0}" -ge 1 ]] || fail "缺 rkv-decoder-v2 解码核"
    [[ "${N_VENC2:-0}" -ge 1 ]] || fail "缺 vpu-encoder-v2 编码核（VEPU）"
    [[ "${N_RKVENC:-0}" -ge 1 ]] || fail "缺 rkv-encoder-v2-core 编码核（RKVENC）"
    fdtget "$DTB" /venc-opp-table compatible >/dev/null 2>&1 || fail "缺 venc-opp-table（rkvenc devfreq/opp 依赖）"
    fdtget "$DTB" /rkvenc-ccu compatible >/dev/null 2>&1 || fail "缺 rkvenc-ccu（且必须定义在 rkvenc-core 之前，否则 attach ccu failed）"
    ok "编解码核：rkvdec ×$N_RKVDEC / vpu-encoder-v2 ×$N_VENC2 / rkv-encoder-v2-core ×$N_RKVENC（+ venc opp/ccu）"

    echo "-- 6) IOMMU 命名必须与官方内核一致（本仓核心判据）--"
    # 注意：树里是双值写法 compatible = "rockchip,rk3588-iommu", "rockchip,rk3568-iommu";
    # 所以按"字符串出现次数"计数，不绑定属性行格式（踩过：带前缀的 grep 会假 0）
    # 诊断先行（避免 grep 无匹配时 pipefail+set -e 静默退出，踩过）
    echo "  DTB 里的 iommu 节点（最多 8 条）:"
    grep -n 'iommu@' "$TMP" 2>/dev/null | head -8 | sed 's/^/    /' || echo "    （无 iommu@ 节点）"
    echo "  含 iommu 的 compatible 行（最多 8 条）:"
    grep -n 'compatible' "$TMP" 2>/dev/null | grep -i 'iommu' | head -8 | sed 's/^/    /' || echo "    （无）"
    N_NEW="$( (grep -o 'rockchip,rk3588-iommu' "$TMP" || true) | wc -l | tr -d ' ')"
    N_OLD="$( (grep -o 'rockchip,iommu-v2' "$TMP" || true) | wc -l | tr -d ' ')"
    echo "  计数: rk3588-iommu=$N_NEW  iommu-v2=$N_OLD"
    [[ "${N_NEW:-0}" -ge 10 ]] || fail "iommu 命名不是官方内核认的 rockchip,rk3588-iommu（仅 ${N_NEW:-0} 处）"
    [[ "${N_OLD:-0}" -eq 0 ]] || fail "DTB 仍有 rockchip,iommu-v2（${N_OLD:-0} 处）—— 官方内核 of_match 里 0 处"
    ok "rk3588-iommu ×$N_NEW，iommu-v2 残留 0"

    echo "-- 7) PCIe / PHY（NVMe + 双 2.5G 的前提）--"
    # 本板实际启用（判据＝本板 iNextOS 实跑 DTB，不是推断）：
    #   fe150000 pcie3x4 → NVMe        fe170000 pcie2x1l0 → M.2
    #   fe180000 pcie2x1l1 → RTL8125 #1(gpio4_2 复位)
    #   fe190000 pcie2x1l2 → RTL8125 #2(gpio4_5 复位，PCI 域 0004:41，phy=combphy0_ps)
    #   fe160000 pcie3x2 本板无 → 保持 disabled
    for n in /pcie@fe150000 /pcie@fe170000 /pcie@fe180000 /pcie@fe190000; do
        st="$(fdtget -t s "$DTB" "$n" status 2>/dev/null || true)"
        [[ "$st" == "okay" ]] || fail "$n 应为 okay（实际 '${st:-缺失}'）—— 少一个就丢一个网口/NVMe"
    done
    ok "PCIe fe150000 + fe170000 + fe180000 + fe190000 全 okay（NVMe + M.2 + 双 2.5G）"
    for ph in /phy@fee00000 /phy@fee10000 /phy@fee20000; do
        st="$(fdtget -t s "$DTB" "$ph" status 2>/dev/null || true)"
        [[ "$st" == "okay" ]] || fail "$ph 应为 okay（combphy0_ps/1_ps/2_psu）"
    done
    ok "combphy0_ps / combphy1_ps / combphy2_psu 全 okay"
    # 第二块 RTL8125 的复位脚必须在，否则链路起不来（物理口有、驱动认不到）
    RG="$(fdtget -t x "$DTB" /pcie@fe190000 reset-gpios 2>/dev/null || true)"
    [[ -n "$RG" ]] || fail "/pcie@fe190000 缺 reset-gpios（第二块 RTL8125 不会上电复位）"

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
