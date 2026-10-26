#!/bin/sh
# 网口链路取证：每 2 秒采样，只在状态变化时落一行，用来判断
# "同一个口在抖" 还是 "线在换口"，不再靠猜。
LOG=/var/log/h88k-linkwatch.log
mkdir -p /var/log
echo "==== linkwatch start $(date -Is) ====" >> $LOG
last=""
while true; do
    cur=""
    for n in /sys/class/net/*; do
        i=$(basename "$n")
        case "$i" in lo|docker*|veth*|br-*) continue;; esac
        c=$(cat "$n/carrier" 2>/dev/null || echo -)
        s=$(cat "$n/operstate" 2>/dev/null || echo -)
        v=$(cat "$n/speed" 2>/dev/null || echo -)
        a=$(cat "$n/address" 2>/dev/null || echo -)
        cur="$cur $i:c=$c/s=$s/v=$v/m=$a"
    done
    if [ "$cur" != "$last" ]; then
        echo "$(date -Is) |$cur" >> $LOG
        last="$cur"
    fi
    sleep 2
done
