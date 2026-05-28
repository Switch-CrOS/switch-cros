#!/usr/bin/env python3
import binascii
import os
import struct
import sys
from pathlib import Path

SECTOR = 512
GPT_HEADER = "<8sIIIIQQQQ16sQIII"
GPT_HEADER_SIZE = struct.calcsize(GPT_HEADER)
MS_BASIC = bytes.fromhex("a2a0d0ebe5b9334487c068b6b72699c7")
LINUX_DATA = bytes.fromhex("af3dc60f838472478e793d69d8477de4")

# New physical order: FAT first, then small ChromeOS metadata/kernel slots,
# rootfs, ROOT-B, and stateful last. Partition numbers remain ChromeOS-ish.
ORDER = [1, 2, 4, 8, 11, 6, 7, 9, 10, 3, 5, 12]
ALIGN = 2048


def align(x, a=ALIGN):
    return ((x + a - 1) // a) * a


def read_at(f, off, size):
    f.seek(off)
    data = f.read(size)
    if len(data) != size:
        raise RuntimeError(f"short read at {off}")
    return data


def write_at(f, off, data):
    f.seek(off)
    f.write(data)


def parse_header(buf):
    vals = struct.unpack(GPT_HEADER, buf[:GPT_HEADER_SIZE])
    keys = ["sig", "rev", "hsize", "hcrc", "reserved", "current_lba", "backup_lba", "first_usable", "last_usable", "disk_guid", "entries_lba", "num_entries", "entry_size", "entries_crc"]
    return dict(zip(keys, vals))


def pack_header(h):
    return struct.pack(GPT_HEADER, h["sig"], h["rev"], h["hsize"], h["hcrc"], h["reserved"], h["current_lba"], h["backup_lba"], h["first_usable"], h["last_usable"], h["disk_guid"], h["entries_lba"], h["num_entries"], h["entry_size"], h["entries_crc"])


def header_sector(h):
    h = h.copy()
    h["hcrc"] = 0
    sector = bytearray(SECTOR)
    sector[:GPT_HEADER_SIZE] = pack_header(h)
    h["hcrc"] = binascii.crc32(sector[:h["hsize"]]) & 0xffffffff
    sector[:GPT_HEADER_SIZE] = pack_header(h)
    return bytes(sector)


def name_of(e):
    return e[56:128].decode("utf-16le", "ignore").rstrip("\x00")


def set_name(e, name):
    b = bytearray(e)
    raw = name.encode("utf-16le")[:72]
    b[56:128] = b"\0" * 72
    b[56:56+len(raw)] = raw
    return bytes(b)


def set_type(e, guid):
    b = bytearray(e)
    b[0:16] = guid
    return bytes(b)


def first(e):
    return struct.unpack_from("<Q", e, 32)[0]


def last(e):
    return struct.unpack_from("<Q", e, 40)[0]


def size(e):
    return last(e) - first(e) + 1


def set_range(e, start, sectors):
    b = bytearray(e)
    struct.pack_into("<Q", b, 32, start)
    struct.pack_into("<Q", b, 40, start + sectors - 1)
    return bytes(b)


def get_entry(entries, entry_size, idx):
    s = (idx - 1) * entry_size
    return bytes(entries[s:s+entry_size])


def put_entry(entries, entry_size, idx, e):
    s = (idx - 1) * entry_size
    entries[s:s+entry_size] = e


def copy_region(src, dst, src_lba, dst_lba, sectors):
    remaining = sectors * SECTOR
    src.seek(src_lba * SECTOR)
    dst.seek(dst_lba * SECTOR)
    bufsize = 16 * 1024 * 1024
    while remaining:
        chunk = src.read(min(bufsize, remaining))
        if not chunk:
            raise RuntimeError("short partition copy")
        dst.write(chunk)
        remaining -= len(chunk)


def mbr_entry(status, ptype, start, sectors):
    return struct.pack("<B3sB3sII", status, b"\xfe\xff\xff", ptype, b"\xfe\xff\xff", start, sectors)


def main():
    if len(sys.argv) not in (2, 3):
        print(f"usage: {sys.argv[0]} SRC_IMAGE [DST_IMAGE]", file=sys.stderr)
        return 2
    src_path = Path(sys.argv[1]).expanduser()
    dst_path = Path(sys.argv[2]).expanduser() if len(sys.argv) == 3 else src_path.with_suffix(".hekate.bin")
    total_sectors = src_path.stat().st_size // SECTOR
    with src_path.open("rb") as src:
        ph = parse_header(read_at(src, SECTOR, SECTOR))
        if ph["sig"] != b"EFI PART":
            raise RuntimeError("no GPT")
        entries_len = ph["num_entries"] * ph["entry_size"]
        old_entries = bytearray(read_at(src, ph["entries_lba"] * SECTOR, entries_len))
        old = {i: get_entry(old_entries, ph["entry_size"], i) for i in range(1, ph["num_entries"] + 1)}
        if name_of(old[1]) != "SWITCHROOT" or name_of(old[12]) != "STATE":
            raise RuntimeError(f"run hekate-fix-gpt-mbr.py first; saw #1={name_of(old[1])!r}, #12={name_of(old[12])!r}")
        new_entries = bytearray(entries_len)
        cursor = 2048
        new_ranges = {}
        for idx in ORDER:
            sectors = size(old[idx])
            if sectors > 1:
                cursor = align(cursor)
            new_ranges[idx] = (cursor, sectors)
            cursor += sectors
        if cursor + 33 > total_sectors:
            raise RuntimeError("image too small for reordered layout")
        dst_path.parent.mkdir(parents=True, exist_ok=True)
        with dst_path.open("wb") as dst:
            dst.truncate(total_sectors * SECTOR)
            for idx in ORDER:
                start, sectors = new_ranges[idx]
                e = old[idx]
                if idx == 1:
                    e = set_name(set_type(e, MS_BASIC), "SWITCHROOT")
                if idx == 12:
                    e = set_type(e, LINUX_DATA)
                e = set_range(e, start, sectors)
                put_entry(new_entries, ph["entry_size"], idx, e)
                copy_region(src, dst, first(old[idx]), start, sectors)
            entries_crc = binascii.crc32(new_entries) & 0xffffffff
            primary = ph.copy()
            primary.update({"current_lba": 1, "backup_lba": total_sectors - 1, "first_usable": 34, "last_usable": total_sectors - 34, "entries_lba": 2, "entries_crc": entries_crc})
            backup = primary.copy()
            backup.update({"current_lba": total_sectors - 1, "backup_lba": 1, "entries_lba": total_sectors - 33})
            mbr = bytearray(SECTOR)
            fat_start, fat_sectors = new_ranges[1]
            mbr[446:462] = mbr_entry(0, 0x0C, fat_start, fat_sectors)
            mbr[462:478] = mbr_entry(0, 0xEE, 1, min(total_sectors - 1, 0xffffffff))
            mbr[510:512] = b"\x55\xaa"
            write_at(dst, 0, mbr)
            write_at(dst, 2 * SECTOR, new_entries)
            write_at(dst, (total_sectors - 33) * SECTOR, new_entries)
            write_at(dst, SECTOR, header_sector(primary))
            write_at(dst, (total_sectors - 1) * SECTOR, header_sector(backup))
            dst.flush(); os.fsync(dst.fileno())
    print(dst_path)
    print(f"p1 SWITCHROOT starts at LBA {new_ranges[1][0]} and is MBR slot 1 FAT32")

if __name__ == "__main__":
    raise SystemExit(main())
