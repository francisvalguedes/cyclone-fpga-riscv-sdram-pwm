
module niosV_ip (
	altpll_0_c1_clk,
	clk_clk,
	new_sdram_controller_0_wire_addr,
	new_sdram_controller_0_wire_ba,
	new_sdram_controller_0_wire_cas_n,
	new_sdram_controller_0_wire_cke,
	new_sdram_controller_0_wire_cs_n,
	new_sdram_controller_0_wire_dq,
	new_sdram_controller_0_wire_dqm,
	new_sdram_controller_0_wire_ras_n,
	new_sdram_controller_0_wire_we_n,
	pio_0_external_connection_export,
	pio_1_external_connection_export,
	pwm_0_conduit_pwm_writeresponsevalid_n,
	reset_reset_n,
	spi_0_external_MISO,
	spi_0_external_MOSI,
	spi_0_external_SCLK,
	spi_0_external_SS_n,
	uart_0_external_connection_rxd,
	uart_0_external_connection_txd);	

	output		altpll_0_c1_clk;
	input		clk_clk;
	output	[12:0]	new_sdram_controller_0_wire_addr;
	output	[1:0]	new_sdram_controller_0_wire_ba;
	output		new_sdram_controller_0_wire_cas_n;
	output		new_sdram_controller_0_wire_cke;
	output		new_sdram_controller_0_wire_cs_n;
	inout	[15:0]	new_sdram_controller_0_wire_dq;
	output	[1:0]	new_sdram_controller_0_wire_dqm;
	output		new_sdram_controller_0_wire_ras_n;
	output		new_sdram_controller_0_wire_we_n;
	output	[3:0]	pio_0_external_connection_export;
	input	[3:0]	pio_1_external_connection_export;
	output		pwm_0_conduit_pwm_writeresponsevalid_n;
	input		reset_reset_n;
	input		spi_0_external_MISO;
	output		spi_0_external_MOSI;
	output		spi_0_external_SCLK;
	output	[1:0]	spi_0_external_SS_n;
	input		uart_0_external_connection_rxd;
	output		uart_0_external_connection_txd;
endmodule
