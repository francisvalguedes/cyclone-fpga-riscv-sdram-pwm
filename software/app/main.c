/*
 * Teste básico de placa para Nios V -- roda como aplicação principal,
 * carregada na SDRAM pelo bootloader (que fica na RAM interna/on-chip) a
 * partir da flash SPI (ver software/bootloader). Este arquivo exercita os
 * três periféricos mais relevantes da placa:
 *
 *   SDRAM: sdram_test() escreve/lê um pequeno array reservado na própria
 *     SDRAM (onde este programa já está rodando) para confirmar que o
 *     controlador de memória está funcionando -- não é um teste exaustivo
 *     de toda a memória, só uma amostra rápida no boot.
 *
 *   Flash SPI: flash_identify() só lê o JEDEC ID e o tamanho do chip
 *     conectado (AMIC A25L80P ou Winbond W25Q16, ver software/common/
 *     spi_flash.c) -- não apaga nem grava nada, então não arrisca a área
 *     onde este próprio firmware está armazenado.
 *
 *   PWM: núcleo customizado (ver mapa de registradores abaixo) com duty
 *     cycle ajustável pelos botões em tempo real.
 *
 * pio_1[3:0] : botões, ativos em nível baixo.
 *   bit 0 : diminui o duty cycle do PWM.
 *   bit 1 : aumenta o duty cycle do PWM.
 *   bit 2 : sem função além do espelho no LED (ver abaixo).
 * pio_0[3:0] : LEDs, ativos em nível alto. Bits 0-2 espelham os botões
 *   correspondentes em tempo real; bit 3 pisca a 1 Hz, independente dos
 *   botões.
 */

#include <stdio.h>
#include <stdint.h>

#include "system.h"
#include "io.h"
#include "sys/alt_alarm.h"
#include "priv/alt_busy_sleep.h"
#include "altera_avalon_pio_regs.h"
#include "spi_flash.h"

#define IO_MASK_3_BITS          0x07U
#define SERIAL_PERIOD_TICKS     1000U       /* ALT_SYS_CLK = 1 kHz */
#define STARTUP_DELAY_US        500000U     /* 500 ms, somente na inicialização */
/* Pausa extra apos as mensagens de boot (SDRAM/flash), antes do loop
 * principal comecar a imprimir o status a cada segundo -- da tempo de
 * abrir um terminal serial e ver o resultado dos testes de boot sem que
 * ja tenha sido varrido pelas linhas de "tick=...". */
#define BOOT_MESSAGE_DELAY_US   (8U * STARTUP_DELAY_US)

/* --- PWM (mesmo mapa de registradores do IP customizado usado no Nios II) --- */
#define PWM_REG_CTRL            (0U * 4U)   /* 0x00: controle (bit0 = enable) */
#define PWM_REG_DIVIDER         (1U * 4U)   /* 0x04: prescaler */
#define PWM_REG_PERIOD          (2U * 4U)   /* 0x08: periodo do contador */
#define PWM_REG_DUTY            (3U * 4U)   /* 0x0C: ciclo de trabalho */

/* Clock do Nios V = 50 MHz. Prescaler 49 -> clock do PWM = 50MHz/50 = 1 MHz.
 * Periodo 999 -> frequencia do PWM = 1MHz/1000 = 1 kHz, faixa de duty 0..999. */
#define PWM_PRESCALER            49U
#define PWM_PERIOD               999U
#define PWM_DUTY_STEP            5U  /* incremento de 5/1000 por toque */
#define PWM_BUTTON_DECREASE_MASK 0x01U /* pio_1 bit 0 */
#define PWM_BUTTON_INCREASE_MASK 0x02U /* pio_1 bit 1 */

/* A área de teste é o array static abaixo; o linker a reserva na SDRAM. */
#define SDRAM_TEST_WORDS        16U

/* Array static: reservado na .bss da SDRAM, fora da stack. */
static volatile alt_u32 sdram_test_area[SDRAM_TEST_WORDS];

/*
 * Executa um teste simples de escrita/leitura no array reservado da SDRAM.
 *
 * Cada padrão é escrito em todas as SDRAM_TEST_WORDS posições e, em seguida,
 * cada posição é lida de volta. Os padrões alternados 0xAAAAAAAA e
 * 0x55555555 exercitam todos os bits com valores 1 e 0, além de verificar
 * transições entre bits vizinhos. Como o ponteiro é volatile, o compilador
 * não pode eliminar nem reutilizar as leituras/escritas no acesso ao hardware.
 *
 * Retorno: 0 se todas as leituras conferirem; caso contrário, retorna o índice
 *          da primeira palavra com erro (1 a SDRAM_TEST_WORDS).
 * Atenção: o conteúdo desse array é sobrescrito a cada execução do teste.
 */
static int sdram_test(void)
{
    static const alt_u32 patterns[] = { 0xAAAAAAAAU, 0x55555555U };
    volatile alt_u32 *const memory = sdram_test_area;
    alt_u32 pattern;
    alt_u32 i;

    for (pattern = 0; pattern < (sizeof(patterns) / sizeof(patterns[0])); ++pattern) {
        /* Fase 1: preenche toda a janela com o padrão atual. */
        for (i = 0; i < SDRAM_TEST_WORDS; ++i) {
            memory[i] = patterns[pattern];
        }

        /* Fase 2: confirma que cada palavra armazenou o mesmo valor. */
        for (i = 0; i < SDRAM_TEST_WORDS; ++i) {
            if (memory[i] != patterns[pattern]) {
                return (int)i + 1; /* índice 1..256 que apresentou erro */
            }
        }
    }

    return 0;
}

/*
 * Identifica o chip de flash SPI conectado e imprime o JEDEC ID e o tamanho
 * total. Somente leitura -- não apaga nem grava nada, então não há risco
 * para a área da flash reservada ao firmware.
 *
 * Retorno: 0 em sucesso, ou o código de erro de spi_flash_detect().
 */
static int flash_identify(void)
{
    const alt_u32 flash_slave = 0U;
    const spi_flash_chip_info_t *chip;
    int result;

    result = spi_flash_detect(SPI_0_BASE, flash_slave, &chip);
    if (result != 0) {
        alt_u32 jedec_id = 0U;
        (void)spi_flash_read_jedec_id(SPI_0_BASE, flash_slave, &jedec_id);
        printf("-ERRO FLASH: chip nao reconhecido (JEDEC 0x%08X, codigo %d).\n",
               (unsigned int)jedec_id, result);
        return result;
    }

    printf("SPI flash: %s JEDEC=0x%06X total=%u bytes\n",
           chip->name, (unsigned int)chip->jedec_id,
           (unsigned int)chip->total_bytes);
    return 0;
}

int main(void)
{
    alt_u64 next_serial_tick;
    int sdram_result;
    static alt_u32 toggle_led_state = 0; /* Estado do 4º LED (toggle) */
    alt_u32 pwm_duty = 0;
    /* Estado anterior dos botoes para detectar borda de descida (pressionar).
     * Inicia em "solto" (todos em 1, ativo em nivel baixo) para nao disparar
     * um incremento/decremento falso logo no primeiro loop. */
    alt_u32 buttons_prev = IO_MASK_3_BITS;

    /* Espera única para clock, SDRAM e periféricos estabilizarem após reset. */
    alt_busy_sleep(STARTUP_DELAY_US);

    IOWR_ALTERA_AVALON_PIO_DATA(PIO_0_BASE, 0);

    /* Configura o PWM: desabilita, ajusta prescaler/periodo, duty inicial
     * em 0 e so entao habilita. */
    IOWR_32DIRECT(PWM_0_BASE, PWM_REG_CTRL, 0x00U);
    IOWR_32DIRECT(PWM_0_BASE, PWM_REG_DIVIDER, PWM_PRESCALER);
    IOWR_32DIRECT(PWM_0_BASE, PWM_REG_PERIOD, PWM_PERIOD);
    IOWR_32DIRECT(PWM_0_BASE, PWM_REG_DUTY, pwm_duty);
    IOWR_32DIRECT(PWM_0_BASE, PWM_REG_CTRL, 0x01U);

    next_serial_tick = alt_nticks() + SERIAL_PERIOD_TICKS;

    sdram_result = sdram_test();

    if (sdram_result == 0) {
        printf("SDRAM - OK: teste em 0x%08X (%u palavras)\n",
                (unsigned int)(uintptr_t)sdram_test_area,
                (unsigned int)SDRAM_TEST_WORDS);
    } else {
        printf("ERRO SDRAM: palavra %d em 0x%08X\n", sdram_result,
                (unsigned int)((uintptr_t)sdram_test_area +
                ((sdram_result - 1) * sizeof(alt_u32))));
    }

    /* Esta aplicacao reside na flash SPI quando iniciada pelo bootloader. */
    (void)flash_identify();

    alt_busy_sleep(BOOT_MESSAGE_DELAY_US);

    while (1) {
        /* 3 LSBs: botão pressionado = 0; LED correspondente deve receber 1. */
        alt_u32 buttons = IORD_ALTERA_AVALON_PIO_DATA(PIO_1_BASE) & IO_MASK_3_BITS;
        alt_u32 leds_from_buttons = (~buttons) & IO_MASK_3_BITS;

        /* O 4º LED (MSB) é controlado pelo toggle. Combina os dois. */
        alt_u32 leds = leds_from_buttons | (toggle_led_state << 3);
        IOWR_ALTERA_AVALON_PIO_DATA(PIO_0_BASE, leds);

        /* Ajuste do duty cycle do PWM por borda de descida (pressionar),
         * nao por nivel -- senao segurar o botao incrementaria/decrementaria
         * a cada iteracao do loop (bem mais rapido que um toque humano). */
        {
            alt_u32 pressed_now = (~buttons) & buttons_prev;

            if ((pressed_now & PWM_BUTTON_INCREASE_MASK) != 0U) {
                pwm_duty = (pwm_duty + PWM_DUTY_STEP > PWM_PERIOD) ?
                           PWM_PERIOD : (pwm_duty + PWM_DUTY_STEP);
                IOWR_32DIRECT(PWM_0_BASE, PWM_REG_DUTY, pwm_duty);
            } else if ((pressed_now & PWM_BUTTON_DECREASE_MASK) != 0U) {
                pwm_duty = (pwm_duty < PWM_DUTY_STEP) ?
                           0U : (pwm_duty - PWM_DUTY_STEP);
                IOWR_32DIRECT(PWM_0_BASE, PWM_REG_DUTY, pwm_duty);
            }
            buttons_prev = buttons;
        }

        /* Temporização cooperativa pelo timer interno, sem delay/busy-wait. */
        if (alt_nticks() >= next_serial_tick) {
            /* Inverte o estado do 4º LED a cada segundo. */
            toggle_led_state = !toggle_led_state;

            printf("tick=%llu botoes=0x%X leds=0x%X pwm_duty=%u/%u\n",
                   (unsigned long long)alt_nticks(),
                   (unsigned int)buttons, (unsigned int)leds,
                   (unsigned int)pwm_duty, (unsigned int)PWM_PERIOD);

            next_serial_tick += SERIAL_PERIOD_TICKS;
        }
    }
}
