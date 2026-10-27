#!/usr/bin/env bash
#==========================================================================
# HINLINK H88K (RK3588) 飞牛 fnOS 镜像装配 —— 按【实机验证通过】的配方
#
# 配方来源：docs/H88K-fnOS-可用配方.md（2026-10-26 实机启动成功后固化）
#   母本：飞牛官方 arm64 镜像（GPT：p1 BOOT ext4 @LBA65536 380MiB / p2 rootfs btrfs）
#   只换三件，其余一律不动：
#     1) u-boot 载荷  [17408, 32MiB)  ← UBOOT（需含 bootflow scan + ext4 读能力）
#     2) 板级 DTB     p1 /dtb/rockchip/rk3588-hlink-h88k.dtb ← 本仓 CI 编译产物
#     3) p1 /fnEnv.txt ← 官方键 + fdtfile（官方 boot.cmd 就靠它取 DTB 路径）
#
# 明确【不做】（都试过、都失败）：
#   · 不生成 extlinux.conf —— 官方链路是 bootflow → /boot.scr → fnEnv
#   · 不放 initrd       —— 官方 fnEnv 无 initrdfile，官方就是无 initrd 启动
#   · 不改内核/rootfs/分区
#
# 用法:
#   BASE=<官方 .img> DTB=<dist/rk3588-hlink-h88k.dtb> \
#   UBOOT=<uboot/h88k-istoreos2025-first32m.bin> BUILD_NUM=1 OUT_DIR=out \
#   bash build-h88k-fnos.sh
#==========================================================================
set -euo pipefail

BASE="${BASE:?需要 BASE=<飞牛官方基镜像 .img>}"
DTB="${DTB:?需要 DTB=<板级 dtb 路径>}"
UBOOT="${UBOOT:?需要 UBOOT=<本板 u-boot 前 32MiB 载荷>}"
OUT_DIR="${OUT_DIR:-out}"
BUILD_NUM="${BUILD_NUM:-0}"
DTB_NAME="rk3588-hlink-h88k.dtb"
UB_OFF=17408
UB_END=$((32*1024*1024))

fail() { echo "✗ $*" >&2; exit 1; }
ok()   { echo "  ✓ $*"; }

[[ -f "$BASE"  ]] || fail "基镜像不存在: $BASE"
[[ -f "$DTB"   ]] || fail "DTB 不存在: $DTB"
[[ -f "$UBOOT" ]] || fail "u-boot 载荷不存在: $UBOOT"

mkdir -p "$OUT_DIR"
IMG="$OUT_DIR/fnos_Mainland-PE_arm_12_HINLINK-H88K.img"
DTB_SHA="$(sha256sum "$DTB" | awk '{print $1}')"

echo "==== H88K fnOS 装配（实机验证配方）===="
echo "  基镜像 : $BASE ($(stat -c%s "$BASE") B, sha256 $(sha256sum "$BASE" | cut -c1-16)…)"
echo "  DTB    : $DTB ($(stat -c%s "$DTB") B, sha256 ${DTB_SHA:0:16}…)"
echo "  u-boot : $UBOOT ($(stat -c%s "$UBOOT") B)"
echo "  产物   : $IMG"

echo
echo "==== 1) 复制基镜像 ===="
cp --reflink=auto "$BASE" "$IMG"
ok "已复制"

echo
echo "==== 2) 注入 u-boot 载荷 [${UB_OFF}, 32MiB) ===="
python3 - "$IMG" "$UBOOT" "$UB_OFF" "$UB_END" <<'PY'
import sys
img, ub, off, end = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
payload = open(ub, 'rb').read()
if len(payload) < end - off:
    sys.exit(f"✗ u-boot 载荷不足（需要 {end-off} B，实际 {len(payload)} B）")
payload = payload[:end - off]
with open(img, 'r+b') as f:
    f.seek(off)
    f.write(payload)
d = open(img, 'rb').read(end)
assert d[0x8000:0x8004] == b'RKNS', "注入后 RKNS 魔数丢失"
assert d[0x800000:0x800004] == bytes.fromhex('d00dfeed'), "注入后 FIT 魔数丢失"
assert d[512:520] == b'EFI PART', "镜像 GPT 头丢失"
print(f"  ✓ 注入完成（RKNS + FIT + GPT 在位，载荷 {len(payload)} B）")
PY

echo
echo "==== 3) 挂载 p1，写入板级三件 ===="
LOOP="$(losetup -fP --show "$IMG")"
BOOT_MNT="$(mktemp -d)"
cleanup() {
    sync
    mountpoint -q "$BOOT_MNT" 2>/dev/null && umount "$BOOT_MNT" 2>/dev/null || true
    [[ -n "${LOOP:-}" ]] && losetup -d "$LOOP" 2>/dev/null || true
    rmdir "$BOOT_MNT" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1
[[ -e "${LOOP}p1" ]] || fail "镜像没有 p1 (BOOT)"
mount "${LOOP}p1" "$BOOT_MNT" || fail "挂载 BOOT 失败"
ok "p1 = $(lsblk -no FSTYPE "${LOOP}p1")"

# 3.1 板级 DTB
mkdir -p "$BOOT_MNT/dtb/rockchip"
cp -f "$DTB" "$BOOT_MNT/dtb/rockchip/$DTB_NAME"
[[ "$(sha256sum "$BOOT_MNT/dtb/rockchip/$DTB_NAME" | awk '{print $1}')" == "$DTB_SHA" ]] \
    || fail "DTB 落盘 sha256 不符"
ok "DTB → dtb/rockchip/$DTB_NAME"

# 3.2 内核：沿用基镜像自带，不替换
KERNEL="$(cd "$BOOT_MNT" && ls vmlinuz-* 2>/dev/null | head -1 || true)"
[[ -n "$KERNEL" && -f "$BOOT_MNT/$KERNEL" ]] || fail "基镜像里找不到内核（vmlinuz-*）"
ok "内核沿用基镜像: $KERNEL（$(stat -c%s "$BOOT_MNT/$KERNEL") B）"

# 3.3 fnEnv.txt —— 官方键 + 本板 fdtfile；无 initrdfile
cat > "$BOOT_MNT/fnEnv.txt" <<EOF
verbosity=7
bootlogo=false
console=both
earlycon=on
extraargs=cma=256M
kernelfile=$KERNEL
fdtfile=rockchip/$DTB_NAME
EOF
grep -q "^fdtfile=rockchip/$DTB_NAME$" "$BOOT_MNT/fnEnv.txt" || fail "fnEnv fdtfile 写入失败"
grep -q "^kernelfile=$KERNEL$"            "$BOOT_MNT/fnEnv.txt" || fail "fnEnv kernelfile 写入失败"
if grep -q '^initrdfile=' "$BOOT_MNT/fnEnv.txt"; then fail "fnEnv 不应有 initrdfile（官方无 initrd）"; fi
sed 's/^/     /' "$BOOT_MNT/fnEnv.txt"

# 3.4 board.json —— fnOS 认板 + LED（sysfs 名与本板 DTB 标签一致）
if [[ -f "$BOOT_MNT/board.json" ]]; then
    cat > "$BOOT_MNT/board.json" <<'EOF'
{
  "model": {
    "id": "hlink,h88k",
    "name": "HINLINK H88K V3"
  },
  "led": [
    { "name": "POWER-LED", "sysfs": "blue:net",   "trigger": "default-on" },
    { "name": "DISK-LED",  "sysfs": "amber:sata", "trigger": "disk-activity" }
  ]
}
EOF
    python3 -c "import json,sys; json.load(open('$BOOT_MNT/board.json'))" || fail "board.json 非法 JSON"
    ok "board.json → hlink,h88k + LED(blue:net / amber:sata)"
else
    echo "  ⚠ p1 无 board.json（跳过，不判失败）"
fi

# 3.5 清掉会抢引导/多余的东西
rm -rf "$BOOT_MNT/extlinux" 2>/dev/null || true
rm -f  "$BOOT_MNT/uInitrd"* 2>/dev/null || true
[[ -f "$BOOT_MNT/boot.scr" ]] || fail "p1 缺 boot.scr（官方引导链断）"
ok "引导链 = boot.scr → fnEnv（无 extlinux / 无 uInitrd）"

sync
umount "$BOOT_MNT"; losetup -d "$LOOP"; rmdir "$BOOT_MNT"; LOOP=""; trap - EXIT

echo
echo "==== 4) GPT 自洽（R5S 官方口径：备份表落镜像末尾 + 全字段 CRC 校验）===="
python3 tools/gpt-fix.py "$IMG" --apply || { echo "❌ GPT 修复/复检失败"; exit 1; }

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
echo "  raw : $(basename "$IMG")  ($(stat -c%s "$IMG") B)  sha256 ${IMG_SHA:0:16}…"
echo "  xz  : $(basename "$OUT_XZ")  ($(stat -c%s "$OUT_XZ") B)  sha256 ${XZ_SHA:0:16}…"
echo
echo "==== 装配完成（BUILD_NUM=$BUILD_NUM）==== 下一步: bash tools/verify-image.sh $IMG"
