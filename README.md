# lyw-hk — HINLINK H88K (RK3588) 飞牛 fnOS 固件适配

为 **HINLINK H88K V3 (RK3588)** 构建飞牛 fnOS ARM64 固件。方案照抄 `lyw-kf`
（KICKPI K1 的 fnOS 适配，已实机验证），按 H88K 实际情况裁剪。

## 一句话

**基镜像 + 厂商金标准 DTB + fnEnv(fdtfile / cma=2G) + board.json**，四步装配；
U-Boot 不动、不注入任何树外模块。

## DTB 金标准（本仓核心）

最终 DTB `dist/rk3588-hinlink-h88k.dtb` = **厂商实机 iNextOS 的
`/boot/dtb/rockchip/rk3588-hinlink-h88k.dtb`（md5 `37193036099ba80b945c792f741afb3e`，
底本存档在 `refs/`）+ 恰好 7 行改造**，可由 `tools/make-final-dtb.py` 逐字节重生。

三份厂商参考交叉核对（全部一致才敢定稿）：

| 项 | ①厂商板级源码 | ②厂商Ubuntu固件 | ③厂商实机iNextOS | ★最终DTB |
|---|---|---|---|---|
| model | HINLINK H88K | HINLINK H88K | HINLINK H88K | HINLINK H88K |
| gmac0 | rgmii-rxid + tx_delay=0x44 | 同 | 同 | 同 |
| LED | blue:net/amber:sata/green:user/red:work | （另一套命名，异类） | 同① | 同① |
| PMIC | rk806(include) | rk806 | rk806 | rk806 |
| 串口 | serial2:1500000n8 | 同 | 同 | 同 |

仅有的 7 行改造（两处偏离厂商，理由如下）：

1. **删 `/reserved-memory/cma`（固定 256M 区）** —— 用户要求 CMA=2G。
   保留固定 reg 会把 CMA 压死在 256M；改走 `fnEnv extraargs=cma=2G`，
   与 K1 同款 fnOS 内核（6.18 trim）实机验证路线一致（K1: cma=1G → CmaTotal=1048576kB）。
2. **PMIC rk806 加 `rockchip,system-power-controller`** —— 厂商三份都没有，
   但主线 `drivers/mfd/rk8xx-core.c` 靠它注册 sys_off 断电 handler
   （`device_property_read_bool` 对 `rockchip,` 前缀与裸名两种写法都认）。
   不加则 `poweroff` 退化成 halt（PMIC 不断电）。

其余（gmac0 时序、PCIe、LED GPIO、eMMC、串口…）**一律厂商原样**。
`phy-mode=rgmii-rxid` 经主线 6.18 `dwmac-rk.c` 源码核实：
`RGMII_RXID → set_to_rgmii(tx_delay, 0)`，DT 的 `tx_delay=0x44` 生效，与厂商行为一致。

## U-Boot 口径（2026-10-26 定）

- 基镜像 **v1.1.0 起前导区（0~32MiB）为零**：3568/3588 无法共用一份 U-Boot（实测：v1.0.0 内嵌
  RK3568 版 ddr-v1.23，整盘刷到 H88K 会砖），飞牛官方也是每板一份，业界同款做法见 ophub/u-boot
  （按板存库、构建时注入）。
- 本仓构建传 `UBOOT=uboot/h88k-first32m.bin`（**H88K 实机 eMMC 前 32MiB 只读提取**，
  sha256 `53049942…`，RKNS@0x8000 + FIT@0x800000 + ddr-v1.18，板上实测能跑的那份），
  注入只写 `[17408, 32MiB)` 载荷区，镜像自身 GPT 保留 —— 产物整盘 dd 也安全。
- 刷写不碰板上现有 U-Boot 的场景（分区刷/dd skip）可不注入，`verify-image.sh` 会按
  "注入 或 前导区全零"二选一断言。

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

刷写方式与原厂一致（MASKROM/RKDevTool 或整盘 dd；**前 32MiB 为空属正常**，
U-Boot 沿用板上现有引导件）。上机验收：

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
