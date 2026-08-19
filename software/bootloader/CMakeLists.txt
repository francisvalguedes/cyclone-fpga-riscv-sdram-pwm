cmake_minimum_required(VERSION 3.14)

add_subdirectory(../bootloader_bsp bootloader_bsp)

include(../bootloader_bsp/toolchain.cmake)

project(bootloader)

enable_language(ASM)
enable_language(C)
enable_language(CXX)

add_executable(bootloader.elf)

target_sources(bootloader.elf
    PRIVATE
        main.c
)

target_include_directories(bootloader.elf
    PRIVATE
        ../common
    PUBLIC
)

target_link_libraries(bootloader.elf
    PRIVATE
        -T "${BspLinkerScript}" -nostdlib
        "${ExtraArchiveLibraries}"
        -Wl,--start-group "${BspLibraryName}" -lc -lstdc++ -lgcc -lm -Wl,--end-group
)

# Create objdump from ELF.
set(objdump bootloader.elf.objdump)
add_custom_command(
    OUTPUT "${objdump}"
    DEPENDS bootloader.elf
    COMMAND "${ToolchainObjdump}" "${ToolchainObjdumpFlags}" bootloader.elf >
            "${objdump}"
    COMMENT "Creating ${objdump}."
    VERBATIM
)
add_custom_target(create-objdump ALL DEPENDS "${objdump}")

# Report space free for stack + heap. Note that the file below is never created
# so the report is always output on build.
set(stack_report_file bootloader.elf.stack_report)
add_custom_command(
    OUTPUT "${stack_report_file}"
    DEPENDS bootloader.elf
    COMMAND niosv-stack-report -p "${ToolchainPrefix}" bootloader.elf
    COMMENT "Reporting memory available for stack + heap in bootloader.elf."
    VERBATIM
)
add_custom_target(niosv-stack-report ALL DEPENDS "${stack_report_file}")

# Generate HEX file(s) from bootloader.elf using elf2hex tool.
# Note : If ECC Full is enabled, width of 39 is set for NiosV TCM. Otherwise, 32.
add_custom_command(
    OUTPUT "new_sdram_controller_0.hex"
    DEPENDS bootloader.elf
    COMMAND elf2hex bootloader.elf -o new_sdram_controller_0.hex -b 0x02000000 -w 32 -e 0x03FFFFFF -r 4
    COMMENT "Creating new_sdram_controller_0.hex."
    VERBATIM
)
add_custom_command(
    OUTPUT "onchip_memory2_0.hex"
    DEPENDS bootloader.elf
    COMMAND elf2hex bootloader.elf -o onchip_memory2_0.hex -b 0x00000000 -w 32 -e 0x00003FFF -r 4
    COMMENT "Creating onchip_memory2_0.hex."
    VERBATIM
)
add_custom_target(create-hex ALL DEPENDS "new_sdram_controller_0.hex" "onchip_memory2_0.hex")
target_sources(bootloader.elf PRIVATE ../common/spi_flash.c serial_boot.c crc32.c)
add_custom_command(OUTPUT "bootloader.hex" DEPENDS bootloader.elf COMMAND elf2hex bootloader.elf -o bootloader.hex -b 0x0 -w 32 -e 0x3FFF COMMENT "Creating bootloader.hex (INIT_FILE da onchip_memory2_0)." VERBATIM)
add_custom_target(create-bootloader-hex ALL DEPENDS "bootloader.hex")
