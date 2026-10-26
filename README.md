# lyw-hk — HINLINK H88K (RK3588) 飞牛 fnOS 固件适配

为 **HINLINK H88K V3 (RK3588)** 构建飞牛 fnOS ARM64 固件。方案照抄 `lyw-kf`
（KICKPI K1 的 fnOS 适配，已实机验证），按 H88K 实际情况裁剪。

## 一句话

**基镜像 + 厂商金标准 DTB + fnEnv(fdtfile / cma=2G) + board.json**，四步装配；
U-Boot 不动、不注入任何树外模块。

## DTB 金标准（本仓核心）

**先说清来源**：飞牛基镜像的 `dtb/rockchip/` 里本来就有 `rk3588-hinlink-h88k.dtb`
（sha256 `c2162495acd7e90f…`），而且它与厂商实机 iNextOS 里那份**逐字节相同** ——
也就是飞牛为这块板直接沿用了厂商 DTB（不是主线骨架）。本仓在此底本上做最小改造：

最终 DTB `dist/rk3588-hinlink-h88k.dtb` = **厂商实机 iNextOS 的
`/boot/dtb/rockchip/rk3588-hinlink-h88k.dtb`（md5 `37193036099ba80b945c792f741afb3e`，
底本存档在 `refs/`）+ 恰好 8 项改造**（7 项板级 + 1 项 IOMMU 命名对齐主线），
可由 `tools/make-final-dtb.py` 重生（sha256 `0cdc16f5…`）。

三份厂商参考交叉核对（全部一致才敢定稿）：

| 项 | ①厂商板级源码 | ②厂商Ubuntu固件 | ③厂商实机iNextOS | ★最终DTB |
|---|---|---|---|---|
| model | HINLINK H88K | HINLINK H88K | HINLINK H88K | HINLINK H88K |
| gmac0 | rgmii-rxid + tx_delay=0x44 | 同 | 同 | 同 |
| LED | blue:net/amber:sata/green:user/red:work | （另一套命名，异类） | 同① | 同① |
| PMIC | rk806(include) | rk806 | rk806 | rk806 |
| 串口 | serial2:1500000n8 | 同 | 同 | 同 |

仅有的 8 项改造（理由如下）：

1. **删 `/reserved-memory/cma`（固定 256M 区）** —— 用户要求 CMA=2G。
   保留固定 reg 会把 CMA 压死在 256M；改走 `fnEnv extraargs=cma=2G`，
   与 K1 同款 fnOS 内核（6.18 trim）实机验证路线一致（K1: cma=1G → CmaTotal=1048576kB）。
2. **PMIC rk806 加 `rockchip,system-power-controller`** —— 厂商三份都没有，
   但主线 `drivers/mfd/rk8xx-core.c` 靠它注册 sys_off 断电 handler
   （`device_property_read_bool` 对 `rockchip,` 前缀与裸名两种写法都认）。
   不加则 `poweroff` 退化成 halt（PMIC 不断电）。
3. **全树 `compatible` 由 `rockchip,iommu-v2` 改成 `rockchip,rk3588-iommu`（21 处）** ——
   厂商 DTB 是配厂商 6.1 内核的写法；本仓内核是主线 6.18，
   `drivers/iommu/rockchip-iommu.c` 的 match 表只有 `rockchip,rk3588-iommu`，
   不改则 IOMMU 全部不 probe（VOP/VPU/RGA 走不到 IOMMU）。
   此项**只影响媒体/显示侧，不挡启动**，且**尚未上机验证** IOMMU 实际工作与否。

其余（gmac0 时序、PCIe、LED GPIO、eMMC、串口…）**一律厂商原样**。
`phy-mode=rgmii-rxid` 经主线 6.18 `dwmac-rk.c` 源码核实：
`RGMII_RXID → set_to_rgmii(tx_delay, 0)`，DT 的 `tx_delay=0x44` 生效，与厂商行为一致。

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
