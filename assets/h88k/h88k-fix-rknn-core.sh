#!/bin/bash
# H88K: 把 rknnlite 的默认 core_mask 钉到 NPU CORE_0
#
# 为什么（2026-10-28 H88K 实机彻查）：
#   官方 T6 DTB（与本机逐项一致）只启用 core0：
#     npu@fdab0000=okay（reg 三段含三核地址）
#     npu@fdac0000/fdad0000=disabled，iommu@fdaca000/fdada000=disabled
#   但 rknnlite 上游默认 core_mask = NPU_CORE_AUTO，源码注释原文：
#     "NPU_CORE_AUTO = 0  # default, run on NPU core randomly."
#   驱动据此随机挑核 → 挑到 core1/core2（节点 disabled、完成中断永不触发）
#   → 每次等满 142s → RKNPU job timeout → soft reset 死循环，
#     trim.txt2vec / trim.img2vec 卡在 rknpu_submit_ioctl（连 systemd stop 都停不掉，成 zombie）。
#   实测对照：CORE_0 only 10/10 成功 5.6s 零超时；AUTO 必现 failed to submit + timeout。
#
# 修法：只改运行时默认值，**DTB 一个字节不动**（完全跟随官方 T6 的意图：只用 core0）。
# 幂等：已改过则跳过；每次开机跑一次，应用更新把库覆盖回来时也会自动修回。
set -u

APPDIRS="/vol1/@appcenter"

# /vol1 是 fnOS 存储池，由 trim_init.service 挂载（H88K 上约 2 分钟）。
# 本单元已 After=trim_init.service，所以正常情况这里已挂好；
# 万一还没挂，**立刻退出不等待** —— 库默认值只在首次需要修，晚一轮开机修也不影响功能，
# 但绝不能让本单元去轮询堵住启动链（第一版的 90 秒轮询把 ai_manager 一起堵了）。
mountpoint -q /vol1 || exit 0
[ -d "$APPDIRS" ] || exit 0

changed=0
for PY in "$APPDIRS"/trim.ai-runtime-rk35*/penv/lib/python*/site-packages/rknnlite/api/rknn_lite.py; do
    [ -f "$PY" ] || continue
    if grep -q 'core_mask=NPU_CORE_AUTO):' "$PY"; then
        cp -a "$PY" "${PY}.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
        sed -i 's/async_mode=False, core_mask=NPU_CORE_AUTO):/async_mode=False, core_mask=NPU_CORE_0):/' "$PY"
        logger -t h88k-fix-rknn-core "patched default core_mask -> NPU_CORE_0: $PY"
        changed=1
    fi
done

if [ "$changed" = 1 ]; then
    logger -t h88k-fix-rknn-core "restarting ai_manager to pick up new default"
    systemctl try-restart ai_manager 2>/dev/null || true
fi
exit 0
