@echo off
REM Apaga e recria os BSPs (software\bsp e software\bootloader_bsp), apaga os
REM diretorios de build do app e do bootloader, e reconfigura o CMake (Ninja)
REM para os dois, sem compilar. Rode a partir de um shell com o PATH do
REM niosv-shell ja configurado (niosv-bsp, niosv-app, cmake, ninja).
REM
REM Uso:
REM   regenerate_bsp.bat
setlocal EnableDelayedExpansion
cd /d "%~dp0"

echo ============================================================
echo  Regenerando BSPs, apagando builds e configurando o CMake
echo  Diretorio: %CD%
echo ============================================================
echo.

echo [1/6] Apagando software\bsp ...
if exist "software\bsp" rmdir /s /q "software\bsp"

echo [1/6] Apagando software\bootloader_bsp ...
if exist "software\bootloader_bsp" rmdir /s /q "software\bootloader_bsp"

echo [1/6] Apagando software\app\build ...
if exist "software\app\build" rmdir /s /q "software\app\build"

echo [1/6] Apagando software\bootloader\build ...
if exist "software\bootloader\build" rmdir /s /q "software\bootloader\build"
echo.

echo [2/6] Gerando BSP do app (software\bsp) ...
call niosv-bsp -c -t=hal --sopcinfo=niosV_ip.sopcinfo --script=bsp_config_app.tcl software\bsp\settings.bsp
if errorlevel 1 goto :erro
echo.

echo [3/6] Gerando BSP do bootloader (software\bootloader_bsp) ...
call niosv-bsp -c -t=hal --sopcinfo=niosV_ip.sopcinfo --script=bsp_config_boot.tcl software\bootloader_bsp\settings.bsp
if errorlevel 1 goto :erro
echo.

echo [4/6] Gerando estrutura do app (niosv-app) ...
call niosv-app -a=software\app -b=software\bsp -s=software\app\main.c
if errorlevel 1 goto :erro

REM niosv-app so inclui em target_sources o(s) arquivo(s) passado(s) em -s
REM (aqui, so main.c). CMake aceita chamar target_sources() varias vezes
REM para o mesmo alvo (elas se acumulam), entao completamos aqui os demais
REM .c do app sem depender do que o niosv-app gerou nem escanear o
REM diretorio (evita pegar arquivos de backup tipo "main copy*.c" por
REM engano). Se adicionar um novo .c ao app, inclua o nome dele aqui tambem.
echo target_sources(app.elf PRIVATE a25l80.c)>> software\app\CMakeLists.txt
echo.

echo [5/6] Gerando estrutura do bootloader (niosv-app) ...
call niosv-app -a=software\bootloader -b=software\bootloader_bsp -s=software\bootloader\main.c
if errorlevel 1 goto :erro

REM Mesma logica do app acima: completa os .c do bootloader que o niosv-app
REM nao incluiu (so recebeu main.c via -s). Se adicionar um novo .c ao
REM bootloader, inclua o nome dele aqui tambem.
echo target_sources(bootloader.elf PRIVATE a25l80.c serial_boot.c crc32.c)>> software\bootloader\CMakeLists.txt

REM O create-hex que o niosv-app gera (onchip_memory2_0.hex / new_sdram_
REM controller_0.hex) nao e o arquivo que a memoria on-chip realmente usa:
REM niosV_ip_onchip_memory2_0.v tem INIT_FILE apontando para
REM software\bootloader\build\bootloader.hex (nome fixo, caminho absoluto).
REM Gera esse arquivo automaticamente a cada build, no lugar do passo manual
REM de elf2hex.
echo add_custom_command(OUTPUT "bootloader.hex" DEPENDS bootloader.elf COMMAND elf2hex bootloader.elf -o bootloader.hex -b 0x0 -w 32 -e 0x3FFF COMMENT "Creating bootloader.hex (INIT_FILE da onchip_memory2_0)." VERBATIM)>> software\bootloader\CMakeLists.txt
echo add_custom_target(create-bootloader-hex ALL DEPENDS "bootloader.hex")>> software\bootloader\CMakeLists.txt
echo.

echo [6/6] Configurando CMake (Ninja) do app ...
pushd software\app
call cmake --fresh -B build -G "Ninja"
if errorlevel 1 (
    popd
    goto :erro
)
popd
echo.

echo [6/6] Configurando CMake (Ninja) do bootloader ...
pushd software\bootloader
call cmake --fresh -B build -G "Ninja"
if errorlevel 1 (
    popd
    goto :erro
)
popd
echo.

echo ============================================================
echo  Concluido com sucesso.
echo  Para compilar:
echo    cmake --build software\app\build
echo    cmake --build software\bootloader\build
echo ============================================================
exit /b 0

:erro
echo.
echo ============================================================
echo  ERRO: um dos passos acima falhou (ver mensagem de erro anterior).
echo ============================================================
exit /b 1
