# refs/ 对照基线（只读，不要改）

| 文件 | 来源 | 用途 |
|---|---|---|
| t6-official.dtb | 官方 T6 镜像 p1 `/dtb/rockchip/rk3588-nanopc-t6.dtb` | **权威母本**：多媒体/网络/内存开关全部以它为准 |
| istoreos-h88k.dtb | iStoreOS 25.12.6 H88K 镜像内 DTB | 本板能跑通的第二参照（PCIe/网口/PHY 配置） |
| rk3588-hinlink-h88k-live-inextos.dtb | iNextOS 实跑 DTB | 本板厂商配置（含 pcie2x1l2 reset、口序） |
| rk3588-hinlink-h88k-vendor-6.1.dts | 厂商 6.1 BSP 板级 DTS 源 | `dts/rk3588-hlink.dtsi` 的来源 |

注意：**官方 T6 DTB 里没有 `/memory` 节点**（只有 `/reserved-memory`），
内存是 u-boot 在引导时注入的（本仓用的 2025.10 u-boot 里确实带
`fdt_fixup_memory` 与 `## WARNING: fixup memory failed!` 字符串）。
本仓仍显式写 `/memory`（`dts/memory-banks.json` → 构建生成），因为它更明确、
且我们是在"没有 memory 节点 → 上电全黑"这坑里爬出来的（见 docs 第二节第 1 条）。
