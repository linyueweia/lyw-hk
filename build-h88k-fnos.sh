#!/usr/bin/env bash
#==========================================================================
# HINLINK H88K (RK3588) 飞牛 fnOS 镜像装配
#
# 参照 lyw-kf（KICKPI K1）方案，按 H88K 实际裁剪：
#   · 注入飞牛官方 RK3588 通用 U-Boot（uboot/fnos-rk3588-first32m.bin，
#     U-Boot 2026.04-TRIM，RKNS@0x8000 + FIT@0x800000），只写 [17408, 32MiB) 载荷区，
#     镜像自身 GPT 保留。板上 eMMC 原有的 U-Boot 2017.09_armbian 在 H88K 上
#     mmc dev 1 初始化失敗（实测 4 次/13 秒全失败），已弃用。
#   · 不注入树外模块：基镜像内核 6.18.18.c951-trim 已带全部所需驱动
#     （STMMAC/DWMAC_ROCKCHIP=m、R8169=m 覆盖 RTL8125、REALTEK_PHY=y、BLK_DEV_NVME=y）。
#   · 只做三件事：注入本板 DTB、写对 fnEnv.txt（fdtfile + cma=2G）、改 board.json。
#
# DTB 金标准：厂商实机 iNextOS 的 /boot/dtb/rockchip/rk3588-hlink-h88k.dtb
#   （md5 37193036099ba80b945c792f741afb3e）+ 8 项改造：
#     ① 删 reserved-memory/cma 固定 256M 区（CMA 改由 cmdline cma=2G 决定，
#        与 K1 同款 fnOS 内核实机验证路线一致）
#     ② PMIC rk806 加 rockchip,system-power-controller（主线 rk8xx 靠它注册
#        sys_off 断电 handler；厂商原版无此属性 → poweroff 只 halt）
#     ③ 全树 compatible rockchip,iommu-v2 → rockchip,rk3588-iommu（21 处；主线 6.18
#        rockchip-iommu match 表只认后者。只影响 VOP/VPU/RGA，不挡启动）
#
# 安全设计（不可放宽）：
#   本脚本只对镜像文件操作，绝不写任何 /dev 设备节点。
#
# 用法:
#   BASE=/path/fnnas-base.img  DTB=dist/rk3588-hlink-h88k.dtb  \
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
# 2026-10-26：DTB 默认【不外部传入】——就地适配基镜像自带的官方 DTB
# （tools/adapt-official-dtb.py，证据来自官方内核二进制的 of_match 表）。
# 传 DTB=<路径> 仅用于回归/对比场景。
DTB="${DTB:-}"
OUT_DIR="${OUT_DIR:-out}"
BUILD_NUM="${BUILD_NUM:-0}"
[[ -f "$BASE" ]] || fail "基镜像不存在: $BASE"
if [[ -n "$DTB" ]]; then
    [[ -f "$DTB" ]] || fail "DTB 不存在: $DTB"
    DTB_NAME="$(basename "$DTB")"
else
    DTB_NAME="rk3588-hinlink-h88k.dtb"      # 基镜像里官方那份的文件名（保持不动）
fi

IMG_SRC_SHA="$(sha256sum "$BASE" | awk '{print $1}')"
echo "==== H88K fnOS 装配 ===="
echo "  基镜像: $BASE (sha256 ${IMG_SRC_SHA:0:16}…)"
if [[ -n "$DTB" ]]; then
    DTB_SHA="$(sha256sum "$DTB" | awk '{print $1}')"
    echo "  DTB   : 外部传入 $DTB (sha256 ${DTB_SHA:0:16}…)"
else
    echo "  DTB   : 就地适配基镜像自带的官方 $DTB_NAME"
fi

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
# ── U-Boot 注入（本板引导件，前导区清零基镜像的配套机制）──────────────
# 基镜像 v1.1.0 起前导区为零（3568/3588 无法共用一份 U-Boot，业界同款做法见
# ophub/u-boot：按板存库、构建时注入）。注入规则：只写 [17408, 32MiB) 载荷区
# （RKNS idbloader @0x8000 + FIT u-boot.itb @0x800000），镜像自身 GPT 前 17408
# 字节（LBA0~33）保留 —— 两者的 GPT 分区布局不同，绝不能覆盖。
if [[ -n "${UBOOT:-}" ]]; then
    [[ -f "$UBOOT" ]] || fail "UBOOT 文件不存在: $UBOOT"
    UBSZ="$(stat -c%s "$UBOOT")"
    [[ "$UBSZ" -eq 33554432 ]] || fail "UBOOT 必须是 32MiB 提取件，实际 $UBSZ"
    dd if="$UBOOT" of="$IMG" bs=1 skip=17408 seek=17408 conv=notrunc status=none
    # 断言：载荷魔数 + GPT 仍是镜像自己的
    python3 - "$IMG" "$UBOOT" <<'PYEOF'
import sys, hashlib, struct
img, ub = sys.argv[1], sys.argv[2]
d = open(img,'rb').read(32*1024*1024)   # 必须读满 32MiB：U-Boot 版本串在 0x800000 之后的 FIT 里
u = open(ub,'rb').read()
assert d[0x8000:0x8004] == b'RKNS', "idbloader 魔数不对"
assert d[0x800000:0x800004] == bytes.fromhex('d00dfeed'), "FIT 魔数不对"
# 2026-10-26 校正：u-boot 必须与【本板 DDR 同源】——判据是 DDR 版本串，不是 build 号（KF 口径）。
# 实测：NanoPC-T6 的 2026.04-TRIM 件在 H88K 上起不来；厂商 Ubuntu 24.04(2026-05) 件
# ddr-v1.18-9fa84341ce 与本板 eMMC/iNextOS 同源，boot_targets=nvme0 mmc1 mmc0。
assert b'ddr-v1.18-9fa84341ce' in d, "注入的 u-boot 不是本板 DDR 同源件（缺 ddr-v1.18-9fa84341ce）"
assert b'boot_targets=' in d and b'mmc0' in d and b'mmc1' in d, "u-boot 的 boot_targets 异常（缺 mmc0/mmc1）"
assert d[512:520] == b'EFI PART', "镜像 GPT 头丢失"
assert hashlib.sha256(d[17408:]).hexdigest() == hashlib.sha256(u[17408:]).hexdigest(), "整片 [17408,32MiB) 载荷与提取件不一致"
# p1 起始 LBA 必须仍是 65536（32MiB）
f = open(img,'rb'); f.seek(512); h = f.read(92)
pl, = struct.unpack('<Q', h[72:80])
f.seek(pl*512); e = f.read(128)
s, = struct.unpack('<Q', e[32:40])
assert s == 65536, f"p1 起始 LBA 变了: {s}"
print("  ✓ U-Boot 注入断言通过（RKNS + FIT + GPT 保留 + p1@65536）")
PYEOF
    echo "  ✓ 已注入本板 U-Boot（载荷区 [17408,32MiB)，来自 $UBOOT）"
else
    echo "  （未传 UBOOT —— 前导区保持基镜像原样）"
fi
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
echo "==== 2) DTB ===="
OFFICIAL_DTB="$BOOT_MNT/dtb/rockchip/$DTB_NAME"
if [[ -n "$DTB" ]]; then
    mkdir -p "$BOOT_MNT/dtb/rockchip"
    cp -f "$DTB" "$OFFICIAL_DTB"
    sync
    GOT="$(sha256sum "$OFFICIAL_DTB" | awk '{print $1}')"
    [[ "$GOT" == "$DTB_SHA" ]] || fail "DTB 落盘 sha256 不符"
    echo "  ✓ 已注入外部 DTB dtb/rockchip/$DTB_NAME (sha256 ${GOT:0:16}…)"
else
    [[ -f "$OFFICIAL_DTB" ]] || fail "基镜像里没有 dtb/rockchip/$DTB_NAME"
    echo "  官方 DTB 原始 sha256: $(sha256sum "$OFFICIAL_DTB" | awk '{print $1}')"
    python3 tools/adapt-official-dtb.py "$OFFICIAL_DTB" || fail "官方 DTB 适配失败"
    sync
    echo "  适配后 sha256: $(sha256sum "$OFFICIAL_DTB" | awk '{print $1}')"
    # 二次硬断言（脚本内部已断言，这里防"改了但没落盘"）
    python3 - "$OFFICIAL_DTB" <<'PYCHK'
import subprocess, sys
d = subprocess.run(["dtc","-I","dtb","-O","dts","-o","-",sys.argv[1]], capture_output=True, text=True).stdout
assert d.count('rockchip,rk3588-iommu') == 21, f"iommu 数量 {d.count('rockchip,rk3588-iommu')} != 21"
assert 'rockchip,iommu-v2' not in d, "仍有 iommu-v2 残留"
assert 'rockchip,system-power-controller' in d, "PMIC 断电属性缺失"
print("  ✓ 适配后 DTB 二次断言通过（iommu ×21 / 无 v2 / PMIC 断电属性）")
PYCHK
fi

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

echo
echo "==== 3.5) extlinux.conf（xck-nas 口径：extlinux 直起内核，与官方 boot.scr 成双路径）===="
BOOT_PARTUUID="$(lsblk -no PARTUUID "$BOOT_PART" | tr -d ' ')"
[[ -n "$BOOT_PARTUUID" && -n "$ROOT_PARTUUID" ]] || fail "拿不到 BOOT/rootfs 的 PARTUUID"
mkdir -p "$BOOT_MNT/extlinux"
cat > "$BOOT_MNT/extlinux/extlinux.conf" <<EXTLINUX
label fnOS
    kernel /vmlinuz
    fdt /dtb/rockchip/$DTB_NAME
    append earlycon=uart8250,mmio32,0xfeb50000 console=ttyS2,1500000 console=tty1 splash=verbose cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory cma=2G ubootpart=PARTUUID=${BOOT_PARTUUID} root=PARTUUID=${ROOT_PARTUUID} rw rootwait
EXTLINUX
grep -q "root=PARTUUID=${ROOT_PARTUUID}" "$BOOT_MNT/extlinux/extlinux.conf" || fail "extlinux.conf root 写入失败"
grep -q "fdt /dtb/rockchip/$DTB_NAME" "$BOOT_MNT/extlinux/extlinux.conf" || fail "extlinux.conf fdt 写入失败"
sed 's/^/     /' "$BOOT_MNT/extlinux/extlinux.conf"
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
