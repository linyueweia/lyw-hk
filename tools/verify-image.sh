#!/usr/bin/env bash
#==========================================================================
# lyw-hk 镜像自证（装配完成后跑，硬门禁 —— 不过就不出产物）
#   用法: sudo bash tools/verify-image.sh out/fnos_Mainland-PE_arm_12_HINLINK-H88K.img
# 断言面 = 本仓库改动项（DTB / fnEnv / board.json / 引导链完整性 / 无串盘隐患）
set -euo pipefail
fail() { echo "✗ $*" >&2; exit 1; }
ok()   { echo "  ✓ $*"; }

IMG="${1:?用法: verify-image.sh <img>}"
[[ -f "$IMG" ]] || fail "镜像不存在: $IMG"
command -v dtc >/dev/null || fail "需要 device-tree-compiler"

PASS=0
TMP="$(mktemp -d)"
LOOP=""
cleanup() {
    mountpoint -q "$TMP/boot" 2>/dev/null && umount "$TMP/boot" 2>/dev/null || true
    mountpoint -q "$TMP/root" 2>/dev/null && umount "$TMP/root" 2>/dev/null || true
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "==== 镜像自证: $(basename "$IMG") ===="
LOOP="$(losetup -fP --show "$IMG")"
sleep 1
mkdir -p "$TMP/boot" "$TMP/root"
mount "${LOOP}p1" "$TMP/boot" || fail "挂载 BOOT 失败"
mount "${LOOP}p2" "$TMP/root" || fail "挂载 rootfs 失败"

echo
echo "── 1) DTB 在位且与仓库成品一致 ──"
F="$TMP/boot/dtb/rockchip/rk3588-hinlink-h88k.dtb"
[[ -f "$F" ]] || fail "镜像缺 dtb/rockchip/rk3588-hinlink-h88k.dtb"
EXP="$(sha256sum "${DTB:-dist/rk3588-hinlink-h88k.dtb}" 2>/dev/null | awk '{print $1}')"
GOT="$(sha256sum "$F" | awk '{print $1}')"
if [[ -n "$EXP" ]]; then
    [[ "$GOT" == "$EXP" ]] || fail "镜像内 DTB sha256 与仓库 dist 不符"
    ok "DTB sha256 = 仓库 dist 成品 (${GOT:0:16}…)"
else
    ok "DTB sha256 = ${GOT:0:16}…（仓库 dist 不在场，跳过比对）"
fi

echo
echo "── 2) DTB 关键属性（金标准）──"
dtc -I dtb -O dts -o "$TMP/in.dts" "$F" 2>/dev/null
[[ "$(fdtget -t s "$F" / model)" == "HINLINK H88K" ]] || fail "model 不符"
ok "model = HINLINK H88K"
[[ "$(fdtget -t s "$F" / compatible)" == *hinlink,h88k* ]] || fail "compatible 不符"
ok "compatible 含 hinlink,h88k"
[[ "$(fdtget -t s "$F" /ethernet@fe1b0000 phy-mode)" == "rgmii-rxid" ]] || fail "gmac0 phy-mode 不符"
[[ "$(fdtget -t i "$F" /ethernet@fe1b0000 tx_delay)" == "68" ]] || fail "gmac0 tx_delay 不符"
ok "gmac0 rgmii-rxid + tx_delay=68(0x44)"
for e in "net blue:net" "sata amber:sata" "user green:user" "work red:work"; do
    set -- $e
    [[ "$(fdtget -t s "$F" "/leds/$1" label)" == "$2" ]] || fail "LED $1 应为 $2"
done
ok "LED 四灯命名 = blue:net/amber:sata/green:user/red:work"
grep -q 'rockchip,system-power-controller' "$TMP/in.dts" || fail "PMIC 缺 system-power-controller"
ok "PMIC 带 rockchip,system-power-controller（关机断电）"
if fdtget "$F" /reserved-memory/cma reg >/dev/null 2>&1; then
    fail "镜像 DTB 仍带 reserved-memory/cma 固定区"
fi
ok "reserved-memory/cma 已删（CMA 交给 cmdline）"
for n in /pcie@fe150000 /pcie@fe170000 /pcie@fe180000 /pcie@fe190000; do
    [[ "$(fdtget -t s "$F" "$n" status)" == "okay" ]] || fail "$n 应 okay"
done
ok "PCIe 四控制器 okay（NVMe/WiFi/2.5G×2）"

echo
echo "── 3) fnEnv.txt（引导参数）──"
FNENV="$TMP/boot/fnEnv.txt"
[[ -f "$FNENV" ]] || fail "缺 fnEnv.txt"
sed 's/^/     /' "$FNENV"
grep -q '^fdtfile=rockchip/rk3588-hinlink-h88k.dtb$' "$FNENV" || fail "fnEnv fdtfile 不符"
ok "fdtfile=rockchip/rk3588-hinlink-h88k.dtb"
grep -q '^extraargs=.*cma=2G' "$FNENV" || fail "fnEnv extraargs 缺 cma=2G"
ok "extraargs 含 cma=2G"
if grep -q '^extraargs=.*cma=256M' "$FNENV"; then
    fail "fnEnv 仍残留 cma=256M"
fi

echo
echo "── 4) 引导链完整性 ──"
[[ -f "$TMP/boot/boot.scr" ]] || fail "缺 boot.scr"
ok "boot.scr 在位"
[[ -f "$TMP/boot/vmlinuz" || -n "$(ls "$TMP/boot"/vmlinuz-* 2>/dev/null)" ]] || fail "缺内核"
ok "内核在位"
if [[ -f "$TMP/boot/extlinux/extlinux.conf" ]]; then
    fail "extlinux.conf 未停用（u-boot 会优先拾取 → 静态 root= 串盘）"
fi
ok "无活动 extlinux.conf"

echo
echo "── 5) board.json ──"
BJ="$TMP/root/board.json"
if [[ -f "$BJ" ]]; then
    sed 's/^/     /' "$BJ"
    grep -q 'hinlink,h88k' "$BJ" || fail "board.json 未指向 hinlink,h88k"
    ok "board.json = hinlink,h88k"
else
    echo "  ⚠ 无 board.json（基镜像若无则跳过）"
fi

echo
echo "── 6) 分区与根文件系统健康 ──"
ROOT_UUID="$(lsblk -no UUID "${LOOP}p2" | tr -d ' ')"
[[ -n "$ROOT_UUID" ]] || fail "rootfs 无 UUID"
ok "rootfs UUID = $ROOT_UUID（fstab 按 UUID 引导）"
btrfs check -n --clear-cache "${LOOP}p2" >/dev/null 2>&1 || true
[[ -d "$TMP/root/usr" && -d "$TMP/root/etc" ]] || fail "rootfs 结构异常（缺 /usr 或 /etc）"
ok "rootfs 结构正常"

echo
echo "== 镜像自证全部通过 =="
