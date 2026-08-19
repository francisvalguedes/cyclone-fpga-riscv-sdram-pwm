# Aplicacao principal: sera copiada integralmente pelo bootloader para a SDRAM.
set_setting hal.linker.allow_code_at_reset false
set_setting hal.linker.enable_alt_load false
set_setting hal.linker.enable_alt_load_copy_rodata false
set_setting hal.linker.enable_alt_load_copy_rwdata false
set_setting hal.linker.enable_alt_load_copy_exceptions false

update_section_mapping .text       new_sdram_controller_0
update_section_mapping .exceptions new_sdram_controller_0
update_section_mapping .rodata     new_sdram_controller_0
update_section_mapping .rwdata     new_sdram_controller_0
update_section_mapping .bss        new_sdram_controller_0
update_section_mapping .heap       new_sdram_controller_0
update_section_mapping .stack      new_sdram_controller_0
set_setting hal.linker.exception_stack_memory_region_name new_sdram_controller_0

# set_setting hal.make.cflags_optimization -Os
# set_setting hal.enable_reduced_device_drivers true
# set_setting hal.enable_lightweight_device_driver_api true
# set_setting hal.enable_exit false
# set_setting hal.enable_clean_exit false
# set_setting hal.make.cflags_user_flags "-ffunction-sections -fdata-sections --specs=nano.specs"
# set_setting hal.make.link_flags "-Wl,--gc-sections --specs=nano.specs"
