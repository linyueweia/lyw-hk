#!/bin/sh
# 在板子上运行（任一能起的内核，如 iStoreOS/Android），输出 memory-banks.json
# 用法: ./capture-memory.sh > dts/memory-banks.json
set -e
NODE=$(ls -d /proc/device-tree/memory* 2>/dev/null | head -1)
[ -n "$NODE" ] || { echo "!! 找不到 /proc/device-tree/memory*" >&2; exit 1; }
HEX=$(hexdump -v -e '1/1 "%02x"' "$NODE/reg")
MODEL=$(tr -d '\0' < /proc/device-tree/model)
python3 - "$HEX" "$MODEL" <<'PY'
import sys, json
h, model = sys.argv[1], sys.argv[2]
b = bytes.fromhex(h)
g = [int.from_bytes(b[i:i+8], 'big') for i in range(0, len(b), 8)]
banks = [{"base": g[i], "size": g[i+1]} for i in range(0, len(g)-1, 2)]
print(json.dumps({
    "_comment": "由 tools/capture-memory.sh 在实机上从 /proc/device-tree/memory/reg 采集，构建时生成 DTS 节点；勿手改",
    "model": model,
    "banks": banks,
}, indent=2))
PY
