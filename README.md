# niosV

Projeto base em FPGA com um soft-core **Nios V/m** (RISC-V) rodando num Cyclone
IV E (`EP4CE6F17C8`), com bootloader próprio na RAM onchip carregado junto com o hardware a partir da Flash Omboard EPCS4, atualização de firmware via
UART e armazenamento em flash SPI externa.

![Foto da placa](docs/board.jpeg)


## Visão geral do hardware

| Item | Detalhe |
|---|---|
| FPGA | Intel/Altera Cyclone IV E, `EP4CE6F17C8` |
| CPU | Nios V/m (`intel_niosv_m`, variante 2), RV32I, sem cache (I$/D$ = 0) |
| Clock de sistema | 50 MHz (gerado por PLL, `altpll_0`, a partir do oscilador da placa) |
| RAM interna (on-chip) | 16 KB, `onchip_memory2_0` |
| SDRAM externa | 32 MB, `new_sdram_controller_0` (barramento de 16 bits, 4 bancos) |
| Flash de firmware | SPI genérica (`spi_0`)  -- Winbond W25Q16 (2 MiB) ou AMIC A25L80P (1 MiB util 960 KiB) detectada em runtime pelo JEDEC ID
| Config. da FPGA | Sem device de configuração serial (`USE_CONFIGURATION_DEVICE OFF`) -- gravação via JTAG |
| Outros periféricos | UART (115200 8N1), 2x PIO (LEDs/botões), PWM próprio |

Definido no Platform Designer/Qsys em [niosV_ip.qsys](niosV_ip.qsys)
(sistema `niosV_ip`) e sintetizado pelo projeto Quartus
[niosV.qpf](niosV.qpf) / [niosV.qsf](niosV.qsf).

## Arquitetura: Von Neumann

O Nios V/m aqui é **Von Neumann**: instruções e dados compartilham o mesmo
espaço de endereçamento e as mesmas memórias físicas -- tanto a RAM interna
(`onchip_memory2_0`) quanto a SDRAM (`new_sdram_controller_0`) guardam
código *e* dados/pilha/heap ao mesmo tempo, sem regiões reservadas
separadas para instrução e dado.

Detalhe de implementação (não muda a classificação acima): o núcleo expõe
duas portas Avalon distintas -- `instruction_manager` e `data_manager` --
para poder buscar instrução e acessar dado no mesmo ciclo sem disputar um
único barramento. Mas `instruction_manager` só chega às duas memórias que
podem conter código (RAM interna e SDRAM, no mesmo endereço que
`data_manager` usa para elas); todo o resto do mapa de memória (UART, SPI,
PIO, PWM, PLL) só é alcançável por `data_manager`. Ou seja: duas portas de
barramento por desempenho, mas uma memória só e um único mapa de
endereços -- não é Harvard (que exigiria memórias/endereços de instrução e
dado fisicamente separados).

## Topologia de memória

```
0x0000_0000  onchip_memory2_0     16 KB   RAM interna -- bootloader (INIT_FILE)
0x0200_0000  new_sdram_controller_0  32 MB  SDRAM -- aplicação (código+dados+pilha+heap)
0x0000_8000  perifericos (altpll, pio_0/1, pwm_0, spi_0, uart_0)  -- ver system.h de cada BSP
```

### RAM interna (`onchip_memory2_0`, 16 KB)

Onde o **bootloader** roda inteiro (código, pilha e heap) -- por isso ele é
mantido pequeno e com pouquíssima verbosidade. O conteúdo inicial dessa
memória é gravado *dentro do bitstream* via `INIT_FILE`
(`ONCHIP_MEMORY2_0_INIT_CONTENTS_FILE = "bootloader"`): trocar o bootloader
exige gerar um novo `.hex` a partir do `.elf` (`elf2hex`), rodar **Update
Memory Initialization File + Start Assembler** no Quartus e regravar a FPGA
via JTAG -- não é algo que se atualiza em campo pela serial.

### SDRAM (`new_sdram_controller_0`, 32 MB)

Onde a **aplicação** (`software/app`) é copiada para rodar, e também serve
de área de *staging* para uma imagem `.nvbi` recebida pela UART antes de
ser gravada na flash. Como é volátil, o bootloader precisa copiar a
aplicação da flash pra cá em todo boot.

### Flash SPI de firmware ( Winbond W25Q16 / AMIC A25L80P )

Guarda o cabeçalho da imagem de boot + o binário da aplicação de forma
persistente (sobrevive a desligar a placa). Acessada pelo núcleo Avalon-SPI
genérico `spi_0` (clock SPI a 1 MHz), driver único em
[software/common/spi_flash.c](software/common/spi_flash.c) com **detecção
do chip em runtime pelo JEDEC ID** (não é fixo em tempo de compilação).

Dois chips suportados hoje:

- **Winbond W25Q16BV/BAV** (2 MiB) -- Chip padrão atual, sem problemas,
 imagem começa normalmente em `0x000000`. Recomendada para uso real. 

- **AMIC A25L80P** (1 MiB) -- o **setor 0** (`0x000000`-`0x00FFFF`) desse
  chip especificamente se mostrou **não confiável para erase/gravação**
  -- ver o comentário grande em `spi_flash.c`. O driver recusa
  automaticamente qualquer erase/gravação nesse setor
  (`SPI_FLASH_ERR_CHIP_UNRELIABLE`), e o bootloader desloca a imagem
  inteira para começar no setor 1 (`0x010000`) quando detecta esse chip --
  perde 64 KB de capacidade útil, mas nunca toca a região problemática.


### EPCS4

Memória SPI Flash de configuração do hardware do FPGA e bootloader,
**não faz parte do hardware gerado** e não aparece no `system.h`de
nenhum BSP. É gravada só por JTAG  arquivo .jic.

## Estrutura do software

```
software/
  bootloader/       bootloader (roda na RAM interna, ver README próprio)
  bootloader_bsp/    BSP gerado para o bootloader (drive mínimo)
  app/               aplicação principal (roda na SDRAM, ver README proprio)
  bsp/                BSP gerado para a app
  common/             driver spi_flash.c/.h compartilhado pelos 3 acima
```

O driver de flash é um só (`software/common/spi_flash.c`/`.h`), referenciado
via caminho relativo pelos `CMakeLists.txt` -- evita ter cópias
divergentes do mesmo código.

## Atualização de firmware via serial

Protocolo binário simples pela UART (handshake, pacotes com CRC32,
relatório de erro estruturado) -- descrito em detalhe em
[software/bootloader/README.md](software/bootloader/README.md). Do lado do
PC:

```
python make_boot_image.py software/app/build/app.elf software/app/build/app.bin
python serial_flash_update.py --port COM8 --baud 115200 software/app/build/app.bin
```

(`pip install pyserial` necessário)

## Compilando e gravando

Comandos completos e passo a passo (BSP, CMake, `elf2hex`,
`niosv-download`) estão em [software/Comandos.md](software/Comandos.md).
Resumo:

```
cmake -S software/bootloader -B software/bootloader/build -G Ninja
cmake --build software/bootloader/build

cmake -S software/app -B software/app/build -G Ninja
cmake --build software/app/build
```

A RAM interna (boatloader) é carregado com o hardware do FPGA
num `.sof` (jtag) ou `.jic`(gravado na flash) para isso: gere o
`.hex`  com:

~~~
elf2hex bootloader.elf -b 0x0 -w 32 -e 0x3FFF -o bootloader.hex
~~~

rode **Update Memory Initialization File + Start Assembler** no
Quartus e grave o `.sof` via JTAG

Para ficar permanente gere o `.jic` em file -> convert programing
files, se já tiver configurado o comando a seguir gera:
~~~
quartus_cpf -c conversion.cof
~~~

na gravação apague o diagrama e carregue o `.jic` que ficará gravado
na flash

A aplicação (Gravada na flash externa é transferida e roda na SDRAM)
pode ser atualizada em campo via `make_boot_image.py` e
 `serial_flash_update.py`, sem utilizar o Quartus.

## Veja também

- [software/bootloader/README.md](software/bootloader/README.md) -- Protocolo de atualização, layout da imagem `.nvbi`
- [software/app/README.md](software/app/README.md)
- [software/app_spi_test/README.md](software/app_spi_test/README.md) -- ferramenta de diagnóstico da flash SPI
- [software/Comandos.md](software/Comandos.md) -- comandos de build/BSP/gravação passo a passo
- [docs/pinout.csv](pcb/pinout_completo.csv) -- pinout completo
- [docs/board.jpeg](pcb/operando.jpeg) -- Foto
- [docs/EP4CE6_Generic_Board_Schematic](EP4CE6_Generic_Board_Schematic.pdf) -- Diagrama Esquemático