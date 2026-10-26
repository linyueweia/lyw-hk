#!/bin/sh
# H88K 网口稳定性调优：RTL8125B 在 EEE / PCIe ASPM 打开时会出现
# "Link is Up → 几秒后 Down" 的反复抖动（NAS 场景不可接受）。
# 这两项都是省电特性，NAS 优先稳定：统一关掉。
ETHTOOL=/usr/sbin/ethtool
LS_BIN=/bin/ls

for n in /sys/class/net/*; do
    if_="$(basename "$n")"
    [ "$if_" = "lo" ] && continue
    dev="$(readlink -f "$n/device/driver" 2>/dev/null | xargs -r basename 2>/dev/null)"
    [ "$dev" = "r8169" ] || continue
    # 1) 关 EEE（PHY 低功耗以太网）
    ${ETHTOOL} --set-eee "$if_" eee off 2>/dev/null || true
    # 2) 关该 PCI 设备的 ASPM（L0s/L1）
    bdf="$(basename "$(readlink -f "$n/device" 2>/dev/null)")"
    if [ -n "$bdf" ] && [ -w "/sys/bus/pci/devices/$bdf/link/l1_aspm" ]; then
        echo 0 > "/sys/bus/pci/devices/$bdf/link/l1_aspm" 2>/dev/null || true
    fi
    if [ -n "$bdf" ] && [ -w "/sys/bus/pci/devices/$bdf/link/l0s_aspm" ]; then
        echo 0 > "/sys/bus/pci/devices/$bdf/link/l0s_aspm" 2>/dev/null || true
    fi
done
exit 0
