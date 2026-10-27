#!/usr/bin/env python3
#==========================================================================
# board.json 判据（单一真源）—— 构建期与镜像自证共用同一份代码
#
# 为什么要有它：
#   build-h88k-fnos.sh 曾经在 3.4 段内联写死一份只有 model/led 的 board.json，
#   与 assets/h88k/board.json（含 fan 段）并存 = 同一职责两套实现。
#   CI 用的是内联那份 → 镜像里没有 fan 段 → fnOS 的 pwm-fancontrol.service
#   每开机报 "Error: No fan configuration found in /boot/board.json" 并 failed。
#   现在装配只 cp assets 那份，判据由本脚本单点定义，两边都调它。
#
# 用法:
#   python3 tools/board-json-check.py <board.json> [--quiet]
# 退出码: 0 = 通过；1 = 不通过（逐条打印 ✗ 原因）
#==========================================================================
import json
import sys

REQUIRED_LED = ("blue:net", "amber:sata")


def main(argv):
    quiet = "--quiet" in argv
    args = [a for a in argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        print("用法: board-json-check.py <board.json> [--quiet]", file=sys.stderr)
        return 2
    path = args[0]

    errs = []

    def req(cond, msg):
        if not cond:
            errs.append(msg)

    try:
        with open(path, "r", encoding="utf-8") as f:
            d = json.load(f)
    except FileNotFoundError:
        print("✗ board.json 不存在: %s" % path, file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001
        print("✗ board.json 非法 JSON: %s" % e, file=sys.stderr)
        return 1

    # --- model ---------------------------------------------------------
    model = d.get("model") or {}
    req(model.get("id") == "hlink,h88k",
        "model.id 应为 hlink,h88k（实际 %r）" % model.get("id"))
    req(bool(model.get("name")), "model.name 不能为空")

    # --- led（fnOS 面板按 name 找 sysfs，两颗都要在）----------------------
    led = d.get("led")
    req(isinstance(led, list) and len(led) >= 2,
        "led 至少 2 项（POWER-LED=blue:net / DISK-LED=amber:sata），实际 %r"
        % (len(led) if isinstance(led, list) else led))
    if isinstance(led, list):
        have = {e.get("sysfs") for e in led if isinstance(e, dict)}
        for s in REQUIRED_LED:
            req(s in have, "led 缺 sysfs=%s（实际 %r）" % (s, sorted(x for x in have if x)))
        for e in led:
            if isinstance(e, dict) and e.get("sysfs") in REQUIRED_LED:
                req(bool(e.get("name")), "led %s 缺 name" % e.get("sysfs"))

    # --- fan（缺了 → pwm-fancontrol.service 直接 exit 1）-----------------
    fan = d.get("fan")
    req(isinstance(fan, list) and len(fan) >= 1,
        "缺 fan 段（fnOS /usr/trim/bin/pwm-fancontrol.sh 读 .fan[]，缺则服务 failed）")
    if isinstance(fan, list):
        for i, f in enumerate(fan):
            if not isinstance(f, dict):
                errs.append("fan[%d] 不是对象" % i)
                continue
            tag = "fan[%d]" % i
            req(bool(f.get("name")), "%s 缺 name" % tag)
            # 脚本把这两个键直接拼成 fancontrol -T / -F 参数
            ts = f.get("tsysfs") or ""
            fs = f.get("fsysfs") or ""
            req("thermal_zone" in ts, "%s.tsysfs 应指向 thermal_zone*/temp（实际 %r）" % (tag, ts))
            req("cooling_device" in fs, "%s.fsysfs 应指向 cooling_device*/cur_state（实际 %r）" % (tag, fs))
            for k in ("start_temp", "max_speed"):
                req(isinstance(f.get(k), int), "%s.%s 应为整数（实际 %r）" % (tag, k, f.get(k)))
            if isinstance(f.get("start_temp"), int):
                req(0 < f["start_temp"] < 120, "%s.start_temp=%s 不合理" % (tag, f["start_temp"]))
            if isinstance(f.get("max_speed"), int):
                req(f["max_speed"] >= 1, "%s.max_speed 应 >=1（实际 %s）" % (tag, f["max_speed"]))
            if "start_speed" in f:
                req(isinstance(f["start_speed"], int), "%s.start_speed 应为整数" % tag)
            if "temp_div" in f:
                req(isinstance(f["temp_div"], int) and f["temp_div"] > 0,
                    "%s.temp_div 应为正数" % tag)

    if errs:
        for e in errs:
            print("  ✗ %s" % e, file=sys.stderr)
        print("✗ board.json 判据未通过（%d 项）: %s" % (len(errs), path), file=sys.stderr)
        return 1

    if not quiet:
        f0 = fan[0]
        print("  ✓ board.json 判据通过: model=%s led=%d fan=%d(%s, %s°C 起, max=%s)"
              % (model["id"], len(led), len(fan), f0.get("name"),
                 f0.get("start_temp"), f0.get("max_speed")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
