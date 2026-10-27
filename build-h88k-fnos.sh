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

# 3.4 board.json —— 单一来源：assets/h88k/board.json（model / led / fan）
#     历史事故：本节曾内联写死一份只有 model/led 的副本，与 assets 那份并存，
#     CI 落地的是缺 fan 的那份 → fnOS 的 pwm-fancontrol.service 每开机报
#     "Error: No fan configuration found in /boot/board.json" 并 failed。
#     现在只拷 assets 那份；判据由 tools/board-json-check.py 单点定义（镜像自证同一份）。
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_SRC="$SELF_DIR/assets/h88k/board.json"
BOARD_CHECK="$SELF_DIR/tools/board-json-check.py"
if [[ -f "$BOOT_MNT/board.json" ]]; then
    [[ -f "$BOARD_SRC"   ]] || fail "缺 $BOARD_SRC（board.json 单一来源）"
    [[ -f "$BOARD_CHECK" ]] || fail "缺 $BOARD_CHECK（board.json 判据）"
    cp -f "$BOARD_SRC" "$BOOT_MNT/board.json" || fail "board.json 拷贝失败"
    python3 "$BOARD_CHECK" "$BOOT_MNT/board.json" || fail "board.json 判据未通过"
    ok "board.json ← assets/h88k/board.json（model + LED×2 + fan 段齐全）"
else
    echo "  ⚠ p1 无 board.json（跳过，不判失败）"
fi

# 3.5 清掉会抢引导/多余的东西
rm -rf "$BOOT_MNT/extlinux" 2>/dev/null || true
rm -f  "$BOOT_MNT/uInitrd"* 2>/dev/null || true
[[ -f "$BOOT_MNT/boot.scr" ]] || fail "p1 缺 boot.scr（官方引导链断）"
ok "引导链 = boot.scr → fnEnv（无 extlinux / 无 uInitrd）"

echo
echo "==== 3.6) OS 层修复：mask 本板没有对应硬件的服务（含 SysV 形态）===="
# 判据与 lyw-kf 同款（2026-10-27 落地），但列表按 H88K 实机裁定（.37 取证）：
#   exim4        只有 /etc/init.d/exim4（SysV，无 unit 文件）→ 旧式只查 *.service 的写法从不命中，
#                开机时 systemd-sysv-generator 才生成 exim4.service，启动即 failed
#                （日志：either install a certificate or change tls_advertise_hosts option）
#   nut-server   /usr/lib/systemd/system/nut-server.service + /etc/init.d/nut-server，本板无 UPS → failed
#   nut-monitor  同族，无 UPS → 一并关掉（否则迟早也 failed）
# ⚠ 故意【不动】的三者（动了就是真故障）：
#   pwm-fancontrol  H88K 风扇就靠它，board.json 的 fan 段是它的配置源，实机 active
#   smartmontools   本板有 NVMe，SMART 可读，属正常使用而非残留
#   networking      fnOS 仍有依赖，mask 有断网风险
ROOT_PART="${LOOP}p2"
[[ -e "$ROOT_PART" ]] || fail "镜像没有 p2 (rootfs)"
ROOT_MNT="$(mktemp -d)"
mount "$ROOT_PART" "$ROOT_MNT" || fail "挂载 rootfs 失败"
ok "p2 = $(lsblk -no FSTYPE "$ROOT_PART")"

H88K_MASK="nut-monitor nut-server exim4"
for u in $H88K_MASK; do
    hit=0
    for d in "$ROOT_MNT/etc/systemd/system" "$ROOT_MNT/usr/lib/systemd/system" "$ROOT_MNT/lib/systemd/system"; do
        [[ -f "$d/$u.service" && ! -L "$d/$u.service" ]] && hit=1
    done
    [[ -f "$ROOT_MNT/etc/init.d/$u" ]] && hit=1      # SysV 也算命中
    if [[ "$hit" = 1 ]]; then
        ln -sf /dev/null "$ROOT_MNT/etc/systemd/system/$u.service"
        ok "mask $u.service"
    else
        echo "  · $u 不在镜像里（跳过）"
    fi
done

# 自证①：存在就必须真 masked（unit 或 SysV 任一形态）
for u in $H88K_MASK; do
    if [[ -e "$ROOT_MNT/etc/systemd/system/$u.service" || -e "$ROOT_MNT/usr/lib/systemd/system/$u.service" \
          || -e "$ROOT_MNT/lib/systemd/system/$u.service" || -f "$ROOT_MNT/etc/init.d/$u" ]]; then
        if [[ -L "$ROOT_MNT/etc/systemd/system/$u.service" ]] \
           && [[ "$(readlink "$ROOT_MNT/etc/systemd/system/$u.service")" == "/dev/null" ]]; then
            ok "自证 $u 已指向 /dev/null"
        else
            fail "$u 存在于镜像但未真正 masked（systemd unit 或 /etc/init.d 脚本）"
        fi
    fi
done
# 自证②：风扇服务绝不能被 mask（这条是防「顺手把 pwm-fancontrol 也关掉」的回归）
if [[ -L "$ROOT_MNT/etc/systemd/system/pwm-fancontrol.service" ]]; then
    fail "pwm-fancontrol 被 mask 了 —— H88K 风扇会彻底失效"
fi
ok "pwm-fancontrol 未被 mask（风扇可正常控速）"

# 3.6b) NPU 只用 core0 的钉死件（2026-10-28 H88K 实机彻查）
#   官方 T6 DTB（与本板逐项一致）只启用 core0：npu@fdac0000/fdad0000 + iommu@fdaca000/fdada000
#   全 disabled，但 rknnlite 上游默认 core_mask = NPU_CORE_AUTO（源码注释："run on NPU core randomly"）
#   → 驱动随机挑到 core1/core2（节点 disabled、完成中断永不触发）→ 每次等满 142s
#   → RKNPU job timeout + soft reset 死循环，trim.txt2vec/img2vec 卡在 rknpu_submit_ioctl。
#   实测：CORE_0 only 10/10 成功 5.6s 零超时；AUTO 必现 failed to submit + timeout。
#   该库文件在 /vol1/@appcenter（首启才下载的应用里），构建期改不到 → 用首启 oneshot 修；
#   **DTB 一个字节不动**（完全跟随官方 T6 的意图）。
install -Dm755 "$SELF_DIR/assets/h88k/h88k-fix-rknn-core.sh" \
    "$ROOT_MNT/usr/local/sbin/h88k-fix-rknn-core.sh" || fail "装 h88k-fix-rknn-core.sh 失败"
install -Dm644 "$SELF_DIR/assets/h88k/h88k-fix-rknn-core.service" \
    "$ROOT_MNT/etc/systemd/system/h88k-fix-rknn-core.service" || fail "装 h88k-fix-rknn-core.service 失败"
mkdir -p "$ROOT_MNT/etc/systemd/system/multi-user.target.wants"
ln -sf ../h88k-fix-rknn-core.service \
    "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/h88k-fix-rknn-core.service" \
    || fail "使能 h88k-fix-rknn-core.service 失败"
[[ -x "$ROOT_MNT/usr/local/sbin/h88k-fix-rknn-core.sh" ]] \
    || fail "自证：h88k-fix-rknn-core.sh 未就位或不可执行"
[[ -L "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/h88k-fix-rknn-core.service" ]] \
    || fail "自证：h88k-fix-rknn-core.service 未 enable"
ok "已装 NPU core0 钉死件（rknnlite 默认 CORE_0，首启自动应用；DTB 不动）"

sync
umount "$ROOT_MNT"; rmdir "$ROOT_MNT"
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
