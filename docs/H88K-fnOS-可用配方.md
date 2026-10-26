# H88K 上让 fnOS 真正启动的可用配方（2026-10-26 实机验证）

结论先说：**H88K 没有官方镜像，所有 "fnos_*_HINLINK-H88K" 的现成包都是失败的**。
可用的做法只有一条：**拿官方 T6 镜像当母本，只换 H88K 的三件板级件**。

实机状态（验收通过）：`Linux H88K 6.18.18.c1145-trim #1145 aarch64`，
`/dev/mmcblk1p2` 为根（卡拔出时 mmcblk1 = eMMC），8GB 内存全认，CMA 256M，
NVMe LITEON 119G，双 RTL8125B 2.5G（0003:31 / 0004:41）+ GMAC 千兆，四颗 LED 齐活。

## 一、母本与三件

母本：官方 `fnos_Mainland-PE_arm_1.2.0701_nanopc-t6_2882.img.gz`
（解压 3,859,808,256 B，GPT：p1 BOOT 380MiB @LBA65536 ext4、p2 rootfs 3245MiB @LBA876544）

只替换这三件，其他一律不动：

| # | 件 | 位置 | 做法 |
|---|---|---|---|
| 1 | u-boot 载荷 | eMMC `[17408, 32MiB)` | 写本板能跑的 u-boot（本仓 `uboot/h88k-istoreos2025-first32m.bin`，`U-Boot 2025.10-OpenWrt`，`bootcmd=bootflow scan -lb`） |
| 2 | 板级 DTB | p1 `/dtb/rockchip/rk3588-hlink-h88k.dtb` | 本仓 CI 产物（飞牛内核树编出，含 `/memory`） |
| 3 | `fnEnv.txt` | p1 `/fnEnv.txt` | 官方键 + H88K 的 `fdtfile`（见下） |

```
verbosity=7
bootlogo=false
console=both
earlycon=on
extraargs=cma=256M
kernelfile=vmlinuz-6.18.18.c1145-trim
fdtfile=rockchip/rk3588-hlink-h88k.dtb      # ← 官方 boot.cmd 就是从这里取 DTB 路径
```

引导链（官方机制，一行都别自造）：`bootflow scan -lb` → 扫到 p1 根上的 `/boot.scr`
→ 官方脚本 `load ${prefix}fnEnv.txt` + `env import -t` → `load` 内核与 `dtb/${fdtfile}`
→ `fdt resize 65536` → `booti ${kernel_addr_r} ${initrd_load_addr} ${fdt_addr_r}`。
官方 fnEnv **没有 initrdfile** → 官方就是**无 initrd** 启动，别往上塞。

## 二、踩过的坑（每条都有实机判据）

1. **DTB 缺 `/memory` 节点 = 上电全黑，串口/HDMI 都无输出**
   vendor dtsi 不带 memory，编译产物里 `device_type="memory"` 出现 0 次。
   判据：`strings dtb | grep -c 'memory@'` 旧为 0、新为 1。
   现在改为 **数据源生成**：`dts/memory-banks.json`（板上 `tools/capture-memory.sh`
   从 `/proc/device-tree/memory/reg` 采集）+ `tools/gen-memory-dtsi.py` 构建时生成，
   DTS 里不写死容量。
2. **u-boot 打点法**（没有串口也能定位）：脚本每阶段往 eMMC 空白扇区写一个字节标记
   `mw.b ${tr} 0xNN 512; mmc write ${tr} <blk> 1`，回来 `dd` 读。实测序列：
   `0x10` 脚本执行 → `0x12` 读到 p1 → `0x21` 内核 → `0x31` DTB → `0x41` initrd → `0x51` 已 booti。
   有了它才敢断定"u-boot 全流程正常、内核被交付后立刻死"。
3. **3.86G 镜像写进 58.3G eMMC 必须把 GPT 备份表搬到盘尾**，否则 u-boot 判分区表损坏。
   `alternate_lba` 由 7,538,687 改为 122,159,103，备份 entries 写在 LBA 122,159,071。
4. **第二个 2.5G 口在 `pcie@fe190000`（pcie2x1l2，PCI 域 0004:41）**
   vendor dtsi 没启用它，只用 `pcie2x1l0/l1`；判据取自本板 iNextOS 实跑 DTB：
   `status=okay`、`reset-gpios=<&gpio4 RK_PA5 GPIO_ACTIVE_HIGH>`、`phy@fee00000`（combphy0_ps）okay。
   少这一个 = 只认到一块 RTL8125，另一口有灯不通。
5. **三个网口都没有出厂 MAC**：两块 RTL8125B 无 EEPROM、RK3588 GMAC 读不到 efuse MAC。
   内核每次开机随机 → DHCP 每次发新租约（实测 IP 从 .28 漂到 .31）。
   修法：`assets/h88k/h88k-set-mac.sh` 按 **SoC serial-number + 设备路径** 派生 `02:` 本地管理 MAC，
   由 `h88k-fix-macs.service` 在 NetworkManager 之前跑；覆盖 `r8169` 与 `st_gmac/rk_gmac-dwmac`。
6. **改 MAC 的脚本必须先记链路状态再恢复**：只 down 不 up，管理口会一直 down，
   后台/SSH 全断（踩过，表现为"只有某个口能连"）。
7. **udev 的 PATH 很窄**：脚本里 `ip`/`sha256sum` 必须写绝对路径，否则 udev 里静默失效、
   手工跑却正常。
8. **不要自己造引导链**：extlinux、自写 boot.scr、自造 initramfs 全部试过，
   最后能起的是"官方 boot.scr + fnEnv"这一条。initramfs 写日志也不可靠（官方无 initrd）。
9. **网口命名按官方（systemd 可预测名）**：`eth0`(GMAC) / `enP3p49s0` / `enP4p65s0`。
   强行改 eth0/eth1/eth2 会和 fnOS 自己的网络管理链打架，不要做。

## 三、板级 DTB 必须包含的项（CI 门禁逐条断言）

- `/memory` 三 bank（0x0020_0000+0xEFE0_0000 / 0x1_0000_0000+0x1_0000_0000 / 0x2_F000_0000+0x1000_0000）且与数据源一致
- PMIC rk806 + `rockchip,system-power-controller`
- iommu：`rockchip,rk3588-iommu` ≥10 处、`rockchip,iommu-v2` = 0
- PCIe：`fe150000`(NVMe) / `fe170000`(M.2) / `fe180000`(2.5G#1) / `fe190000`(2.5G#2) 全 okay；
  `fe190000` 必须有 `reset-gpios`
- combphy：`fee00000` / `fee10000` / `fee20000` 全 okay
- LED：`blue:net` / `amber:sata` / `green:user` / `red:work`
- gmac：`rgmii-rxid` + 厂商 tx_delay + MAC 侧复位三件套

## 四、验收命令（上板直接跑）

```sh
uname -a                                    # 6.18.18.c1145-trim
cat /proc/cmdline                           # root=PARTUUID=... cma=256M cgroup_*
grep -E "MemTotal|CmaTotal" /proc/meminfo   # 8123084 kB / 262144 kB
lspci -nn | grep -c RTL8125                 # 2
for n in /sys/class/net/*; do echo "$n $(cat $n/address) $(cat $n/operstate)"; done
cat /sys/class/leds/blue:net/trigger        # [default-on]
cat /sys/class/leds/amber:sata/trigger      # [disk-activity]
lsblk | grep -E "nvme|mmcblk1"
```

## 五、网口与多媒体：实机结论（2026-10-26 夜）

### 5.1 三个网口（V3，丝印 ETH0/ETH1/ETH2，上到下）
| 丝印 | 控制器 | 内核名 | 速率 | DT 节点 |
|---|---|---|---|---|
| ETH0 | RTL8125B | enP3p49s0 或 enP4p65s0 | 2.5G | pcie@fe180000 / fe190000 |
| ETH1 | RTL8125B | 同上（另一个） | 2.5G | 同上 |
| ETH2 | RK3588 GMAC | eth0 | 1G | ethernet@fe1b0000 |

- 两个 2.5G 分别走 `pcie@fe180000`（PCI 0003:31）与 `pcie@fe190000`（PCI 0004:41，**必须显式启用**，
  reset-gpios=<&gpio4 RK_PA5>、phy=combphy0_ps）。
- **`/ethernet@fe1b0000` 绝对不能带 `label` 属性**：stmmac 驱动拿 label 当网卡名，
  与 r8169 的默认 ethN 抢名 → `stmmac_dvr_probe: ERROR -17`（EEXIST），
  整个千兆口不出现，管理地址随探测顺序乱漂（实测 .28→.29→.30→.31→.32）。
  iStoreOS 的 DTB 就没有这条 label —— 这是逐属性对比出来的唯一实质差异。
- 三块网卡都没有出厂 MAC（8125 无 EEPROM、GMAC 读不到 efuse）→ 见 `assets/h88k/h88k-set-mac.sh`。
- 地址稳定性：`/etc/NetworkManager/conf.d/99-h88k-dhcp-client-id.conf` 里 `dhcp-client-id=mac`，
  租约跟 MAC 走，端口改名不再换 IP（不要写静态 IP，用户要求 DHCP）。

### 5.2 GPU / NPU / VPU：官方内核驱动不支持 RK3588（DTS 已按 T6 全开）
```
mali.ko        of_match = arm,mali-300/400/450/470、rockchip,rk3328-mali      ✗ 不认 arm,mali-valhall-csf
rk_vcodec.ko   of_match = rockchip,vpu-decoder-v1/v2、vpu-encoder-v1/v2        ✗ 不认 rk3588-vdec / vpu121 / vepu121
rga3.ko        of_match = rockchip,rga2 / rockchip,rga3                        ✗ 不认 rockchip,rk3588-rga（→ rga iommu bind failed）
config         DRM_PANTHOR / DRM_PANFROST / MALI_KBASE 全部未编入               ✗ RK3588 GPU 的 mainline 驱动不在内核里
```
- DTS 侧已按官方 T6 对齐（`dts/t6-align.dtsi`：gpu@fb000000、vop@fdd90000、vop_mmu、hdmi0/1、
  hdmi0/1-sound、i2s、i2c DDC、hdptxphy 等全部 okay），门禁强制 GPU/VOP/HDMI = okay。
- 实机效果：VOP 能 bound，但 rockchip-drm 组件链被 `hdmi1` 与 `hdmi0/1-sound`
  （asoc-simple-card parse error）挡住 → 仍无 `/dev/dri`。
- 要真正可用必须重编内核（PANTHOR / rkvdec2/rkvenc2 / rknpu 厂商模块），超出"官方 T6 母本"范围。

### 5.3 链路抖动的排查结论
`/var/log/h88k-linkwatch.log`（每 2 秒采样、只记变化）显示：修好 MAC 脚本后长时间零变化。
之前"突然断网"的两次都能对上时间戳：是我在活链路上跑改 MAC 的脚本（改 MAC 必须先 down）。
脚本现已加保护：`carrier=1` 的活链路一律不碰。
