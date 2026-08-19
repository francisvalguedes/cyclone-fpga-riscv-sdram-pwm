# Bootloader Nios V (A25L80P -> SDRAM)

Este bootloader roda na RAM interna do Nios V. Ao ligar, ele:

1. Verifica o **botao de gatilho** (bit 0 do `pio_1`, ativo em nivel
   baixo, mesmo periferico de botoes usado em `software/app/main.c`). Se
   estiver pressionado, aguarda por um curto intervalo o handshake do
   protocolo de **atualizacao de firmware via serial**. Se detectado,
   recebe uma nova imagem `.nvbi`, grava-a na A25L80P (com verificacao por
   CRC32) e informa o resultado pela UART.
2. Em qualquer outro caso (botao solto, ou timeout do handshake apos o
   botao pressionado), segue o fluxo normal: le o cabecalho da imagem
   gravada na A25L80P, copia a aplicacao para a SDRAM e salta para o ponto
   de entrada.


## Layout da A25L80P

```
0x000000 .. 0x00001F   boot_image_header_t (32 bytes)
0x000020 ..            imagem binaria da aplicacao (linkada para a SDRAM)
```

O cabecalho e gerado por `tools/make_boot_image.py` a partir do binario da
aplicacao (veja aquele script para o formato exato do `.nvbi`).

## Atualizacao de firmware via serial

Arquivos: `serial_boot.h` / `serial_boot.c`.

Fluxo:

1. Ao ligar, o bootloader verifica o botao de gatilho
   (`SERIAL_BOOT_BUTTON_MASK` = bit 0 do `pio_1`, ativo em nivel baixo, em
   `main.c`). Se estiver pressionado, escuta a UART por uma janela de
   tempo (`SERIAL_BOOT_HANDSHAKE_POLLS`) esperando o byte `'U'` enviado
   repetidamente pela ferramenta host. Ao detectar, responde `'C'` e entra
   no modo de recepcao. Se o botao nao estiver pressionado, o bootloader
   segue direto para o boot normal, sem tocar na UART.

2. O host envia um pacote **START** (16 bytes: magic + tamanho da imagem +
   CRC32 da imagem + CRC32 do proprio pacote). O bootloader confere o CRC32
   do pacote, o magic e se a imagem cabe na SDRAM/flash, e responde
   ACK (`0x06`) ou NAK (`0x15`).
3. O host envia a imagem em pacotes **DATA** de ate 256 bytes (numero de
   sequencia + tamanho + payload + CRC32). Cada pacote e confirmado
   individualmente com ACK/NAK; em caso de NAK o host deve reenviar o
   mesmo pacote.
4. Ao completar o recebimento, o bootloader:
   - confere o CRC32 da imagem completa (staged na SDRAM);
   - apaga os blocos de 64 KB necessarios da A25L80P;
   - grava a imagem pagina a pagina (256 bytes);
   - le de volta e confere o CRC32 gravado;
   - responde `DONE` (`0x04`) em sucesso, ou `ERR` (`0x15`) seguido de um
     byte de codigo de erro em caso de falha.
5. Independente do resultado, o bootloader segue para o fluxo normal de
   boot (le o cabecalho da A25L80P e salta para a aplicacao). Se a
   gravacao teve sucesso, a nova imagem sera a executada.

A area de staging usada para receber a imagem antes de grava-la na flash e
a propria SDRAM (`NEW_SDRAM_CONTROLLER_0_BASE`), reaproveitando o espaco
que normalmente recebe a aplicacao copiada da flash.

### Ferramenta host

Use `tools/serial_flash_update.py` (requer `pip install pyserial`):

```
python tools/serial_flash_update.py --port COM5 app.nvbi
```

O script executa o handshake, envia o pacote START, todos os pacotes DATA
com retransmissao automatica em caso de NAK, e exibe o progresso e o
resultado final.

### Observacoes / limitacoes

- O protocolo e implementado por polling (sem interrupcoes) para manter o
  bootloader pequeno; os timeouts sao baseados em contagem de iteracoes,
  nao em um timer de hardware, entao sao aproximados e dependem da
  frequencia de clock do Nios V configurada no projeto.
- Nao ha autenticacao/assinatura da imagem; qualquer host que fale o
  protocolo pode regravar a flash. Se isso for uma preocupacao, considere
  adicionar uma checagem adicional (chave/senha) no pacote START.
- O CRC32 e o mesmo algoritmo em ambos os lados (poly 0xEDB88320, init
  0xFFFFFFFF, xorout 0xFFFFFFFF), permitindo usar `zlib.crc32` no host.

## Compilando

```
cmake -S software/bootloader -B software/bootloader/build -G Ninja
cmake --build software/bootloader/build --target bootloader.elf
```

Verifique o tamanho do binario (deve caber na RAM interna do Nios V,
tipicamente 16 KB):

```
riscv32-unknown-elf-size software/bootloader/build/bootloader.elf
```
