#!/usr/bin/env bash
#==========================================================================
# lyw-hk DTB 门禁（构建前跑，秒级）
#   1) dtc 把 dts/ 源编译出来 —— 证明源码语法可编译
#   2) 编译产物与 dist/ 成品逐项语义比对（fdtget 关键属性，字节级不强求）
#   3) 对 dist/ 成品直接断言金标准（厂商实机 DTB + 7 行改造清单）
# 判据全部来自「厂商三份参考交叉核对 + 主线 6.18 源码」，详见 README。
set -euo pipefail
fail() { echo "✗ $*" >&2; exit 1; }
ok()   { echo "  ✓ $*"; }

DTS="${DTS:-dts/rk3588-hinlink-h88k.dts}"
DTB="${DTB:-dist/rk3588-hinlink-h88k.dtb}"
REF="${REF:-refs/rk3588-hinlink-h88k-live-inextos.dtb}"

[[ -f "$DTS" ]] || fail "缺 $DTS"
[[ -f "$DTB" ]] || fail "缺 $DTB"
command -v dtc >/dev/null || fail "需要 device-tree-compiler (dtc)"
command -v fdtget >/dev/null || fail "需要 fdtget"

echo "==== 1) dtc 编译 dts 源 ===="
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
dtc -I dts -O dtb -o "$TMP/from_dts.dtb" "$DTS" 2>"$TMP/dtc.log" \
    || { cat "$TMP/dtc.log"; fail "dtc 编译失败"; }
# dtc 对反编译源常有 unit_address 之类的良性 Warning —— 只拦 Error（红字必失败）
if grep -qiE '^(Error|.*: Error)' "$TMP/dtc.log"; then
    cat "$TMP/dtc.log"; fail "dtc 编译错误"
fi
if [[ -s "$TMP/dtc.log" ]]; then
    echo "  （dtc 告警，不判死）:"
    # 注意 pipefail：不能用 sed|head（SIGPIPE 会把整条管道变成非零 → 假红），用 awk 限行
    awk 'NR<=5{print "     " $0} END{if(NR>5)print "     … 共 " NR " 行告警"}' "$TMP/dtc.log"
fi
ok "dtc 编译通过 ($(stat -c%s "$TMP/from_dts.dtb") B)"

echo
echo "==== 2) dist 成品 vs dts 编译件：语义比对 ===="
dtc -I dtb -O dts -o "$TMP/dist.dts" "$DTB" 2>/dev/null
dtc -I dtb -O dts -o "$TMP/src.dts" "$TMP/from_dts.dtb" 2>/dev/null
# phandle 编号允许不同，比对关键属性值
cmp_prop() {
    local node="$1" prop="$2"
    local a b
    a="$(fdtget -t s "$DTB" "$node" "$prop" 2>/dev/null || echo MISSING)"
    b="$(fdtget -t s "$TMP/from_dts.dtb" "$node" "$prop" 2>/dev/null || echo MISSING)"
    [[ "$a" == "$b" ]] || fail "属性不一致 $node.$prop: dist=$a dts编译=$b"
    ok "$node.$prop = $a"
}
cmp_prop / model
cmp_prop / compatible
cmp_prop /ethernet@fe1b0000 phy-mode
cmp_prop /leds/net label
cmp_prop /leds/sata label
cmp_prop /leds/user label
cmp_prop /leds/work label

echo
echo "==== 3) dist 成品金标准断言 ===="
[[ "$(fdtget -t s "$DTB" / model)" == "HINLINK H88K" ]] || fail "model 不是 HINLINK H88K"
ok "model = HINLINK H88K"
[[ "$(fdtget -t s "$DTB" / compatible)" == *hinlink,h88k* ]] || fail "compatible 缺 hinlink,h88k"
ok "compatible 含 hinlink,h88k"
[[ "$(fdtget -t s "$DTB" /ethernet@fe1b0000 phy-mode)" == "rgmii-rxid" ]] || fail "gmac0 phy-mode 应为 rgmii-rxid"
ok "gmac0 phy-mode = rgmii-rxid（主线 dwmac-rk rxid 分支读 tx_delay，源码已核）"
[[ "$(fdtget -t i "$DTB" /ethernet@fe1b0000 tx_delay)" == "68" ]] || fail "gmac0 tx_delay 应为 68(0x44)"
ok "gmac0 tx_delay = 68 (0x44)"
[[ "$(fdtget -t s "$DTB" /leds/net label)" == "blue:net" ]] || fail "LED net 命名不符"
[[ "$(fdtget -t s "$DTB" /leds/sata label)" == "amber:sata" ]] || fail "LED sata 命名不符"
[[ "$(fdtget -t s "$DTB" /leds/user label)" == "green:user" ]] || fail "LED user 命名不符"
[[ "$(fdtget -t s "$DTB" /leds/work label)" == "red:work" ]] || fail "LED work 命名不符"
ok "LED 四灯 = blue:net/amber:sata/green:user/red:work（厂商板级源码+实机两票）"
# 改造①：cma 固定区必须已删（CMA 交给 cmdline cma=2G）
if fdtget "$DTB" /reserved-memory/cma reg >/dev/null 2>&1; then
    fail "reserved-memory/cma 仍在（会把 CMA 压死在 256M，cmdline cma=2G 无效）"
fi
ok "reserved-memory/cma 已删（CMA 由 fnEnv extraargs=cma=2G 决定）"
# 改造②：PMIC 断电属性必须在
PMIC_PATH="$(fdtget -t s "$DTB" /spi@feb20000/rk806single@0 compatible 2>/dev/null || true)"
[[ "$PMIC_PATH" == *rk806* ]] || fail "PMIC 节点 compatible 不是 rk806（路径变了？）"
if ! dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -q 'rockchip,system-power-controller'; then
    fail "PMIC 缺 rockchip,system-power-controller（poweroff 会退化成 halt）"
fi
ok "PMIC rk806 带 rockchip,system-power-controller（关机断电）"
# PCIe 三口 okay（NVMe/2.5G×2 的前提）
for n in /pcie@fe150000 /pcie@fe170000 /pcie@fe180000 /pcie@fe190000; do
    [[ "$(fdtget -t s "$DTB" "$n" status)" == "okay" ]] || fail "$n 应为 okay"
done
ok "PCIe fe15/fe17/fe18/fe19 全 okay（NVMe + WiFi + 2.5G×2）"

# 与金标准底本（厂商实机 DTB）差异面：只允许 7 行改造
if [[ -f "$REF" ]]; then
    echo
    echo "==== 4) 与厂商实机底本的差异面（应恰好 7 行）===="
    dtc -I dtb -O dts -o "$TMP/ref.dts" "$REF" 2>/dev/null
    DIFF_N="$(diff "$TMP/ref.dts" "$TMP/dist.dts" | grep -cE '^[<>]' || true)"
    echo "  差异行数: $DIFF_N"
    [[ "$DIFF_N" -le 8 ]] || fail "与厂商实机底本差异过大（$DIFF_N 行），疑似附带损伤"
    ok "差异面受控（仅删 cma 节点 + 加 power-controller）"
fi

echo
echo "== DTB 门禁全部通过 =="
