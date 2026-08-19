#!/usr/bin/env python3
"""Gera um .bin inútil, com cabecalho NVBI (mesmo formato de make_boot_image.py) e um
payload de teste com padrao conhecido, para gravar na serial flash via
serial_flash_update.py sem precisar compilar um firmware de verdade.

Uso:
    python make_test_bin.py --size 256 --output test.bin
    python make_test_bin.py --size 4096 --pattern fixed --byte 0xAA --output test.bin
    python serial_flash_update.py --port COM8 --baud 115200 test.bin

ATENCAO: apos gravar este arquivo, a serial flash fica com um payload que NAO e
firmware de verdade (so um padrao de teste). Se o proximo boot for normal
(sem segurar o botao de atualizacao), o bootloader vai tentar executar esse
payload -- grave um firmware valido de novo depois do teste.
"""

import argparse
import pathlib
import struct
import sys
import zlib

MAGIC = 0x4E564249       # "NVBI"
VERSION = 1
HEADER_SIZE = 32
SRAM_BASE = 0x02000000   # NEW_SDRAM_CONTROLLER_0_BASE


def make_pattern(size: int, pattern: str, byte_value: int, text: bytes) -> bytes:
    if pattern == "incrementing":
        return bytes((i & 0xFF) for i in range(size))
    if pattern == "fixed":
        return bytes([byte_value]) * size
    if pattern == "ascii":
        if not text:
            raise ValueError("--text nao pode ser vazio para pattern=ascii")
        return (text * (size // len(text) + 1))[:size]
    raise ValueError(f"padrao desconhecido: {pattern}")


def build_nvbi_image(payload: bytes, load_address: int, entry_address: int) -> bytes:
    """Monta cabecalho + payload no mesmo formato de make_boot_image.py
    (struct "<8I": magic, version, header_size, image_size, load_address,
    entry_address, image_crc32, header_crc32)."""
    image_crc = zlib.crc32(payload) & 0xFFFFFFFF
    header = struct.pack("<8I", MAGIC, VERSION, HEADER_SIZE, len(payload),
                         load_address, entry_address, image_crc, 0)
    header_crc = zlib.crc32(header) & 0xFFFFFFFF
    header = header[:-4] + struct.pack("<I", header_crc)
    return header + payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("test.bin"),
                         help="arquivo .bin de saida (padrao: test.bin)")
    parser.add_argument("--size", type=int, default=256,
                         help="tamanho do payload em bytes, sem contar o cabecalho (padrao: 256)")
    parser.add_argument("--pattern", choices=["incrementing", "fixed", "ascii"],
                         default="incrementing", help="padrao de dados (padrao: incrementing)")
    parser.add_argument("--byte", type=lambda s: int(s, 0), default=0xFF,
                         help="valor do byte fixo para --pattern=fixed (padrao: 0xFF)")
    parser.add_argument("--text", default="TESTE ",
                         help="texto repetido para --pattern=ascii (padrao: 'TESTE ')")
    parser.add_argument("--load-address", type=lambda s: int(s, 0), default=SRAM_BASE,
                         help=f"load_address/entry_address gravados no cabecalho "
                              f"(padrao: 0x{SRAM_BASE:08X}, base da SDRAM)")
    args = parser.parse_args()

    if args.size <= 0:
        print("Erro: --size deve ser maior que zero.", file=sys.stderr)
        return 1
    if (args.load_address & 0x3) != 0:
        print("Erro: --load-address deve ser multiplo de 4.", file=sys.stderr)
        return 1

    payload = make_pattern(args.size, args.pattern, args.byte & 0xFF,
                           args.text.encode("ascii"))
    image = build_nvbi_image(payload, args.load_address, args.load_address)

    args.output.write_bytes(image)

    print(f"Gerado: {args.output} ({len(image)} bytes = {HEADER_SIZE} de "
          f"cabecalho + {len(payload)} de payload), padrao={args.pattern}")
    print("Aviso: payload de teste, nao e firmware de verdade -- grave um "
          "firmware valido depois de testar a gravacao.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
