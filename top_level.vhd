library ieee;
use ieee.std_logic_1164.all;

entity top_level is
    port (
        -- Clock e reset da placa
        clk_50M : in  std_logic;
        rst_n   : in  std_logic;

        -- Interface física da SDRAM
        S_ADDR  : out   std_logic_vector(12 downto 0);
        S_BA    : out   std_logic_vector(1 downto 0);
        S_CAS_N : out   std_logic;
        S_CKE   : out   std_logic;
        S_CS_N  : out   std_logic;
        S_DQ    : inout std_logic_vector(15 downto 0);
        S_DQM   : out   std_logic_vector(1 downto 0);
        S_RAS_N : out   std_logic;
        S_WE_N  : out   std_logic;
        S_CLK   : out   std_logic;

        -- Interface UART do sistema Nios II
        UART_RX : in  std_logic;
        UART_TX : out std_logic;

        -- SPI da flash sistema Nios II
        FLASH_DCLK : out std_logic;
        FLASH_SCE  : out std_logic; 
        FLASH_SDO   : out  std_logic;
        FLASH_DATA0   : in   std_logic;

		-- SPI do sistema Nios II
		SPI_MISO : in  std_logic;
		SPI_MOSI : out std_logic;
		SPI_SCLK : out std_logic;
		SPI_SS_N : out std_logic;

        -- PIOs de 4 bits do sistema Nios II
        PIO_OUT : out std_logic_vector(3 downto 0);
        PIO_IN  : in  std_logic_vector(3 downto 0);

        -- saída PWM
        PWM : out std_logic
    );
end entity top_level;

architecture rtl of top_level is

 	component niosV_ip is
		port (
			altpll_0_c1_clk                        : out   std_logic;                                        -- clk
			clk_clk                                : in    std_logic                     := 'X';             -- clk
			new_sdram_controller_0_wire_addr       : out   std_logic_vector(12 downto 0);                    -- addr
			new_sdram_controller_0_wire_ba         : out   std_logic_vector(1 downto 0);                     -- ba
			new_sdram_controller_0_wire_cas_n      : out   std_logic;                                        -- cas_n
			new_sdram_controller_0_wire_cke        : out   std_logic;                                        -- cke
			new_sdram_controller_0_wire_cs_n       : out   std_logic;                                        -- cs_n
			new_sdram_controller_0_wire_dq         : inout std_logic_vector(15 downto 0) := (others => 'X'); -- dq
			new_sdram_controller_0_wire_dqm        : out   std_logic_vector(1 downto 0);                     -- dqm
			new_sdram_controller_0_wire_ras_n      : out   std_logic;                                        -- ras_n
			new_sdram_controller_0_wire_we_n       : out   std_logic;                                        -- we_n
			pio_0_external_connection_export       : out   std_logic_vector(3 downto 0);                     -- export
			pio_1_external_connection_export       : in    std_logic_vector(3 downto 0)  := (others => 'X'); -- export
			pwm_0_conduit_pwm_writeresponsevalid_n : out   std_logic;                                        -- writeresponsevalid_n
			reset_reset_n                          : in    std_logic                     := 'X';             -- reset_n
			spi_0_external_MISO                    : in    std_logic                     := 'X';             -- MISO
			spi_0_external_MOSI                    : out   std_logic;                                        -- MOSI
			spi_0_external_SCLK                    : out   std_logic;                                        -- SCLK
			spi_0_external_SS_n                    : out   std_logic_vector(1 downto 0);                     -- SS_n
			uart_0_external_connection_rxd         : in    std_logic                     := 'X';             -- rxd
			uart_0_external_connection_txd         : out   std_logic                                         -- txd
		);
	end component niosV_ip;


	signal signal_spi_MOSI : std_logic;
	signal signal_spi_MISO : std_logic;
	signal signal_spi_SCLK : std_logic;
	signal signal_spi_SS_N : std_logic_vector(1 downto 0);

begin

    u_nios_system : niosV_ip
        port map (
            clk_clk                           => clk_50M,
            altpll_0_c1_clk                     => S_CLK,
            reset_reset_n                     => rst_n,

            new_sdram_controller_0_wire_addr  => S_ADDR,
            new_sdram_controller_0_wire_ba    => S_BA,
            new_sdram_controller_0_wire_cas_n => S_CAS_N,
            new_sdram_controller_0_wire_cke   => S_CKE,
            new_sdram_controller_0_wire_cs_n  => S_CS_N,
            new_sdram_controller_0_wire_dq    => S_DQ,
            new_sdram_controller_0_wire_dqm   => S_DQM,
            new_sdram_controller_0_wire_ras_n => S_RAS_N,
            new_sdram_controller_0_wire_we_n  => S_WE_N,

            pio_0_external_connection_export  => PIO_OUT,
            pio_1_external_connection_export  => PIO_IN,

			spi_0_external_MISO               => signal_spi_MISO,
			spi_0_external_MOSI               => signal_spi_MOSI,
			spi_0_external_SCLK               => signal_spi_SCLK,
			spi_0_external_SS_n               => signal_spi_SS_N,

            uart_0_external_connection_rxd    => UART_RX,
            uart_0_external_connection_txd    => UART_TX,

            pwm_0_conduit_pwm_writeresponsevalid_n => PWM
        );

		-- SS_n(0): A25L80P
		-- SS_n(1): microSD
		signal_spi_MISO <= 	FLASH_DATA0 when signal_spi_SS_N(0) = '0' else
							SPI_MISO    when signal_spi_SS_N(1) = '0' else
							'1';

		SPI_MOSI <= signal_spi_MOSI;
		SPI_SCLK <= signal_spi_SCLK;
		SPI_SS_N <= signal_spi_SS_N(1);

		FLASH_DCLK <= signal_spi_SCLK;
		FLASH_SCE  <= signal_spi_SS_N(0);
		FLASH_SDO  <= signal_spi_MOSI;

end architecture rtl;
