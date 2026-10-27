# lyw-hk — HINLINK H88K (RK3588) 跑飞牛 fnOS

## 一句话结论

**H88K 没有可用的官方 fnOS 镜像（现成的 `fnos_*_HINLINK-H88K` 包都起不来）。**
唯一跑通的配方是：**拿官方 T6 镜像当母本，只换三件板级件**，其余一律保持官方原样。
2026-10-26 已在实机（eMMC 独立启动、卡拔出）验证通过，细节见
[`docs/H88K-fnOS-可用配方.md`](docs/H88K-fnOS-可用配方.md)。

## 配方（三件替换）

| # | 件 | 位置 | 来源 |
|---|---|---|---|
| 1 | u-boot 载荷 | eMMC/镜像 `[17408, 32MiB)` | `uboot/h88k-istoreos2025-first32m.bin`（`U-Boot 2025.10-OpenWrt`，含 `bootflow scan -lb` + ext4） |
| 2 | 板级 DTB | p1 `/dtb/rockchip/rk3588-hlink-h88k.dtb` | 本仓 CI 产物（飞牛内核树 `unifreq/linux-6.18.y` 编出） |
| 3 | `fnEnv.txt` | p1 `/fnEnv.txt` | `assets/h88k/fnEnv.txt`（官方键 + `fdtfile`，**无 initrdfile**） |

引导链（官方那一条，不要自造）：
`bootflow scan -lb` → p1 `/boot.scr` → 读 `fnEnv.txt` → `load` 内核与 `dtb/${fdtfile}` → `booti`。

## 目录

```
dts/
  rk3588-hlink.dtsi        板级公共 dtsi（厂商 DTS 来源 + PMIC 断电属性 + PCIe 复位/PHY）
  rk3588-hlink-h88k.dts    板级入口（model/compatible + #include 两个 dtsi）
  t6-align.dtsi            与官方 T6 DTB 逐节点对齐的开/关项（GPU/VOP/HDMI 开、NPU 关…）
                           （不写 /memory 节点：与 T6 一致，内存由 u-boot 注入）
build-dtb.sh               在飞牛内核树里编 DTB（CI 用）
build-h88k-fnos.sh         装配镜像：官方母本 + 三件 + GPT 收尾
tools/
  verify-h88k-dts.sh       DTB 硬门禁（内存/PMIC/iommu/PCIe/combphy/多媒体/LED/gmac）
  verify-image.sh          镜像自证（分区/DTB/fnEnv/引导链/u-boot 载荷/GPT/rootfs）
  fix-gpt-backup.py        把 3.6G 镜像写进更大 eMMC 时把 GPT 备份表搬到盘尾
uboot/                    本板 u-boot 前 32MiB 载荷 + SHA256SUMS（只留实机验证那份）
assets/h88k/              运行时修复件：board.json（LED）、fnEnv.txt、MAC 固定脚本与 unit
refs/                     对照基线 DTB：官方 T6 / iStoreOS / iNextOS 实跑，以及厂商 6.1 DTS 源
docs/                     实机踩坑与验收记录
```

## 用法

```bash
# 1) 编 DTB（CI 里也这么跑）
bash build-dtb.sh                     # 产物 dist/rk3588-hlink-h88k.dtb

# 2) 装配镜像（BASE 用官方 T6 母本）
BASE=/path/fnos_official_arm64.img \
DTB=dist/rk3588-hlink-h88k.dtb \
UBOOT=uboot/h88k-istoreos2025-first32m.bin \
OUT_DIR=out bash build-h88k-fnos.sh

# 3) 自证
sudo -E DTB=dist/rk3588-hlink-h88k.dtb \
     UBOOT=uboot/h88k-istoreos2025-first32m.bin \
     bash tools/verify-image.sh out/fnos_Mainland-PE_arm_12_HINLINK-H88K.img
```

## CI

- `Build DTB only`（`.github/workflows/build-dtb.yml`）：编 DTB + 全套硬门禁 + 上传产物
- `Build fnOS HINLINK H88K Image`：拉官方母本 → 装配 → 自证 → 发 release

## 已知边界（不是 DTB 能解决的）

官方内核对 **GPU/NPU/VPU** 没有 RK3588 的驱动：`mali.ko` 只匹配 Mali-400/450，
`rk_vcodec.ko` 只匹配 `vpu-decoder-v1/v2`，`rga3.ko` 只认 `rga2/rga3`，config 里也没有
`DRM_PANTHOR/PANFROST`。DTB 已按官方 T6 逐节点一致，但硬件能力用不上。要真用得重编内核。

## 关键坑（详见 docs）

1. `/memory` 不要自己写：官方 T6 的 DTB 也没有，内存由 u-boot `fdt_fixup_memory` 注入
   （实测注入三 bank 8GB，MemTotal 8123084 kB）。曾经手写一版，属多余
2. `/ethernet@fe1b0000` 不能带 `label`（stmmac 撞名 `-17`，千兆口整个消失、地址乱漂）
3. 第二个 2.5G 要显式启用 `pcie@fe190000` + `combphy0_ps`（reset `<&gpio4 RK_PA5>`）
4. 三块网卡都没有出厂 MAC → 按 SoC 序列号 + 设备路径派生固定 MAC
5. 3.6G 镜像写进 58G eMMC 必须把 GPT 备份表搬到盘尾
6. 不要加 extlinux、不要塞 initrd —— 官方链路只有 `boot.scr → fnEnv`


---

## 刷写完必做：GPT 按目标盘适配（否则卡在 `Waiting for root device`）

镜像只写到盘的头部，GPT 主头里的 `alternate_lba` / `last_usable` 仍指向**镜像文件末尾**。
刷进比镜像大的卡（几乎所有 TF/SD 卡）后：

- **U-Boot 宽容**：照样从 `mmcblk1:1` 读 `boot.scr`，引导看起来完全正常；
- **Linux 内核严格**：`alternate_lba` 不在设备末尾就拒绝整张分区表 → `mmcblk1:` 后面
  **不列 p1 p2** → 卡死 `Waiting for root device PARTUUID=...`（无 panic、无报错、干等）。

**刷完对目标盘跑一次**（三仓通用同一份工具）：

```sh
# 1) 按目标盘真实容量重算 GPT 全部字段（主/备头 + 分区项 + 保护 MBR），并把 rootfs 的 PARTUUID 换新
python3 tools/gpt-fix.py /dev/sdX --apply --renew-partuuid=2

# 2) 判据
fdisk -l /dev/sdX                    # 必须能看到 p1 / p2
python3 tools/gpt-fix.py /dev/sdX    # 必须输出「GPT 全字段自洽（主/备/MBR）」
```

`--renew-partuuid=2` 的作用：本仓镜像与板上 eMMC 里的系统同源时 `rootfs` 的 PARTUUID 相同，
内核会**先挂到 eMMC 那个**（起的是旧系统而不是卡上的）。换掉 GUID 即可，
`boot.cmd` 用 `part uuid` 现场取值，**不需要改任何引导文件**。

构建期已有同一道门禁（装配末尾 `gpt-fix.py --apply`），保证**镜像自身**自洽；
上面这一步是**设备侧**适配，两者都要跑。

> 2026-10-27 实机两次踩坑：T68M 与 K1 都表现为「U-Boot 正常、内核干等根设备」，
> 日志特征 = `mmcblk1: mmc1:… 14.7 GiB` 之后**没有** `mmcblk1: p1 p2` 这一行。
