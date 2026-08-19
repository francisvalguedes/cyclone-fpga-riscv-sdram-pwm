/*
 * Bootloader residente na RAM interna do Nios V.
 *
 * Layout na flash SPI (chip identificado em runtime -- ver spi_flash_detect()
 * em software/common/spi_flash.h):
 *   0x000000 .. 0x00001F  boot_image_header_t
 *   0x000020 ..             imagem binaria da aplicacao para a SDRAM
 *
 * A imagem deve ter sido linkada para NEW_SDRAM_CONTROLLER_0_BASE. O campo
 * entry_address deve apontar para o simbolo _start da imagem, e nao para
 * main(), pois _start inicializa gp, bss e o vetor de excecoes.
 *
 * Ao ligar, o bootloader verifica o botao de gatilho (bit 3 do pio_1,
 * ativo em nivel baixo). Se estiver pressionado, aguarda por um curto
 * intervalo o handshake do protocolo de atualizacao via serial (veja
 * serial_boot.h/.c); se detectado, recebe uma nova imagem .nvbi e grava na
 * flash. Em qualquer outro caso (botao solto, ou timeout do handshake),
 * segue o fluxo normal: copia a imagem da flash para a SDRAM e salta para
 * ela.
 */


#include <stddef.h>
#include <stdint.h>

#include "system.h"
#include "sys/alt_stdio.h"
#include "altera_avalon_pio_regs.h"
#include "spi_flash.h"
#include "serial_boot.h"
#include "crc32.h"

#define BOOT_FLASH_SLAVE          0U
#define BOOT_IMAGE_MAGIC           0x4E564249U /* "NVBI" */
#define BOOT_IMAGE_VERSION         1U
#define BOOT_COPY_BUFFER_BYTES     SPI_FLASH_PAGE_BYTES

/* Janela de espera pelo handshake de atualizacao serial, usada somente
 * quando o gatilho por botao esta pressionado ao ligar. O valor de polls
 * foi calibrado experimentalmente para a UART a 115200 bps / CPU a 50 MHz;
 * nao depende de timer (o bootloader roda sem interrupcoes). */
#define SERIAL_BOOT_HANDSHAKE_POLLS  100000000U

/* Botao de gatilho para o modo de atualizacao serial: bit 3 do pio_1
 * (mesmo periferico de botoes usado em software/app/main.c), ativo em
 * nivel baixo. Mantenha pressionado durante o reset/ligacao da placa para
 * entrar no modo de gravacao via serial. */
#define SERIAL_BOOT_BUTTON_MASK     0x8U

#define SELFTEST_PATTERN_BYTES      64U

/* Diagnostico opcional: apaga o bloco que contem BRINGUP_OFFSET_TEST_ADDR e
 * grava DIRETAMENTE nesse offset, como primeira e unica operacao -- sem as
 * ~16 paginas anteriores que uma atualizacao real faria antes de chegar
 * la. Serve para isolar se um travamento observado num offset especifico
 * (ex.: 0x1000) e proprio daquela regiao da flash ou um efeito cumulativo
 * de muitas operacoes SPI em sequencia. Quando ligado, substitui o fluxo
 * normal de atualizacao serial neste boot (nao espera handshake). */
#define BRINGUP_OFFSET_TEST         0
#define BRINGUP_OFFSET_TEST_ADDR    0x1000U

/* Os logs deste arquivo sao propositalmente curtos (poucos bytes por linha):
 * cada alt_printf() gasta .text (formatacao, um call site por chamada, sem
 * dedup a -O0) e bloqueia a CPU byte a byte na UART. So um humano num
 * terminal le essas linhas -- serial_flash_update.py usa exclusivamente o
 * protocolo binario de serial_boot.h, nao este texto. Legenda:
 *   BOOT        ligou
 *   GO          vai saltar para a aplicacao
 *   ST OK       autoteste rapido da flash passou
 *   ST J=<hex>  autoteste: falha ao ler JEDEC ID (codigo spi_flash.h)
 *   ST ID=<hex> autoteste: JEDEC ID lido, mas nao confere
 *   ST E=<hex>  autoteste: falha no erase (codigo spi_flash.h)
 *   ST P=<hex>  autoteste: falha na gravacao (codigo spi_flash.h)
 *   ST R=<hex>  autoteste: falha na leitura (codigo spi_flash.h)
 *   ST C        autoteste: dado lido nao confere com o gravado
 *   E:HS        timeout no handshake da atualizacao serial
 *   E:J=<hex>   boot normal: falha ao ler JEDEC ID (codigo spi_flash.h)
 *   E:ID=<hex>  boot normal: JEDEC ID lido, mas nao confere
 *   E:HDR       boot normal: cabecalho invalido
 *   E:CPY       boot normal: falha ao copiar a imagem ou CRC nao confere
 */

/* Diagnostico opcional de bring-up: com 1, o botao de gatilho roda uma
 * varredura DESTRUTIVA de toda a flash SPI (apaga/grava/confere cada um dos
 * SELFTEST_TOTAL_BLOCKS blocos de 64K) em vez do autoteste rapido de 1
 * bloco. Use somente para localizar em qual regiao da flash o erase/
 * gravacao esta falhando; deixe em 0 para o uso normal (atualizacao de
 * firmware via serial nao precisa disto). Depois de rodar com 1, grave um
 * firmware valido de novo com serial_flash_update.py antes de usar a placa
 * normalmente -- o cabecalho/imagem de boot atuais terao sido apagados
 * pelo teste, mesmo que ele reporte OK em todos os blocos. */
#define BRINGUP_FULL_CHIP_TEST      0

typedef struct {
    alt_u32 magic;
    alt_u32 version;
    alt_u32 header_size;
    alt_u32 image_size;
    alt_u32 load_address;
    alt_u32 entry_address;
    alt_u32 image_crc32;
    alt_u32 header_crc32;
} boot_image_header_t;

typedef void (*boot_entry_t)(void);

static alt_u32 boot_header_crc(const boot_image_header_t *header)
{
    boot_image_header_t copy = *header;

    copy.header_crc32 = 0U;
    return crc32_update(0xFFFFFFFFU, (const alt_u8 *)&copy, sizeof(copy)) ^
           0xFFFFFFFFU;
}

static int boot_header_is_valid(const boot_image_header_t *header,
                                 alt_u32 flash_total_bytes,
                                 alt_u32 image_offset)
{
    const alt_u32 sdram_end = NEW_SDRAM_CONTROLLER_0_BASE +
                              NEW_SDRAM_CONTROLLER_0_SPAN;

    if ((header->magic != BOOT_IMAGE_MAGIC) ||
        (header->version != BOOT_IMAGE_VERSION) ||
        (header->header_size != sizeof(*header)) ||
        (header->header_crc32 != boot_header_crc(header))) {
        return 0;
    }

    if ((header->image_size == 0U) ||
        (header->image_size >
         (flash_total_bytes - image_offset - header->header_size))) {
        return 0;
    }

    if ((header->load_address < NEW_SDRAM_CONTROLLER_0_BASE) ||
        (header->load_address >= sdram_end) ||
        (header->image_size > (sdram_end - header->load_address))) {            
        return 0;
    }

    if (((header->entry_address & 0x3U) != 0U) ||
        (header->entry_address < header->load_address) ||
        (header->entry_address >= (header->load_address + header->image_size))) {
        return 0;
    }

    alt_printf("S:LD=%x\n", (unsigned long)header->load_address);

    return 1;
}

/*
 * Le a imagem da flash SPI direto para o endereco final em header->load_address
 * (na SDRAM), sem passar por um buffer intermediario na RAM interna: o
 * bootloader inteiro roda com pilha/heap na onchip_memory2_0 (16K), entao um
 * buffer local aqui competiria com o resto do bootloader por esse espaco
 * apertado. A SDRAM ja esta em uso como destino final (e como staging da
 * atualizacao serial em serial_update_check), entao escrever nela direto
 * durante a copia e seguro.
 */
static int boot_copy_image(const boot_image_header_t *header,
                            alt_u32 image_offset)
{
    volatile alt_u8 *destination = (volatile alt_u8 *)(uintptr_t)header->load_address;
    alt_u32 flash_offset = image_offset + header->header_size;
    alt_u32 remaining = header->image_size;
    alt_u32 crc = 0xFFFFFFFFU;
    alt_u32 chunk;
    int result;

    while (remaining != 0U) {
        chunk = (remaining > BOOT_COPY_BUFFER_BYTES) ? BOOT_COPY_BUFFER_BYTES : remaining;
        result = spi_flash_read(SPI_0_BASE, BOOT_FLASH_SLAVE, flash_offset,
                             (alt_u8 *)(uintptr_t)destination, chunk);
        if (result != 0) {
            return result;
        }

        crc = crc32_update(crc, (const alt_u8 *)(uintptr_t)destination, chunk);

        destination += chunk;
        flash_offset += chunk;
        remaining -= chunk;
    }

    return ((crc ^ 0xFFFFFFFFU) == header->image_crc32) ? 0 : -100;
}

static void boot_halt(void)
{
    for (;;) {
        __asm__ volatile ("wfi");
    }
}

/*
 * Diagnostico opcional (BRINGUP_OFFSET_TEST=1): apaga o bloco de 64K que
 * contem 'offset' e grava um padrao conhecido DIRETAMENTE ali, como
 * primeira e unica operacao -- sem nenhuma pagina anterior. Imprime uma
 * linha por etapa (E@/E<-/P@/P<-/R<-/C/OK), igual ao SERIAL_BOOT_VERBOSE_COPY
 * de serial_boot.c: se travar, a ultima linha impressa mostra exatamente
 * em qual etapa.
 */
#if BRINGUP_OFFSET_TEST

static void spi_flash_offset_test(alt_u32 spi_base, alt_u32 slave, alt_u32 offset)
{
    alt_u8 pattern[SELFTEST_PATTERN_BYTES];
    alt_u8 read_back[SELFTEST_PATTERN_BYTES];
    alt_u32 block_offset = offset - (offset % SPI_FLASH_BLOCK_BYTES);
    alt_u32 i;
    int result;

    alt_printf("OT E@%x\n", (unsigned long)block_offset);
    result = spi_flash_erase_block_64k(spi_base, slave, block_offset);
    alt_printf("OT E<-%x\n", (unsigned long)result);
    if (result != 0) {
        return;
    }

    for (i = 0U; i < sizeof(pattern); ++i) {
        pattern[i] = (alt_u8)(i ^ 0x5AU);
    }

    alt_printf("OT P@%x\n", (unsigned long)offset);
    result = spi_flash_write(spi_base, slave, offset, pattern, sizeof(pattern));
    alt_printf("OT P<-%x\n", (unsigned long)result);
    if (result != 0) {
        return;
    }

    for (i = 0U; i < sizeof(read_back); ++i) {
        read_back[i] = 0U;
    }
    result = spi_flash_read(spi_base, slave, offset, read_back, sizeof(read_back));
    alt_printf("OT R<-%x\n", (unsigned long)result);
    if (result != 0) {
        return;
    }

    for (i = 0U; i < sizeof(pattern); ++i) {
        if (read_back[i] != pattern[i]) {
            alt_printf("OT C\n");
            return;
        }
    }
    alt_printf("OT OK\n");
}
#endif

/*
 * Le o estado do botao de gatilho (bit 0 do pio_1). Retorna 1 se estiver
 * pressionado (nivel baixo), 0 caso contrario.
 */
static int serial_boot_button_pressed(void)
{
    alt_u32 buttons = IORD_ALTERA_AVALON_PIO_DATA(PIO_1_BASE);
    return ((buttons & SERIAL_BOOT_BUTTON_MASK) == 0U) ? 1 : 0;
}


/*
 * Verifica o gatilho por botao ao ligar. Se o botao estiver pressionado,
 * aguarda pelo handshake de atualizacao via serial e, se detectado, executa
 * o protocolo completo. A imagem recebida (.nvbi) e armazenada como staging
 * na propria SDRAM, em NEW_SDRAM_CONTROLLER_0_BASE, antes de ser gravada na
 * flash SPI. Se o botao nao estiver pressionado, retorna imediatamente sem
 * tocar na serial, permitindo o boot normal prosseguir sem atraso.
 *
 * A partir do momento em que o handshake e aceito ha uma ferramenta host
 * (serial_flash_update.py) do outro lado de UART_0_BASE decodificando o
 * protocolo binario (ver serial_boot.h): ACK/NAK por pacote e, ao final,
 * DONE ou ERR + relatorio estruturado. Essa e a fonte de verdade que o
 * host usa para exibir mensagens ao usuario -- por isso, daqui em diante
 * o bootloader NAO deve escrever texto solto em UART_0_BASE (alt_printf
 * usa esse mesmo UART como stdio): faria apenas ruido no meio do fluxo
 * binario que o host esta lendo, sem nenhuma informacao que os codigos ja
 * nao carreguem. Se a gravacao falhar, o bootloader para aqui (boot_halt)
 * em vez de cair no boot normal: apos um erase/gravacao parcial o
 * cabecalho em offset 0 quase certamente ficou invalido, entao continuar
 * so geraria mais texto na mesma UART sem chance real de sucesso.
 */
static void serial_update_check(alt_u32 flash_total_bytes,
                                 alt_u32 image_offset)
{
    alt_u8 *staging = (alt_u8 *)(uintptr_t)NEW_SDRAM_CONTROLLER_0_BASE;
    int result;

    if (!serial_boot_button_pressed()) {
        return;
    }

#if BRINGUP_OFFSET_TEST
    spi_flash_offset_test(SPI_0_BASE, BOOT_FLASH_SLAVE, BRINGUP_OFFSET_TEST_ADDR);
    return;
#endif

    if (!serial_boot_wait_handshake(UART_0_BASE, SERIAL_BOOT_HANDSHAKE_POLLS)) {
        alt_printf("E:HS\n");
        return;
    }

    result = serial_boot_run(UART_0_BASE, SPI_0_BASE, BOOT_FLASH_SLAVE,
                              staging, NEW_SDRAM_CONTROLLER_0_SPAN,
                              flash_total_bytes, image_offset);
    if (result != 0) {
        boot_halt();
    }
}


int main(void)
{
    boot_image_header_t header;
    const spi_flash_chip_info_t *chip;
    alt_u32 image_offset;
    int result;

    alt_printf("BOOT_1.3\n");

    /* Deteccao por JEDEC ID precisa vir antes de qualquer outra chamada
     * spi_flash_* (inclusive dentro de serial_update_check/serial_boot_run):
     * elas dependem do chip detectado para validar limites de endereco e
     * escolher a estrategia de erase correta (ver spi_flash_detect() em
     * spi_flash.h/.c). */
    result = spi_flash_detect(SPI_0_BASE, BOOT_FLASH_SLAVE, &chip);
    if (result != 0) {
        alt_u32 jedec_id = 0U;
        (void)spi_flash_read_jedec_id(SPI_0_BASE, BOOT_FLASH_SLAVE, &jedec_id);
        alt_printf("E:ID=%x\n", (unsigned long)jedec_id);
        boot_halt();
    }

    /* Chips com quirk_block0_unreliable (ver spi_flash.h) nao apagam o
     * bloco 0 de forma confiavel -- a imagem de boot (cabecalho + app)
     * nunca deve viver la. Nesses chips, tudo comeca no setor 1
     * (0x10000); o setor 0 nunca e lido, apagado ou gravado por este
     * bootloader. Em chips sem essa quirk (ex.: Winbond W25Q16), a imagem
     * comeca em 0x000000 normalmente. */
    image_offset = chip->quirk_block0_unreliable ? SPI_FLASH_BLOCK_BYTES : 0U;

    serial_update_check(chip->total_bytes, image_offset);

    result = spi_flash_read(SPI_0_BASE, BOOT_FLASH_SLAVE, image_offset,
                         (alt_u8 *)&header, sizeof(header));
    if ((result != 0) ||
        !boot_header_is_valid(&header, chip->total_bytes, image_offset)) {
        alt_printf("E:HDR\n");
        boot_halt();
    }

    result = boot_copy_image(&header, image_offset);
    if (result != 0) {
        alt_printf("E:CPY\n");
        boot_halt();
    }

    /* Necessario mesmo no Nios V/m atual sem caches, e seguro se forem
     * habilitados em uma futura variante do processador. */
    __asm__ volatile ("fence.i" ::: "memory");

    alt_printf("GO\n");

    // Remover depois de testar a gravacao via serial: se a aplicacao nao estiver
    // while (1){}

    ((boot_entry_t)(uintptr_t)header.entry_address)();

    boot_halt();
    return 0;
}
