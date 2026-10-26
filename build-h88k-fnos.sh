#!/usr/bin/env bash
#==========================================================================
# HINLINK H88K (RK3588) 飞牛 fnOS 镜像装配
#
# 参照 lyw-kf（KICKPI K1）方案，按 H88K 实际裁剪：
#   · 不注入 u-boot：H88K eMMC 现有厂商 u-boot 走 distro boot（boot.scr→fnEnv），
#     基镜像前 32MiB 保持空闲，引导件区一个字节都不碰（用户口径：U-Boot 不动）。
#   · 不注入树外模块：基镜像内核 6.18.18.c951-trim 已带全部所需驱动
#     （STMMAC/DWMAC_ROCKCHIP=m、R8169=m 覆盖 RTL8125、REALTEK_PHY=y、BLK_DEV_NVME=y）。
#   · 只做三件事：注入本板 DTB、写对 fnEnv.txt（fdtfile + cma=2G）、改 board.json。
#
# DTB 金标准：厂商实机 iNextOS 的 /boot/dtb/rockchip/rk3588-hinlink-h88k.dtb
#   （md5 37193036099ba80b945c792f741afb3e）+ 仅 7 行改造：
#     ① 删 reserved-memory/cma 固定 256M 区（CMA 改由 cmdline cma=2G 决定，
#        与 K1 同款 fnOS 内核实机验证路线一致）
#     ② PMIC rk806 加 rockchip,system-power-controller（主线 rk8xx 靠它注册
#        sys_off 断电 handler；厂商原版无此属性 → poweroff 只 halt）
#
# 安全设计（不可放宽）：
#   本脚本只对镜像文件操作，绝不写任何 /dev 设备节点。
#
# 用法:
#   BASE=/path/fnnas-base.img  DTB=dist/rk3588-hinlink-h88k.dtb  \
#   BUILD_NUM=1  OUT_DIR=out  bash build-h88k-fnos.sh
set -euo pipefail

umount_safe() {
    local mnt="$1" i
    sync
    for i in 1 2 3; do
        umount "$mnt" 2>/dev/null && return 0
        sleep 2
    done
    umount -l "$mnt" 2>/dev/null && echo "  ⚠ $mnt 忙，已惰性卸载（数据已 sync）" && return 0
    return 0
}

fail() { echo "✗ $*" >&2; exit 1; }

BASE="${BASE:?需要 BASE=<飞牛基镜像 .img>}"
DTB="${DTB:?需要 DTB=<本板 .dtb>}"
OUT_DIR="${OUT_DIR:-out}"
BUILD_NUM="${BUILD_NUM:-0}"
[[ -f "$BASE" ]] || fail "基镜像不存在: $BASE"
[[ -f "$DTB" ]] || fail "DTB 不存在: $DTB"

DTB_NAME="$(basename "$DTB")"
[[ "$DTB_NAME" == "rk3588-hinlink-h88k.dtb" ]] || fail "DTB 文件名必须是 rk3588-hinlink-h88k.dtb，得到: $DTB_NAME"

IMG_SRC_SHA="$(sha256sum "$BASE" | awk '{print $1}')"
DTB_SHA="$(sha256sum "$DTB" | awk '{print $1}')"
echo "==== H88K fnOS 装配 ===="
echo "  基镜像: $BASE (sha256 ${IMG_SRC_SHA:0:16}…)"
echo "  DTB   : $DTB (sha256 ${DTB_SHA:0:16}…)"

mkdir -p "$OUT_DIR"
IMG="$OUT_DIR/fnos_Mainland-PE_arm_12_HINLINK-H88K.img"
cp -f "$BASE" "$IMG"
echo "  产物副本: $IMG"

cleanup() {
    mountpoint -q "$BOOT_MNT" 2>/dev/null && umount_safe "$BOOT_MNT" || true
    mountpoint -q "$ROOT_MNT" 2>/dev/null && umount_safe "$ROOT_MNT" || true
    [[ -n "${LOOP:-}" ]] && losetup -d "$LOOP" 2>/dev/null || true
}
BOOT_MNT="$(mktemp -d)"; ROOT_MNT="$(mktemp -d)"
trap cleanup EXIT

echo
echo "==== 1) 挂载镜像分区 ===="
LOOP="$(losetup -fP --show "$IMG")"
sleep 1
BOOT_PART="${LOOP}p1"; ROOT_PART="${LOOP}p2"
[[ -e "$BOOT_PART" ]] || fail "镜像没有 p1 (BOOT)"
[[ -e "$ROOT_PART" ]] || fail "镜像没有 p2 (rootfs)"
mount "$BOOT_PART" "$BOOT_MNT" || fail "挂载 BOOT 失败"
mount "$ROOT_PART" "$ROOT_MNT" || fail "挂载 rootfs 失败"
echo "  BOOT type: $(lsblk -no FSTYPE "$BOOT_PART")  rootfs type: $(lsblk -no FSTYPE "$ROOT_PART")"
ROOT_PARTUUID="$(lsblk -no PARTUUID "$ROOT_PART" | tr -d ' ')"
echo "  rootfs PARTUUID = $ROOT_PARTUUID（boot.scr 每次现场取，不写死）"

echo
echo "==== 2) 注入 DTB ===="
mkdir -p "$BOOT_MNT/dtb/rockchip"
cp -f "$DTB" "$BOOT_MNT/dtb/rockchip/$DTB_NAME"
sync
GOT="$(sha256sum "$BOOT_MNT/dtb/rockchip/$DTB_NAME" | awk '{print $1}')"
[[ "$GOT" == "$DTB_SHA" ]] || fail "DTB 落盘 sha256 不符"
echo "  ✓ dtb/rockchip/$DTB_NAME (sha256 ${GOT:0:16}…)"

echo
echo "==== 3) fnEnv.txt（保留基镜像字段，只改 fdtfile / extraargs）===="
if [[ -f "$BOOT_MNT/fnEnv.txt" ]]; then
    sed 's/^/     原: /' "$BOOT_MNT/fnEnv.txt"
    grep -vE '^(fdtfile|extraargs)=' "$BOOT_MNT/fnEnv.txt" > /tmp/_hh_fnenv.keep || true
    {
        cat /tmp/_hh_fnenv.keep
        echo "fdtfile=rockchip/$DTB_NAME"
        echo "extraargs=cma=2G"
    } > "$BOOT_MNT/fnEnv.txt"
else
    cat > "$BOOT_MNT/fnEnv.txt" <<EOF
verbosity=1
bootlogo=false
console=both
extraargs=cma=2G
fdtfile=rockchip/$DTB_NAME
EOF
fi
sync
echo "  ── 新 fnEnv.txt ──"
sed 's/^/     /' "$BOOT_MNT/fnEnv.txt"
grep -q "^fdtfile=rockchip/$DTB_NAME$" "$BOOT_MNT/fnEnv.txt" || fail "fnEnv fdtfile 写入失败"
grep -q '^extraargs=cma=2G$' "$BOOT_MNT/fnEnv.txt" || fail "fnEnv extraargs 写入失败"
# K1 教训：extlinux.conf 会被 u-boot 优先拾取导致静态 root= 串盘 → 一律停用
if [[ -f "$BOOT_MNT/extlinux/extlinux.conf" ]]; then
    mv -f "$BOOT_MNT/extlinux/extlinux.conf" "$BOOT_MNT/extlinux/extlinux.conf.h88k-off"
    echo "  ✓ 已停用 extlinux.conf →（.h88k-off），引导交回官方 boot.scr"
fi
[[ -f "$BOOT_MNT/boot.scr" ]] || fail "BOOT 分区缺 boot.scr（引导链断）"

echo
echo "==== 4) board.json（设备描述改为 H88K）===="
BJ="$ROOT_MNT/board.json"
if [[ -f "$BJ" ]]; then
    cp -f "$BJ" /tmp/_hh_board.json.orig
    cat > "$BJ" <<'EOF'
{
  "model": {
    "id": "hinlink,h88k",
    "name": "HINLINK H88K (RK3588)"
  },
  "led": []
}
EOF
    python3 -c "import json,sys; json.load(open('$BJ'))" || fail "board.json 不是合法 JSON"
    echo "  ✓ board.json → hinlink,h88k"
else
    echo "  ⚠ rootfs 无 board.json（跳过，不判失败）"
fi

sync
umount_safe "$BOOT_MNT"
umount_safe "$ROOT_MNT"
mountpoint -q "$BOOT_MNT" && fail "BOOT 未卸干净" || true
mountpoint -q "$ROOT_MNT" && fail "rootfs 未卸干净" || true
losetup -d "$LOOP" 2>/dev/null || true
LOOP=""
trap - EXIT

echo
echo "==== 5) 打包 ===="
OUT_XZ="$IMG.xz"
rm -f "$OUT_XZ"
xz -T0 -9 -c "$IMG" > "$OUT_XZ"
IMG_SHA="$(sha256sum "$IMG" | awk '{print $1}')"
XZ_SHA="$(sha256sum "$OUT_XZ" | awk '{print $1}')"
{
    echo "$IMG_SHA  $(basename "$IMG")"
    echo "$XZ_SHA  $(basename "$OUT_XZ")"
    echo "$DTB_SHA  $DTB_NAME"
} > "$OUT_DIR/SHA256SUMS"
echo "  raw  : $(basename "$IMG")  ($(stat -c%s "$IMG") B)"
echo "  xz   : $(basename "$OUT_XZ")  ($(stat -c%s "$OUT_XZ") B)"
echo "  SHA256SUMS:"
sed 's/^/     /' "$OUT_DIR/SHA256SUMS"
echo
echo "==== 装配完成（BUILD_NUM=$BUILD_NUM）===="
