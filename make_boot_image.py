#!/usr/bin/env python3
"""Cria a imagem NVBI consumida pelo bootloader da A25L80P."""

import argparse
import pathlib
import struct
import subprocess
import zlib

MAGIC = 0x4E564249       # "NVBI"
VERSION = 1
HEADER_SIZE = 32
SRAM_BASE = 0x02000000


def entry_from_elf(elf: pathlib.Path, nm: str) -> int:
    output = subprocess.check_output([nm, "-n", str(elf)], text=True)
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[2] == "_start":
            return int(fields[0], 16)
    raise RuntimeError("simbolo _start nao encontrado no ELF")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("elf", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--objcopy", default="riscv32-unknown-elf-objcopy")
    parser.add_argument("--nm", default="riscv32-unknown-elf-nm")
    args = parser.parse_args()

    raw = args.output.with_suffix(".bin")
    subprocess.check_call([args.objcopy, "-O", "binary", str(args.elf), str(raw)])
    payload = raw.read_bytes()
    entry = entry_from_elf(args.elf, args.nm)

    if not payload:
        raise RuntimeError("ELF nao gerou payload")
    if entry < SRAM_BASE:
        raise RuntimeError("_start nao esta na SDRAM")

    image_crc = zlib.crc32(payload) & 0xFFFFFFFF
    header = struct.pack("<8I", MAGIC, VERSION, HEADER_SIZE, len(payload),
                         SRAM_BASE, entry, image_crc, 0)
    header_crc = zlib.crc32(header) & 0xFFFFFFFF
    header = header[:-4] + struct.pack("<I", header_crc)
    args.output.write_bytes(header + payload)

    print(f"imagem: {args.output}")
    print(f"payload: {len(payload)} bytes; _start=0x{entry:08X}; CRC=0x{image_crc:08X}")


if __name__ == "__main__":
    main()
