// (C) 2001-2025 Altera Corporation. All rights reserved.
// Your use of Altera Corporation's design tools, logic functions and other 
// software and tools, and its AMPP partner logic functions, and any output 
// files from any of the foregoing (including device programming or simulation 
// files), and any associated documentation or information are expressly subject 
// to the terms and conditions of the Altera Program License Subscription 
// Agreement, Altera IP License Agreement, or other applicable 
// license agreement, including, without limitation, that your use is for the 
// sole purpose of programming logic devices manufactured by Altera and sold by 
// Altera or its authorized distributors.  Please refer to the applicable 
// agreement for further details.


//altera message_off 10036 10858 10230 10030 10034
`timescale 1 ns / 1 ns
module niosV_ip_intel_generic_serial_flash_interface_top_0_qspi_inf_inst #(
    parameter DEV_FAMILY    = "Arria 10",   
    parameter NCS_LENGTH    = 3,            // number of FPGA SPI NCS interfaces
    parameter DATA_LENGTH   = 4,            // number of FPGA SPI Data interfaces
    parameter MODE_LENGTH   = 1,             // SPI Data interfaces in used for selected mode
    parameter ENABLE_SIM_MODEL    = "false"       // use of embedded flash model
) (
    input               clk,
    input               reset,

    input [8:0]         in_cmd_channel,     // WY: not using, remove
    input               in_cmd_eop,
    output logic        in_cmd_ready,
    input               in_cmd_sop,
    input [7:0]         in_cmd_data,
    input               in_cmd_valid,

    output logic [7:0]  out_rsp_data,   
    input               out_rsp_ready,      // WY: flash could not be backpressure, remove
    output logic        out_rsp_valid,
    output logic                    qspi_pins_dclk,
    output logic [NCS_LENGTH-1:0]   qspi_pins_ncs,
    
    inout [DATA_LENGTH-1:0]         qspi_pins_data,
    
    // Signals directly from the command gen component
    input [3:0]         chip_select,        // Chip select values
    input [3:0]         op_num_lines,
    input [3:0]         addr_num_lines,
    input [3:0]         data_num_lines,
    input [4:0]         dummy_cycles,
    input               qspi_interface_en,
    input               require_rdata,
    input [4:0]         baud_rate_divisor,
    input [11:0]        cs_delay_setting,
    input [3:0]         read_capture_delay,
    
    //from cmd module, for require_rdata signal
    input              has_data_out,
    input [8:0]        numb_data_bytes
);
    
    logic                   oe_wire;

    logic ncs_active_state;     
    logic [15:0]            ncs_active_wire;
   
    logic [NCS_LENGTH-1:0]  ncs_wire;
    logic [NCS_LENGTH-1:0]  ncs_reg;
    
   

    //+-------------------------------------------------------------------------------
    //| Internal signals
    //+--------------------------------------------------------------------------------
    logic [2:0]             demux_channel;
    logic                   cmd_eop_adp_8_1;
    logic                   cmd_ready_adp_8_1;
    logic                   cmd_sop_adp_8_1;
    logic [7:0]            cmd_data_adp_8_1;
    logic                   cmd_valid_adp_8_1;
    logic [11:0]            cmd_channel_adp_8_1;

    logic                   cmd_eop_adp_8_2;
    logic                   cmd_ready_adp_8_2;
    logic                   cmd_sop_adp_8_2;
    logic [7:0]            cmd_data_adp_8_2;
    logic                   cmd_valid_adp_8_2;
    logic [11:0]            cmd_channel_adp_8_2;
    
    logic                   cmd_eop_adp_8_4;
    logic                   cmd_ready_adp_8_4;
    logic                   cmd_sop_adp_8_4;
    logic [7:0]            cmd_data_adp_8_4;
    logic                   cmd_valid_adp_8_4;
    logic [11:0]            cmd_channel_adp_8_4;
    
    logic                   cmd_out_ready_adp_8_1;
    logic                   cmd_out_valid_adp_8_1; 
    logic [11:0]            cmd_out_channel_adp_8_1;   
    logic [3:0]             cmd_out_data_adp_8_1;
    logic                   cmd_out_sop_adp_8_1;
    logic                   cmd_out_eop_adp_8_1;
    logic                   cmd_out_ready_adp_8_2;
    logic                   cmd_out_valid_adp_8_2;
    logic [11:0]            cmd_out_channel_adp_8_2;
    logic [3:0]             cmd_out_data_adp_8_2;
    logic                   cmd_out_sop_adp_8_2;
    logic                   cmd_out_eop_adp_8_2;
    logic                   cmd_out_ready_adp_8_4;
    logic                   cmd_out_valid_adp_8_4; 
    logic [11:0]            cmd_out_channel_adp_8_4;
    logic [3:0]             cmd_out_data_adp_8_4;
    logic                   cmd_out_sop_adp_8_4;
    logic                   cmd_out_eop_adp_8_4;
    logic                   cmd_out_ready;
    logic                   cmd_out_valid;
    logic [3:0]             cmd_out_data;
    logic [11:0]            cmd_out_channel;
    logic                   cmd_out_sop;
    logic                   cmd_out_eop;
    logic [3:0]             sc_fifo_0_out_data;
    logic                   sc_fifo_0_out_valid;
    logic                   sc_fifo_0_out_ready;
    logic                   sc_fifo_0_out_startofpacket;
    logic                   sc_fifo_0_out_endofpacket;
    logic [11:0]            sc_fifo_0_out_channel;
    logic [3:0]             type_of_transaction;

    // Signals to flash
    logic [3:0]             flash_data_out;
    logic [3:0]             flash_data_in;
    logic [3:0]             flash_data_oe;
    logic                   flash_clk_reg;
    logic                   oe_reg;
    logic [3:0]             flash_data_out_reg;
    logic [3:0]             flash_data_oe_reg;

    // Signals to clock generator
    logic                   clock_genenrator_en;
    logic                   flash_clk;
    logic                   flash_clk_neg;
    logic                   flash_clk_neg_reg;
    logic flash_clk_pos;
    logic flash_clk_latch_datain;

    logic cs_assert_cnt_done;
    logic [3:0] cs_assert_cnt;
    logic [3:0] cs_assert_cnt_next;
    logic cs_deassert_cnt_done;
    logic [3:0] cs_deassert_cnt;
    logic [3:0] cs_deassert_cnt_next;
    logic cs_deassert_to_idle_cnt_done;
    logic [3:0] cs_deassert_to_idle_cnt;
    logic [3:0] cs_deassert_to_idle_cnt_next;
    logic [4:0] dummy_cnt_val;
    
    logic           rdata_received;
    logic [7:0]     flash_read_data_cnt;
    logic           flash_read_data_cnt_done;
    logic [7:0]     flash_read_data_cnt_next;
    
    // Decode the channel to check the value is belong to opcode, address, data, or dummy
    // base on this, check with the line each filed is set, route them to correct adapter
    // For incoming packet:
    //                  Channel decode: 0001: opcode
    //                                  0010: address
    //                                  0100: write data
    //                                  1000: dummy
    // For data lines (take from user);  op_num_lines; addr_num_lines; data_num_lines
    //                  Channel decode: 0001: 1 line
    //                                  0010: 2 lines
    //                                  0100: 4 lines
    //                                  1000: reserved
    // 
    // for the in_cmd_channel; the [MSB, MSB-1] os the decode to indicate where this packet come from
    //                          2'b01 is the channel for XIP controller
    //                          2'b10 is the channel for CST controller
    //                          need this information since now the instruction lines are runtime.
    always_comb begin
        // For the packet comes from CSR, the data lines are same for opcode, address, data in, out
        // For write/read comes from XIP, the opcode lines, address lines and data lines can be different
        if (in_cmd_channel[5:4] == 2'b10) begin // from csr
            demux_channel  = op_num_lines[2:0];
        end else begin // from xip -not correct, please check this
            if (in_cmd_channel[3:0] == 4'b0001) // this is opcode
                demux_channel  = op_num_lines[2:0];
            else if (in_cmd_channel[3:0] == 4'b0010) // address
                demux_channel  = addr_num_lines[2:0];
                 else
                demux_channel = data_num_lines[2:0]; // dummy and data use same setting for data lines
        end
    end // always_comb

    //+-------------------------------------------------------------------------------    
    //| The Demux, route the incomming packet to correct adapter depend on the setting
    //| of the data lines are used.
    //+-------------------------------------------------------------------------------
    demultiplexer_12_channels demultiplexer_inst (
        .clk                (clk),
        .reset              (reset),
        .sink_ready         (in_cmd_ready),
        .sink_channel       ({in_cmd_channel,demux_channel}),
        .sink_data          (in_cmd_data),
        .sink_startofpacket (in_cmd_channel[7]),
        .sink_endofpacket   (in_cmd_channel[6]),
        .sink_valid         (in_cmd_valid),
        .src0_ready         (cmd_ready_adp_8_1),
        .src0_valid         (cmd_valid_adp_8_1),
        .src0_data          (cmd_data_adp_8_1),
        .src0_channel       (cmd_channel_adp_8_1),
        .src0_startofpacket (cmd_sop_adp_8_1),
        .src0_endofpacket   (cmd_eop_adp_8_1),
        .src1_ready         (cmd_ready_adp_8_2),
        .src1_valid         (cmd_valid_adp_8_2),
        .src1_data          (cmd_data_adp_8_2),
        .src1_channel       (cmd_channel_adp_8_2),
        .src1_startofpacket (cmd_sop_adp_8_2),
        .src1_endofpacket   (cmd_eop_adp_8_2),
        .src2_ready         (cmd_ready_adp_8_4),
        .src2_valid         (cmd_valid_adp_8_4),
        .src2_data          (cmd_data_adp_8_4),
        .src2_channel       (cmd_channel_adp_8_4),
        .src2_startofpacket (cmd_sop_adp_8_4),
        .src2_endofpacket   (cmd_eop_adp_8_4)
    );

    //+-------------------------------------------------------------------------------    
    //| The adapters which converts the packet (8 bits) to either 1, 2, or 4 bits each
    //+-------------------------------------------------------------------------------
    adapter_8_1 adapter_8_1_inst (
        .clk               (clk),
        .reset_n           (!reset),
        .in_data           (cmd_data_adp_8_1),
        .in_valid          (cmd_valid_adp_8_1),
        .in_ready          (cmd_ready_adp_8_1),
        .in_startofpacket  (cmd_sop_adp_8_1),
        .in_endofpacket    (cmd_eop_adp_8_1),
        .in_channel        (cmd_channel_adp_8_1),
        .out_channel       (cmd_out_channel_adp_8_1),
        .out_data          (cmd_out_data_adp_8_1),         
        .out_valid         (cmd_out_valid_adp_8_1),
        .out_ready         (cmd_out_ready_adp_8_1),
        .out_startofpacket (cmd_out_sop_adp_8_1),
        .out_endofpacket   (cmd_out_eop_adp_8_1)
    );

    adapter_8_2 adapter_8_2_inst (
        .clk                (clk),
        .reset_n            (!reset),
        .in_data            (cmd_data_adp_8_2),
        .in_valid           (cmd_valid_adp_8_2),
        .in_startofpacket   (cmd_sop_adp_8_2),
        .in_endofpacket     (cmd_eop_adp_8_2),
        .in_ready           (cmd_ready_adp_8_2),
        .in_channel        (cmd_channel_adp_8_2),
        .out_channel       (cmd_out_channel_adp_8_2),
        .out_data           (cmd_out_data_adp_8_2),
        .out_valid          (cmd_out_valid_adp_8_2),
        .out_ready          (cmd_out_ready_adp_8_2),
        .out_startofpacket  (cmd_out_sop_adp_8_2),
        .out_endofpacket    (cmd_out_eop_adp_8_2)
    );

    adapter_8_4 adapter_8_4_inst (
        .clk                (clk),
        .reset_n            (!reset),
        .in_data            (cmd_data_adp_8_4),
        .in_valid           (cmd_valid_adp_8_4),
        .in_startofpacket   (cmd_sop_adp_8_4),
        .in_endofpacket     (cmd_eop_adp_8_4),
        .in_ready           (cmd_ready_adp_8_4),
        .in_channel        (cmd_channel_adp_8_4),
        .out_channel       (cmd_out_channel_adp_8_4),
        .out_data           (cmd_out_data_adp_8_4),
        .out_valid          (cmd_out_valid_adp_8_4),
        .out_ready          (cmd_out_ready_adp_8_4),
        .out_startofpacket  (cmd_out_sop_adp_8_4),
        .out_endofpacket    (cmd_out_eop_adp_8_4)
    );

    //+-------------------------------------------------------------------------------    
    //| The Mux, route converted data acornginly to the number of line to the fifo
    //+-------------------------------------------------------------------------------
    qspi_inf_mux qspi_inf_mux_inst (
        .clk                 (clk),
        .reset               (reset),
        .src_ready           (cmd_out_ready),
        //.src_ready           (1),
        .src_valid           (cmd_out_valid),
        .src_data            (cmd_out_data),
        .src_channel         (cmd_out_channel),
        .src_startofpacket   (cmd_out_sop),
        .src_endofpacket     (cmd_out_eop),
        .sink0_ready         (cmd_out_ready_adp_8_1),
        .sink0_valid         (cmd_out_valid_adp_8_1),
        .sink0_channel       (cmd_out_channel_adp_8_1), 
        .sink0_data          (cmd_out_data_adp_8_1),
        .sink0_startofpacket (cmd_out_sop_adp_8_1),
        .sink0_endofpacket   (cmd_out_eop_adp_8_1),
        .sink1_ready         (cmd_out_ready_adp_8_2),
        .sink1_valid         (cmd_out_valid_adp_8_2),
        .sink1_channel       (cmd_out_channel_adp_8_2),
        .sink1_data          (cmd_out_data_adp_8_2),
        .sink1_startofpacket (cmd_out_sop_adp_8_2),
        .sink1_endofpacket   (cmd_out_eop_adp_8_2),
        .sink2_ready         (cmd_out_ready_adp_8_4),
        .sink2_valid         (cmd_out_valid_adp_8_4),
        .sink2_channel       (cmd_out_channel_adp_8_4),
        .sink2_data          (cmd_out_data_adp_8_4),
        .sink2_startofpacket (cmd_out_sop_adp_8_4),
        .sink2_endofpacket   (cmd_out_eop_adp_8_4)
    );

    logic fifo_pop_out;
    logic fifo_read_trigger;
    //+-------------------------------------------------------------------------------    
    //| The fifo buffer data before sending to the flash
    //+-------------------------------------------------------------------------------
    inf_sc_fifo_ser_data inf_sc_fifo_ser_data_inst (
        .clk               (clk),
        .reset             (reset),
        .in_data           (cmd_out_data),
        .in_valid          (cmd_out_valid),
        .in_ready          (cmd_out_ready),
        .in_startofpacket  (cmd_out_sop),
        .in_endofpacket    (cmd_out_eop),
        .in_channel        (cmd_out_channel),
        .out_data          (sc_fifo_0_out_data),
        .out_valid         (sc_fifo_0_out_valid),
        .out_ready         (fifo_pop_out),
        .out_startofpacket (sc_fifo_0_out_startofpacket),
        .out_endofpacket   (sc_fifo_0_out_endofpacket),
        .out_channel       (sc_fifo_0_out_channel)
    );
    //sc_fifo_0_out_channel: the demux input channel has format: [2bits]: controller csr or xip][4bits]: type of transaction: opcode, addr, ..., [3bits]: demux channels
    // at output, the demux shift right 3 bits (num ouput) so the final channel here [3bits]: shifted - should not read [4bits]: type of transaction: opcode, addr, ...
    // use last 4 bits to indicate what kind of transaction is this.

   // State machine
    typedef enum bit [11:0]
    {
        ST_IDLE           = 12'b000000000001,
        ST_ASSERT_CS_DLY    = 12'b000000000010,
        ST_START_CLK        = 12'b000000000100,
        ST_ASSERT_CS        = 12'b000000001000,
        ST_SEND             = 12'b000000010000,
        ST_DUMMY_CYCLES     = 12'b000000100000,
        ST_RECEIVE          = 12'b000001000000,
        ST_STOP_CLK         = 12'b000010000000,
        ST_DEASSERT_CS      = 12'b000100000000,
        ST_DEASSERT_CS_DLY  = 12'b001000000000,
        ST_EXTRA_DEASSERT_CS_TO_IDLE_DLY  = 12'b010000000000,
        ST_DEASSERT_CS_TO_IDLE_DLY  = 12'b100000000000
     } t_state;
    t_state state, next_state;

    logic [3:0]         op_num_lines_reg;
    logic [3:0]         addr_num_lines_reg;
    logic [3:0]         data_num_lines_reg;
     always_ff @(posedge clk or posedge reset) begin
        if (reset) begin 
            op_num_lines_reg   <= '0;
            addr_num_lines_reg <= '0;
            data_num_lines_reg <= '0;
        end 
        else begin 
            if (state == ST_START_CLK) begin
                op_num_lines_reg   <= op_num_lines;
                addr_num_lines_reg <= addr_num_lines;
                data_num_lines_reg <= data_num_lines;
            end
        end // else: !if(reset)
     end // always_ff @
    

    // SCFIFO for buffering require_rdata, chip_select, and dummy_cycles.
    wire        require_rdata_buf;
    wire [3:0]  chip_select_buf;
    wire [4:0]  dummy_cycles_buf;
    logic       fifo_rdreq;
    
    always @(posedge clk or posedge reset) begin 
        if(reset)
            fifo_rdreq <= '0;
        else begin
            if (state == ST_STOP_CLK)
                fifo_rdreq <= 1'b1;
            else
                fifo_rdreq <= 1'b0;
        end
    end
    
    scfifo  sideband_buf (
                .aclr (reset),
                .clock (clk),
                .data ({chip_select,require_rdata,dummy_cycles}),
                .rdreq (fifo_rdreq),
                .sclr (reset),
                .wrreq (in_cmd_sop & in_cmd_ready & in_cmd_valid),
                .empty (),
                .full (),
                .q ({chip_select_buf,require_rdata_buf,dummy_cycles_buf}),
                .usedw (),
                .almost_empty (),
                .almost_full (),
                .eccstatus ());
    defparam
        sideband_buf.add_ram_output_register  = "OFF",
        sideband_buf.enable_ecc  = "FALSE",
        sideband_buf.intended_device_family  = DEV_FAMILY,
        sideband_buf.lpm_numwords  = 8,
        sideband_buf.lpm_showahead  = "ON",
        sideband_buf.lpm_type  = "scfifo",
        sideband_buf.lpm_width  = 10,
        sideband_buf.lpm_widthu  = 3,
        sideband_buf.overflow_checking  = "OFF",
        sideband_buf.underflow_checking  = "OFF",
        sideband_buf.use_eab  = "OFF";

    always_comb begin 
        //flash_data_out = sc_fifo_0_out_data;
        //if (sc_fifo_0_out_channel == 4'h01) begin // opcode
        if (type_of_transaction == 4'h1) begin 
            if (op_num_lines_reg == 4'b0001) begin 
                flash_data_out[3]  = 1'b1;
                flash_data_out[2]  = 1'b1;
                //flash_data_out[1]  = 1'bz;
                flash_data_out[1]  = 1'b0;
                flash_data_out[0]  = sc_fifo_0_out_data[0];
            end
            else if (op_num_lines_reg == 4'b0010) begin // x2
                flash_data_out[3]  = 1'b1;
                flash_data_out[2]  = 1'b1;
                flash_data_out[1]  = sc_fifo_0_out_data[1];
                flash_data_out[0]  = sc_fifo_0_out_data[0];
            end
            else 
                flash_data_out  = sc_fifo_0_out_data;
        end
        else if (type_of_transaction == 4'h2) begin 
            if (addr_num_lines_reg == 4'b0001) begin 
                flash_data_out[3]  = 1'b1;
                flash_data_out[2]  = 1'b1;
                //flash_data_out[1]  = 1'bz;
                flash_data_out[1]  = 1'b0;
                flash_data_out[0]  = sc_fifo_0_out_data[0];
            end
            else if (addr_num_lines_reg == 4'b0010) begin // x2
                flash_data_out[3]  = 1'b1;
                flash_data_out[2]  = 1'b1;
                flash_data_out[1]  = sc_fifo_0_out_data[1];
                flash_data_out[0]  = sc_fifo_0_out_data[0];
            end
            else 
                flash_data_out  = sc_fifo_0_out_data;
        end
        else if (type_of_transaction == 4'h4) begin 
            if (data_num_lines_reg == 4'b0001) begin 
                flash_data_out[3]  = 1'b1;
                flash_data_out[2]  = 1'b1;
                //flash_data_out[1]  = 1'bz;
                flash_data_out[1]  = 1'b0;
                flash_data_out[0]  = sc_fifo_0_out_data[0];
            end
            else if (data_num_lines_reg == 4'b0010) begin // x2
                flash_data_out[3]  = 1'b1;
                flash_data_out[2]  = 1'b1;
                flash_data_out[1]  = sc_fifo_0_out_data[1];
                flash_data_out[0]  = sc_fifo_0_out_data[0];
            end
            else 
                flash_data_out  = sc_fifo_0_out_data;
        end
        else begin 
            flash_data_out[3]  = 1'b1;
            flash_data_out[2]  = 1'b1;
            flash_data_out[1]  = 1'b1;
            flash_data_out[0]  = 1'b1;
        end // else: !if(type_of_transaction == 4'h4)
    end // always_comb
    
    logic pol;
    assign pol = 1'b1;
    logic clock_genenrator_en_pol0;
    logic clock_gen_en;
    always_ff @(posedge clk) begin
        clock_genenrator_en_pol0 <= clock_genenrator_en;
    end
    assign clock_gen_en = pol ? clock_genenrator_en : clock_genenrator_en_pol0;

    clk_div #( 
        .WIDTH  (5)
    ) clk_div_new_inst_2
    (
        .clk                    (clk),
        .reset                  (reset),
        //.divisor                (5'h1),
        .divisor                (baud_rate_divisor),
        //.divisor                (5'h32),
        .pol                    (pol),
        //.enable                 (clock_genenrator_en),
        .enable                 (clock_gen_en),
        .falling_edge_trigger   (fifo_read_trigger),
        .clk_out                (flash_clk),
        .rising_edge            (flash_clk_pos),
        .falling_edge           (flash_clk_neg)
    );

    // +--------------------------------------------------
    // | Dummy cycles counter
    // +--------------------------------------------------
    logic dummy_cnt_done;
    logic [4:0] dummy_cnt;
    logic [4:0] dummy_cnt_next;
    
    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            dummy_cnt <= '0;
        else 
            dummy_cnt <= dummy_cnt_next;
    end

    assign dummy_cnt_done = (dummy_cnt == (dummy_cycles_buf - 5'h1)) && fifo_read_trigger;

    always_comb begin 
        dummy_cnt_next = dummy_cnt;
        if ((state == ST_DUMMY_CYCLES) && fifo_read_trigger) begin
            dummy_cnt_next = dummy_cnt_next + 4'h1;
            if (dummy_cnt_done)
                dummy_cnt_next = '0;
        end
    end


    // +--------------------------------------------------
    // | State Machine: update state
    // +--------------------------------------------------
    // |
    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            state <= ST_IDLE;
        else
            state <= next_state;
    end
    // +--------------------------------------------------
    // | State Machine: next state condition
    // +--------------------------------------------------
    always_comb begin
        next_state  = ST_IDLE;
        case (state)
            ST_IDLE: begin
                next_state  = ST_IDLE;
                if (sc_fifo_0_out_valid) begin
                    if (cs_delay_setting[3:0] <= 4'h1) // if CS delay is 0, then to start_clk, if 1 then use at start_clk, assert CS
                        next_state = ST_START_CLK;
                    else // if not 1 then go to delay CS, if it is 1 then make use of start_clk state
                        next_state = ST_ASSERT_CS_DLY;
                end
            end
            ST_ASSERT_CS_DLY: begin 
                next_state = ST_ASSERT_CS_DLY;
                if (cs_assert_cnt_done)
                    next_state = ST_START_CLK;
            end
            ST_START_CLK: begin 
                next_state = ST_ASSERT_CS;
            end
            ST_ASSERT_CS: begin
               next_state = ST_SEND; 
            end
            ST_SEND: begin 
                next_state = ST_SEND;
                if (sc_fifo_0_out_endofpacket && sc_fifo_0_out_channel[8] && fifo_pop_out) begin
                    if (require_rdata_buf) begin
                        if (dummy_cycles_buf > 0)
                            next_state = ST_DUMMY_CYCLES;
                        else    
                            next_state = ST_RECEIVE;
                    end
                    else
                        next_state = ST_STOP_CLK;
                end
            end
            ST_DUMMY_CYCLES: begin
                next_state = ST_DUMMY_CYCLES;
                if (dummy_cnt_done) 
                    next_state = ST_RECEIVE;
            end
            ST_RECEIVE: begin
                /* if (require_rdata) 
                    next_state = ST_RECEIVE;
                else 
                    next_state = ST_STOP_CLK; */
                    
                if (baud_rate_divisor <= 5'h6) begin 
                    next_state = ST_RECEIVE;
                    if (rdata_received)
                        next_state = ST_STOP_CLK;
                end else begin 
                    if (require_rdata) 
                        next_state = ST_RECEIVE;
                    else 
                        next_state = ST_STOP_CLK;
                end
            end
            ST_STOP_CLK: begin 
                if (cs_delay_setting[7:4] == 4'h0) // if CS deassert delay is 0, then to deaasert, 
                    next_state = ST_DEASSERT_CS;
                else
                    next_state = ST_DEASSERT_CS_DLY;
            end
            ST_DEASSERT_CS_DLY: begin 
                next_state = ST_DEASSERT_CS_DLY;
                if (cs_deassert_cnt_done)
                    next_state = ST_DEASSERT_CS;
            end
            ST_DEASSERT_CS: begin
                if (cs_delay_setting[3:0] == 4'h0) begin
                    if (cs_delay_setting[11:8] == 4'h0) begin
                        next_state = ST_IDLE;
                    end else begin
                        next_state = ST_DEASSERT_CS_TO_IDLE_DLY;
                    end
                end else begin
                    next_state = ST_EXTRA_DEASSERT_CS_TO_IDLE_DLY;
                end
            end
            
            ST_EXTRA_DEASSERT_CS_TO_IDLE_DLY: begin
            if (cs_delay_setting[11:8] == 4'h0) begin
                    next_state = ST_IDLE;
                end else begin
                    next_state = ST_DEASSERT_CS_TO_IDLE_DLY;
                end
            end
            
            ST_DEASSERT_CS_TO_IDLE_DLY: begin 
                if (cs_deassert_to_idle_cnt_done)
                    next_state = ST_IDLE;
            else
                    next_state = ST_DEASSERT_CS_TO_IDLE_DLY;
            end

        endcase // case (state)
    end // always_comb
    
    // +--------------------------------------------------
    // | State Machine: state outputs
    // +--------------------------------------------------
    always_comb begin
        clock_genenrator_en  = '0;
        fifo_pop_out         = '0;
        case (state)
            ST_IDLE: begin
                clock_genenrator_en  = '0;
                fifo_pop_out         = '0;
            end
            ST_ASSERT_CS_DLY: begin
                clock_genenrator_en  = '0;
                fifo_pop_out         = '0;
            end
            ST_START_CLK: begin 
                clock_genenrator_en  = 1;
                fifo_pop_out         = '0;
            end
            ST_ASSERT_CS: begin 
                clock_genenrator_en  = 1;
                fifo_pop_out         = '0;
            end
            ST_SEND: begin 
                clock_genenrator_en  = 1;
                fifo_pop_out         = fifo_read_trigger;
            end
            ST_RECEIVE: begin 
                if (baud_rate_divisor == 5'h1) begin 
                    if (rdata_received) begin
                        clock_genenrator_en  = 0;
                    end else begin 
                        clock_genenrator_en  = 1;
                    end
                end else begin 
                    clock_genenrator_en  = 1;
                end
                fifo_pop_out         = '0;
            end
            ST_DUMMY_CYCLES: begin 
                clock_genenrator_en  = 1;
                fifo_pop_out         = '0;
            end
            ST_STOP_CLK: begin 
                clock_genenrator_en  = 0;
                fifo_pop_out         = '0;
            end
            ST_DEASSERT_CS: begin 
                clock_genenrator_en  = 0;
                fifo_pop_out         = '0;
            end
            default: begin
                clock_genenrator_en  = '0;
                fifo_pop_out         = '0;
            end
        endcase // case (state)
    end


    //+-------------------------------------------------------------------------------    
    //| oe, active low, qspi_interface_en must be registered in previous component
    //+-------------------------------------------------------------------------------
    assign oe_wire  = ~qspi_interface_en;

    //+-------------------------------------------------------------------------------
    //| ncs, active low
    //+-------------------------------------------------------------------------------
    // convert chip_select to one-hot signal
    always @(chip_select_buf) begin
        ncs_active_wire               = 0;
        ncs_active_wire[chip_select_buf]  = 1'b1;
    end
    assign ncs_active_state = ((state == ST_START_CLK && (cs_delay_setting[3:0] >= 4'h1)) ||  state == ST_ASSERT_CS || state == ST_ASSERT_CS_DLY
                              || state == ST_SEND
                              || state == ST_RECEIVE || state == ST_DUMMY_CYCLES
                              || state == ST_STOP_CLK || state == ST_DEASSERT_CS_DLY);

    genvar i;
    generate
        for (i=0; i<NCS_LENGTH; i++) begin : ncs_active_inst
            assign ncs_wire[i]  = ~ncs_active_wire[i] || ~ncs_active_state;
        end
    endgenerate

    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            ncs_reg <= {NCS_LENGTH{1'b1}};
        else
            ncs_reg <= ncs_wire;
    end

    // +--------------------------------------------------
    // | CS Assert counter
    // +--------------------------------------------------

    
    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            cs_assert_cnt <= '0;
        else 
            cs_assert_cnt <= cs_assert_cnt_next;
    end

    assign cs_assert_cnt_done = (cs_assert_cnt == (cs_delay_setting[3:0] - 4'h2)); // one is at start_clk state, one for this calculate, so - 2 as start from 0

    always_comb begin 
        cs_assert_cnt_next = cs_assert_cnt;
        if (state == ST_ASSERT_CS_DLY) begin
            cs_assert_cnt_next = cs_assert_cnt_next + 4'h1;
            if (cs_assert_cnt_done)
                cs_assert_cnt_next = '0;
        end
    end
    // +--------------------------------------------------
    // | CS Deassert counter
    // +--------------------------------------------------

    
    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            cs_deassert_cnt <= '0;
        else 
            cs_deassert_cnt <= cs_deassert_cnt_next;
    end

    assign cs_deassert_cnt_done = (cs_deassert_cnt == (cs_delay_setting[7:4] - 4'h1)); 

    always_comb begin 
        cs_deassert_cnt_next = cs_deassert_cnt;
        if (state == ST_DEASSERT_CS_DLY) begin
            cs_deassert_cnt_next = cs_deassert_cnt_next + 4'h1;
            if (cs_deassert_cnt_done)
                cs_deassert_cnt_next = '0;
        end
    end
    // +--------------------------------------------------
    // | CS Deassert to IDLE counter
    // +--------------------------------------------------

    
    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            cs_deassert_to_idle_cnt <= '0;
        else 
            cs_deassert_to_idle_cnt <= cs_deassert_to_idle_cnt_next;
    end

    assign cs_deassert_to_idle_cnt_done = (cs_deassert_to_idle_cnt == (cs_delay_setting[11:8] - 4'h1)); 

    always_comb begin 
        cs_deassert_to_idle_cnt_next = cs_deassert_to_idle_cnt;
        if (state == ST_DEASSERT_CS_TO_IDLE_DLY) begin
            cs_deassert_to_idle_cnt_next = cs_deassert_to_idle_cnt_next + 4'h1;
            if (cs_deassert_to_idle_cnt_done)
                cs_deassert_to_idle_cnt_next = '0;
        end
    end

    //+-------------------------------------------------------------------------------    
    //|      datain(read at posedge) 
    //+-------------------------------------------------------------------------------    
    logic [15:0] read_capture_delay_reg;
    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            read_capture_delay_reg <= '0;
        else begin
            if (state == ST_RECEIVE)
                read_capture_delay_reg      <= {read_capture_delay_reg[13:0], flash_clk_pos};
            else 
                read_capture_delay_reg <= '0;     
        end
    end

    assign flash_clk_latch_datain = read_capture_delay_reg[read_capture_delay];

    logic [7:0] flash_datain_reg;
    logic [7:0] flash_datain_reg_t;
    

    //always_ff @(negedge clk or posedge reset) begin
    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            flash_datain_reg <= '0;
        else begin
            if (flash_clk_latch_datain) begin
                if (data_num_lines == 4'b0001) //x1
                    flash_datain_reg <= {flash_datain_reg[6:0], flash_data_in[1]};
                else if (data_num_lines == 4'b0010)  //x2
                    flash_datain_reg <= {flash_datain_reg[5:0], flash_data_in[1:0]};
                else //x4
                    flash_datain_reg <= {flash_datain_reg[3:0], flash_data_in};
            end
        end
    end

    //+-------------------------------------------------------------------------------    
    logic [3:0] read_data_cnt;
    logic [3:0] read_data_cnt_next;
    logic       read_data_done;

    logic       read_data_valid;
    // +--------------------------------oo------------------
    // | Address bytes counter
    // +--------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            read_data_cnt <= '0;
        else begin
            if (state == ST_SEND) begin
                if (data_num_lines == 4'b0001) //x1
                    read_data_cnt <= 7;
                else if (data_num_lines == 4'b0010) //x2
                    read_data_cnt <= 3;
                else  //x4
                    read_data_cnt <= 1;
            end
            else
                read_data_cnt <= read_data_cnt_next;
        end
    end


    //assign read_data_done = ((read_data_cnt == 0) & flash_clk_neg & (state == ST_RECEIVE));
    assign read_data_done = ((read_data_cnt == 0) & flash_clk_latch_datain & (state == ST_RECEIVE));

    always_comb begin 
        read_data_cnt_next = read_data_cnt;
        //if ((state == ST_RECEIVE) & flash_clk_neg) begin
            if ((state == ST_RECEIVE) & flash_clk_latch_datain) begin
            read_data_cnt_next = read_data_cnt_next - 4'h1;
            if (read_data_done) begin
                if (data_num_lines == 4'b0001) //x1
                    read_data_cnt_next = 7;
                else if (data_num_lines == 4'b0010) //x2
                    read_data_cnt_next = 3;
                else  //x4
                    read_data_cnt_next = 1;
            end
        end
    end
    
    // +--------------------------------------------------
    // | Write Data bytes counter
    // +--------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            flash_read_data_cnt <= '0;
        else
            flash_read_data_cnt <= flash_read_data_cnt_next;
    end
    assign flash_read_data_cnt_done = ((flash_read_data_cnt == (numb_data_bytes - 4'h1)) & read_data_done);
    
    always_comb begin 
        flash_read_data_cnt_next = flash_read_data_cnt;
        if (read_data_done) begin
            flash_read_data_cnt_next = flash_read_data_cnt_next + 4'h1;
            if (flash_read_data_cnt_done)
                flash_read_data_cnt_next = '0;
        end
    end
    
    assign rdata_received = has_data_out && flash_read_data_cnt_done;

    always_ff @(posedge clk) begin    
        read_data_valid <= read_data_done;
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            out_rsp_data  <= '0;
            out_rsp_valid <= '0;
        end
        else if (read_data_valid) begin
            //out_rsp_data  <= flash_datain_reg;
            out_rsp_data  <= flash_datain_reg;
            out_rsp_valid <= 1'b1;
        end
        else begin
            out_rsp_data  <= out_rsp_data;
            out_rsp_valid <= '0;
        end
    end

// +--------------------------------------------------------------------------------
// |     dataoe, 1=output, 0=input
// +--------------------------------------------------------------------------------

    assign type_of_transaction = sc_fifo_0_out_channel[3:0];

  	// +--------------------------------------------------
	// | Data_OE Deassert counter (It is Active Low))
	// +--------------------------------------------------
	logic rising_edge_ncs_detected ;
	logic dataoe_deassert_cnt_done ;
	logic [3:0] dataoe_deassert_cnt ;
	
	//Synchronous process to count dataoe_deassert_cnt
	always_ff @(posedge clk or posedge reset) begin
	  if (reset) begin
		dataoe_deassert_cnt <= 4'b0000;
	  end else begin
		if (rising_edge_ncs_detected && (dataoe_deassert_cnt != 4'b0001)) begin
		  dataoe_deassert_cnt <= dataoe_deassert_cnt + 1;
		end else if (dataoe_deassert_cnt == 4'b0001 || state == ST_IDLE) begin
		  dataoe_deassert_cnt <= 4'b0000;
		end
	  end
	end

	//Synchronous process to determine the value of dataoe_deassert_cnt_done
	always_ff @(negedge clk or posedge reset) begin
	  if (reset) begin
		dataoe_deassert_cnt_done <= 1'b0;
	  end else begin
		if (dataoe_deassert_cnt == 4'b0001) begin
		  dataoe_deassert_cnt_done <= 1'b1;
		end else if (state == ST_IDLE) begin
		  dataoe_deassert_cnt_done <= 1'b0;
		end
	  end
	end

	always_comb begin
		if (NCS_LENGTH == 3) begin
			if ((ncs_wire[0] == 1'b1 && ncs_reg[0] ==1'b0) || (ncs_wire[1] == 1'b1 && ncs_reg[1] == 1'b0) || (ncs_wire[2] == 1'b1 && ncs_reg[2] == 1'b0)) begin // detects rising edge in chip select 
				rising_edge_ncs_detected = 1;
			end 
			else begin
				rising_edge_ncs_detected = 0;
			end
		end else if (NCS_LENGTH==2) begin
			if ((ncs_wire[0] == 1'b1 && ncs_reg[0] ==1'b0) || (ncs_wire[1] == 1'b1 && ncs_reg[1] == 1'b0)) begin // detects rising edge in chip select 
				rising_edge_ncs_detected = 1;
			end 
			else begin
				rising_edge_ncs_detected = 0;
			end
		end else if (NCS_LENGTH==1) begin
			if ((ncs_wire[0] == 1'b1 && ncs_reg[0] ==1'b0)) begin // detects rising edge in chip select 
				rising_edge_ncs_detected = 1;
			end 
			else begin
				rising_edge_ncs_detected = 0;
			end
		end
	end
	
    always_comb begin  
    flash_data_oe = 4'b1111; 
		if (state == ST_SEND) begin 
			case (type_of_transaction)
				4'h1: begin 
					if (op_num_lines_reg == 4'b0001) 
						flash_data_oe = 4'b1101;
					else 
						flash_data_oe = 4'b1111;
				end
				4'h2: begin 
					if (addr_num_lines_reg == 4'b0001) 
						flash_data_oe = 4'b1101;
					else  
						flash_data_oe = 4'b1111;     
				end
				4'h4: begin 
					if (data_num_lines_reg == 4'b0001) 
						flash_data_oe = 4'b1101;
					else  
						flash_data_oe = 4'b1111;     
				end
				default: begin 
					flash_data_oe = 4'b1111;     
				end
			endcase 
		end
		else if (state == ST_RECEIVE) begin 
			if (data_num_lines_reg == 4'b0001) begin
				flash_data_oe = 4'b1101;
			end else if (data_num_lines_reg == 4'b0010) begin
				flash_data_oe = 4'b1100;
			end else begin
				flash_data_oe = 4'b0000;
			end
		end 
		else if (!dataoe_deassert_cnt_done && (state == ST_STOP_CLK || state == ST_DEASSERT_CS || state == ST_DEASSERT_CS_DLY || state == ST_DEASSERT_CS_TO_IDLE_DLY)) begin
			if (data_num_lines_reg == 4'b0001) begin
				flash_data_oe = 4'b1101;
			end else if (data_num_lines_reg == 4'b0010) begin
				flash_data_oe = 4'b1100;
			end else begin
				flash_data_oe = 4'b0000;
			end
		end
	end



    always_ff @(posedge clk) begin
        flash_clk_reg      <= flash_clk;
        oe_reg             <= oe_wire;
        flash_data_out_reg <= flash_data_out;
        flash_clk_neg_reg  <= flash_clk_neg;
        flash_data_oe_reg  <= flash_data_oe;
    end

    //+--------------------------------------------------------------------------------
    //|      QSPI interfaces 
    //+--------------------------------------------------------------------------------
    // feed to asmiblock
// GPIO interface
    intel_generic_serial_flash_interface_gpio #(
        .NCS_LENGTH(NCS_LENGTH),
        .DATA_LENGTH(DATA_LENGTH)
    ) dedicated_interface (
        .atom_ports_dclk(flash_clk_reg),
        .atom_ports_ncs(ncs_reg),
        .atom_ports_oe(oe_reg),
        .atom_ports_dataout(flash_data_out_reg),
        .atom_ports_dataoe(flash_data_oe_reg),
        .atom_ports_datain(flash_data_in),
        
        .qspi_pins_dclk(qspi_pins_dclk),
        .qspi_pins_ncs(qspi_pins_ncs),
        .qspi_pins_data(qspi_pins_data));
    

endmodule 


