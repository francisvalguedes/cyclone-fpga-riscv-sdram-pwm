/*
 * Atualizacao de firmware da flash SPI via UART (polling, sem interrupcoes).
 *
 * Consulte serial_boot.h para a descricao completa do protocolo.
 */

#include <stddef.h>

#include "serial_boot.h"
#include "system.h"
#include "sys/alt_stdio.h"
#include "altera_avalon_uart_regs.h"
#include "spi_flash.h"
#include "crc32.h"

/* Normalmente nenhum alt_printf() (texto solto) e usado neste arquivo: a
 * partir do handshake ha uma ferramenta host (serial_flash_update.py) do
 * outro lado decodificando o protocolo binario nesta mesma UART (ACK/NAK por
 * pacote, DONE/ERR + relatorio estruturado ao final -- ver serial_boot.h).
 * Ela e quem exibe texto ao usuario a partir dos codigos.
 *
 * EXCECAO DIAGNOSTICA TEMPORARIA: os lacos de erase/gravacao/verificacao
 * abaixo ganharam um alt_printf por operacao (ver SERIAL_BOOT_VERBOSE_COPY)
 * porque o sintoma investigado agora e a placa TRAVAR (sem retornar erro
 * algum) durante a gravacao -- nesse caso o protocolo binario nunca chega a
 * ser enviado, entao a unica pista de onde travou e a ultima linha de texto
 * impressa antes do silencio. serial_flash_update.py ja ignora texto solto
 * de boa enquanto espera DONE/ERR, entao isso nao quebra o host; e so para
 * ser removido (ou desligado via SERIAL_BOOT_VERBOSE_COPY 0) quando o
 * travamento estiver resolvido. */
#define SERIAL_BOOT_VERBOSE_COPY 1

/* Numero de iteracoes de polling usadas como "timeout" de byte dentro de um
 * pacote em andamento. Nao depende de timer; e apenas um limite generoso
 * para nao travar para sempre se o host parar de enviar. */
#define SERIAL_BOOT_BYTE_TIMEOUT_POLLS   20000000U

#define SERIAL_BOOT_START_PACKET_BYTES   16U
#define SERIAL_BOOT_DATA_HEADER_BYTES    4U  /* seq(2) + len(2) */
#define SERIAL_BOOT_DATA_CRC_BYTES        4U

#define SERIAL_BOOT_ERR_TIMEOUT          (-1)
#define SERIAL_BOOT_ERR_CRC              (-2)
#define SERIAL_BOOT_ERR_MAGIC            (-3)
#define SERIAL_BOOT_ERR_SIZE             (-4)
#define SERIAL_BOOT_ERR_SEQ              (-5)
#define SERIAL_BOOT_ERR_FLASH            (-6)
#define SERIAL_BOOT_ERR_VERIFY           (-7)

/* NAO reexecutar erase/gravacao apos um timeout aguardando WIP=0: um timeout
 * de software nao prova que a operacao no chip falhou, so que ela nao
 * terminou dentro do orcamento de polling. Reenviar WRITE_ENABLE + um novo
 * comando de erase/gravacao enquanto a flash SPI pode ainda estar ocupada
 * internamente terminando a operacao anterior e comportamento nao
 * especificado pela maioria dos chips NOR SPI e pode confundir o
 * interpretador de comandos do chip (foi tentado aqui antes e piorou o
 * sintoma: leituras de JEDEC ID passaram a falhar logo em seguida). Se uma
 * operacao estourar o orcamento de polling, o correto e aumentar o orcamento
 * (ver SPI_FLASH_ERASE_READY_POLLS em spi_flash.c) e/ou reportar a falha, nao
 * insistir imediatamente. */

static void uart_putc(alt_u32 uart_base, alt_u8 c)
{
    while ((IORD_ALTERA_AVALON_UART_STATUS(uart_base) &
            ALTERA_AVALON_UART_STATUS_TRDY_MSK) == 0U) {
        /* aguarda transmissor livre */
    }
    IOWR_ALTERA_AVALON_UART_TXDATA(uart_base, c);
}

/* Retorna 1 e grava o byte em *out se recebido dentro do timeout; 0 se
 * esgotou o timeout sem receber nada. */
static int uart_getc_timeout(alt_u32 uart_base, alt_u8 *out, alt_u32 polls)
{
    alt_u32 status;
    alt_u32 i;

    for (i = 0U; i < polls; ++i) {
        status = IORD_ALTERA_AVALON_UART_STATUS(uart_base);
        IOWR_ALTERA_AVALON_UART_STATUS(uart_base, 0U); /* limpa erros */
        if ((status & ALTERA_AVALON_UART_STATUS_RRDY_MSK) != 0U) {
            *out = (alt_u8)IORD_ALTERA_AVALON_UART_RXDATA(uart_base);
            return 1;
        }
    }
    return 0;
}

static alt_u32 load_le32(const alt_u8 *p)
{
    return ((alt_u32)p[0]) | ((alt_u32)p[1] << 8) |
           ((alt_u32)p[2] << 16) | ((alt_u32)p[3] << 24);
}

static alt_u32 load_le16(const alt_u8 *p)
{
    return ((alt_u32)p[0]) | ((alt_u32)p[1] << 8);
}

static void uart_put_u32_le(alt_u32 uart_base, alt_u32 value)
{
    uart_putc(uart_base, (alt_u8)value);
    uart_putc(uart_base, (alt_u8)(value >> 8));
    uart_putc(uart_base, (alt_u8)(value >> 16));
    uart_putc(uart_base, (alt_u8)(value >> 24));
}

/* Envia o relatorio de erro estruturado descrito em serial_boot.h: byte ERR,
 * seguido de protocol_code/stage/driver_code/offset. driver_result deve ser
 * o retorno bruto (0 ou negativo) de uma chamada spi_flash_*, ou 0 quando a
 * falha nao vem dessa camada (ex.: CRC da imagem completa). */
static void send_error_report(alt_u32 uart_base, int protocol_code,
                               alt_u8 stage, int driver_result,
                               alt_u32 offset)
{
    uart_putc(uart_base, SERIAL_BOOT_ERR);
    uart_putc(uart_base, (alt_u8)(-protocol_code));
    uart_putc(uart_base, stage);
    uart_putc(uart_base, (alt_u8)((driver_result != 0) ? -driver_result : 0));
    uart_put_u32_le(uart_base, offset);
}

int serial_boot_wait_handshake(alt_u32 uart_base, alt_u32 poll_iterations)
{
    alt_u8 c;

    if (uart_getc_timeout(uart_base, &c, poll_iterations) == 0) {
        return 0;
    }
    if (c != (alt_u8)SERIAL_BOOT_HELLO) {
        return 0;
    }

    /* Drena eventuais 'U' extras que o host manda em rajada. */
    while (uart_getc_timeout(uart_base, &c, 1000U) != 0) {
        if (c != (alt_u8)SERIAL_BOOT_HELLO) {
            break;
        }
    }

    uart_putc(uart_base, (alt_u8)SERIAL_BOOT_READY);
    return 1;
}

/* Le exatamente 'length' bytes com timeout por byte. Retorna 0 em sucesso,
 * SERIAL_BOOT_ERR_TIMEOUT se algum byte nao chegar a tempo. */
static int uart_read_exact(alt_u32 uart_base, alt_u8 *dest, alt_u32 length)
{
    alt_u32 i;

    for (i = 0U; i < length; ++i) {
        if (uart_getc_timeout(uart_base, &dest[i],
                               SERIAL_BOOT_BYTE_TIMEOUT_POLLS) == 0) {
            return SERIAL_BOOT_ERR_TIMEOUT;
        }
    }
    return 0;
}

int serial_boot_run(alt_u32 uart_base, alt_u32 spi_base, alt_u32 flash_slave,
                     alt_u8 *staging_base, alt_u32 staging_size,
                     alt_u32 flash_total_bytes, alt_u32 image_offset)
{
    alt_u8 start_packet[SERIAL_BOOT_START_PACKET_BYTES];
    alt_u8 header[SERIAL_BOOT_DATA_HEADER_BYTES];
    alt_u8 payload[SERIAL_BOOT_MAX_PACKET];
    alt_u8 packet_crc_bytes[SERIAL_BOOT_DATA_CRC_BYTES];
    alt_u32 image_size;
    alt_u32 image_crc32;
    alt_u32 received;
    alt_u32 expected_seq;
    alt_u32 crc;
    alt_u32 offset;
    alt_u32 chunk;
    alt_u32 block_offset;
    alt_u8 verify[SPI_FLASH_PAGE_BYTES];
    int result;

    /* --- Pacote START --- */
    result = uart_read_exact(uart_base, start_packet,
                              sizeof(start_packet));
    if (result != 0) {
        return result;
    }

    crc = crc32_update(0xFFFFFFFFU, start_packet, 12U) ^ 0xFFFFFFFFU;
    if (crc != load_le32(&start_packet[12])) {
        uart_putc(uart_base, SERIAL_BOOT_NAK);
        return SERIAL_BOOT_ERR_CRC;
    }

    if (load_le32(&start_packet[0]) != SERIAL_BOOT_MAGIC) {
        uart_putc(uart_base, SERIAL_BOOT_NAK);
        return SERIAL_BOOT_ERR_MAGIC;
    }

    image_size = load_le32(&start_packet[4]);
    image_crc32 = load_le32(&start_packet[8]);

    if ((image_size == 0U) || (image_size > staging_size) ||
        (image_size > (flash_total_bytes - image_offset))) {
        uart_putc(uart_base, SERIAL_BOOT_NAK);
        return SERIAL_BOOT_ERR_SIZE;
    }

    uart_putc(uart_base, SERIAL_BOOT_ACK);

    /* --- Pacotes DATA --- */
    received = 0U;
    expected_seq = 0U;

    while (received < image_size) {
        result = uart_read_exact(uart_base, header, sizeof(header));
        if (result != 0) {
            return result;
        }

        {
            alt_u32 seq = load_le16(&header[0]);
            alt_u32 len = load_le16(&header[2]);

            if ((len == 0U) || (len > SERIAL_BOOT_MAX_PACKET) ||
                (len > (image_size - received))) {
                uart_putc(uart_base, SERIAL_BOOT_NAK);
                return SERIAL_BOOT_ERR_SIZE;
            }

            result = uart_read_exact(uart_base, payload, len);
            if (result != 0) {
                return result;
            }

            result = uart_read_exact(uart_base, packet_crc_bytes,
                                      sizeof(packet_crc_bytes));
            if (result != 0) {
                return result;
            }

            crc = crc32_update(0xFFFFFFFFU, header, sizeof(header));
            crc = crc32_update(crc, payload, len) ^ 0xFFFFFFFFU;

            if (crc != load_le32(packet_crc_bytes)) {
                uart_putc(uart_base, SERIAL_BOOT_NAK);
                continue; /* host deve reenviar o mesmo seq */
            }

            if (seq != expected_seq) {
                uart_putc(uart_base, SERIAL_BOOT_NAK);
                continue;
            }

            {
                alt_u32 i;
                for (i = 0U; i < len; ++i) {
                    staging_base[received + i] = payload[i];
                }
            }

            received += len;
            expected_seq++;
            uart_putc(uart_base, SERIAL_BOOT_ACK);
        }
    }

    /* --- Confere CRC32 da imagem completa --- */
    crc = crc32_update(0xFFFFFFFFU, staging_base, image_size) ^ 0xFFFFFFFFU;
    if (crc != image_crc32) {
        send_error_report(uart_base, SERIAL_BOOT_ERR_CRC,
                           SERIAL_BOOT_STAGE_NONE, 0, 0U);
        return SERIAL_BOOT_ERR_CRC;
    }

    /* --- Apaga blocos necessarios ---
     * block_offset e endereco ABSOLUTO na flash (soma image_offset): o
     * setor 0 nunca entra nesse laço quando image_offset >= 64K (chips com
     * quirk_block0_unreliable -- ver spi_flash.h e main.c). */
    for (block_offset = image_offset; block_offset < (image_offset + image_size);
         block_offset += SPI_FLASH_BLOCK_BYTES) {
#if SERIAL_BOOT_VERBOSE_COPY
        alt_printf("E@%x\n", (unsigned long)block_offset);
#endif
        result = spi_flash_erase_block_64k(spi_base, flash_slave, block_offset);
#if SERIAL_BOOT_VERBOSE_COPY
        alt_printf("E<-%x\n", (unsigned long)result);
#endif
        if (result != 0) {
            send_error_report(uart_base, SERIAL_BOOT_ERR_FLASH,
                               SERIAL_BOOT_STAGE_ERASE, result, block_offset);
            return SERIAL_BOOT_ERR_FLASH;
        }
    }

    /* --- Grava pagina a pagina ---
     * offset aqui e RELATIVO ao inicio da imagem (para indexar
     * staging_base corretamente); o endereco de flash usado em cada
     * chamada e image_offset + offset. */
    for (offset = 0U; offset < image_size; offset += chunk) {
        chunk = ((image_size - offset) > SPI_FLASH_PAGE_BYTES) ?
                SPI_FLASH_PAGE_BYTES : (image_size - offset);
#if SERIAL_BOOT_VERBOSE_COPY
        alt_printf("P@%x\n", (unsigned long)(image_offset + offset));
#endif
        result = spi_flash_write(spi_base, flash_slave, image_offset + offset,
                              staging_base + offset, chunk);
#if SERIAL_BOOT_VERBOSE_COPY
        alt_printf("P<-%x\n", (unsigned long)result);
#endif
        if (result != 0) {
            send_error_report(uart_base, SERIAL_BOOT_ERR_FLASH,
                               SERIAL_BOOT_STAGE_PROGRAM, result,
                               image_offset + offset);
            return SERIAL_BOOT_ERR_FLASH;
        }
    }

    /* --- Verifica CRC32 lendo de volta da flash --- */
    crc = 0xFFFFFFFFU;
    for (offset = 0U; offset < image_size; offset += chunk) {
        chunk = ((image_size - offset) > sizeof(verify)) ? sizeof(verify) :
                (image_size - offset);
#if SERIAL_BOOT_VERBOSE_COPY
        alt_printf("V@%x\n", (unsigned long)(image_offset + offset));
#endif
        result = spi_flash_read(spi_base, flash_slave, image_offset + offset,
                                verify, chunk);
        if (result != 0) {
            send_error_report(uart_base, SERIAL_BOOT_ERR_VERIFY,
                               SERIAL_BOOT_STAGE_VERIFY_READ, result,
                               image_offset + offset);
            return SERIAL_BOOT_ERR_VERIFY;
        }
        crc = crc32_update(crc, verify, chunk);
    }
    crc ^= 0xFFFFFFFFU;

    if (crc != image_crc32) {
        send_error_report(uart_base, SERIAL_BOOT_ERR_VERIFY,
                           SERIAL_BOOT_STAGE_VERIFY_CRC, 0, 0U);
        return SERIAL_BOOT_ERR_VERIFY;
    }

    uart_putc(uart_base, SERIAL_BOOT_DONE);
    return 0;
}
