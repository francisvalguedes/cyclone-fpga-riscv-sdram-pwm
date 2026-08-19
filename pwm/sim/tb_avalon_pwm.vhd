-- ============================================================================
-- Testbench: tb_avalon_pwm
-- Descricao: Testbench autoverificavel para o IP avalon_pwm. Escreve/le os
--            registradores via um modelo funcional do barramento Avalon-MM
--            e mede eletricamente a forma de onda de pwm_out para validar
--            prescaler, periodo, duty cycle e polaridade.
-- Ferramenta alvo: Questa Intel FPGA Starter Edition (VHDL-2008).
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_avalon_pwm is
end entity tb_avalon_pwm;

architecture sim of tb_avalon_pwm is

    constant DATA_WIDTH : integer := 32;
    constant ADDR_WIDTH  : integer := 2;
    constant CLK_PERIOD  : time    := 20 ns; -- 50 MHz

    constant ADDR_CTRL    : std_logic_vector(1 downto 0) := "00";
    constant ADDR_DIVIDER : std_logic_vector(1 downto 0) := "01";
    constant ADDR_PERIOD  : std_logic_vector(1 downto 0) := "10";
    constant ADDR_DUTY    : std_logic_vector(1 downto 0) := "11";

    signal clk           : std_logic := '0';
    signal reset_n       : std_logic := '0';
    signal avs_address   : std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');
    signal avs_read      : std_logic := '0';
    signal avs_readdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal avs_write     : std_logic := '0';
    signal avs_writedata : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
    signal pwm_out       : std_logic;

    signal sim_done    : boolean := false;
    signal error_count : integer := 0;

begin

    -- ------------------------------------------------------------------
    -- DUT
    -- ------------------------------------------------------------------
    dut : entity work.avalon_pwm
        generic map (
            DATA_WIDTH => DATA_WIDTH,
            ADDR_WIDTH => ADDR_WIDTH
        )
        port map (
            clk           => clk,
            reset_n       => reset_n,
            avs_address   => avs_address,
            avs_read      => avs_read,
            avs_readdata  => avs_readdata,
            avs_write     => avs_write,
            avs_writedata => avs_writedata,
            pwm_out       => pwm_out
        );

    -- ------------------------------------------------------------------
    -- Clock
    -- ------------------------------------------------------------------
    clk_gen : process
    begin
        while not sim_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process clk_gen;

    -- ------------------------------------------------------------------
    -- Estimulo / verificacao
    -- ------------------------------------------------------------------
    stim : process

        -- Escreve um registrador via barramento Avalon-MM.
        procedure avalon_write(addr : std_logic_vector(1 downto 0);
                                data : std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(clk);
            avs_address   <= addr;
            avs_writedata <= data;
            avs_write     <= '1';
            wait until rising_edge(clk);
            avs_write     <= '0';
        end procedure;

        -- Le um registrador via barramento Avalon-MM (leitura combinacional no DUT).
        procedure avalon_read(addr : std_logic_vector(1 downto 0);
                               data : out std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(clk);
            avs_address <= addr;
            avs_read    <= '1';
            wait for 1 ns;
            data := avs_readdata;
            wait until rising_edge(clk);
            avs_read    <= '0';
        end procedure;

        procedure check_eq(actual, expected : std_logic_vector; msg : string) is
        begin
            if actual /= expected then
                report "FALHA: " & msg &
                       " | esperado=" & to_hstring(expected) &
                       " obtido=" & to_hstring(actual)
                    severity error;
                error_count <= error_count + 1;
            else
                report "OK: " & msg severity note;
            end if;
        end procedure;

        procedure check_time(actual, expected : time; msg : string) is
        begin
            if actual /= expected then
                report "FALHA: " & msg &
                       " | esperado=" & time'image(expected) &
                       " obtido=" & time'image(actual)
                    severity error;
                error_count <= error_count + 1;
            else
                report "OK: " & msg severity note;
            end if;
        end procedure;

        procedure check_true(cond : boolean; msg : string) is
        begin
            if not cond then
                report "FALHA: " & msg severity error;
                error_count <= error_count + 1;
            else
                report "OK: " & msg severity note;
            end if;
        end procedure;

        -- Desabilita o PWM (reseta os contadores internos), espera e
        -- reabilita com a polaridade indicada, deixando o DUT num estado
        -- conhecido (contadores comecando em zero).
        procedure enable_pwm(polarity_invert : std_logic) is
        begin
            avalon_write(ADDR_CTRL, x"00000000");
            wait for CLK_PERIOD * 2;
            if polarity_invert = '1' then
                avalon_write(ADDR_CTRL, x"00000003"); -- bit0=1 enable, bit1=1 inverte
            else
                avalon_write(ADDR_CTRL, x"00000001"); -- bit0=1 enable, bit1=0 normal
            end if;
            -- pwm_raw e pwm_out dependem de reg_ctrl em cascata (dois niveis
            -- de logica combinacional atualizando em deltas diferentes); um
            -- pequeno avanco de tempo assenta esse glitch de delta-cycle
            -- antes de comecarmos a medir bordas de pwm_out.
            wait for 1 ns;
        end procedure;

        -- Mede a duracao em alto e em baixo de um ciclo completo de "target",
        -- descartando o primeiro trecho (pode estar truncado dependendo do
        -- instante em que a medicao comecou a observar o sinal).
        procedure measure_pwm(signal target : std_logic;
                               start_high    : in boolean;
                               high_time, low_time : out time) is
            variable t0, t1, t2 : time;
        begin
            if start_high then
                wait until falling_edge(target); -- descarta 1o trecho em alto
                t0 := now;
                wait until rising_edge(target);
                t1 := now;
                wait until falling_edge(target);
                t2 := now;
                low_time  := t1 - t0;
                high_time := t2 - t1;
            else
                wait until rising_edge(target);  -- descarta 1o trecho em baixo
                t0 := now;
                wait until falling_edge(target);
                t1 := now;
                wait until rising_edge(target);
                t2 := now;
                high_time := t1 - t0;
                low_time  := t2 - t1;
            end if;
        end procedure;

        variable rd_data             : std_logic_vector(31 downto 0);
        variable meas_high, meas_low : time;
        variable exp_high, exp_low   : time;

        -- Prescaler dispara a cada (DIVIDER_TB+1) clocks; o periodo do PWM
        -- dura (PERIOD_TB+1) "ticks" do prescaler; fica em alto por DUTY_TB ticks.
        constant DIVIDER_TB : integer := 3;
        constant PERIOD_TB  : integer := 10;
        constant DUTY_TB    : integer := 3;

    begin
        ------------------------------------------------------------------
        -- TC1: comportamento apos reset
        ------------------------------------------------------------------
        reset_n <= '0';
        wait for CLK_PERIOD * 3;
        check_true(pwm_out = '0', "TC1: pwm_out em '0' apos reset");
        reset_n <= '1';
        wait for CLK_PERIOD * 2;

        avalon_read(ADDR_CTRL, rd_data);
        check_eq(rd_data, x"00000000", "TC1: reg_ctrl zerado apos reset");
        avalon_read(ADDR_DIVIDER, rd_data);
        check_eq(rd_data, x"00000000", "TC1: reg_divider zerado apos reset");
        avalon_read(ADDR_PERIOD, rd_data);
        check_eq(rd_data, x"00000000", "TC1: reg_period zerado apos reset");
        avalon_read(ADDR_DUTY, rd_data);
        check_eq(rd_data, x"00000000", "TC1: reg_duty zerado apos reset");

        ------------------------------------------------------------------
        -- TC2: escrita/leitura dos registradores
        ------------------------------------------------------------------
        avalon_write(ADDR_DIVIDER, std_logic_vector(to_unsigned(DIVIDER_TB, 32)));
        avalon_write(ADDR_PERIOD,  std_logic_vector(to_unsigned(PERIOD_TB, 32)));
        avalon_write(ADDR_DUTY,    std_logic_vector(to_unsigned(DUTY_TB, 32)));

        avalon_read(ADDR_DIVIDER, rd_data);
        check_eq(rd_data, std_logic_vector(to_unsigned(DIVIDER_TB, 32)), "TC2: readback reg_divider");
        avalon_read(ADDR_PERIOD, rd_data);
        check_eq(rd_data, std_logic_vector(to_unsigned(PERIOD_TB, 32)), "TC2: readback reg_period");
        avalon_read(ADDR_DUTY, rd_data);
        check_eq(rd_data, std_logic_vector(to_unsigned(DUTY_TB, 32)), "TC2: readback reg_duty");

        ------------------------------------------------------------------
        -- TC3: PWM habilitado, polaridade normal
        ------------------------------------------------------------------
        enable_pwm('0');

        exp_high := DUTY_TB * (DIVIDER_TB + 1) * CLK_PERIOD;
        exp_low  := ((PERIOD_TB + 1) - DUTY_TB) * (DIVIDER_TB + 1) * CLK_PERIOD;

        measure_pwm(pwm_out, true, meas_high, meas_low);
        check_time(meas_high, exp_high, "TC3: duracao em alto (polaridade normal)");
        check_time(meas_low,  exp_low,  "TC3: duracao em baixo (polaridade normal)");

        ------------------------------------------------------------------
        -- TC4: PWM habilitado, polaridade invertida
        -- (com bit1=1, pwm_out = not pwm_raw: alto/baixo trocam de lugar)
        ------------------------------------------------------------------
        enable_pwm('1');

        measure_pwm(pwm_out, false, meas_high, meas_low);
        check_time(meas_high, exp_low,  "TC4: duracao em alto (polaridade invertida)");
        check_time(meas_low,  exp_high, "TC4: duracao em baixo (polaridade invertida)");

        ------------------------------------------------------------------
        -- TC5: duty = 0 -> saida sempre em baixo
        ------------------------------------------------------------------
        avalon_write(ADDR_DUTY, x"00000000");
        enable_pwm('0');
        wait for ((PERIOD_TB + 1) * (DIVIDER_TB + 1) + 5) * CLK_PERIOD;
        check_true(pwm_out = '0', "TC5: pwm_out em baixo com duty=0");

        ------------------------------------------------------------------
        -- TC6: duty > periodo -> saida sempre em alto
        ------------------------------------------------------------------
        avalon_write(ADDR_DUTY, std_logic_vector(to_unsigned(PERIOD_TB + 5, 32)));
        enable_pwm('0');
        wait for ((PERIOD_TB + 1) * (DIVIDER_TB + 1) + 5) * CLK_PERIOD;
        check_true(pwm_out = '1', "TC6: pwm_out em alto com duty > periodo");

        ------------------------------------------------------------------
        -- TC7: desabilitar o PWM forca pwm_out em baixo (polaridade normal)
        ------------------------------------------------------------------
        avalon_write(ADDR_CTRL, x"00000000");
        wait until rising_edge(clk);
        check_true(pwm_out = '0', "TC7: pwm_out em baixo com PWM desabilitado");

        ------------------------------------------------------------------
        -- Resultado final
        ------------------------------------------------------------------
        wait for CLK_PERIOD * 2;
        report "===================================================";
        if error_count = 0 then
            report "TODOS OS TESTES PASSARAM";
        else
            report integer'image(error_count) & " TESTE(S) FALHARAM" severity error;
        end if;
        report "===================================================";

        sim_done <= true;
        wait for CLK_PERIOD;
        std.env.stop(error_count);
        wait;
    end process stim;

end architecture sim;
