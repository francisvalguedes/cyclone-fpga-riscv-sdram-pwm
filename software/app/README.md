# app

Aplicação principal de demonstração da placa: LEDs, botões, PWM e checagens rápidas de SDRAM e da flash SPI no boot.

## O que faz

- **Boot**: roda `sdram_test()` (escreve/lê um pequeno array na própria SDRAM, onde este programa já está executando) e `flash_identify()` (lê JEDEC ID e tamanho do chip de flash SPI conectado — **só leitura**, não apaga nem grava nada).
- **Loop principal**:
  - `pio_1[3:0]` (botões, ativos em nível baixo): bit 0 diminui o duty cycle do PWM, bit 1 aumenta, bit 2 não tem função própria.
  - `pio_0[3:0]` (LEDs, ativos em nível alto): bits 0-2 espelham os botões correspondentes em tempo real; bit 3 pisca a 1 Hz, independente dos botões.
  - PWM: núcleo customizado, duty ajustável pelos botões (ver `PWM_PRESCALER`/`PWM_PERIOD`/`PWM_DUTY_STEP` em `main.c`).
  - Uma vez por segundo, imprime uma linha de status pela serial, por exemplo:
    ```
    tick=1485 botoes=0x7 leds=0x8 pwm_duty=0/999
    ```

## Como essa aplicação roda na placa

Este firmware não vai na flash de configuração do FPGA (o bitstream/`.sof`/`.jic`) — é carregado pelo bootloader (`software/bootloader`) a partir da flash SPI de dados para a SDRAM, onde executa. Pode ser atualizado via protocolo serial (sem precisar de JTAG) ou gravado direto via JTAG para testes rápidos durante o desenvolvimento.

## Build, gravação e atualização

Todos os comandos (gerar BSP, compilar, gravar via JTAG, converter `.elf`→`.hex`/`.sof`→`.jic`, atualizar via serial) estão centralizados em [`BUILD.md`](../../BUILD.md), na raiz do repositório.
