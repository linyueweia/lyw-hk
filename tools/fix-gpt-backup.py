#!/usr/bin/env python3
"""把 GPT 的备份表/备份头搬回目标盘末尾（除写盘后必踩的一个坑）。

背景（2026-10-26 H88K 实测定论）：
  飞牛镜像只有 3.86 GiB，而 H88K 的 eMMC 是 58.3 GiB。整盘 `dd` 之后，
  **主 GPT 头里的 alternate_lba 仍指向镜像自身的末尾（约 3.86G 处）**，
  备份 GPT 表/头也不在盘尾。Linux 内核只警告并继续用主表，但
  **u-boot 的 `disk/part_efi.c` 会校验 "备份头必须在盘尾"**，
  不成立就直接判分区表损坏 → 一个分区都读不到 → 引导被跳过（表现为"刷完起不来"）。

  iStoreOS / Armbian 的镜像是 MBR，没有这个问题，所以"同一个板子刷 iStoreOS 就能起、
  刷飞牛就起不来"（2026-10-26 实测）。

做法：就地改写 —— 只动 LBA1（主头）+ 盘尾 33 个扇区（备份表 + 备份头），
  分区项、文件系统、数据区一个字节都不碰。CRC32 全部重算并回读校验。

用法：
  python3 tools/fix-gpt-backup.py /dev/mmcblk0            # 直接改设备
  python3 tools/fix-gpt-backup.py out/fnos_xxx.img        # 改镜像文件（先按目标盘容量算）
  python3 tools/fix-gpt-backup.py /dev/mmcblk0 --dry-run  # 只看差多少
  python3 tools/fix-gpt-backup.py img --image-sectors N   # 镜像预扩容到 N 扇区

安全设计：
  · 只接受 "EFI PART" 签名，否则拒绝；不是 GPT 就什么都不写
  · 分区项 CRC 必须自洽（否则说明表已损坏，直接退出，不猜）
  · 写入后回读校验：主头 alternate_lba == 盘尾、备份头签名与 my_lba 正确、两处 CRC 自洽
"""

import argparse
import os
import struct
import sys
import zlib

SIG = b"EFI PART"
HDR_SIZE = 92
ENTRY_SZ = 128
ENTRY_CNT = 128
ENT_TABLE_SECTORS = ENTRY_SZ * ENTRY_CNT // 512  # 32


def crc32(b) -> int:
    return zlib.crc32(b) & 0xFFFFFFFF


def fix_header(hdr: bytes, my_lba: int, alt_lba: int, ent_lba: int, last_usable: int) -> bytes:
    h = bytearray(hdr[:512])
    struct.pack_into("<Q", h, 24, my_lba)
    struct.pack_into("<Q", h, 32, alt_lba)
    struct.pack_into("<Q", h, 48, last_usable)
    struct.pack_into("<Q", h, 72, ent_lba)
    struct.pack_into("<I", h, 16, 0)
    struct.pack_into("<I", h, 16, crc32(h[:HDR_SIZE]))
    return bytes(h)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--image-sectors", type=int, default=0,
                    help="对镜像文件操作时，按这个扇区数当作目标盘容量（默认=文件自身大小）")
    a = ap.parse_args()

    is_file = os.path.isfile(a.target)
    if is_file:
        total_sectors = a.image_sectors or (os.path.getsize(a.target) // 512)
        fh = open(a.target, "r+b" if not a.dry_run else "rb")
    else:
        with open(a.target, "rb") as probe:
            probe.seek(0, os.SEEK_END)
            total_sectors = probe.tell() // 512
        fh = open(a.target, "r+b" if not a.dry_run else "rb")

    last_lba = total_sectors - 1

    fh.seek(512)
    hdr = fh.read(512)
    if hdr[:8] != SIG:
        print("✗ 不是 GPT（LBA1 无 'EFI PART' 签名）—— 什么都不做")
        return 2

    my_lba, alt_lba, ent_lba = (struct.unpack_from("<Q", hdr, 24)[0],
                               struct.unpack_from("<Q", hdr, 32)[0],
                               struct.unpack_from("<Q", hdr, 72)[0])
    stored_hcrc = struct.unpack_from("<I", hdr, 16)[0]
    chk = bytearray(hdr[:HDR_SIZE]); struct.pack_into("<I", chk, 16, 0)
    if crc32(chk) != stored_hcrc:
        print("✗ 主头 CRC 不自洽（表已损坏）—— 拒绝改写，请人工介入")
        return 2

    fh.seek(ent_lba * 512)
    entries = fh.read(ENTRY_SZ * ENTRY_CNT)
    stored_ecrc = struct.unpack_from("<I", hdr, 88)[0]
    if crc32(entries) != stored_ecrc:
        print("✗ 分区项 CRC 不自洽 —— 拒绝改写")
        return 2

    print(f"目标: {a.target}  总扇区 {total_sectors}  末 LBA {last_lba}")
    print(f"现状: my_lba={my_lba}  alternate_lba={alt_lba}  entries_lba={ent_lba}")
    if alt_lba == last_lba:
        print("✓ 已经是盘尾布局，无需修改")
        return 0
    print(f"待修: alternate_lba {alt_lba} → {last_lba}（差 {last_lba - alt_lba} 扇区）")
    if a.dry_run:
        print("（--dry-run：不写）")
        return 0

    newp = fix_header(hdr, 1, last_lba, 2, last_lba - 1 - ENT_TABLE_SECTORS)
    newb = fix_header(hdr, last_lba, 1, last_lba - ENT_TABLE_SECTORS, last_lba - 1 - ENT_TABLE_SECTORS)
    fh.seek(512); fh.write(newp)
    fh.seek((last_lba - ENT_TABLE_SECTORS) * 512); fh.write(entries + newb)
    fh.flush(); os.fsync(fh.fileno())

    # 回读校验
    fh.seek(512); p = fh.read(512)
    fh.seek(last_lba * 512); b = fh.read(512)
    ok = True
    for name, blk, exp_my, exp_alt in (("primary", p, 1, last_lba), ("backup", b, last_lba, 1)):
        if blk[:8] != SIG:
            print(f"✗ {name} 签名缺失"); ok = False; continue
        g_my, g_alt = struct.unpack_from("<Q", blk, 24)[0], struct.unpack_from("<Q", blk, 32)[0]
        h = bytearray(blk[:HDR_SIZE]); stored = struct.unpack_from("<I", h, 16)[0]
        struct.pack_into("<I", h, 16, 0)
        good = (g_my == exp_my and g_alt == exp_alt and crc32(h) == stored)
        print(f"{'✓' if good else '✗'} {name}: my_lba={g_my} alternate_lba={g_alt} crc={'OK' if crc32(h)==stored else 'BAD'}")
        ok &= good
    fh.close()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
