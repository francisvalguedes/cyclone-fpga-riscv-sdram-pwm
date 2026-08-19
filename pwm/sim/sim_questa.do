# ============================================================================
# Script de simulacao para o Questa Intel FPGA Starter Edition
#
# Uso:
#   1) Abra o Questa FSE (ex: D:\altera_lite\25.1std\questa_fse\win64\vsim.exe)
#      ou o menu Tools > Run Simulation Tool dentro do Quartus.
#   2) No prompt do Questa, va para esta pasta e rode:
#        cd d:/rep_win/fpgaProjetos/cyclone-fpga-riscv-sdram-pwm/pwm/sim
#        do sim_questa.do
# ============================================================================

quit -sim -force

if {[file exists work]} {
    vdel -all -lib work
}
vlib work
vmap work work

vcom -2008 -work work ../avalon_pwm.vhd
vcom -2008 -work work tb_avalon_pwm.vhd

vsim -voptargs=+acc work.tb_avalon_pwm

add wave -divider "Avalon-MM"
add wave /tb_avalon_pwm/clk
add wave /tb_avalon_pwm/reset_n
add wave /tb_avalon_pwm/avs_address
add wave /tb_avalon_pwm/avs_write
add wave /tb_avalon_pwm/avs_writedata
add wave /tb_avalon_pwm/avs_read
add wave /tb_avalon_pwm/avs_readdata

add wave -divider "PWM"
add wave /tb_avalon_pwm/pwm_out

add wave -divider "DUT (interno)"
add wave /tb_avalon_pwm/dut/reg_ctrl
add wave /tb_avalon_pwm/dut/reg_divider
add wave /tb_avalon_pwm/dut/reg_period
add wave /tb_avalon_pwm/dut/reg_duty
add wave /tb_avalon_pwm/dut/prescaler_cnt
add wave /tb_avalon_pwm/dut/pwm_cnt

run -all

wave zoom full
