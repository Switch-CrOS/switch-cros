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


def update_header_crc(h, original_sector):
    h = h.copy()
    h["hcrc"] = 0
    sector = bytearray(original_sector)
    sector[:GPT_HEADER_SIZE] = pack_header(h)
    for i in range(h["hsize"], SECTOR):
        sector[i] = 0
    h["hcrc"] = binascii.crc32(sector[:h["hsize"]]) & 0xffffffff
    sector[:GPT_HEADER_SIZE] = pack_header(h)
    return h, bytes(sector)


def name_of(entry):
    return entry[56:128].decode("utf-16le", "ignore").rstrip("\x00")


def set_type(entry, guid):
    e = bytearray(entry)
    e[0:16] = guid
    return bytes(e)


def set_name(entry, name):
    e = bytearray(entry)
    raw = name.encode("utf-16le")[:72]
    e[56:128] = b"\0" * 72
    e[56:56 + len(raw)] = raw
    return bytes(e)


def first_lba(entry):
    return struct.unpack_from("<Q", entry, 32)[0]


def last_lba(entry):
    return struct.unpack_from("<Q", entry, 40)[0]


def mbr_entry(status, ptype, first, sectors):
    return struct.pack("<B3sB3sII", status, b"\xfe\xff\xff", ptype, b"\xfe\xff\xff", first, sectors)


def load_entries(f, header):
    size = header["num_entries"] * header["entry_size"]
    return bytearray(read_at(f, header["entries_lba"] * SECTOR, size))


def get_entry(entries, header, idx):
    start = (idx - 1) * header["entry_size"]
    return bytes(entries[start:start + header["entry_size"]])


def put_entry(entries, header, idx, entry):
    start = (idx - 1) * header["entry_size"]
    entries[start:start + header["entry_size"]] = entry


def normalize_entries(entries, header):
    e1 = get_entry(entries, header, 1)
    e12 = get_entry(entries, header, 12)
    n1, n12 = name_of(e1), name_of(e12)
    if n1 in ("EFI-SYSTEM", "SWITCHROOT") and n12 == "STATE":
        fat = set_name(set_type(e1, MS_BASIC), "SWITCHROOT")
        state = set_type(e12, LINUX_DATA)
    elif n1 == "STATE" and n12 == "EFI-SYSTEM":
        fat = set_name(set_type(e12, MS_BASIC), "SWITCHROOT")
        state = set_type(e1, LINUX_DATA)
    else:
        raise RuntimeError(f"unexpected GPT entries: #1={n1!r}, #12={n12!r}")
    put_entry(entries, header, 1, fat)
    put_entry(entries, header, 12, state)
    return fat


def write_gpt(f, header_lba):
    sector = read_at(f, header_lba * SECTOR, SECTOR)
    h = parse_header(sector)
    if h["sig"] != b"EFI PART":
        raise RuntimeError(f"GPT header not found at LBA {header_lba}")
    entries = load_entries(f, h)
    fat = normalize_entries(entries, h)
    h["entries_crc"] = binascii.crc32(entries) & 0xffffffff
    h, sector_out = update_header_crc(h, sector)
    write_at(f, h["entries_lba"] * SECTOR, entries)
    write_at(f, h["current_lba"] * SECTOR, sector_out)
    return fat, h


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} IMAGE", file=sys.stderr)
        return 2
    image = Path(sys.argv[1]).expanduser()
    total_sectors = image.stat().st_size // SECTOR
    with image.open("r+b") as f:
        fat, primary = write_gpt(f, 1)
        write_gpt(f, primary["backup_lba"])
        fat_first = first_lba(fat)
        fat_sectors = last_lba(fat) - fat_first + 1
        mbr = bytearray(read_at(f, 0, SECTOR))
        mbr[:446] = b"\0" * 446
        mbr[446:462] = mbr_entry(0x00, 0x0C, fat_first, fat_sectors)
        mbr[462:478] = mbr_entry(0x00, 0xEE, 1, min(total_sectors - 1, 0xffffffff))
        mbr[478:510] = b"\0" * 32
        mbr[510:512] = b"\x55\xaa"
        write_at(f, 0, mbr)
        f.flush()
        os.fsync(f.fileno())
    print(f"GPT partition 1 is SWITCHROOT FAT-compatible data: start={fat_first} sectors={fat_sectors}")
    print("Hybrid MBR slot 1 is FAT32 LBA; slot 2 is protective GPT")

if __name__ == "__main__":
    raise SystemExit(main())
