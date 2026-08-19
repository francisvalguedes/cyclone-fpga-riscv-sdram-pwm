#ifndef CRC32_H
#define CRC32_H

#include "alt_types.h"

/*
 * CRC32 usado tanto na validacao do cabecalho/imagem na flash SPI (main.c)
 * quanto no protocolo de atualizacao via serial (serial_boot.c). Poly
 * 0xEDB88320, sem init/xorout embutidos aqui -- o chamador passa o crc
 * inicial (tipicamente 0xFFFFFFFF) e aplica o XOR final (0xFFFFFFFF) no
 * resultado, igual ao zlib.crc32 usado no host (serial_flash_update.py).
 */
alt_u32 crc32_update(alt_u32 crc, const alt_u8 *data, alt_u32 length);

#endif /* CRC32_H */
