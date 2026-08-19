#ifndef SERIAL_BOOT_H
#define SERIAL_BOOT_H

/*
 * Protocolo simples de atualizacao de firmware da flash SPI via UART.
 *
 * Formato dos pacotes (little-endian), todos com CRC32 (poly 0xEDB88320,
 * inicial 0xFFFFFFFF, XOR final 0xFFFFFFFF - mesmo algoritmo do bootloader):
 *
 *  Handshake: PC envia byte 'U' repetidamente ate receber 'C' do device.
 *
 *  Pacote START (recebido apos o handshake), 16 bytes:
 *      u32 magic       ("NVUP" = 0x50555654 na ordem de bytes recebida)
 *      u32 image_size  (tamanho total da imagem .nvbi, em bytes)
 *      u32 image_crc32 (CRC32 da imagem completa)
 *      u32 packet_crc32 (CRC32 dos 12 bytes anteriores deste pacote)
 *  Resposta do device: SERIAL_BOOT_ACK ou SERIAL_BOOT_NAK.
 *
 *  Pacotes DATA (um ou mais, ate completar image_size bytes), formato:
 *      u16 seq          (numero sequencial iniciando em 0)
 *      u16 len          (quantidade de bytes validos em payload, 1..256)
 *      u8  payload[len]
 *      u32 packet_crc32 (CRC32 de seq+len+payload)
 *  Resposta do device por pacote: SERIAL_BOOT_ACK ou SERIAL_BOOT_NAK
 *  (repita o mesmo seq em caso de NAK).
 *
 *  Ao final (todos os bytes recebidos e CRC32 da imagem conferido), o device
 *  apaga e grava a flash SPI e responde:
 *      SERIAL_BOOT_DONE  em caso de sucesso
 *      SERIAL_BOOT_ERR   em caso de falha, seguido de um relatorio de 7 bytes:
 *          u8  protocol_code  (codigo generico, ver SERIAL_BOOT_ERR_* no .c)
 *          u8  stage          (SERIAL_BOOT_STAGE_*, em que etapa falhou)
 *          u8  driver_code    (codigo de spi_flash.h, 0 se nao aplicavel)
 *          u32 offset         (offset na flash SPI relacionado a falha)
 *      Isso substitui o uso de texto de depuracao na UART para diagnostico:
 *      o texto (alt_printf) continua sendo emitido para quem observa um
 *      terminal serial diretamente, mas a ferramenta host deve decodificar
 *      apenas os codigos binarios acima, que sao a fonte de verdade.
 */

#include "alt_types.h"

#define SERIAL_BOOT_MAGIC        0x50555654U /* "TVUP" ao ler em LE = 'T','V','U','P' -> ver .c */
#define SERIAL_BOOT_HELLO        'U'
#define SERIAL_BOOT_READY        'C'
#define SERIAL_BOOT_ACK          0x06U
#define SERIAL_BOOT_NAK          0x15U
#define SERIAL_BOOT_DONE         0x04U
#define SERIAL_BOOT_ERR          0x15U

#define SERIAL_BOOT_MAX_PACKET   256U
#define SERIAL_BOOT_MAX_RETRIES  5U

/* Etapas reportadas no relatorio de erro (ver formato de SERIAL_BOOT_ERR
 * acima). Mantido em sincronia com a lista de mesmo nome no host
 * (serial_flash_update.py). */
#define SERIAL_BOOT_STAGE_NONE          0U
#define SERIAL_BOOT_STAGE_ERASE         1U
#define SERIAL_BOOT_STAGE_PROGRAM       2U
#define SERIAL_BOOT_STAGE_VERIFY_READ   3U
#define SERIAL_BOOT_STAGE_VERIFY_CRC    4U

/*
 * Aguarda pelo handshake de atualizacao serial por um numero de iteracoes de
 * polling (nao depende de timer). Retorna 1 se o handshake 'U' foi recebido
 * (e 'C' ja foi respondido), 0 caso contrario (timeout).
 */
int serial_boot_wait_handshake(alt_u32 uart_base, alt_u32 poll_iterations);

/*
 * Executa o protocolo completo de atualizacao: recebe a imagem em buffer
 * (staging), confere o CRC32 total, apaga e grava a flash SPI, verifica e
 * responde ao host. Retorna 0 em sucesso, ou codigo de erro negativo.
 *
 * staging_base/staging_size definem uma area de RAM (tipicamente na SDRAM)
 * usada para armazenar a imagem recebida antes de gravar a flash.
 * flash_total_bytes e o tamanho do chip SPI NOR detectado (ver
 * spi_flash_detect() em spi_flash.h), usado para validar o tamanho da imagem
 * recebida antes de apagar/gravar. image_offset e o offset onde a imagem
 * (cabecalho + app) comeca de fato na flash -- 0 normalmente, ou o inicio
 * do setor 1 (0x10000) em chips com quirk_block0_unreliable, para nunca
 * apagar/gravar o bloco 0 desses chips (ver main.c).
 */
int serial_boot_run(alt_u32 uart_base, alt_u32 spi_base, alt_u32 flash_slave,
                     alt_u8 *staging_base, alt_u32 staging_size,
                     alt_u32 flash_total_bytes, alt_u32 image_offset);

#endif /* SERIAL_BOOT_H */
