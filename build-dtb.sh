#!/usr/bin/env bash
#==========================================================================
# H88K(fnOS) DTB 云编译 —— 在【飞牛内核树】里编厂商板级 DTS
#
# 为什么必须在飞牛内核树里编（2026-10-26 定案）：
#   厂商发布镜像里的 rk3588-hinlink-h88k.dtb 是用厂商 6.1 BSP 树编的，
#   其 SoC 级节点写的是 rockchip,iommu-v2 等厂商命名；而飞牛内核
#   （unifreq/linux-6.18.y，即 6.18.18.cXXX-trim 的来源）的
#   rk3588-base.dtsi 里是 rockchip,rk3588-iommu（×14，iommu-v2 ×0）。
#   直接拿厂商 DTB 配飞牛内核 → iommu/时钟/电源域绑定不上（"DTB 与内核不配套"）。
#
#   本脚本把【只含板级覆盖】的 dts/rk3588-hinlink-h88k.dts 放进该树编译，
#   SoC 级定义全部取自飞牛树 → 产出的 DTB 天然与内核配套。
#   （同一套做法见 xck-nas/build-dtb.sh：clone 树 → 覆盖 dts → make dtbs）
#
# 用法：
#   bash build-dtb.sh                    # 克隆树 + 编译 + 输出 dist/*.dtb
#   KERNEL_DIR=/path/to/tree bash build-dtb.sh   # 复用已 clone 的树
#==========================================================================
set -euo pipefail

KERNEL_REPO="${KERNEL_REPO:-https://github.com/unifreq/linux-6.18.y.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-main}"
KERNEL_DIR="${KERNEL_DIR:-kernel}"
DTS_SRC="${DTS_SRC:-dts/rk3588-hinlink-h88k.dts}"
DTS_NAME="rk3588-hinlink-h88k.dts"
OUT="${OUT:-dist/rk3588-hinlink-h88k.dtb}"

[[ -f "$DTS_SRC" ]] || { echo "✗ 缺 $DTS_SRC"; exit 1; }

echo "==== 1) 准备飞牛内核树 ===="
if [[ ! -d "$KERNEL_DIR/.git" ]]; then
    git clone --depth 1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
else
    echo "  复用已有树: $KERNEL_DIR"
fi

echo
echo "==== 2) 放入板级 DTS 并登记到 Makefile ===="
DTS_DIR="$KERNEL_DIR/arch/arm64/boot/dts/rockchip"
cp "$DTS_SRC" "$DTS_DIR/$DTS_NAME"
MK="$DTS_DIR/Makefile"
if grep -q "$DTS_NAME" "$MK"; then
    echo "  Makefile 已有 $DTS_NAME"
else
    echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += $DTS_NAME" >> "$MK"
    echo "  已追加 Makefile 条目"
fi

echo
echo "==== 3) 编译 DTB（不需要交叉工具链）===="
( cd "$KERNEL_DIR" && make ARCH=arm64 defconfig >/dev/null && make ARCH=arm64 dtbs -j"$(nproc)" )

echo
echo "==== 4) 取出产物 ===="
mkdir -p "$(dirname "$OUT")"
cp "$DTS_DIR/${DTS_NAME%.dts}.dtb" "$OUT"
ls -la "$OUT"
sha256sum "$OUT"
echo "  ✓ DTB 由飞牛内核树编译，SoC 级绑定与内核同源"
