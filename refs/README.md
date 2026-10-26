# refs/ 对照基线（只读，不要改）

| 文件 | 来源 | 用途 |
|---|---|---|
| t6-official.dtb | **官方 T6 镜像 p1 `/dtb/rockchip/rk3588-nanopc-t6.dtb` 原样抽取**（130,259 B，sha256 `09425cc79aafe37dd0b94c2e6baebb6950d39a7a12cbeeaa4cc392d1c4830983`）；与本板 `/boot/dtb/rockchip/rk3588-nanopc-t6.dtb` 逐字节相同 | **权威母本**：多媒体/网络/内存开关全部以它为准 |
| istoreos-h88k.dtb | iStoreOS 25.12.6 H88K 镜像内 DTB | 本板能跑通的第二参照（PCIe/网口/PHY 配置） |
| rk3588-hinlink-h88k-live-inextos.dtb | iNextOS 实跑 DTB | 本板厂商配置（含 pcie2x1l2 reset、口序） |
| rk3588-hinlink-h88k-vendor-6.1.dts | 厂商 6.1 BSP 板级 DTS 源 | `dts/rk3588-hlink.dtsi` 的来源 |

> **2026-10-27 更正（重要，踩过一次）**：本目录此前那份 `t6-official.dtb`（194,576 B / 1098 节点）
> **不是**官方镜像里的 DTB，而是主线 6.18 内核树编的 `rk3588-nanopc-t6.dtb`：
> 它写 `arm,mali-valhall-csf` / `rockchip,rk3588-rknn-core` / `rockchip,rk3588-rga3`，
> **没有 `/mpp-srv`**、`npu` 是 `disabled`。当时据此在 `dts/t6-align.dtsi` 里给 NPU/RGA 显式加了
> `status = "disabled"`，并写下"官方内核里 rknpu/rga3 的 of_match 不认 rk3588 节点"的错误结论 ——
> 结果 GPU/NPU/VPU/RGA 四个驱动全部注册成功、0 设备绑定，设备上一个加速器都不出。
>
> 真件（本目录现在这份）是 **vendor 命名 + 全开**：
> ```
> /mpp-srv           okay  rockchip,mpp-service
> /npu@fdab0000      okay  rockchip,rk3588-rknpu（三核合一）
> /gpu@fb000000      okay  rockchip,rk3588-mali-csf, arm,mali-valhall
>                          clock-names = clk_mali/clk_gpu_coregroup/clk_gpu_stacks/clk_gpu
> /rga@fdb60000/70000 okay rockchip,rga3_core0 / rga3_core1
> /rga@fdb80000      okay  rockchip,rga2_core0
> ```
> 而飞牛内核 6.18.18.c1145-trim 的加速器驱动全是 **BSP 树外模块**
> （`updates/trim/rk_gpu/rkgpu_bifrost_csf.ko`、`updates/trim/rk_vcodec/{rknpu,rk_vcodec,rga3}.ko`），
> of_match 正是上面这些字符串。**判据永远是驱动 match 表，不是"某块参考板怎么写"。**

注意：**官方 T6 DTB 里没有 `/memory` 节点**（只有 `/reserved-memory`），
内存是 u-boot 在引导时注入的（本仓用的 2025.10 u-boot 里确实带
`fdt_fixup_memory` 与 `## WARNING: fixup memory failed!` 字符串）。
本仓也不写 `/memory`（2026-10-27 对照实验：写与不写 MemTotal 都是 8123084 kB），门禁断言"不得带 /memory"。

## 2026-10-27 23:59 更正（上一段"官方没有编码核"是错的）

从 `refs/t6-official.dtb`（130,259 B / sha `09425cc7…`）逐节点重读，官方 T6 **有完整编码链**，
之前漏判是因为只按 `gpu/npu/video-codec/mpp/rga` 关键字过滤，没看 `vepu@`/`vdpu@`/`rkvenc-`：

| 官方节点 | compatible | status | 关键属性 |
|---|---|---|---|
| `/vepu@fdb50000` | `rockchip,vpu-encoder-v2` | **disabled** | irq 120，供 MPP 认但没有启用 |
| `/vdpu@fdb50400` | `rockchip,vpu-decoder-v2` | okay | irq 119，与 vepu 共享 0xfdb50 块 |
| `/rkvenc-ccu` | `rockchip,rkv-encoder-v2-ccu` | okay | 编码 CCU |
| `/rkvenc-core@fdbd0000` | `rockchip,rkv-encoder-v2-core` | okay | irq 101，`venc-supply`/`mem-supply` = PMIC dcdc-reg4 |
| `/rkvenc-core@fdbe0000` | 同上 | okay | irq 104，第二个编码核 |
| `/iommu@fdbdf000` `/iommu@fdbef000` | `rockchip,rk3588-iommu` | okay | 两个编码核的 MMU |
| `/venc-opp-table` | `operating-points-v2` | — | 800MHz，`opp-microvolt` **6 值**（venc+mem 两个 supply） |

推论（已在本板实证）：
- 编码是 RKVENC 干的，VEPU 官方就没启用 → vepu 中断一直是 0 是正常的。
- `venc-supply` 必须给；本板的 RK806 `dcdc-reg4` 标签是 `vdd_vdenc_s0`。缺它必报
  `_opp_set_regulators: no regulator (venc) found`。
- 所有 opp 表的 `opp-microvolt` 都是 **6 值**（2 supply × min/target/max）；只给 3 值会报
  `Invalid number of elements in microvolt property (3) with supplies (2)` →
  `_of_add_opp_table_v2: Failed to add OPP, -22`。GPU 也一样（mali+mem）。
- 官方 opp 表还带 pvtm/nvmem 校准（nvmem-cells → efuse 的 `*-opp-info` 子节点）；本板 efuse 缺
  这些子节点，故只搬 hz/uV，不做逐片校准。
