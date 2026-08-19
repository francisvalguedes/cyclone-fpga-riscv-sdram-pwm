#!/usr/bin/env python3
"""
Envia uma imagem .nvbi ao bootloader do Nios V pela porta serial, usando o
protocolo simples implementado em software/bootloader/serial_boot.c/.h.

A imagem deve ter sido gerada com make_boot_image.py (cabecalho NVBI de 32
bytes + binario da aplicacao); este script confere esse cabecalho antes de
enviar para evitar gravar uma imagem sem cabecalho por engano.

Requer o pacote pyserial (pip install pyserial).

Uso:
    python make_boot_image.py app.elf app.bin
    python serial_flash_update.py --port COM5 app.bin
    python serial_flash_update.py --port /dev/ttyUSB0 --baud 115200 app.bin

Em caso de falha na gravacao, o bootloader (a partir desta versao) responde
com um relatorio estruturado (etapa + offset na flash + codigo do driver da
spi flash) em vez de apenas um codigo generico; requer o bootloader.elf
recompilado com as mudancas correspondentes em serial_boot.c/.h.
"""

import argparse
import pathlib
import struct
import sys
import time
import zlib

try:
    import serial
except ImportError:
    print("Erro: pacote 'pyserial' nao encontrado. Instale com: pip install pyserial",
          file=sys.stderr)
    sys.exit(1)

MAGIC = 0x50555654  # "TVUP" em little-endian

# Cabecalho NVBI esperado no INICIO do arquivo enviado (ver make_boot_image.py
# e boot_image_header_t em software/bootloader/main.c). O bootloader grava os
# bytes recebidos diretamente a partir do offset 0 da spi flash, que e onde ele
# espera achar esse cabecalho no boot normal seguinte -- enviar um .bin "cru"
# (sem rodar make_boot_image.py antes) sobrescreve essa area com lixo.
NVBI_MAGIC = 0x4E564249  # "NVBI"
NVBI_HEADER_FORMAT = "<8I"
NVBI_HEADER_SIZE = 32

ACK = 0x06
NAK = 0x15
DONE = 0x04
ERR = 0x15
MAX_PACKET = 256
MAX_RETRIES = 5
HANDSHAKE_TIMEOUT_S = 15.0
BYTE_TIMEOUT_S = 40.0
# Espera pelo status final (DONE/ERR) apos o ultimo pacote DATA: cobre o
# apagar+gravar+verificar da imagem inteira na spi flash (uma imagem de ~95 KB
# passa por ~375 paginas), entao precisa de bem mais margem que um timeout
# de byte avulso.
FINAL_STATUS_TIMEOUT_S = 240.0

# Tamanho do relatorio estruturado que segue o byte ERR (ver serial_boot.h):
# protocol_code(1) + stage(1) + driver_code(1) + offset(4, little-endian).
ERR_REPORT_BYTES = 7

# Codigos de protocolo (SERIAL_BOOT_ERR_* em software/bootloader/serial_boot.c).
PROTOCOL_ERROR_NAMES = {
    1: "timeout aguardando dados do host",
    2: "CRC32 invalido",
    3: "magic invalido",
    4: "tamanho invalido",
    5: "numero de sequencia invalido",
    6: "falha na flash (erase/gravacao)",
    7: "falha na verificacao (leitura pos-gravacao)",
}

# Etapas em que a falha ocorreu (SERIAL_BOOT_STAGE_* em serial_boot.h).
STAGE_NAMES = {
    0: "geral",
    1: "apagar bloco (erase)",
    2: "gravar pagina (program)",
    3: "ler de volta para verificacao (verify-read)",
    4: "conferir CRC32 final (verify-crc)",
}

# Codigos da camada de driver da flash.
DRIVER_ERROR_NAMES = {
    0: "nenhum",
    1: "argumento invalido",
    2: "erro de transferencia SPI",
    3: "timeout aguardando flash pronta (WIP)",
    4: "offset/tamanho fora da faixa",
    5: "timeout no nucleo SPI (TRDY/RRDY/TMT nao respondeu)",
}

# DEBUG: nível de verbosidade
VERBOSE = False


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def hexdump(data: bytes, max_bytes: int = 64) -> str:
    """Retorna um dump hex da mensagem para depuração."""
    if len(data) > max_bytes:
        data = data[:max_bytes]
        return " ".join(f"{b:02X}" for b in data) + " ..."
    return " ".join(f"{b:02X}" for b in data)


def debug_log(msg: str, data: bytes = None, prefix: str = "DEBUG") -> None:
    """Log de depuração com dados opcionais."""
    if not VERBOSE:
        return
    if data is not None:
        print(f"[{prefix}] {msg}: {len(data)} bytes")
        print(f"[{prefix}]   HEX: {hexdump(data)}")
        # Tenta interpretar como ASCII se todos os bytes forem imprimíveis
        if all(32 <= b < 127 or b in (10, 13) for b in data):
            try:
                print(f"[{prefix}]   ASC: {data.decode('ascii', errors='ignore')}")
            except:
                pass
    else:
        print(f"[{prefix}] {msg}")


def read_exact(ser: serial.Serial, count: int, timeout: float) -> bytes:
    """Lê exatamente 'count' bytes binarios (sem filtrar ASCII), com timeout total."""
    data = bytearray()
    deadline = time.monotonic() + timeout
    while len(data) < count and time.monotonic() < deadline:
        chunk = ser.read(count - len(data))
        if chunk:
            data.extend(chunk)
        else:
            time.sleep(0.001)
    if len(data) < count:
        raise TimeoutError(
            f"Timeout lendo detalhes do erro: esperado {count} bytes, "
            f"recebido {len(data)} ({hexdump(bytes(data))})."
        )
    return bytes(data)


def describe_error_report(report: bytes) -> str:
    """Decodifica o relatorio estruturado de 7 bytes enviado apos ERR (ver
    SERIAL_BOOT_ERR em software/bootloader/serial_boot.h) em uma mensagem
    legivel para o usuario."""
    protocol_code, stage, driver_code, offset = struct.unpack("<BBBI", report)

    protocol_desc = PROTOCOL_ERROR_NAMES.get(protocol_code, f"codigo desconhecido {protocol_code}")
    stage_desc = STAGE_NAMES.get(stage, f"etapa desconhecida {stage}")

    lines = [
        f"Bootloader reportou erro: {protocol_desc} (codigo -{protocol_code}).",
        f"  Etapa: {stage_desc}",
    ]
    if stage in (1, 2, 3):
        lines.append(f"  Offset na Flash SPI: 0x{offset:06X} ({offset} bytes)")
    if driver_code:
        driver_desc = DRIVER_ERROR_NAMES.get(driver_code, f"codigo desconhecido {driver_code}")
        lines.append(f"  Causa na camada de flash: {driver_desc} (codigo -{driver_code})")
    return "\n".join(lines)


def parse_nvbi_header(image_bytes: bytes):
    """Decodifica o cabecalho NVBI (32 bytes) no inicio da imagem, se presente
    e valido (magic + CRC32 do proprio cabecalho conferem). Retorna None se a
    imagem nao comeca com um cabecalho NVBI reconhecivel -- provavelmente
    porque foi enviado o .bin cru, sem passar por make_boot_image.py antes."""
    if len(image_bytes) < NVBI_HEADER_SIZE:
        return None

    (magic, version, header_size, image_size, load_address,
     entry_address, image_crc32, header_crc32) = struct.unpack(
        NVBI_HEADER_FORMAT, image_bytes[:NVBI_HEADER_SIZE])

    if magic != NVBI_MAGIC or header_size != NVBI_HEADER_SIZE:
        return None

    header_zeroed = image_bytes[:NVBI_HEADER_SIZE - 4] + b"\x00\x00\x00\x00"
    if crc32(header_zeroed) != header_crc32:
        return None

    return {
        "version": version,
        "image_size": image_size,
        "load_address": load_address,
        "entry_address": entry_address,
        "image_crc32": image_crc32,
    }


def handshake(ser: serial.Serial) -> None:
    """Realiza o handshake com o bootloader."""
    print("Aguardando bootloader (envie o reset da placa agora se necessario)...")
    debug_log("Iniciando handshake, enviando 'U' (0x55) repetidamente")
    
    deadline = time.monotonic() + HANDSHAKE_TIMEOUT_S
    ser.reset_input_buffer()
    
    # Limpa o buffer de entrada antes de começar
    ser.reset_input_buffer()
    debug_log("Buffer de entrada limpo")
    
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        ser.write(b"U")
        ser.flush()
        debug_log(f"Enviado 'U' (0x55) #{attempt}")
        
        # Lê qualquer resposta disponível
        response = ser.read(1)
        if response:
            debug_log(f"Resposta recebida: 0x{response[0]:02X} ('{chr(response[0]) if 32 <= response[0] < 127 else '?'}')")
            
            if response == b"C":
                print("Handshake OK, bootloader pronto para receber.")
                debug_log("Handshake completado com sucesso!")
                return
            
            # Se recebeu algo diferente de 'C', mostra e continua
            print(f"Resposta inesperada do bootloader: 0x{response[0]:02X} ('{chr(response[0]) if 32 <= response[0] < 127 else '?'}'), continuando...")
        else:
            # Se não recebeu nada, continua enviando 'U'
            if attempt % 10 == 0:
                print(f"Aguardando resposta... (enviado 'U' {attempt} vezes)")
    
    raise TimeoutError("Nao foi possivel completar o handshake com o bootloader. "
                       "Verifique se a placa esta ligada/resetada e a porta correta.")


def read_ack(ser: serial.Serial, expected_cmd: str = "ACK/NAK") -> int:
    """Lê um byte de resposta do bootloader, ignorando caracteres ASCII."""
    debug_log(f"Aguardando resposta ({expected_cmd})")
    
    # Lê bytes até encontrar ACK (0x06), NAK (0x15), DONE (0x04) ou ERR (0x15)
    start_time = time.monotonic()
    timeout = BYTE_TIMEOUT_S
    
    while time.monotonic() - start_time < timeout:
        if ser.in_waiting:
            byte = ser.read(1)[0]
            
            # Se for byte de protocolo, retorna
            if byte in (ACK, NAK, DONE, ERR):
                debug_log(f"Resposta de protocolo: 0x{byte:02X}")
                return byte
            
            # Se for caractere ASCII imprimível, ignora (depuração)
            if 32 <= byte <= 126 or byte in (10, 13):  # imprimível ou CR/LF
                debug_log(f"Ignorando caractere de depuração: '{chr(byte)}' (0x{byte:02X})")
                continue
            
            # Se for outro byte não imprimível (exceto protocolo), log e ignora
            debug_log(f"Ignorando byte não protocolo: 0x{byte:02X}")
            continue
        
        # Pequena pausa para não sobrecarregar a CPU
        time.sleep(0.001)
    
    raise TimeoutError("Timeout aguardando resposta do device.")


def send_start(ser: serial.Serial, image: bytes) -> None:
    """Envia o pacote START para o bootloader."""
    # Prepara o pacote START
    header = struct.pack("<3I", MAGIC, len(image), crc32(image))
    packet = header + struct.pack("<I", crc32(header))
    
    debug_log("Preparando pacote START", data=packet)
    debug_log(f"  MAGIC: 0x{MAGIC:08X} ('TVUP')")
    debug_log(f"  image_size: {len(image)} bytes")
    debug_log(f"  image_crc32: 0x{crc32(image):08X}")
    debug_log(f"  packet_crc32: 0x{crc32(header):08X}")

    for attempt in range(MAX_RETRIES):
        print(f"Enviando pacote START (tentativa {attempt + 1}/{MAX_RETRIES})...")
        debug_log(f"Enviando START, tamanho total: {len(packet)} bytes", data=packet)
        
        ser.write(packet)
        ser.flush()
        debug_log("Pacote START enviado, aguardando resposta...")
        
        try:
            status = read_ack(ser, "START")
        except TimeoutError as e:
            print(f"Timeout na resposta do START: {e}")
            debug_log(f"Timeout no START, tentativa {attempt + 1}")
            continue
        
        if status == ACK:
            print("START aceito pelo bootloader.")
            debug_log("START OK!")
            return
        elif status == NAK:
            # Tenta ler dados adicionais (código de erro)
            error_code = ser.read(1)
            if error_code:
                debug_log(f"Código de erro adicional: 0x{error_code[0]:02X} (na prática: -{error_code[0]})")
                print(f"START rejeitado (NAK), código de erro: -{error_code[0]} (0x{error_code[0]:02X}), tentativa {attempt + 1}/{MAX_RETRIES}...")
            else:
                print(f"START rejeitado (NAK), tentativa {attempt + 1}/{MAX_RETRIES}...")
        else:
            debug_log(f"Resposta inesperada: 0x{status:02X}")
            print(f"Resposta inesperada: 0x{status:02X}, tentativa {attempt + 1}/{MAX_RETRIES}...")
        
        # Pequena pausa antes de reenviar
        time.sleep(0.5)
    
    # Se chegou aqui, todas as tentativas falharam
    # Tenta ler o buffer para ver se tem mais dados
    pending = ser.in_waiting
    if pending:
        debug_log(f"Buffer tem {pending} bytes pendentes")
        pending_data = ser.read(pending)
        debug_log("Dados pendentes", data=pending_data)
    
    raise RuntimeError("Bootloader rejeitou o pacote START apos varias tentativas.")


def send_data(ser: serial.Serial, image: bytes) -> None:
    """Envia os dados da imagem em pacotes."""
    total = len(image)
    offset = 0
    seq = 0
    
    debug_log(f"Iniciando envio de dados: {total} bytes")

    while offset < total:
        chunk = image[offset:offset + MAX_PACKET]
        header = struct.pack("<HH", seq & 0xFFFF, len(chunk))
        packet = header + chunk + struct.pack("<I", crc32(header + chunk))
        
        debug_log(f"Preparando pacote DATA seq={seq}", data=packet)
        debug_log(f"  seq={seq}, len={len(chunk)}, offset={offset}")

        for attempt in range(MAX_RETRIES):
            ser.write(packet)
            ser.flush()
            debug_log(f"Pacote DATA seq={seq} enviado, aguardando ACK")
            
            try:
                status = read_ack(ser, f"DATA seq={seq}")
            except TimeoutError as e:
                print(f"Timeout no pacote seq={seq}, tentativa {attempt + 1}/{MAX_RETRIES}...")
                debug_log(f"Timeout no DATA seq={seq}")
                continue
            
            if status == ACK:
                debug_log(f"Pacote DATA seq={seq} OK")
                break
            elif status == NAK:
                # Tenta ler dados adicionais (código de erro)
                error_code = ser.read(1)
                if error_code:
                    debug_log(f"Código de erro adicional: 0x{error_code[0]:02X}")
                    print(f"Pacote seq={seq} rejeitado (NAK), erro: -{error_code[0]}, tentativa {attempt + 1}/{MAX_RETRIES}...")
                else:
                    print(f"Pacote seq={seq} rejeitado (NAK), tentativa {attempt + 1}/{MAX_RETRIES}...")
                debug_log("Reenviando pacote DATA")
            else:
                debug_log(f"Resposta inesperada no DATA: 0x{status:02X}")
                print(f"Resposta inesperada no pacote seq={seq}: 0x{status:02X}, tentativa {attempt + 1}/{MAX_RETRIES}...")
            
            time.sleep(0.2)
        else:
            raise RuntimeError(f"Bootloader rejeitou o pacote seq={seq} apos varias tentativas.")

        offset += len(chunk)
        seq += 1
        percent = (offset * 100) // total
        print(f"\renviando... {percent:3d}% ({offset}/{total} bytes)", end="", flush=True)

    print()
    debug_log(f"Todos os {seq} pacotes enviados com sucesso")


def wait_final_status(ser: serial.Serial) -> None:
    """Aguarda o status final da gravação, ignorando texto de depuração."""
    print("Aguardando gravacao na spi flash (pode levar alguns segundos)...")
    debug_log("Aguardando status final")
    
    # Primeiro, verifica se há dados pendentes no buffer
    pending = ser.in_waiting
    if pending:
        debug_log(f"Buffer tem {pending} bytes pendentes ANTES do status final")
        pending_data = ser.read(pending)
        debug_log("Dados pendentes", data=pending_data)
    
    # Procura por DONE (0x04) ou ERR (0x15) ignorando texto ASCII
    start_time = time.monotonic()
    timeout = FINAL_STATUS_TIMEOUT_S
    
    while time.monotonic() - start_time < timeout:
        if ser.in_waiting:
            byte = ser.read(1)[0]
            
            debug_log(f"Byte recebido no status final: 0x{byte:02X} ('{chr(byte) if 32 <= byte < 127 else '?'}')")
            
            # Se for DONE (sucesso)
            if byte == DONE:
                print("Firmware gravado e verificado com sucesso!")
                debug_log("DONE (0x04) recebido")
                return
            
            # Se for ERR (erro): segue um relatorio estruturado de
            # ERR_REPORT_BYTES bytes (protocol_code, stage, driver_code,
            # offset) -- ver describe_error_report() e serial_boot.h.
            if byte == ERR:
                report = read_exact(ser, ERR_REPORT_BYTES, BYTE_TIMEOUT_S)
                debug_log("Relatorio de erro recebido", data=report)
                raise RuntimeError(describe_error_report(report))
            
            # Se for caractere ASCII imprimível ou CR/LF, ignora (depuração)
            if (32 <= byte <= 126) or (byte in (10, 13)):
                debug_log(f"Ignorando caractere de depuração: '{chr(byte)}' (0x{byte:02X})")
                continue
            
            # Qualquer outro byte não esperado
            debug_log(f"Byte inesperado: 0x{byte:02X}, continuando...")
            continue
        
        # Pequena pausa
        time.sleep(0.01)
    
    # Se chegou aqui, timeout
    # Tenta ler o que sobrou no buffer para diagnóstico
    pending = ser.in_waiting
    if pending:
        debug_log(f"Timeout: {pending} bytes pendentes no buffer")
        data = ser.read(pending)
        debug_log("Dados pendentes", data=data)
        try:
            texto = data.decode('ascii', errors='ignore')
            debug_log(f"Texto pendente: {texto}")
        except:
            pass
    
    raise TimeoutError("Timeout aguardando status final (DONE/ERR) do bootloader.")


def main() -> int:
    global VERBOSE
    
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", type=pathlib.Path, help="arquivo .nvbi a enviar")
    parser.add_argument("--port", required=True, help="porta serial (ex: COM5, /dev/ttyUSB0)")
    parser.add_argument("--baud", type=int, default=115200, help="baud rate (padrao: 115200)")
    parser.add_argument("-v", "--verbose", action="store_true", help="modo verboso para depuração")
    parser.add_argument("--skip-header-check", action="store_true",
                         help="envia mesmo sem um cabecalho NVBI valido no inicio do arquivo "
                              "(perigoso: normalmente indica que make_boot_image.py nao foi rodado)")
    args = parser.parse_args()

    VERBOSE = args.verbose

    image_bytes = args.image.read_bytes()
    if not image_bytes:
        print("Erro: arquivo de imagem vazio.", file=sys.stderr)
        return 1

    print(f"Imagem: {args.image} ({len(image_bytes)} bytes, CRC32=0x{crc32(image_bytes):08X})")

    nvbi_header = parse_nvbi_header(image_bytes)
    if nvbi_header is None:
        print(
            "Aviso: o arquivo nao comeca com um cabecalho NVBI valido (magic/CRC nao conferem).\n"
            "         O bootloader grava estes bytes a partir do offset 0 da spi flash, que e onde\n"
            "         ele espera esse cabecalho no boot normal seguinte -- sem ele, apos a gravacao\n"
            "         'com sucesso' o proximo boot falhara com 'cabecalho invalido'.\n"
            "         Gere a imagem correta antes com:\n"
            f"           python make_boot_image.py <app.elf> {args.image}",
            file=sys.stderr,
        )
        if not args.skip_header_check:
            print("Abortando (use --skip-header-check para enviar assim mesmo).", file=sys.stderr)
            return 1
    else:
        print(
            f"Cabecalho NVBI OK: versao={nvbi_header['version']}, "
            f"payload={nvbi_header['image_size']} bytes, "
            f"load=0x{nvbi_header['load_address']:08X}, "
            f"entry=0x{nvbi_header['entry_address']:08X}, "
            f"CRC32(payload)=0x{nvbi_header['image_crc32']:08X}"
        )

    if VERBOSE:
        # Mostra os primeiros 64 bytes da imagem para diagnóstico
        print(f"Primeiros 64 bytes da imagem: {hexdump(image_bytes[:64])}")
        print(f"Tamanho da imagem: {len(image_bytes)} bytes")
        print(f"CRC32 da imagem: 0x{crc32(image_bytes):08X}")
        print(f"MAGIC esperado: 0x{MAGIC:08X} ('TVUP')")
        print(f"ACK esperado: 0x{ACK:02X}, NAK: 0x{NAK:02X}, DONE: 0x{DONE:02X}")

    with serial.Serial(args.port, args.baud, timeout=BYTE_TIMEOUT_S) as ser:
        debug_log(f"Porta serial aberta: {args.port} @ {args.baud} baud")
        debug_log(f"Configuração: {ser}")
        
        try:
            handshake(ser)
            
            # Pausa curta após handshake
            time.sleep(0.1)
            
            send_start(ser, image_bytes)
            
            # Pausa curta antes de enviar dados
            time.sleep(0.1)
            
            send_data(ser, image_bytes)
            wait_final_status(ser)
            
        except (TimeoutError, RuntimeError, serial.SerialException) as exc:
            print(f"\nErro: {exc}", file=sys.stderr)
            
            # Informações adicionais em caso de erro
            if hasattr(ser, 'in_waiting') and ser.in_waiting:
                pending = ser.in_waiting
                print(f"\nDados pendentes no buffer ({pending} bytes):", file=sys.stderr)
                data = ser.read(pending)
                if data:
                    print(f"HEX: {hexdump(data)}", file=sys.stderr)
                    try:
                        if all(32 <= b < 127 or b in (10, 13) for b in data):
                            print(f"ASC: {data.decode('ascii', errors='ignore')}", file=sys.stderr)
                    except:
                        pass
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())