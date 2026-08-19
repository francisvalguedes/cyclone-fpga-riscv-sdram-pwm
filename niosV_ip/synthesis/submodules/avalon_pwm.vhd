-- ============================================================================
-- Módulo: avalon_pwm
-- Descrição: IP Core de PWM configurável integrado ao barramento Avalon-MM Slave.
--            Permite ajuste dinâmico de pre-scaler, período, duty cycle e polaridade.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity avalon_pwm is
    generic (
        DATA_WIDTH : integer := 32; -- Largura de dados do barramento Avalon (32 bits padrão)
        ADDR_WIDTH : integer := 2   -- Largura do endereço (2 bits = 4 endereços de palavra)
    );
    port (
        -- --------------------------------------------------------------------
        -- Sinais de Clock e Reset Globais
        -- --------------------------------------------------------------------
        clk           : in  std_logic;                                -- Clock do sistema/barramento
        reset_n       : in  std_logic;                                -- Reset assíncrono (ativo em '0')

        -- --------------------------------------------------------------------
        -- Interface Avalon Memory-Mapped Slave (avs_)
        -- --------------------------------------------------------------------
        avs_address   : in  std_logic_vector(ADDR_WIDTH-1 downto 0);  -- Endereço offset
        avs_read      : in  std_logic;                                -- Sinal de leitura (ativo em '1')
        avs_readdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);  -- Dados de leitura
        avs_write     : in  std_logic;                                -- Sinal de escrita (ativo em '1')
        avs_writedata : in  std_logic_vector(DATA_WIDTH-1 downto 0);  -- Dados de escrita

        -- --------------------------------------------------------------------
        -- Conduit Interface (Sinais externos do IP)
        -- --------------------------------------------------------------------
        pwm_out       : out std_logic                                 -- Sinal físico de saída do PWM
    );
end entity avalon_pwm;

architecture rtl of avalon_pwm is

    -- ========================================================================
    -- Registradores Internos Mapeados em Memória
    -- ========================================================================
    signal reg_ctrl    : unsigned(DATA_WIDTH-1 downto 0) := (others => '0'); -- Reg 0 (0x00): Controle
    signal reg_divider : unsigned(DATA_WIDTH-1 downto 0) := (others => '0'); -- Reg 1 (0x04): Prescaler
    signal reg_period  : unsigned(DATA_WIDTH-1 downto 0) := (others => '0'); -- Reg 2 (0x08): Período
    signal reg_duty    : unsigned(DATA_WIDTH-1 downto 0) := (others => '0'); -- Reg 3 (0x0C): Duty Cycle

    -- ========================================================================
    -- Sinais Internos de Processamento do Core PWM
    -- ========================================================================
    signal prescaler_cnt  : unsigned(DATA_WIDTH-1 downto 0) := (others => '0');
    signal pwm_cnt        : unsigned(DATA_WIDTH-1 downto 0) := (others => '0');
    signal tick_prescaler : std_logic := '0';
    signal pwm_raw        : std_logic := '0';

begin

    -- ========================================================================
    -- 1. ESCRITA NO BARRAMENTO AVALON-MM (Escrita Síncrona)
    -- ========================================================================
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            reg_ctrl    <= (others => '0');
            reg_divider <= (others => '0');
            reg_period  <= (others => '0');
            reg_duty    <= (others => '0');
        elsif rising_edge(clk) then
            if avs_write = '1' then
                case avs_address is
                    when "00"   => reg_ctrl    <= unsigned(avs_writedata);
                    when "01"   => reg_divider <= unsigned(avs_writedata);
                    when "10"   => reg_period  <= unsigned(avs_writedata);
                    when "11"   => reg_duty    <= unsigned(avs_writedata);
                    when others => null;
                end case;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- 2. LEITURA NO BARRAMENTO AVALON-MM (Leitura Combinacional)
    -- ========================================================================
    process(avs_read, avs_address, reg_ctrl, reg_divider, reg_period, reg_duty)
    begin
        if avs_read = '1' then
            case avs_address is
                when "00"   => avs_readdata <= std_logic_vector(reg_ctrl);
                when "01"   => avs_readdata <= std_logic_vector(reg_divider);
                when "10"   => avs_readdata <= std_logic_vector(reg_period);
                when "11"   => avs_readdata <= std_logic_vector(reg_duty);
                when others => avs_readdata <= (others => '0');
            end case;
        else
            avs_readdata <= (others => '0');
        end if;
    end process;

    -- ========================================================================
    -- 3. CORE DO PWM: DIVISOR DE CLOCK (PRESCALER)
    -- ========================================================================
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            prescaler_cnt  <= (others => '0');
            tick_prescaler <= '0';
        elsif rising_edge(clk) then
            if reg_ctrl(0) = '1' then -- Habilitado (CTRL bit 0 = 1)
                if prescaler_cnt >= reg_divider then
                    prescaler_cnt  <= (others => '0');
                    tick_prescaler <= '1';
                else
                    prescaler_cnt  <= prescaler_cnt + 1;
                    tick_prescaler <= '0';
                end if;
            else
                prescaler_cnt  <= (others => '0');
                tick_prescaler <= '0';
            end if;
        end if;
    end process;

    -- ========================================================================
    -- 4. CORE DO PWM: CONTADOR PRINCIPAL DE PERÍODO
    -- ========================================================================
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            pwm_cnt <= (others => '0');
        elsif rising_edge(clk) then
            if reg_ctrl(0) = '0' then
                pwm_cnt <= (others => '0');
            elsif tick_prescaler = '1' then
                if pwm_cnt >= reg_period then
                    pwm_cnt <= (others => '0');
                else
                    pwm_cnt <= pwm_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- 5. GERAÇÃO DA ONDA E CONTROLE DE POLARIDADE (Saída do Hardware)
    -- ========================================================================
    pwm_raw <= '1' when (pwm_cnt < reg_duty) and (reg_ctrl(0) = '1') else '0';

    pwm_out <= not pwm_raw when (reg_ctrl(1) = '1') else pwm_raw;

end architecture rtl;