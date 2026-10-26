#!/bin/sh
# H88K: 三个网口都没有出厂 MAC（两块 RTL8125B 无 EEPROM，RK3588 GMAC 也读不到 efuse MAC），
# 内核每次开机给随机地址 → DHCP 每次给新 IP（实测 192.168.10.28→29→30 漂移）。
# 这里按 SoC serial-number + 设备路径派生稳定的本地管理地址（02: 前缀）。
# 用设备路径派生，网口名怎么变 MAC 都不变。
# 注意 1：udev PATH 很窄，外部命令必须绝对路径（踩过：写 ip/sha256sum 时静默失效）
# 注意 2：改 MAC 需链路 down，改完恢复原状态（踩过：没恢复 → 网口一直 down）
# 注意 3：覆盖 r8169（双 2.5G）与 st_gmac / rk_gmac-dwmac（千兆口），否则管理口 MAC 仍随机
IP_BIN=/usr/sbin/ip
SHA_BIN=/usr/bin/sha256sum
TR_BIN=/usr/bin/tr
CUT_BIN=/usr/bin/cut
CAT_BIN=/bin/cat
LS_BIN=/bin/ls

fix_one() {
    if_="$1"
    [ -n "$if_" ] || return 0
    dev="$(${LS_BIN} -l /sys/class/net/$if_/device 2>/dev/null | sed 's#.*/##')"
    [ -n "$dev" ] || return 0
    ser="$(${TR_BIN} -d '\0' < /proc/device-tree/serial-number 2>/dev/null)"
    [ -n "$ser" ] || ser="h88k"
    h="$(printf '%s|%s' "$ser" "$dev" | ${SHA_BIN} | ${CUT_BIN} -c1-12)"
    mac="02:$(echo "$h" | ${CUT_BIN} -c1-2):$(echo "$h" | ${CUT_BIN} -c3-4):$(echo "$h" | ${CUT_BIN} -c5-6):$(echo "$h" | ${CUT_BIN} -c7-8):$(echo "$h" | ${CUT_BIN} -c9-10)"
    cur="$(${CAT_BIN} /sys/class/net/$if_/address 2>/dev/null)"
    [ "$cur" = "$mac" ] && return 0
    # 活链路一律不碰：改 MAC 必须先 down，会把正在跑的 SSH/面板打断（踩过：用户看到"突然断网"）
    carr="$(${CAT_BIN} /sys/class/net/$if_/carrier 2>/dev/null || echo 0)"
    [ "$carr" = "1" ] && return 0
    was_up=0
    ${IP_BIN} link show "$if_" 2>/dev/null | head -1 | grep -q "UP" && was_up=1
    ${IP_BIN} link set dev "$if_" down 2>/dev/null || true
    ${IP_BIN} link set dev "$if_" address "$mac" 2>/dev/null || true
    [ "$was_up" = "1" ] && ${IP_BIN} link set dev "$if_" up 2>/dev/null || true
    return 0
}

if [ -n "$1" ]; then
    fix_one "$1"
else
    for n in /sys/class/net/*; do
        if_="$(basename "$n")"
        [ "$if_" = "lo" ] && continue
        [ -e "/sys/class/net/$if_/device" ] || continue
        drv="$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)" 2>/dev/null)"
        case "$drv" in
            r8169|st_gmac|rk_gmac-dwmac|dwmac_rk) fix_one "$if_" ;;
        esac
    done
fi
exit 0
