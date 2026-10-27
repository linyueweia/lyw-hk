#!/usr/bin/env bash
#==========================================================================
# tools/board-json-check.py 的自测：1 正例 + 6 负例，秒级，挂进 CI 构建前
#
# 为什么要有它：
#   判据如果只会「绿」，就等于没有判据。历史上 board.json 的 fan 段就是这样丢的
#   —— 装配脚本内联的那份缺 fan，而门禁只 grep 了 model/led，于是红着眼睛出了个
#   pwm-fancontrol.service 每开机 failed 的镜像。
#==========================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_RAW="$(mktemp -d)"
trap 'rm -rf "$TMP_RAW"' EXIT
TMP="$TMP_RAW"
# 本机（Windows/git-bash）验证时：native python 不认 /c/... 形式的路径，
# 用 cygpath -m 转成 C:/... ；Linux CI 上没有 cygpath，保持原样。
if command -v cygpath >/dev/null 2>&1; then
    SELF_DIR="$(cygpath -m "$SELF_DIR")"
    TMP="$(cygpath -m "$TMP_RAW")"
fi
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "✗ 找不到 python（可用 PYTHON=... 指定）" >&2; exit 1; }
CHECK() { "$PY" "$SELF_DIR/tools/board-json-check.py" "$@"; }
SRC="$SELF_DIR/assets/h88k/board.json"

pass=0
failcnt=0

expect_ok() {  # $1=描述 $2=文件
    if CHECK "$2" >/dev/null 2>&1; then
        echo "  ✓ 正例通过: $1"
        pass=$((pass + 1))
    else
        echo "  ✗ 正例被误判红: $1" >&2
        CHECK "$2" >&2 || true
        failcnt=$((failcnt + 1))
    fi
}

expect_bad() {  # $1=描述 $2=文件
    if CHECK "$2" >/dev/null 2>&1; then
        echo "  ✗ 负例没被拦下（判据失效）: $1" >&2
        failcnt=$((failcnt + 1))
    else
        echo "  ✓ 负例被拦下: $1"
        pass=$((pass + 1))
    fi
}

echo "── tools/board-json-check.py 自测 ──"
[[ -f "$SRC" ]] || { echo "✗ 缺 $SRC" >&2; exit 1; }

# ---- 正例：仓库里那份（装配时就是拷它）----
expect_ok "assets/h88k/board.json（含 fan 段）" "$SRC"

# ---- 负例 1：缺 fan 段（= 10-27 镜像里落地的那份，pwm-fancontrol 必 failed）----
"$PY" - "$SRC" "$TMP/no-fan.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d.pop('fan', None)
json.dump(d, open(sys.argv[2], 'w'), ensure_ascii=False, indent=2)
PY
expect_bad "缺 fan 段" "$TMP/no-fan.json"

# ---- 负例 2：led 少一颗 ----
"$PY" - "$SRC" "$TMP/one-led.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['led'] = d['led'][:1]
json.dump(d, open(sys.argv[2], 'w'), ensure_ascii=False, indent=2)
PY
expect_bad "led 只有 1 颗" "$TMP/one-led.json"

# ---- 负例 3：model.id 不是本板 ----
"$PY" - "$SRC" "$TMP/wrong-model.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['model']['id'] = 'hinlink,h88k'
json.dump(d, open(sys.argv[2], 'w'), ensure_ascii=False, indent=2)
PY
expect_bad "model.id 拼写不对" "$TMP/wrong-model.json"

# ---- 负例 4：fan.fsysfs 没指向 cooling_device（改成普通路径）----
"$PY" - "$SRC" "$TMP/bad-fsysfs.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['fan'][0]['fsysfs'] = '/sys/class/hwmon/hwmon0/pwm1'
json.dump(d, open(sys.argv[2], 'w'), ensure_ascii=False, indent=2)
PY
expect_bad "fan.fsysfs 不是 cooling_device" "$TMP/bad-fsysfs.json"

# ---- 负例 5：start_temp 缺失（非整数）----
"$PY" - "$SRC" "$TMP/no-starttemp.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['fan'][0].pop('start_temp', None)
json.dump(d, open(sys.argv[2], 'w'), ensure_ascii=False, indent=2)
PY
expect_bad "fan 缺 start_temp" "$TMP/no-starttemp.json"

# ---- 负例 6：非法 JSON ----
printf '{ "model": { "id": "hlink,h88k" ,\n' > "$TMP/broken.json"
expect_bad "非法 JSON" "$TMP/broken.json"

echo "── 结果：$pass 通过 / $failcnt 失败 ──"
[[ "$failcnt" -eq 0 ]] || exit 1
echo "== board.json 判据自测全部通过 =="
