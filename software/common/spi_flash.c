#include "spi_flash.h"

#include "altera_avalon_spi.h"
#include "altera_avalon_spi_regs.h"

#define SPI_FLASH_CMD_READ_ID       0x9FU
#define SPI_FLASH_CMD_READ_STATUS   0x05U
#define SPI_FLASH_CMD_WRITE_ENABLE  0x06U
#define SPI_FLASH_CMD_WRITE_DISABLE 0x04U
#define SPI_FLASH_CMD_WRITE_STATUS  0x01U
#define SPI_FLASH_CMD_READ          0x03U
#define SPI_FLASH_CMD_PAGE_PROGRAM  0x02U
#define SPI_FLASH_CMD_BLOCK_ERASE   0xD8U
#define SPI_FLASH_STATUS_WIP        0x01U
#define SPI_FLASH_STATUS_BP_MASK    0x1CU /* BP0..BP2 (bits 2..4) */
/* Orcamento usado para gravar 1 pagina e para checagens de "ja esta
 * pronto?" antes de emitir um novo comando. Cada iteracao faz uma
 * transacao SPI completa (RDSR, 16 ciclos de SCLK a 1 MHz -- ver
 * targetClockRate do IP spi_0 no .qsys), entao e o clock SPI que domina o
 * tempo de cada iteracao, nao o clock de sistema (50 MHz). Gravacao de
 * pagina real leva poucos ms; ~4,5s de folga aqui e generoso. (O
 * travamento no bloco 0 da A25L80P nao era orcamento insuficiente -- ver
 * quirk_block0_unreliable abaixo.) */
#define SPI_FLASH_READY_POLLS       250000U
/* Apagar um bloco de 64K (ou, no caso do bloco 0, um sub-setor de 4K por
 * vez) e mais lento que gravar uma pagina; mantem orcamento proprio maior
 * (~9 s no pior caso)  */
#define SPI_FLASH_ERASE_READY_POLLS 500000U

/* Orcamento de polling para cada espera de status dentro de uma unica
 * transferencia SPI (ver spi_flash_spi_transfer() abaixo). */
#define SPI_FLASH_SPI_POLL_BUDGET   1000000U

/*
 * Tabela de chips SPI NOR suportados, identificados pelo JEDEC ID (RDID,
 * opcode 0x9F) lido por spi_flash_detect(). O driver foi escrito originalmente
 * so para a AMIC A25L80P; a Winbond W25Q16BV/BAV foi adicionada depois
 * (mesmo protocolo basico, chip maior, sem a peculiaridade de erase do
 * bloco 0). Ver spi_flash.h para o significado de cada campo.
 */
static const spi_flash_chip_info_t g_known_chips[] = {
    { 0x7F372014U, "AMIC A25L80P",        1024U * 1024U, 1 },
    { 0xEF401500U, "Winbond W25Q16BV/BAV", 2048U * 1024U, 0 },
};
/* AMIC A25L80P: apos duas estrategias de erase diferentes para o bloco 0
 * testadas em hardware real (ver comentario acima de
 * spi_flash_erase_block_64k) e nenhuma se mostrar confiavel -- o chip
 * segue detectavel (leitura/JEDEC funcionam), mas com
 * quirk_block0_unreliable=1: spi_flash_erase_block_64k() recusa apagar o
 * bloco 0 imediatamente em vez de arriscar mais um travamento. Recomendado
 * usar a Winbond W25Q16 (testada, sem esse problema) daqui pra frente. */
#define SPI_FLASH_KNOWN_CHIP_COUNT \
    (sizeof(g_known_chips) / sizeof(g_known_chips[0]))

static const spi_flash_chip_info_t *g_current_chip = 0;

/* Funcoes que dependem do chip detectado (limites de endereco, escolha de
 * estrategia de erase) chamam isto primeiro. spi_flash_read_jedec_id(),
 * spi_flash_read_status() e spi_flash_wait_ready() nao chamam -- sao os
 * primitivos genericos que o proprio spi_flash_detect() usa, e funcionam
 * identicamente em qualquer chip SPI NOR. */
static int spi_flash_require_chip(void)
{
    return (g_current_chip != 0) ? 0 : SPI_FLASH_ERR_NOT_DETECTED;
}

/*
 * Recusa qualquer erase/gravacao que toque o bloco 0 (0x000000..0x00FFFF)
 * de um chip marcado quirk_block0_unreliable (ver g_known_chips e o
 * comentario acima de spi_flash_erase_block_64k). So chamada por
 * erase_block_64k e write -- leitura nunca apresentou problema nesse
 * chip, entao spi_flash_read() nao chama isto, para nao impedir
 * diagnostico do conteudo do bloco 0 se algum dia for preciso.
 *
 * Precisa ser chamada DEPOIS de spi_flash_require_chip() (assume
 * g_current_chip != 0).
 */
static int spi_flash_reject_block0(alt_u32 offset)
{
    if (g_current_chip->quirk_block0_unreliable &&
        (offset < SPI_FLASH_BLOCK_BYTES)) {
        return SPI_FLASH_ERR_CHIP_UNRELIABLE;
    }
    return 0;
}

/*
 * Substitui alt_avalon_spi_command() (BSP, em
 * software/bootloader_bsp/drivers/src/altera_avalon_spi.c) com a MESMA
 * logica de protocolo, mas com orcamento de polling limitado em cada
 * espera de status.
 *
 * A versao do BSP tem tres lacos de espera SEM NENHUM LIMITE (TRDY/RRDY
 * durante a transferencia, e TMT no final); se o nucleo Avalon-SPI algum
 * dia nao sinalizar pronto -- por qualquer motivo, um glitch eletrico, por
 * exemplo -- a CPU trava ali para sempre: sem gerar erro, sem responder a
 * UART, e so um power-cycle recupera. Foi exatamente o sintoma observado
 * gravando a A25L80P (trava sem retornar erro algum, diferente do timeout
 * de WIP que ja e tratado por SPI_FLASH_READY_POLLS/SPI_FLASH_ERASE_READY_POLLS).
 *
 * Como aquele arquivo do BSP e regenerado pelo niosv-bsp (qualquer edicao
 * direta nele se perde na proxima regeneracao), a correcao fica aqui, na
 * nossa arvore de fontes, como uma copia com orcamento limitado.
 */
static int spi_flash_spi_transfer(alt_u32 base, alt_u32 slave,
                                alt_u32 write_length, const alt_u8 *write_data,
                                alt_u32 read_length, alt_u8 *read_data,
                                alt_u32 flags)
{
    const alt_u8 *write_end = write_data + write_length;
    alt_u8 *read_end = read_data + read_length;
    alt_u32 write_zeros = read_length;
    alt_u32 read_ignore = write_length;
    alt_u32 status;
    alt_32 credits = 1;
    alt_u32 polls;

    IOWR_ALTERA_AVALON_SPI_SLAVE_SEL(base, 1U << slave);

    if ((flags & ALT_AVALON_SPI_COMMAND_TOGGLE_SS_N) == 0U) {
        IOWR_ALTERA_AVALON_SPI_CONTROL(base, ALTERA_AVALON_SPI_CONTROL_SSO_MSK);
    }

    /* Descarta dado antigo no RXDATA, caso uma comunicacao anterior tenha
     * sido interrompida e deixado lixo para tras. */
    (void)IORD_ALTERA_AVALON_SPI_RXDATA(base);

    for ( ; ; ) {
        for (polls = 0U; ; ++polls) {
            status = IORD_ALTERA_AVALON_SPI_STATUS(base);
            if (((status & ALTERA_AVALON_SPI_STATUS_TRDY_MSK) != 0U && credits > 0) ||
                ((status & ALTERA_AVALON_SPI_STATUS_RRDY_MSK) != 0U)) {
                break;
            }
            if (polls >= SPI_FLASH_SPI_POLL_BUDGET) {
                /* Sempre libera o barramento em timeout, mesmo com a flag
                 * MERGE: quem chamou vai desistir e retornar o erro, nunca
                 * vai completar a chamada seguinte que normalmente
                 * liberaria o CS -- deixando-o preso em nivel baixo para
                 * sempre se nao soltarmos aqui. */
                IOWR_ALTERA_AVALON_SPI_CONTROL(base, 0U);
                return SPI_FLASH_ERR_SPI_TIMEOUT;
            }
        }

        if ((status & ALTERA_AVALON_SPI_STATUS_TRDY_MSK) != 0U && credits > 0) {
            credits--;
            if (write_data < write_end) {
                IOWR_ALTERA_AVALON_SPI_TXDATA(base, *write_data++);
            } else if (write_zeros > 0U) {
                write_zeros--;
                IOWR_ALTERA_AVALON_SPI_TXDATA(base, 0U);
            } else {
                credits = -1024;
            }
        }

        if ((status & ALTERA_AVALON_SPI_STATUS_RRDY_MSK) != 0U) {
            alt_u32 rxdata = IORD_ALTERA_AVALON_SPI_RXDATA(base);

            if (read_ignore > 0U) {
                read_ignore--;
            } else {
                *read_data++ = (alt_u8)rxdata;
            }
            credits++;

            if ((read_ignore == 0U) && (read_data == read_end)) {
                break;
            }
        }
    }

    for (polls = 0U; ; ++polls) {
        status = IORD_ALTERA_AVALON_SPI_STATUS(base);
        if ((status & ALTERA_AVALON_SPI_STATUS_TMT_MSK) != 0U) {
            break;
        }
        if (polls >= SPI_FLASH_SPI_POLL_BUDGET) {
            /* Mesmo motivo do timeout acima: sempre libera o barramento,
             * mesmo com a flag MERGE. */
            IOWR_ALTERA_AVALON_SPI_CONTROL(base, 0U);
            return SPI_FLASH_ERR_SPI_TIMEOUT;
        }
    }

    if ((flags & ALT_AVALON_SPI_COMMAND_MERGE) == 0U) {
        IOWR_ALTERA_AVALON_SPI_CONTROL(base, 0U);
    }

    return (int)read_length;
}

static int spi_flash_spi_command(alt_u32 spi_base, alt_u32 slave,
                               alt_u32 write_length, const alt_u8 *write_data,
                               alt_u32 read_length, alt_u8 *read_data,
                               alt_u32 flags)
{
    int result = spi_flash_spi_transfer(spi_base, slave, write_length,
                                     write_data, read_length, read_data,
                                     flags);

    return (result == (int)read_length) ? 0 : result;
}

int spi_flash_read_jedec_id(alt_u32 spi_base, alt_u32 slave, alt_u32 *jedec_id)
{
    const alt_u8 command = SPI_FLASH_CMD_READ_ID;
    alt_u8 id[4];
    int result;

    if (jedec_id == 0) {
        return SPI_FLASH_ERR_ARGUMENT;
    }

    result = spi_flash_spi_command(spi_base, slave, 1U, &command, 4U, id, 0U);
    if (result == 0) {
        *jedec_id = ((alt_u32)id[0] << 24) |
                    ((alt_u32)id[1] << 16) |
                    ((alt_u32)id[2] << 8) |
                    (alt_u32)id[3];
    }
    return result;
}

int spi_flash_detect(alt_u32 spi_base, alt_u32 slave,
                   const spi_flash_chip_info_t **chip_out)
{
    alt_u32 jedec_id;
    alt_u32 i;
    int result;

    result = spi_flash_read_jedec_id(spi_base, slave, &jedec_id);
    if (result != 0) {
        return result;
    }

    for (i = 0U; i < SPI_FLASH_KNOWN_CHIP_COUNT; ++i) {
        if (g_known_chips[i].jedec_id == jedec_id) {
            g_current_chip = &g_known_chips[i];
            if (chip_out != 0) {
                *chip_out = g_current_chip;
            }
            return 0;
        }
    }

    g_current_chip = 0;
    return SPI_FLASH_ERR_UNKNOWN_CHIP;
}

const spi_flash_chip_info_t *spi_flash_current_chip(void)
{
    return g_current_chip;
}

int spi_flash_read_status(alt_u32 spi_base, alt_u32 slave, alt_u8 *status)
{
    const alt_u8 command = SPI_FLASH_CMD_READ_STATUS;

    if (status == 0) {
        return SPI_FLASH_ERR_ARGUMENT;
    }
    return spi_flash_spi_command(spi_base, slave, 1U, &command, 1U, status, 0U);
}

static int spi_flash_wait_ready_polls(alt_u32 spi_base, alt_u32 slave,
                                    alt_u32 max_polls)
{
    alt_u32 polls;
    alt_u8 status;
    int result;

    for (polls = 0; polls < max_polls; ++polls) {
        result = spi_flash_read_status(spi_base, slave, &status);
        if (result != 0) {
            return result;
        }
        if ((status & SPI_FLASH_STATUS_WIP) == 0U) {
            return 0;
        }
    }
    return SPI_FLASH_ERR_TIMEOUT;
}

int spi_flash_wait_ready(alt_u32 spi_base, alt_u32 slave)
{
    return spi_flash_wait_ready_polls(spi_base, slave, SPI_FLASH_READY_POLLS);
}

static int spi_flash_write_enable(alt_u32 spi_base, alt_u32 slave)
{
    const alt_u8 command = SPI_FLASH_CMD_WRITE_ENABLE;
    alt_u8 unused_read_data;

    return spi_flash_spi_command(spi_base, slave, 1U, &command, 0U,
                               &unused_read_data, 0U);
}

/*
 * Garante que os bits de protecao de escrita (BP0..BP2) estejam
 * desligados antes de apagar/gravar. Esses bits sao voláteis em muitos
 * chips SPI NOR (o estado pode nao ser o mesmo em todo power-on), e o
 * driver nunca garantia isso explicitamente antes -- so foi confirmado
 * BP=0 numa leitura pontual em bring-up, nao a cada boot. Chamado sempre
 * antes de um erase, entao cobre tanto a atualizacao real quanto os
 * diagnosticos isolados.
 */
static int spi_flash_clear_protection(alt_u32 spi_base, alt_u32 slave)
{
    alt_u8 command[2];
    alt_u8 unused_read_data;
    alt_u8 status;
    int result;

    result = spi_flash_read_status(spi_base, slave, &status);
    if (result != 0) {
        return result;
    }
    if ((status & SPI_FLASH_STATUS_BP_MASK) == 0U) {
        return 0; /* ja desprotegido, nada a fazer */
    }

    result = spi_flash_write_enable(spi_base, slave);
    if (result != 0) {
        return result;
    }

    command[0] = SPI_FLASH_CMD_WRITE_STATUS;
    command[1] = 0x00U;
    result = spi_flash_spi_command(spi_base, slave, 2U, command, 0U,
                                 &unused_read_data, 0U);
    if (result != 0) {
        return result;
    }

    return spi_flash_wait_ready(spi_base, slave);
}

int spi_flash_read(alt_u32 spi_base, alt_u32 slave, alt_u32 offset,
                alt_u8 *data, alt_u32 length)
{
    alt_u8 command[4];
    int result;

    result = spi_flash_require_chip();
    if (result != 0) {
        return result;
    }
    if ((data == 0) || (length == 0U) || (offset >= g_current_chip->total_bytes) ||
        (length > (g_current_chip->total_bytes - offset))) {
        return SPI_FLASH_ERR_RANGE;
    }

    command[0] = SPI_FLASH_CMD_READ;
    command[1] = (alt_u8)(offset >> 16);
    command[2] = (alt_u8)(offset >> 8);
    command[3] = (alt_u8)offset;

    result = spi_flash_wait_ready(spi_base, slave);
    if (result != 0) {
        return result;
    }
    return spi_flash_spi_command(spi_base, slave, 4U, command, length, data, 0U);
}

/*
 * Emite um unico comando Sector Erase (0xD8) no offset dado e aguarda a
 * conclusao. NAO faz suposicao alguma sobre quantos bytes isso realmente
 * apaga -- ver o comentario grande acima de spi_flash_erase_block_64k() para
 * o motivo disso importar tanto nessa peca especifica.
 */
static int spi_flash_erase_sector(alt_u32 spi_base, alt_u32 slave,
                                alt_u32 sector_offset)
{
    alt_u8 command[4];
    alt_u8 unused_read_data;
    int result;

    result = spi_flash_wait_ready(spi_base, slave);
    if (result != 0) {
        return result;
    }
    result = spi_flash_clear_protection(spi_base, slave);
    if (result != 0) {
        return result;
    }
    result = spi_flash_write_enable(spi_base, slave);
    if (result != 0) {
        return result;
    }

    command[0] = SPI_FLASH_CMD_BLOCK_ERASE;
    command[1] = (alt_u8)(sector_offset >> 16);
    command[2] = (alt_u8)(sector_offset >> 8);
    command[3] = (alt_u8)sector_offset;
    result = spi_flash_spi_command(spi_base, slave, 4U, command, 0U,
                                 &unused_read_data, 0U);
    return (result == 0) ?
           spi_flash_wait_ready_polls(spi_base, slave, SPI_FLASH_ERASE_READY_POLLS) :
           result;
}

/*
 * Bloco 0 da AMIC A25L80P (quirk_block0_unreliable): permanentemente
 * bloqueado para erase/gravacao via spi_flash_reject_block0().
 *
 * Esse bloco tem "Flexible Sector Architecture" (Tabela 2 do datasheet --
 * sub-setores nao-uniformes de 4K/4K/8K/16K/32K, ao contrario dos blocos
 * 1..15, uniformes de 64K). Duas estrategias de erase foram testadas em
 * hardware real: sub-setores uniformes de 4K via opcode 0x20 (usado pelo
 * flashrom para esse chip, nao documentado no datasheet); e 0xD8 nos 5
 * offsets/tamanhos exatos da Tabela 2 (bate com a entrada "A25L80P",
 * TEST_OK_PRE, do flashrom). As duas travaram a gravacao seguinte em
 * algum ponto, e o padrao de falha nao era fixo por endereco -- o mesmo
 * endereco que sempre funcionava sozinho passou a travar dependendo de
 * quantas operacoes SPI o precederam na mesma sessao. Confirmado em dois
 * chips A25L80P fisicos diferentes; uma Winbond W25Q16BAV no mesmo
 * hardware/firmware nunca apresentou nenhum desses sintomas.
 *
 * Nao e um bug de opcode corrigivel por software -- indica amostra de
 * silicio fora de especificacao. Use a Winbond W25Q16 (sem essa
 * peculiaridade) para dados reais.
 */
int spi_flash_erase_block_64k(alt_u32 spi_base, alt_u32 slave,
                            alt_u32 block_offset)
{
    int result;

    result = spi_flash_require_chip();
    if (result != 0) {
        return result;
    }
    if ((block_offset >= g_current_chip->total_bytes) ||
        ((block_offset % SPI_FLASH_BLOCK_BYTES) != 0U)) {
        return SPI_FLASH_ERR_RANGE;
    }
    result = spi_flash_reject_block0(block_offset);
    if (result != 0) {
        return result;
    }

    return spi_flash_erase_sector(spi_base, slave, block_offset);
}

static int spi_flash_program_page(alt_u32 spi_base, alt_u32 slave,
                                alt_u32 offset, const alt_u8 *data,
                                alt_u32 length)
{
    alt_u8 command[4];
    alt_u8 unused_read_data;
    int result;

    /* Ao contrario de spi_flash_read() e spi_flash_erase_block_64k(), esta
     * funcao nao tinha garantia de que o dispositivo estivesse pronto
     * antes de iniciar a escrita; como e chamada em sequencia por
     * spi_flash_write(), a espera no final da pagina anterior cobria os
     * casos normais, mas nao a primeira chamada apos outra operacao
     * externa a este driver. */
    result = spi_flash_wait_ready(spi_base, slave);
    if (result != 0) {
        return result;
    }

    result = spi_flash_write_enable(spi_base, slave);
    if (result != 0) {
        return result;
    }

    command[0] = SPI_FLASH_CMD_PAGE_PROGRAM;
    command[1] = (alt_u8)(offset >> 16);
    command[2] = (alt_u8)(offset >> 8);
    command[3] = (alt_u8)offset;
    result = spi_flash_spi_command(spi_base, slave, 4U, command, 0U,
                                 &unused_read_data,
                                 ALT_AVALON_SPI_COMMAND_MERGE);
    if (result != 0) {
        return result;
    }
    result = spi_flash_spi_command(spi_base, slave, length, data, 0U,
                                 &unused_read_data, 0U);
    if (result != 0) {
        return result;
    }
    return spi_flash_wait_ready(spi_base, slave);
}

int spi_flash_write(alt_u32 spi_base, alt_u32 slave, alt_u32 offset,
                 const alt_u8 *data, alt_u32 length)
{
    alt_u32 page_remaining;
    alt_u32 current_length;
    int result;

    result = spi_flash_require_chip();
    if (result != 0) {
        return result;
    }
    if ((data == 0) || (length == 0U) || (offset >= g_current_chip->total_bytes) ||
        (length > (g_current_chip->total_bytes - offset))) {
        return SPI_FLASH_ERR_RANGE;
    }
    result = spi_flash_reject_block0(offset);
    if (result != 0) {
        return result;
    }

    while (length != 0U) {
        page_remaining = SPI_FLASH_PAGE_BYTES - (offset % SPI_FLASH_PAGE_BYTES);
        current_length = (length < page_remaining) ? length : page_remaining;
        result = spi_flash_program_page(spi_base, slave, offset, data,
                                     current_length);
        if (result != 0) {
            return result;
        }
        offset += current_length;
        data += current_length;
        length -= current_length;
    }
    return 0;
}
