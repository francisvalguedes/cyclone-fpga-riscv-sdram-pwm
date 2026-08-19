# Desabilita código no endereço de reset
set_setting hal.linker.allow_code_at_reset true

# O bootloader e o vetor de reset ficam na RAM interna. Nao ha imagem anterior
# para alt_load copiar; esta funcionalidade precisa permanecer desabilitada.
set_setting hal.linker.enable_alt_load true
set_setting hal.linker.enable_alt_load_copy_rodata true
set_setting hal.linker.enable_alt_load_copy_rwdata true
set_setting hal.linker.enable_alt_load_copy_exceptions true

# O script padrao escolhe a maior RAM (a SDRAM). Sobrescrevemos as secoes do
# bootloader para a on-chip RAM, que esta disponivel imediatamente no reset.
update_section_mapping .text       onchip_memory2_0
update_section_mapping .exceptions onchip_memory2_0
update_section_mapping .rodata     onchip_memory2_0
update_section_mapping .rwdata     onchip_memory2_0
update_section_mapping .bss        onchip_memory2_0
update_section_mapping .heap       onchip_memory2_0
update_section_mapping .stack      onchip_memory2_0
set_setting hal.linker.exception_stack_memory_region_name onchip_memory2_0

# Otimização de tamanho no BSP (-Os)
set_setting hal.make.cflags_optimization -Os 

# Habilita drivers reduzidos de periféricos (UART, SPI, PWM, etc.)
set_setting hal.enable_reduced_device_drivers true

# API direta: elimina descritores POSIX e torna a UART usada pelo bootloader
# polled/leve. O bootloader chama somente os drivers SPI e UART diretamente.
set_setting hal.enable_lightweight_device_driver_api true

# Reduz overhead de I/O e descritores de arquivo
set_setting hal.max_file_descriptors 4
set_setting hal.enable_exit false
set_setting hal.enable_clean_exit false

# Usa Newlib-Nano (Biblioteca C leve para RISC-V) e Remove Seções Mortas
set_setting hal.make.cflags_user_flags "-ffunction-sections -fdata-sections --specs=nano.specs"
set_setting hal.make.link_flags "-Wl,--gc-sections --specs=nano.specs"
