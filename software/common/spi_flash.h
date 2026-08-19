#ifndef SPI_FLASH_H
#define SPI_FLASH_H

#include "alt_types.h"

#define SPI_FLASH_PAGE_BYTES        256U
#define SPI_FLASH_BLOCK_BYTES       (64U * 1024U)

/* Codigos de erro da camada de driver SPI flash. */
#define SPI_FLASH_ERR_ARGUMENT      (-1)
#define SPI_FLASH_ERR_SPI           (-2)
#define SPI_FLASH_ERR_TIMEOUT       (-3)
#define SPI_FLASH_ERR_RANGE         (-4)
/* Nucleo Avalon-SPI nao sinalizou TRDY/RRDY/TMT dentro do orcamento de
 * polling (ver SPI_FLASH_SPI_POLL_BUDGET em spi_flash.c) -- diferente de
 * SPI_FLASH_ERR_TIMEOUT (que e sobre o chip de flash estar ocupado/WIP), este
 * e sobre o proprio transporte SPI nao responder. */
#define SPI_FLASH_ERR_SPI_TIMEOUT   (-5)
/* spi_flash_detect() leu um JEDEC ID que nao bate com nenhum chip da tabela
 * interna (ver g_known_chips em spi_flash.c). */
#define SPI_FLASH_ERR_UNKNOWN_CHIP  (-6)
/* Uma funcao que depende do chip detectado (read/write/erase) foi chamada
 * antes de spi_flash_detect() ter sido chamada com sucesso ao menos uma vez. */
#define SPI_FLASH_ERR_NOT_DETECTED  (-7)
/* Bloco 0 deste chip marcado quirk_block0_unreliable=1 (ver o comentario
 * acima de spi_flash_erase_block_64k() em spi_flash.c) -- devolvido
 * imediatamente, sem tentar nenhum comando na flash. */
#define SPI_FLASH_ERR_CHIP_UNRELIABLE (-8)

/*
 * Descreve um chip SPI NOR suportado por este driver. O driver foi escrito
 * originalmente so para a AMIC A25L80P, mas o mesmo protocolo basico
 * (WREN/RDSR/READ/PP/erase) e comum a varios chips SPI NOR -- a diferenca
 * real entre eles, na pratica observada neste projeto, e o tamanho total e
 * uma unica peculiaridade de erase (ver quirk_block0_unreliable). Por
 * isso um driver so, com deteccao em runtime pelo JEDEC ID, em vez de
 * copias .c/.h separadas por chip -- ter 3 copias quase identicas
 * (app/app_spi_test/bootloader) e o que fez uma correcao ficar so num
 * lugar por um tempo.
 */
typedef struct {
    alt_u32 jedec_id;
    const char *name;
    alt_u32 total_bytes;
    /* 1 se o bloco 0 (0x000000..0x00FFFF) deste chip e conhecido por nao
     * ser confiavel para erase/gravacao (especifico da AMIC A25L80P; ver
     * o comentario acima de spi_flash_erase_block_64k() em spi_flash.c).
     * spi_flash_erase_block_64k() recusa apagar o bloco 0 desses chips
     * (SPI_FLASH_ERR_CHIP_UNRELIABLE); leitura e deteccao continuam
     * normais. */
    int quirk_block0_unreliable;
} spi_flash_chip_info_t;

/*
 * Le o JEDEC ID e identifica o chip conectado contra a tabela interna de
 * chips suportados (ver spi_flash.c). Deve ser chamada com sucesso antes de
 * qualquer spi_flash_read/spi_flash_write/spi_flash_erase_*, pois essas funcoes
 * dependem do chip detectado para validar limites de endereco e escolher a
 * estrategia de erase correta.
 *
 * chip_out pode ser NULL se quem chamou nao precisa do descritor
 * imediatamente (ver spi_flash_current_chip()).
 *
 * Retorno: 0 em sucesso; SPI_FLASH_ERR_UNKNOWN_CHIP se o JEDEC ID lido nao
 * bate com nenhum chip conhecido; ou o erro de spi_flash_read_jedec_id() em
 * caso de falha de SPI (chip_out nao e escrito nesses casos de erro).
 */
int spi_flash_detect(alt_u32 spi_base, alt_u32 slave,
                   const spi_flash_chip_info_t **chip_out);

/*
 * Descritor do ultimo chip detectado com sucesso por spi_flash_detect(), ou
 * NULL se nenhuma deteccao bem-sucedida ainda ocorreu.
 */
const spi_flash_chip_info_t *spi_flash_current_chip(void);

int spi_flash_read_jedec_id(alt_u32 spi_base, alt_u32 slave, alt_u32 *jedec_id);
int spi_flash_read_status(alt_u32 spi_base, alt_u32 slave, alt_u8 *status);
int spi_flash_wait_ready(alt_u32 spi_base, alt_u32 slave);
int spi_flash_read(alt_u32 spi_base, alt_u32 slave, alt_u32 offset,
                alt_u8 *data, alt_u32 length);
int spi_flash_erase_block_64k(alt_u32 spi_base, alt_u32 slave,
                            alt_u32 block_offset);
int spi_flash_write(alt_u32 spi_base, alt_u32 slave, alt_u32 offset,
                 const alt_u8 *data, alt_u32 length);

#endif /* SPI_FLASH_H */
