# Build

Comandos para gerar o BSP, compilar o software Nios V, gravar via JTAG e atualizar o firmware via serial. Todos os comandos assumem que o diretório atual é a **raiz do repositório** (onde estão `niosV.qpf`, `niosV_ip.sopcinfo`, `bsp_config_boot.tcl`, `conversion.cof`, `make_boot_image.py`, `serial_flash_update.py`), salvo indicação contrária.

## Pré-requisitos

- Quartus Prime com o toolchain Nios V (`niosv-bsp`, `niosv-app`, `niosv-download`, `elf2hex`) disponível no PATH ou no Nios V Shell.
- CMake + Ninja.
- Python 3 com `pyserial` instalado (para `make_boot_image.py`/`serial_flash_update.py`).

> Em alguns ambientes Windows `elf2hex`/`niosv-stack-report` não ficam no PATH do shell. Se o comando "não for reconhecido", chame pelo caminho completo dentro da instalação do Quartus (ex.: `.../niosv/bin/elf2hex.exe`) ou no Nios V Shell.

## 0.0 Gerar o IP 

No Quartus em Tools - > Platform Designer (abre niosV_ip.qsys) - > Gerar HDL

## 0.1 Compilar o HDL

No Quartus em Start Compilation

## 0.2 Gravar o hardware no FPGA via Jtag  (volátil - arquivo: output_files - > .sof ) 

No Quartus Programmer

## 1. Gerar os BSP do bootloader e APP

Criar as pastas bootloader_bsp e bsp.

Gerar `software/bootloader_bsp/` com o comando a partir de `niosV_ip.sopcinfo` e `bsp_config_boot.tcl` (ambos versionados na raiz) — não fica no controle de versão, então rode isto após clonar o repositório ou sempre que o sistema Platform Designer mudar:

```
niosv-bsp -c -t=hal --sopcinfo=niosV_ip.sopcinfo --script=bsp_config_boot.tcl software/bootloader_bsp/settings.bsp
```

O mesmo padrão vale para `software/bsp/` (BSP do app), usando `bsp_config_app.tcl`.

```
niosv-bsp -c -t=hal --sopcinfo=niosV_ip.sopcinfo --script=bsp_config_app.tcl software/bsp/settings.bsp
```

para abrir o bsp editor gráfico

```
niosv-bsp-editor
```

## 2. Gerar a estrutura de projeto (CMake) do bootloader

Só executar se precisar recriar ou reconfigurar o CMakelist.txt (ou se o BSP mudar de forma estrutural) — cria `software/bootloader/CMakeLists.txt` e `software/app/CMakeLists.txt`:

OBS: sobrescreverá configuração atual que já gera o arquivo bootloader.hex com o mesmo nome configurado na memória on-chip

```
niosv-app -a=software/bootloader -b=software/bootloader_bsp -s=software/bootloader/main.c
niosv-app -a=software/app -b=software/bsp -s=software/app/main.c

```

## 3. Compilar

Compilação padrão:

```
cmake --fresh -B software/bootloader/build -S software/bootloader -G "Ninja"
cmake --build software/bootloader/build
```

```
cmake --fresh -B software/app/build -S software/app -G "Ninja"
cmake --build software/app/build
```

Compilação otimizada para tamanho (`MinSizeRel`):

```
cmake --fresh -B software/bootloader/build -S software/bootloader -G "Ninja" -DCMAKE_BUILD_TYPE=MinSizeRel
ninja -C software/bootloader/build
```

Recompilar depois de alterações (bootloader e/ou app):

```
cmake --build software/app/build
cmake --build software/bootloader/build
```

Compilar só um alvo específico:

```
cmake --build software/bootloader/build --target bootloader.elf
```

ainda é possível na pasta do app:
```
cd software/app
cmake --fresh -B build -G "Ninja"
cmake --build build
```
ou

```
cd build
ninja clean
ninja
```

## 4. Gravar via JTAG

```
niosv-download -g software/bootloader/build/bootloader.elf
niosv-download -g software/app/build/app.elf
```

# Para gravação não volátil

## 5. Converter `.elf` para `.hex` para integrar inicialização da memória on-chip por hardware

O `CMakeLists.txt` já gera `bootloader.hex` automaticamente durante `cmake --build` (usado como `INIT_FILE` de `onchip_memory2_0` no Quartus). Comando manual equivalente, se precisar rodar isolado:

```
elf2hex software/bootloader/build/bootloader.elf -b 0x0 -w 32 -e 0x3FFF -o software/bootloader/build/bootloader.hex
```

o caminho software\bootloader\build\bootloader.hex está configurado na `onchip_memory2_0`, mas para atualizar no Quartus:

Processing - > Update Memory Initialization File

Processing - > Start - > Start Assembler

Após isso o hardware do SOC e o firmware do bootloader estão integrados no arquivo `.sof` que pode ser gravado no hardware do FPGA (volátil)

## 6. Gerar o `.jic`(SPI Flash - não volátil) a partir do `.sof` (volátil)

No Quartus vá em FIles - > Convert Programming Files, carregue conversion.cof se o FPGA ou sua Flash de configuração forem diferentes tem que ser reconfigurado, depois clique em `Save Conversion Setup` e `Generate`

Depois isso pode ser feito também com o comando:
```
quartus_cpf -c conversion.cof
```

o arquivo conversion.cof é um arquivo de configuração do hardware criado no Quartus menu: 

Graver o `.jic` no FPGA no Quartus - > Programmer - pode ser necessário excluir o arquivo anterior e adicionar o `.jic`

## 7. Atualizar firmware na Flash de programa (app) via serial (sem JTAG)

```
python make_boot_image.py software/app/build/app.elf software/app/build/app.bin
python serial_flash_update.py --port COM8 --baud 115200 software/app/build/app.bin
```

Para verbosidade/depuração (`-v` liga o modo verboso.)

```
python serial_flash_update.py --port COM8 --baud 115200 -v software/app/build/app.bin
```