# lyw-hk — HINLINK H88K (RK3588) 飞牛 fnOS 固件适配

为 **HINLINK H88K V3 (RK3588)** 构建飞牛 fnOS ARM64 固件。方案照抄 `lyw-kf`
（KICKPI K1 的 fnOS 适配，已实机验证），按 H88K 实际情况裁剪。

## 一句话

**基镜像 + 厂商金标准 DTB + fnEnv(fdtfile / cma=2G) + board.json**，四步装配；
U-Boot 不动、不注入任何树外模块。

## DTB 适配（2026-10-26 定案：用飞牛内核树自带的板级 DTS）

**结论先说：这块板在飞牛内核树里已经有官方血统的板级 DTS，不需要移植厂商 6.1 的 DTS。**

- 内核树 `unifreq/linux-6.18.y`（飞牛 `6.18.18.cXXX-trim` 的来源树）自带：
  - `arch/arm64/boot/dts/rockchip/rk3588-hlink.dtsi`（24.7 KB，板级公共部分，作者 Flippy）
  - `rk3588-hlink-h88k.dts`（基础版）/ `-v3.dts` / `-v31.dts`（H88K V3 / V3.1，31.6 KB 全量）
- 与实物逐项对上（厂商 DTB 三份交叉核对）：LED `blue:net/amber:sata/green:user/red:work`、
  `gmac0 phy-mode=rgmii-rxid` + `tx_delay=0x44`、PMIC `rockchip,rk806`、无 cma 固定区、
  `#include "rk3588.dtsi"` ⇒ SoC 级（iommu/时钟/电源域）天然与飞牛内核同源。
- 本仓只做 **1 项改造**：`pmic@0` 补 `rockchip,system-power-controller`
  （主线 rk8xx-core 靠它注册 sys_off handler；不加则 `poweroff` 只 halt 不断电）。
- 产物名随树内命名：`dist/rk3588-hlink-h88k.dtb`，`model = "Hlink H88K"`、`compatible = "hlink,h88k"`。
- ⚠ **反面记录（已弃）**：曾用厂商发布镜像里的 `rk3588-hinlink-h88k.dtb`（厂商 6.1 BSP 树编的，
  SoC 级写 `rockchip,iommu-v2`）去配飞牛 6.18 内核，并手改 21 处字符串救 ——
  飞牛树里是 `rockchip,rk3588-iommu`（×14，iommu-v2 ×0），这就是"DTB 与内核不配套"的本体。
  厂商 6.1 DTS 现只存 `refs/rk3588-hinlink-h88k-vendor-6.1.dts` 作对照，不参与构建。

## U-Boot 口径（2026-10-26 校正版，判据是 DDR 不是 build 号）

**判据（KF 口径）：u-boot 必须与【本板 DDR 同源】，断 DDR 版本串，不断 build 号。**

- 本仓注入 `uboot/h88k-vendor-first32m.bin`（sha256 `f2e48d08f85a3c71…`，32MiB），
  来源＝厂商 Ubuntu 24.04 `20260524-ubuntu-24.04-desktop-arm64-hinlink-h88k.img`
  的前 32MiB：`RKNS@0x8000` + `FIT@0x800000`，`U-Boot 2017.09 (May 23 2026)`，
  **`ddr-v1.18-9fa84341ce`**（与板上 iNextOS 运行时 cmdline 里的 DDR 版本逐字一致），
  `boot_targets=nvme0 mmc1 mmc0 mtd2 mtd1 mtd0 usb0 pxe dhcp`。
- ❌ **反面记录（已删）**：曾用 fnOS 官方 NanoPC-T6 镜像里的 `U-Boot 2026.04-TRIM`
  当"RK3588 通用件"——它只是 **T6 板的** 件，在 H88K 上起不来（eMMC 实测黑屏）。
  "同 SoC 就能通用"是错的，K1 仓同一条教训：u-boot 不自编、不跨板借用。
- ⚠ **不要手改 u-boot 里的 `boot_targets`**：改动落在 FIT 负载内，SPL 会按 hash 校验，
  不重签必然 `sha256 error!`（KF 已用血的代价记为坑 1）。本仓试过 `fit-resign.py`
  对这份厂商 FIT，5 个 image 节点全报 MISMATCH（工具与该 FIT 结构不兼容）——
  **所以引导顺序不动，改用介质选择来控制（见下节）。**
- 注入只写 `[17408, 32MiB)` 载荷区，镜像自身 GPT 前 17408 字节保留；
  `verify-image.sh` 硬门禁：RKNS + FIT + 整片 32MiB 逐字节一致 + **含 `ddr-v1.18-9fa84341ce`**。

## 启动介质与引导顺序（2026-10-26 实测定论）

1. **BootROM 只认 eMMC 的 IDB**：把 eMMC 的 `0x8000` 4 字节 `RKNS` 清零后，板子既不进系统、
   也不落 SD，直接停在 MASKROM 等 USB（实测）→ 别想着"清 IDB 逼它从 SD 起"。
2. **介质选择发生在 eMMC 里那份 u-boot 的 distro boot**：`boot_targets` 写死在二进制，
   顺序是 `nvme0 → mmc1(SD) → mmc0(eMMC)` ⇒ **卡在槽里就一定起卡上的系统，eMMC 里的系统
   一次都不会被尝试**（`/proc/mounts` 里 `/boot` 落在 `mmcblk1p1` 即为实证）。
   ⇒ 要测 eMMC 上的系统，**那一次卡不能插**；插回卡即回到卡上的系统（安全的退路）。
3. **写盘后必须把 GPT 备份表搬回盘尾**：镜像 3.86 GiB、eMMC 58.3 GiB，整盘 dd 后主头的
   `alternate_lba` 仍指向镜像末尾 → u-boot `part_efi.c` 判"分区表损坏" → 一个分区都读不到
   （内核只警告、照常能读，所以"dd 校验通过但刷完起不来"）。用
   `tools/fix-gpt-backup.py <盘\|镜像>` 就地修（只动 LBA1 + 盘尾 33 扇区，CRC 重算并回读断言）。
   iStoreOS/Armbian 是 MBR，无此问题 —— 这就是"刷 iStoreOS 能起、刷飞牛起不来"的根因。
4. **引导双路径**：p1 同时保留官方 `boot.scr`（`part uuid` 现场取身份）与本仓新写的
   `extlinux/extlinux.conf`（xck-nas 口径：`kernel /vmlinuz` + `fdt /dtb/rockchip/…` +
   `root=PARTUUID=…` + `console=ttyS2,1500000` + `earlycon=…feb50000` + `cma=2G`）。
   任何一条被 u-boot 选中都能起；extlinux 的好处是内核升级后 `/vmlinuz` 符号链接自动跟随。

## 基镜像

`linyueweia/fnnas-base-images` release `v1.0.0` 的
`fnnas-official-arm64-image_rockchip.img.gz`（解压 sha256 以 CI 实取值为准；
本地取证件 `d0f4d40b…`、release 资产 `4ad44904…`，结构相同、字节不同 —— 与 lyw-kf 同一现象）。

布局：GPT，BOOT(ext4) @32MiB / 360MiB，rootfs(btrfs) @408MiB，**前 32MiB 留空**。
内核 `6.18.18.c951-trim`（全系通用），驱动面已核实：
`STMMAC_ETH=m / DWMAC_ROCKCHIP=m / R8169=m(覆盖 RTL8125) / REALTEK_PHY=y /
PCIE_ROCKCHIP=y / BLK_DEV_NVME=y / MFD_RK8XX_SPI=y / DW_WATCHDOG=y`。

## 构建

```bash
# CI（推荐）：push 到 main 或 Actions → Build fnOS HINLINK H88K Image → Run workflow
# 产物: artifact fnos-hinlink-h88k-<n> / release fnos_hinlink-h88k_<n>
#        fnos_Mainland-PE_arm_12_HINLINK-H88K.img.xz + SHA256SUMS

# 本地（Linux）:
bash tools/verify-dtb.sh                       # DTB 门禁
sudo BASE=fnnas-base.img DTB=dist/rk3588-hinlink-h88k.dtb UBOOT=uboot/h88k-first32m.bin bash build-h88k-fnos.sh
sudo DTB=dist/rk3588-hinlink-h88k.dtb bash tools/verify-image.sh out/*.img
```

## 刷写与验收

**写盘三步，缺一不可**：

```bash
# 1) 整盘写（MASKROM/RKDevTool 分段写，或从另一个系统 dd）
#    注意：RKDevTool「下载镜像」页对 >2GB 的单文件会 32 位长度溢出 → 按 1.75GiB 分段
# 2) 把 GPT 备份表搬回盘尾（否则 u-boot 判分区表损坏，刷完起不来）
sudo python3 tools/fix-gpt-backup.py /dev/mmcblk0
# 3) 确认引导路径
sudo mount /dev/mmcblk0p1 /mnt/boot
cat /mnt/boot/extlinux/extlinux.conf       # extlinux 路径
cat /mnt/boot/fnEnv.txt                    # 官方 boot.scr 路径
```

上机验收：

```bash
grep -o 'cma=[0-9]*[MG]' /proc/cmdline        # 期望 cma=2G
cat /proc/device-tree/model                   # HINLINK H88K
ethtool eth2 | grep -E 'Speed|Link'            # 千兆口（RTL8211F）协商正常
lspci -nn | grep -i ethernet                   # 两块 10ec:8125（2.5G）
ls /sys/class/leds/                            # blue:net green:user amber:sata red:work
poweroff                                       # 关机后指示灯全灭 = PMIC 断电生效
```

## 目录

```
build-h88k-fnos.sh                  装配脚本（只碰镜像文件，绝不写 /dev 节点）
dts/rk3588-hinlink-h88k.dts         最终 DTS 源（反编译，供 dtc 重编译校验）
dist/rk3588-hinlink-h88k.dtb        最终 DTB 成品（pyfdt 从底本改造，270281 B）
refs/rk3588-hinlink-h88k-live-inextos.dtb   厂商实机底本（金标准存档）
tools/make-final-dtb.py             DTB 可复现生成器（重生 + 断言）
tools/verify-dtb.sh                 DTB 门禁（dtc 编译 + 金标准 + 差异面 ≤8 行）
tools/verify-image.sh               镜像自证（硬门禁）
.github/workflows/build-fnos-hinlink-h88k.yml
```

## 回滚

原系统不受影响（本仓从不碰设备）；刷回 = 用原 iNextOS/原厂镜像重刷。
fnEnv.txt 单独回滚：删 `fdtfile=`/`extraargs=` 两行即回基镜像默认（cma=256M）。
