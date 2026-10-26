#!/usr/bin/env bash
#==========================================================================
# H88K fnOS 镜像自证（硬门禁）—— 断言"实机验证通过的配方"各项
#
# 用法: sudo -E DTB=dist/rk3588-hlink-h88k.dtb \
#        UBOOT=uboot/h88k-istoreos2025-first32m.bin \
#        bash tools/verify-image.sh <镜像.img>
#
# 原则：只断言"配方本身"，不写任何与配方矛盾的检查（旧版曾同时要求
# extlinux 存在与不存在、cma=2G 与禁止 256M、只认 T6 的 2026.04 却又注入
# 2017.09 —— 结果必然永远失败）。
#==========================================================================
set -euo pipefail
# ERR trap：set -e 静默退出时至少告诉我们死在哪一行（踩过：grep 无匹配 + pipefail → 无声 exit 1）
trap 'echo "  ✗ 命令失败退出 @行 $LINENO（set -e / pipefail）" >&2' ERR

IMG="${1:?用法: verify-image.sh <镜像.img>}"
DTB="${DTB:-dist/rk3588-hlink-h88k.dtb}"
UBOOT="${UBOOT:-}"
TMP="$(mktemp -d)"
LOOP=""
FAILED=0

fail() { echo "  ✗ $*" >&2; FAILED=1; }
ok()   { echo "  ✓ $*"; }
cleanup() {
    mountpoint -q "$TMP/boot" 2>/dev/null && umount "$TMP/boot" 2>/dev/null || true
    mountpoint -q "$TMP/root" 2>/dev/null && umount "$TMP/root" 2>/dev/null || true
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "==== 镜像自证: $(basename "$IMG") ($(stat -c%s "$IMG") B) ===="

LOOP="$(losetup -fP --show "$IMG")"
sleep 1
mkdir -p "$TMP/boot" "$TMP/root"
mount "${LOOP}p1" "$TMP/boot" || { fail "挂载 BOOT 失败"; exit 1; }
mount "${LOOP}p2" "$TMP/root" || { fail "挂载 rootfs 失败"; exit 1; }

echo
echo "── 1) 分区与文件系统 ──"
P1FS="$(lsblk -no FSTYPE "${LOOP}p1")"; P2FS="$(lsblk -no FSTYPE "${LOOP}p2")"
[[ "$P1FS" == "ext4"  ]] && ok "p1 = ext4（官方布局）" || fail "p1 应为 ext4，实际 $P1FS"
[[ "$P2FS" == "btrfs" ]] && ok "p2 = btrfs（官方布局）" || fail "p2 应为 btrfs，实际 $P2FS"

echo
echo "── 2) 板级 DTB ──"
F="$TMP/boot/dtb/rockchip/rk3588-hlink-h88k.dtb"
[[ -f "$F" ]] || fail "缺 dtb/rockchip/rk3588-hlink-h88k.dtb"
if [[ -f "$DTB" ]]; then
    [[ "$(sha256sum "$F" | awk '{print $1}')" == "$(sha256sum "$DTB" | awk '{print $1}')" ]] \
        && ok "镜像内 DTB 与传入 DTB 逐字节一致（sha256 $(sha256sum "$F" | cut -c1-16)…）" \
        || fail "镜像内 DTB 与传入 DTB 不一致"
fi
MODEL="$(fdtget -t s "$F" / model)"
[[ "$MODEL" == *H88K* ]] && ok "model = $MODEL" || fail "model 不符: $MODEL"
if fdtget -t s "$F" / compatible | grep -qi h88k; then ok "compatible 含 h88k"; else fail "compatible 不含 h88k"; fi

echo
echo "── 3) 内存节点（与官方 T6 一致：DTB 不写，u-boot 注入）──"
if dtc -I dtb -O dts -o - "$F" 2>/dev/null | grep -q 'device_type = "memory"'; then
    fail "DTB 不应自带 /memory 节点（官方 T6 也没有；实测 u-boot 会注入三 bank 8GB）"
else
    ok "无 /memory 节点（u-boot 引导时注入，实机 MemTotal 8123084 kB）"
fi

echo "── 4) DTB 关键属性 ──"
dtc -I dtb -O dts -o "$TMP/in.dts" "$F" 2>/dev/null || true
N_IOMMU="$( { grep -o 'rockchip,rk3588-iommu' "$TMP/in.dts" || true; } | wc -l | tr -d ' ')"
N_V2="$( { grep -o 'rockchip,iommu-v2' "$TMP/in.dts" || true; } | wc -l | tr -d ' ')"
[[ "${N_IOMMU:-0}" -ge 10 ]] && ok "iommu = rockchip,rk3588-iommu ×$N_IOMMU" || fail "iommu 不是官方内核认的命名（仅 ${N_IOMMU:-0}）"
[[ "${N_V2:-0}" -eq 0 ]] && ok "无 rockchip,iommu-v2 残留" || fail "仍有 rockchip,iommu-v2 ×${N_V2}"
LBL="$(fdtget -t s "$F" /ethernet@fe1b0000 label 2>/dev/null || true)"
[[ -z "$LBL" ]] && ok "gmac 无 label（否则 stmmac 撞名 -17，千兆口消失）" || fail "gmac 带 label='$LBL'"
[[ "$(fdtget -t s "$F" /ethernet@fe1b0000 phy-mode)" == "rgmii-rxid" ]] && ok "gmac phy-mode=rgmii-rxid" || fail "gmac phy-mode 不符"
[[ "$(fdtget -t i "$F" /ethernet@fe1b0000 tx_delay)" == "68" ]] && ok "gmac tx_delay=0x44" || fail "gmac tx_delay 不符"
for e in "net blue:net" "sata amber:sata" "user green:user" "work red:work"; do
    set -- $e
    [[ "$(fdtget -t s "$F" "/leds/$1" label)" == "$2" ]] || fail "LED $1 应为 $2"
done
ok "LED 四灯 = blue:net / amber:sata / green:user / red:work"
if grep -q 'rockchip,system-power-controller' "$TMP/in.dts"; then ok "PMIC 带 system-power-controller"; else fail "PMIC 缺断电属性"; fi

echo
echo "── 5) PCIe / PHY（NVMe + 双 2.5G 前提）──"
for n in /pcie@fe150000 /pcie@fe170000 /pcie@fe180000 /pcie@fe190000; do
    [[ "$(fdtget -t s "$F" "$n" status)" == "okay" ]] || fail "$n 应 okay"
done
ok "PCIe fe150000/170000/180000/190000 全 okay"
for ph in /phy@fee00000 /phy@fee10000 /phy@fee20000; do
    [[ "$(fdtget -t s "$F" "$ph" status)" == "okay" ]] || fail "$ph 应 okay"
done
ok "combphy0_ps/1_ps/2_psu 全 okay"

echo
echo "── 6) 多媒体（与官方 T6 逐节点一致）──"
for n in /gpu@fb000000 /vop@fdd90000 /hdmi@fde80000 /hdmi@fdea0000; do
    [[ "$(fdtget -t s "$F" "$n" status)" == "okay" ]] || fail "$n 应 okay（与 T6 一致）"
done
ok "GPU / VOP / HDMI0 / HDMI1 均 okay"
for n in /npu@fdab0000 /npu@fdac0000 /npu@fdad0000 /video-codec@fdc38000 /video-codec@fdc40000 /rga@fdb60000 /rga@fdb70000; do
    [[ "$(fdtget -t s "$F" "$n" status)" == "disabled" ]] || fail "$n 应 disabled（T6 亦然）"
done
ok "NPU 与多余 vdec/rga 均 disabled（与 T6 一致）"
NV="$( { grep -o 'rockchip,rk3588-vpu121' "$TMP/in.dts" || true; } | wc -l | tr -d ' ')"
NE="$( { grep -o 'rockchip,rk3588-vepu121' "$TMP/in.dts" || true; } | wc -l | tr -d ' ')"
[[ "${NV:-0}" -ge 1 ]] && [[ "${NE:-0}" -ge 4 ]] && ok "编解码核 vpu121 ×$NV / vepu121 ×$NE" || fail "编解码核数量异常"

echo
echo "── 7) fnEnv.txt（官方引导参数入口）──"
FN="$TMP/boot/fnEnv.txt"
[[ -f "$FN" ]] || fail "缺 fnEnv.txt"
sed 's/^/     /' "$FN"
grep -q '^fdtfile=rockchip/rk3588-hlink-h88k.dtb$' "$FN" && ok "fdtfile=rockchip/rk3588-hlink-h88k.dtb" || fail "fnEnv fdtfile 不符"
grep -q '^extraargs=.*cma=256M' "$FN" && ok "extraargs 含 cma=256M（官方 T6 取值）" || fail "fnEnv extraargs 缺 cma=256M"
grep -q '^initrdfile=' "$FN" && fail "fnEnv 不应有 initrdfile（官方无 initrd 启动）" || ok "无 initrdfile（官方就是无 initrd）"
KER="$(grep '^kernelfile=' "$FN" | cut -d= -f2)"
[[ -n "$KER" && -f "$TMP/boot/$KER" ]] && ok "kernelfile=$KER 在 p1 中存在" || fail "kernelfile 指向的文件不存在: $KER"

echo
echo "── 8) 引导链（只允许官方那一条）──"
[[ -f "$TMP/boot/boot.scr" ]] && ok "boot.scr 在位（官方引导脚本）" || fail "缺 boot.scr"
if grep -qa 'fnEnv' "$TMP/boot/boot.scr"; then ok "boot.scr 内部读 fnEnv（官方机制）"; else fail "boot.scr 不像官方脚本（未引用 fnEnv）"; fi
[[ -e "$TMP/boot/extlinux" ]] && fail "不应存在 extlinux/（会抢在官方脚本前）" || ok "无 extlinux/"
ls "$TMP/boot"/uInitrd* >/dev/null 2>&1 && fail "不应存在 uInitrd（官方无 initrd）" || ok "无 uInitrd"

echo
echo "── 9) u-boot 载荷 ──"
python3 - "$IMG" "${UBOOT:-}" <<'PY'
import hashlib, os, sys, re
img, ub = sys.argv[1], sys.argv[2]
d = open(img, 'rb').read(32*1024*1024)
assert d[0x8000:0x8004] == b'RKNS', "前导区缺 RKNS（idbloader）"
assert d[0x800000:0x800004] == bytes.fromhex('d00dfeed'), "前导区缺 FIT（u-boot）"
ver = re.search(rb'U-Boot 20[0-9]{2}\.[0-9]{2}[^\x00]{0,40}', d)
bt  = re.search(rb'boot_targets=[^\x00]{0,80}', d)
if ub and os.path.exists(ub):
    u = open(ub, 'rb').read()
    # UBOOT 是"从源镜像 17408 起"的裁切件（长度 ≤ 32MiB-17408），构建时整段写在 17408 处，
    # 所以这里比的是 image[17408:17408+len(u)] == u（曾经误写成 u[17408:] → 必然不等）
    seg = d[17408:17408 + len(u)]
    assert len(seg) == len(u), f"镜像载荷区不足：{len(seg)} < {len(u)}"
    assert seg == u, f"镜像 [17408,17408+{len(u)}) 与传入 UBOOT 不一致"
    print(f"  ✓ 与传入 UBOOT 逐字节一致（{ver.group().decode() if ver else '版本串未找到'}）")
else:
    print(f"  ✓ 前导区含 RKNS+FIT（{ver.group().decode() if ver else '版本串未找到'}）")
print(f"  ✓ boot_targets: {bt.group().decode() if bt else '(未找到)'}")
PY

echo
echo "── 10) GPT 自洽 ──"
python3 - "$IMG" <<'PY'
import struct, os, sys
img = sys.argv[1]
last = os.path.getsize(img)//512 - 1
f = open(img,'rb')
f.seek(512); h = f.read(92)
assert h[:8] == b'EFI PART', "主 GPT 头缺失"
alt = struct.unpack_from('<Q', h, 32)[0]
assert alt == last, f"主表 alternate_lba={alt} 应等于镜像末尾 {last}"
f.seek(last*512); b = f.read(8)
assert b == b'EFI PART', "镜像末尾缺备份 GPT 头"
print(f"  ✓ alternate_lba={last}，末尾备份头在位")
PY

echo
echo "── 11) rootfs 完整性 ──"
[[ -d "$TMP/root/usr" && -d "$TMP/root/etc" ]] && ok "rootfs 有 /usr /etc" || fail "rootfs 结构异常"
BJ="$TMP/boot/board.json"
if [[ -f "$BJ" ]]; then
    grep -q 'hlink,h88k' "$BJ" && ok "board.json = hlink,h88k" || fail "board.json 未指向 hlink,h88k"
    grep -q 'blue:net' "$BJ" && ok "board.json 含 LED 映射 blue:net" || echo "  ⚠ board.json 无 LED 映射（不致命）"
fi

echo
if [[ "$FAILED" -ne 0 ]]; then
    echo "== 镜像自证失败 ==" >&2
    exit 1
fi
echo "== 镜像自证全部通过 =="
