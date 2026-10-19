`default_nettype none
module alu (
	enable,
	decoded_alu_arithmetic_mux,
	decoded_alu_output_mux,
	rs,
	rt,
	rd_val,
	alu_out,
	div_by_zero,
	flag_c,
	flag_v,
	flag_z,
	flag_n,
	flag_sat
);
	parameter DATA_BITS = 16;
	input wire enable;
	input wire [4:0] decoded_alu_arithmetic_mux;
	input wire decoded_alu_output_mux;
	input wire [DATA_BITS - 1:0] rs;
	input wire [DATA_BITS - 1:0] rt;
	input wire [DATA_BITS - 1:0] rd_val;
	output reg [DATA_BITS - 1:0] alu_out;
	output reg div_by_zero;
	output reg flag_c;
	output reg flag_v;
	output reg flag_z;
	output reg flag_n;
	output reg flag_sat;
	localparam ADD = 5'd0;
	localparam SUB = 5'd1;
	localparam MUL = 5'd2;
	localparam DIV = 5'd3;
	localparam AND = 5'd4;
	localparam OR = 5'd5;
	localparam XOR = 5'd6;
	localparam SHL = 5'd7;
	localparam SHR = 5'd8;
	localparam MOD = 5'd9;
	localparam MIN = 5'd10;
	localparam MAX = 5'd11;
	localparam ABS = 5'd12;
	localparam NEG = 5'd13;
	localparam MAC = 5'd14;
	localparam POPCNT = 5'd15;
	localparam CLZ = 5'd16;
	localparam BREV = 5'd17;
	always @(*) begin : sv2v_autoblock_1
		reg signed [DATA_BITS - 1:0] min_val;
		reg signed [DATA_BITS - 1:0] max_val;
		reg [DATA_BITS:0] ext_add;
		reg [DATA_BITS:0] ext_sub;
		reg signed [(DATA_BITS * 2) - 1:0] ext_mul;
		reg signed [DATA_BITS * 2:0] ext_mac;
		min_val = {1'b1, {DATA_BITS - 1 {1'b0}}};
		max_val = {1'b0, {DATA_BITS - 1 {1'b1}}};
		ext_add = {1'b0, rs} + {1'b0, rt};
		ext_sub = {1'b0, rs} - {1'b0, rt};
		ext_mul = $signed(rs) * $signed(rt);
		ext_mac = $signed(rd_val) + ext_mul;
		div_by_zero = 1'b0;
		flag_c = 1'b0;
		flag_v = 1'b0;
		flag_sat = 1'b0;
		flag_z = 1'b0;
		flag_n = 1'b0;
		if (!enable)
			alu_out = {DATA_BITS {1'b0}};
		else if (decoded_alu_output_mux == 1'b1)
			alu_out = {{DATA_BITS - 3 {1'b0}}, rs < rt, rs == rt, rs > rt};
		else begin
			case (decoded_alu_arithmetic_mux)
				ADD: begin
					alu_out = ext_add[DATA_BITS - 1:0];
					flag_c = ext_add[DATA_BITS];
					flag_v = ~(rs[DATA_BITS - 1] ^ rt[DATA_BITS - 1]) & (rs[DATA_BITS - 1] ^ alu_out[DATA_BITS - 1]);
					if (flag_v)
						flag_sat = 1'b1;
				end
				SUB: begin
					alu_out = ext_sub[DATA_BITS - 1:0];
					flag_c = ext_sub[DATA_BITS];
					flag_v = (rs[DATA_BITS - 1] ^ rt[DATA_BITS - 1]) & (rs[DATA_BITS - 1] ^ alu_out[DATA_BITS - 1]);
					if (flag_v)
						flag_sat = 1'b1;
				end
				MUL: begin
					alu_out = ext_mul[DATA_BITS - 1:0];
					if ((ext_mul > max_val) || (ext_mul < min_val)) begin
						flag_v = 1'b1;
						flag_sat = 1'b1;
					end
				end
				DIV:
					if (rt == 0) begin
						alu_out = {DATA_BITS {1'b0}};
						div_by_zero = 1'b1;
					end
					else
						alu_out = rs / rt;
				AND: alu_out = rs & rt;
				OR: alu_out = rs | rt;
				XOR: alu_out = rs ^ rt;
				SHL: begin
					alu_out = rs << rt;
					if ((rt > 0) && (rt <= DATA_BITS)) begin : sv2v_autoblock_2
						integer shl_idx;
						shl_idx = DATA_BITS - rt;
						flag_c = rs[shl_idx];
					end
					else
						flag_c = 1'b0;
				end
				SHR: begin
					alu_out = rs >> rt;
					if ((rt > 0) && (rt <= DATA_BITS)) begin : sv2v_autoblock_3
						integer shr_idx;
						shr_idx = rt - 1;
						flag_c = rs[shr_idx];
					end
					else
						flag_c = 1'b0;
				end
				MOD:
					if (rt == 0) begin
						alu_out = {DATA_BITS {1'b0}};
						div_by_zero = 1'b1;
					end
					else
						alu_out = rs % rt;
				MIN: alu_out = ($signed(rs) < $signed(rt) ? rs : rt);
				MAX: alu_out = ($signed(rs) > $signed(rt) ? rs : rt);
				ABS: alu_out = ($signed(rs) < 0 ? -$signed(rs) : rs);
				NEG: begin
					alu_out = -$signed(rs);
					if ($signed(rs) == min_val) begin
						flag_v = 1'b1;
						flag_sat = 1'b1;
					end
				end
				MAC: begin
					alu_out = ext_mac[DATA_BITS - 1:0];
					if ((ext_mac > max_val) || (ext_mac < min_val)) begin
						flag_v = 1'b1;
						flag_sat = 1'b1;
					end
				end
				POPCNT: begin
					alu_out = {DATA_BITS {1'b0}};
					begin : sv2v_autoblock_4
						reg signed [31:0] b;
						for (b = 0; b < DATA_BITS; b = b + 1)
							alu_out = alu_out + rs[b];
					end
				end
				CLZ: begin
					alu_out = DATA_BITS;
					begin : sv2v_autoblock_5
						reg signed [31:0] n;
						for (n = DATA_BITS - 1; n >= 0; n = n - 1)
							if (rs[n] && (alu_out == DATA_BITS))
								alu_out = (DATA_BITS - 1) - n;
					end
				end
				BREV: begin
					alu_out = {DATA_BITS {1'b0}};
					begin : sv2v_autoblock_6
						reg signed [31:0] b;
						for (b = 0; b < DATA_BITS; b = b + 1)
							alu_out[b] = rs[(DATA_BITS - 1) - b];
					end
				end
				default: alu_out = {DATA_BITS {1'b0}};
			endcase
			flag_z = alu_out == {DATA_BITS {1'b0}};
			flag_n = alu_out[DATA_BITS - 1];
		end
	end
endmodule
`default_nettype none
module axi4_adapter (
	clk,
	reset,
	custom_read_valid,
	custom_read_addr,
	custom_read_ready,
	custom_read_data,
	custom_write_valid,
	custom_write_addr,
	custom_write_data,
	custom_write_strobe,
	custom_write_ready,
	m_axi_awaddr,
	m_axi_awvalid,
	m_axi_awready,
	m_axi_awlen,
	m_axi_awsize,
	m_axi_awburst,
	m_axi_wdata,
	m_axi_wstrb,
	m_axi_wvalid,
	m_axi_wready,
	m_axi_wlast,
	m_axi_bresp,
	m_axi_bvalid,
	m_axi_bready,
	m_axi_araddr,
	m_axi_arvalid,
	m_axi_arready,
	m_axi_arlen,
	m_axi_arsize,
	m_axi_arburst,
	m_axi_rdata,
	m_axi_rresp,
	m_axi_rlast,
	m_axi_rvalid,
	m_axi_rready
);
	parameter ADDR_BITS = 32;
	parameter DATA_BITS = 128;
	parameter CUSTOM_STROBE_BITS = 4;
	input wire clk;
	input wire reset;
	input wire custom_read_valid;
	input wire [ADDR_BITS - 1:0] custom_read_addr;
	output reg custom_read_ready;
	output reg [DATA_BITS - 1:0] custom_read_data;
	input wire custom_write_valid;
	input wire [ADDR_BITS - 1:0] custom_write_addr;
	input wire [DATA_BITS - 1:0] custom_write_data;
	input wire [CUSTOM_STROBE_BITS - 1:0] custom_write_strobe;
	output reg custom_write_ready;
	output reg [ADDR_BITS - 1:0] m_axi_awaddr;
	output reg m_axi_awvalid;
	input wire m_axi_awready;
	output wire [7:0] m_axi_awlen;
	output wire [2:0] m_axi_awsize;
	output wire [1:0] m_axi_awburst;
	output reg [DATA_BITS - 1:0] m_axi_wdata;
	output reg [(DATA_BITS / 8) - 1:0] m_axi_wstrb;
	output reg m_axi_wvalid;
	input wire m_axi_wready;
	output wire m_axi_wlast;
	input wire [1:0] m_axi_bresp;
	input wire m_axi_bvalid;
	output reg m_axi_bready;
	output reg [ADDR_BITS - 1:0] m_axi_araddr;
	output reg m_axi_arvalid;
	input wire m_axi_arready;
	output wire [7:0] m_axi_arlen;
	output wire [2:0] m_axi_arsize;
	output wire [1:0] m_axi_arburst;
	input wire [DATA_BITS - 1:0] m_axi_rdata;
	input wire [1:0] m_axi_rresp;
	input wire m_axi_rlast;
	input wire m_axi_rvalid;
	output reg m_axi_rready;
	assign m_axi_awlen = 8'd0;
	assign m_axi_arlen = 8'd0;
	assign m_axi_awburst = 2'b01;
	assign m_axi_arburst = 2'b01;
	assign m_axi_wlast = 1'b1;
	localparam BYTES_PER_BEAT = DATA_BITS / 8;
	assign m_axi_awsize = $clog2(BYTES_PER_BEAT);
	assign m_axi_arsize = $clog2(BYTES_PER_BEAT);
	localparam ADDR_SHIFT = $clog2(BYTES_PER_BEAT);
	reg [1:0] r_state;
	always @(posedge clk)
		if (reset) begin
			r_state <= 2'd0;
			m_axi_arvalid <= 0;
			m_axi_rready <= 0;
			custom_read_ready <= 0;
			custom_read_data <= 0;
		end
		else begin
			custom_read_ready <= 0;
			case (r_state)
				2'd0:
					if (custom_read_valid && !custom_read_ready) begin
						m_axi_arvalid <= 1'b1;
						m_axi_araddr <= custom_read_addr << ADDR_SHIFT;
						r_state <= 2'd1;
					end
				2'd1:
					if (m_axi_arready && m_axi_arvalid) begin
						m_axi_arvalid <= 1'b0;
						m_axi_rready <= 1'b1;
						r_state <= 2'd2;
					end
				2'd2:
					if (m_axi_rvalid && m_axi_rready) begin
						m_axi_rready <= 1'b0;
						custom_read_data <= m_axi_rdata;
						custom_read_ready <= 1'b1;
						r_state <= 2'd0;
					end
			endcase
		end
	reg [1:0] w_state;
	always @(posedge clk)
		if (reset) begin
			w_state <= 2'd0;
			m_axi_awvalid <= 0;
			m_axi_wvalid <= 0;
			m_axi_bready <= 0;
			custom_write_ready <= 0;
		end
		else begin
			custom_write_ready <= 0;
			case (w_state)
				2'd0:
					if (custom_write_valid && !custom_write_ready) begin
						m_axi_awvalid <= 1'b1;
						m_axi_awaddr <= custom_write_addr << ADDR_SHIFT;
						m_axi_wvalid <= 1'b1;
						m_axi_wdata <= custom_write_data;
						m_axi_wstrb <= {{4 {custom_write_strobe[3]}}, {4 {custom_write_strobe[2]}}, {4 {custom_write_strobe[1]}}, {4 {custom_write_strobe[0]}}};
						w_state <= 2'd1;
					end
				2'd1: begin
					if (m_axi_awready)
						m_axi_awvalid <= 1'b0;
					if (m_axi_wready)
						m_axi_wvalid <= 1'b0;
					if ((!m_axi_awvalid || m_axi_awready) && (!m_axi_wvalid || m_axi_wready)) begin
						m_axi_bready <= 1'b1;
						w_state <= 2'd2;
					end
				end
				2'd2:
					if (m_axi_bvalid && m_axi_bready) begin
						m_axi_bready <= 1'b0;
						custom_write_ready <= 1'b1;
						w_state <= 2'd0;
					end
			endcase
		end
endmodule
`default_nettype none
module controller (
	clk,
	reset,
	consumer_read_valid,
	consumer_read_address,
	consumer_read_ready,
	consumer_read_data,
	consumer_write_valid,
	consumer_write_address,
	consumer_write_data,
	consumer_write_strobe,
	consumer_write_ready,
	mem_read_valid,
	mem_read_address,
	mem_read_ready,
	mem_read_data,
	mem_write_valid,
	mem_write_address,
	mem_write_data,
	mem_write_strobe,
	mem_write_ready
);
	parameter ADDR_BITS = 8;
	parameter DATA_BITS = 16;
	parameter BLOCK_DATA_BITS = 64;
	parameter NUM_CONSUMERS = 4;
	parameter NUM_CHANNELS = 1;
	parameter WRITE_ENABLE = 1;
	input wire clk;
	input wire reset;
	input wire [NUM_CONSUMERS - 1:0] consumer_read_valid;
	input wire [(NUM_CONSUMERS * ADDR_BITS) - 1:0] consumer_read_address;
	output reg [NUM_CONSUMERS - 1:0] consumer_read_ready;
	output reg [(NUM_CONSUMERS * BLOCK_DATA_BITS) - 1:0] consumer_read_data;
	input wire [NUM_CONSUMERS - 1:0] consumer_write_valid;
	input wire [(NUM_CONSUMERS * ADDR_BITS) - 1:0] consumer_write_address;
	input wire [(NUM_CONSUMERS * BLOCK_DATA_BITS) - 1:0] consumer_write_data;
	input wire [(NUM_CONSUMERS * 4) - 1:0] consumer_write_strobe;
	output reg [NUM_CONSUMERS - 1:0] consumer_write_ready;
	output reg [NUM_CHANNELS - 1:0] mem_read_valid;
	output reg [(NUM_CHANNELS * ADDR_BITS) - 1:0] mem_read_address;
	input wire [NUM_CHANNELS - 1:0] mem_read_ready;
	input wire [(NUM_CHANNELS * BLOCK_DATA_BITS) - 1:0] mem_read_data;
	output reg [NUM_CHANNELS - 1:0] mem_write_valid;
	output reg [(NUM_CHANNELS * ADDR_BITS) - 1:0] mem_write_address;
	output reg [(NUM_CHANNELS * BLOCK_DATA_BITS) - 1:0] mem_write_data;
	output reg [(NUM_CHANNELS * 4) - 1:0] mem_write_strobe;
	input wire [NUM_CHANNELS - 1:0] mem_write_ready;
	localparam IDLE = 3'b000;
	localparam READ_WAITING = 3'b010;
	localparam WRITE_WAITING = 3'b011;
	localparam READ_RELAYING = 3'b100;
	localparam WRITE_RELAYING = 3'b101;
	localparam PTR_WIDTH = (NUM_CONSUMERS > 1 ? $clog2(NUM_CONSUMERS) : 1);
	reg [2:0] controller_state [0:NUM_CHANNELS - 1];
	reg [PTR_WIDTH - 1:0] current_consumer [0:NUM_CHANNELS - 1];
	reg [NUM_CONSUMERS - 1:0] channel_serving_consumer;
	reg [PTR_WIDTH - 1:0] rr_ptr [0:NUM_CHANNELS - 1];
	reg [NUM_CONSUMERS - 1:0] next_channel_serving;
	reg consumer_claimed;
	integer i;
	integer j;
	integer k;
	integer c;
	always @(posedge clk)
		if (reset) begin
			mem_read_valid <= 0;
			mem_write_valid <= 0;
			consumer_read_ready <= 0;
			consumer_write_ready <= 0;
			channel_serving_consumer <= 0;
			for (i = 0; i < NUM_CHANNELS; i = i + 1)
				begin
					mem_read_address[((NUM_CHANNELS - 1) - i) * ADDR_BITS+:ADDR_BITS] <= 0;
					mem_write_address[((NUM_CHANNELS - 1) - i) * ADDR_BITS+:ADDR_BITS] <= 0;
					mem_write_data[((NUM_CHANNELS - 1) - i) * BLOCK_DATA_BITS+:BLOCK_DATA_BITS] <= 0;
					current_consumer[i] <= 0;
					controller_state[i] <= IDLE;
					rr_ptr[i] <= 0;
				end
			for (i = 0; i < NUM_CONSUMERS; i = i + 1)
				consumer_read_data[((NUM_CONSUMERS - 1) - i) * BLOCK_DATA_BITS+:BLOCK_DATA_BITS] <= 0;
		end
		else begin
			next_channel_serving = channel_serving_consumer;
			for (i = 0; i < NUM_CHANNELS; i = i + 1)
				case (controller_state[i])
					IDLE: begin
						consumer_claimed = 1'b0;
						for (k = 0; k < NUM_CONSUMERS; k = k + 1)
							begin
								j = (rr_ptr[i] + k) % NUM_CONSUMERS;
								if (!consumer_claimed) begin
									if (consumer_read_valid[j] && !next_channel_serving[j]) begin
										next_channel_serving[j] = 1'b1;
										consumer_claimed = 1'b1;
										current_consumer[i] <= j;
										mem_read_valid[i] <= 1;
										for (c = 0; c < NUM_CONSUMERS; c = c + 1) begin
											if (c == j) begin
												mem_read_address[((NUM_CHANNELS - 1) - i) * ADDR_BITS+:ADDR_BITS] <= consumer_read_address[((NUM_CONSUMERS - 1) - c) * ADDR_BITS+:ADDR_BITS];
											end
										end
										controller_state[i] <= READ_WAITING;
									end
									else if ((WRITE_ENABLE && consumer_write_valid[j]) && !next_channel_serving[j]) begin
										next_channel_serving[j] = 1'b1;
										consumer_claimed = 1'b1;
										current_consumer[i] <= j;
										mem_write_valid[i] <= 1;
										for (c = 0; c < NUM_CONSUMERS; c = c + 1) begin
											if (c == j) begin
												mem_write_address[((NUM_CHANNELS - 1) - i) * ADDR_BITS+:ADDR_BITS] <= consumer_write_address[((NUM_CONSUMERS - 1) - c) * ADDR_BITS+:ADDR_BITS];
												mem_write_data[((NUM_CHANNELS - 1) - i) * BLOCK_DATA_BITS+:BLOCK_DATA_BITS] <= consumer_write_data[((NUM_CONSUMERS - 1) - c) * BLOCK_DATA_BITS+:BLOCK_DATA_BITS];
												mem_write_strobe[((NUM_CHANNELS - 1) - i) * 4+:4] <= consumer_write_strobe[((NUM_CONSUMERS - 1) - c) * 4+:4];
											end
										end
										controller_state[i] <= WRITE_WAITING;
									end
								end
							end
					end
					READ_WAITING:
						if (mem_read_ready[i]) begin
							mem_read_valid[i] <= 0;
								for (c = 0; c < NUM_CONSUMERS; c = c + 1) begin
									if (c == current_consumer[i]) begin
										consumer_read_data[((NUM_CONSUMERS - 1) - c) * BLOCK_DATA_BITS+:BLOCK_DATA_BITS] <= mem_read_data[((NUM_CHANNELS - 1) - i) * BLOCK_DATA_BITS+:BLOCK_DATA_BITS];
									end
								end
							consumer_read_ready[current_consumer[i]] <= 1;
							controller_state[i] <= READ_RELAYING;
						end
					WRITE_WAITING:
						if (mem_write_ready[i]) begin
							mem_write_valid[i] <= 0;
							consumer_write_ready[current_consumer[i]] <= 1;
							controller_state[i] <= WRITE_RELAYING;
						end
					READ_RELAYING:
						if (!consumer_read_valid[current_consumer[i]]) begin
							next_channel_serving[current_consumer[i]] = 1'b0;
							consumer_read_ready[current_consumer[i]] <= 0;
							rr_ptr[i] <= (current_consumer[i] + 1) % NUM_CONSUMERS;
							controller_state[i] <= IDLE;
						end
					WRITE_RELAYING:
						if (!consumer_write_valid[current_consumer[i]]) begin
							next_channel_serving[current_consumer[i]] = 1'b0;
							consumer_write_ready[current_consumer[i]] <= 0;
							rr_ptr[i] <= (current_consumer[i] + 1) % NUM_CONSUMERS;
							controller_state[i] <= IDLE;
						end
				endcase
			channel_serving_consumer <= next_channel_serving;
		end
endmodule
`default_nettype none
module core (
	clk,
	reset,
	global_reset,
	start,
	done,
	block_id,
	thread_count,
	exception_raised,
	exception_warp_id,
	exception_pc,
	exception_cause,
	program_mem_read_valid,
	program_mem_read_address,
	program_mem_read_ready,
	program_mem_read_data,
	data_mem_read_valid,
	data_mem_read_address,
	data_mem_read_ready,
	data_mem_read_data,
	data_mem_write_valid,
	data_mem_write_address,
	data_mem_write_data,
	data_mem_write_strobe,
	data_mem_write_ready,
	pmu_cfg_0,
	pmu_cfg_1,
	pmu_cfg_2,
	pmu_cfg_3,
	pmu_cnt_0,
	pmu_cnt_1,
	pmu_cnt_2,
	pmu_cnt_3,
	pmu_reset,
	pmu_snapshot,
	pmu_snap_0,
	pmu_snap_1,
	pmu_snap_2,
	pmu_snap_3,
	ic_ev_access,
	ic_ev_hit,
	ic_ev_stall,
	dc_ev_read_acc,
	dc_ev_read_hit,
	dc_ev_read_stall,
	dc_ev_write_acc,
	dc_ev_write_hit,
	dc_ev_write_stall
);
	parameter DATA_MEM_ADDR_BITS = 32;
	parameter DATA_MEM_DATA_BITS = 32;
	parameter PROGRAM_MEM_ADDR_BITS = 32;
	parameter PROGRAM_MEM_DATA_BITS = 32;
	parameter THREADS_PER_BLOCK = 4;
	parameter NUM_WARPS = 4;
	parameter SHARED_MEM_ADDR_BITS = 8;
	parameter SHARED_MEM_SIZE = 256;
	parameter MAX_MEM_ADDR = 32'h0000ffff;
	parameter DATA_BITS = 32;
	parameter DEBUG = 0;
	input wire clk;
	input wire reset;
	input wire global_reset;
	input wire start;
	output wire done;
	input wire [7:0] block_id;
	input wire [$clog2(THREADS_PER_BLOCK * NUM_WARPS):0] thread_count;
	output reg exception_raised;
	output reg [$clog2(NUM_WARPS) - 1:0] exception_warp_id;
	output reg [PROGRAM_MEM_ADDR_BITS - 1:0] exception_pc;
	output reg [3:0] exception_cause;
	output wire program_mem_read_valid;
	output wire [PROGRAM_MEM_ADDR_BITS - 1:0] program_mem_read_address;
	input wire program_mem_read_ready;
	input wire [PROGRAM_MEM_DATA_BITS - 1:0] program_mem_read_data;
	output wire data_mem_read_valid;
	output wire [DATA_MEM_ADDR_BITS - 1:0] data_mem_read_address;
	input wire data_mem_read_ready;
	input wire [(DATA_MEM_DATA_BITS * 4) - 1:0] data_mem_read_data;
	output wire data_mem_write_valid;
	output wire [DATA_MEM_ADDR_BITS - 1:0] data_mem_write_address;
	output wire [(DATA_MEM_DATA_BITS * 4) - 1:0] data_mem_write_data;
	output wire [3:0] data_mem_write_strobe;
	input wire data_mem_write_ready;
	input wire [4:0] pmu_cfg_0;
	input wire [4:0] pmu_cfg_1;
	input wire [4:0] pmu_cfg_2;
	input wire [4:0] pmu_cfg_3;
	output wire [31:0] pmu_cnt_0;
	output wire [31:0] pmu_cnt_1;
	output wire [31:0] pmu_cnt_2;
	output wire [31:0] pmu_cnt_3;
	input wire pmu_reset;
	input wire pmu_snapshot;
	output wire [31:0] pmu_snap_0;
	output wire [31:0] pmu_snap_1;
	output wire [31:0] pmu_snap_2;
	output wire [31:0] pmu_snap_3;
	input wire ic_ev_access;
	input wire ic_ev_hit;
	input wire ic_ev_stall;
	input wire dc_ev_read_acc;
	input wire dc_ev_read_hit;
	input wire dc_ev_read_stall;
	input wire dc_ev_write_acc;
	input wire dc_ev_write_hit;
	input wire dc_ev_write_stall;
	wire [THREADS_PER_BLOCK - 1:0] lsu_we_array;
	wire [$clog2(NUM_WARPS) - 1:0] lsu_warp_id_array [0:THREADS_PER_BLOCK - 1];
	wire [4:0] lsu_rd_array;
	wire [(THREADS_PER_BLOCK * DATA_BITS) - 1:0] lsu_data_array;
	wire if_instruction_valid;
	wire core_running = start && !done;
	wire fetch_stall = !if_instruction_valid;
	wire [NUM_WARPS - 1:0] flush_warp_mask;
	wire [THREADS_PER_BLOCK - 1:0] sched_active_mask;
	wire [$clog2(NUM_WARPS) - 1:0] sched_warp_id;
	wire [PROGRAM_MEM_ADDR_BITS - 1:0] if_pc;
	wire valid_issue;
	wire [31:0] if_instruction;
	wire frontend_stall = fetch_stall;
	wire fetcher_stall = !core_running;
	fetcher #(
		.PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
		.PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)
	) fetcher_instance(
		.clk(clk),
		.reset(reset),
		.stall(fetcher_stall),
		.flush(flush_warp_mask[sched_warp_id]),
		.current_pc(if_pc),
		.mem_read_valid(program_mem_read_valid),
		.mem_read_address(program_mem_read_address),
		.mem_read_ready(program_mem_read_ready),
		.mem_read_data(program_mem_read_data),
		.instruction_valid(if_instruction_valid),
		.instruction(if_instruction)
	);
	reg [31:0] id_instruction;
	reg [PROGRAM_MEM_ADDR_BITS - 1:0] id_pc;
	reg [THREADS_PER_BLOCK - 1:0] id_active_mask;
	reg [$clog2(NUM_WARPS) - 1:0] id_warp_id;
	reg [$clog2(NUM_WARPS) - 1:0] issued_warp_id;
	always @(posedge clk)
		if (reset) begin
			id_instruction <= 0;
			id_pc <= 0;
			id_active_mask <= 0;
			id_warp_id <= 0;
			issued_warp_id <= 0;
		end
		else if (flush_warp_mask[sched_warp_id])
			id_active_mask <= 0;
		else begin
			if (valid_issue)
				issued_warp_id <= sched_warp_id;
			id_warp_id <= (if_instruction_valid ? issued_warp_id : id_warp_id);
			id_instruction <= (if_instruction_valid ? if_instruction : 0);
			id_pc <= if_pc;
			id_active_mask <= (if_instruction_valid ? sched_active_mask : 0);
		end
	wire [4:0] id_rd;
	wire [4:0] id_rs;
	wire [4:0] id_rt;
	wire [2:0] id_nzp;
	wire [DATA_BITS - 1:0] id_imm;
	wire id_reg_we;
	wire id_mem_re;
	wire id_mem_we;
	wire id_nzp_we;
	wire id_rs_re;
	wire id_rt_re;
	wire id_rd_re;
	wire id_flags_we;
	wire [1:0] id_reg_mux;
	wire [4:0] id_alu_arith_mux;
	wire id_alu_out_mux;
	wire id_pc_mux;
	wire id_call;
	wire id_ret_fn;
	wire id_exit;
	wire id_sync;
	wire id_shared_re;
	wire id_shared_we;
	wire id_use_mem_offset;
	wire [15:0] id_mem_addr_offset;
	wire [1:0] id_atomic;
	reg [1:0] ex_atomic;
	decoder #(.DATA_BITS(DATA_BITS)) decoder_inst(
		.instruction(id_instruction),
		.decoded_rd_address(id_rd),
		.decoded_rs_address(id_rs),
		.decoded_rt_address(id_rt),
		.decoded_nzp(id_nzp),
		.decoded_immediate(id_imm),
		.decoded_use_mem_offset(id_use_mem_offset),
		.decoded_mem_addr_offset(id_mem_addr_offset),
		.decoded_rs_read_enable(id_rs_re),
		.decoded_rt_read_enable(id_rt_re),
		.decoded_reg_write_enable(id_reg_we),
		.decoded_mem_read_enable(id_mem_re),
		.decoded_mem_write_enable(id_mem_we),
		.decoded_nzp_write_enable(id_nzp_we),
		.decoded_reg_input_mux(id_reg_mux),
		.decoded_alu_arithmetic_mux(id_alu_arith_mux),
		.decoded_alu_output_mux(id_alu_out_mux),
		.decoded_pc_mux(id_pc_mux),
		.decoded_sync(id_sync),
		.decoded_shared_read_enable(id_shared_re),
		.decoded_shared_write_enable(id_shared_we),
		.decoded_ret_fn(id_ret_fn),
		.decoded_exit(id_exit),
		.decoded_call(id_call),
		.decoded_atomic(id_atomic),
		.decoded_rd_read_enable(id_rd_re),
		.decoded_flags_write_enable(id_flags_we)
	);
	wire [DATA_BITS - 1:0] id_rs_data [0:THREADS_PER_BLOCK - 1];
	wire [DATA_BITS - 1:0] id_rt_data [0:THREADS_PER_BLOCK - 1];
	wire [DATA_BITS - 1:0] id_rd_data [0:THREADS_PER_BLOCK - 1];
	reg [THREADS_PER_BLOCK - 1:0] ex_active_mask;
	reg [$clog2(NUM_WARPS) - 1:0] ex_warp_id;
	reg [4:0] ex_rd;
	reg [4:0] ex_rs;
	reg [4:0] ex_rt;
	reg ex_rs_re;
	reg ex_rt_re;
	reg ex_reg_we;
	reg ex_mem_re;
	reg ex_mem_we;
	reg ex_nzp_we;
	reg ex_flags_we;
	reg [1:0] ex_reg_mux;
	reg [4:0] ex_alu_arith_mux;
	reg ex_alu_out_mux;
	reg ex_pc_mux;
	reg ex_sync;
	reg ex_shared_re;
	reg ex_shared_we;
	reg ex_use_mem_offset;
	reg [15:0] ex_mem_addr_offset;
	reg ex_call;
	reg ex_ret_fn;
	reg ex_exit;
	reg [2:0] ex_nzp;
	reg [DATA_BITS - 1:0] ex_imm;
	reg [DATA_BITS - 1:0] ex_rs_data [0:THREADS_PER_BLOCK - 1];
	reg [DATA_BITS - 1:0] ex_rt_data [0:THREADS_PER_BLOCK - 1];
	reg [DATA_BITS - 1:0] ex_rd_data [0:THREADS_PER_BLOCK - 1];
	reg ex_rd_re;
	reg [PROGRAM_MEM_ADDR_BITS - 1:0] ex_pc;
	always @(posedge clk)
		if (reset) begin
			ex_active_mask <= 0;
			ex_warp_id <= 0;
			ex_reg_we <= 0;
			ex_mem_re <= 0;
			ex_mem_we <= 0;
			ex_shared_re <= 0;
			ex_shared_we <= 0;
			ex_nzp_we <= 0;
			ex_sync <= 0;
			ex_pc_mux <= 0;
			ex_rs_re <= 0;
			ex_rt_re <= 0;
			ex_call <= 0;
			ex_ret_fn <= 0;
			ex_exit <= 0;
			ex_rd_re <= 0;
			ex_atomic <= 0;
			ex_flags_we <= 0;
		end
		else if (flush_warp_mask[id_warp_id]) begin
			ex_active_mask <= 0;
			ex_call <= 0;
			ex_ret_fn <= 0;
			ex_exit <= 0;
			ex_atomic <= 0;
			ex_flags_we <= 0;
		end
		else begin
			ex_active_mask <= id_active_mask;
			ex_warp_id <= id_warp_id;
			ex_pc <= id_pc;
			ex_rd <= id_rd;
			ex_rs <= id_rs;
			ex_rt <= id_rt;
			ex_rs_re <= id_rs_re;
			ex_rt_re <= id_rt_re;
			ex_nzp <= id_nzp;
			ex_imm <= id_imm;
			ex_rd_re <= id_rd_re;
			ex_flags_we <= id_flags_we;
			begin : sv2v_autoblock_1
				reg signed [31:0] j;
				for (j = 0; j < THREADS_PER_BLOCK; j = j + 1)
					begin
						ex_rs_data[j] <= id_rs_data[j];
						ex_rt_data[j] <= id_rt_data[j];
						ex_rd_data[j] <= id_rd_data[j];
					end
			end
			ex_reg_we <= id_reg_we;
			ex_mem_re <= id_mem_re;
			ex_mem_we <= id_mem_we;
			ex_nzp_we <= id_nzp_we;
			ex_reg_mux <= id_reg_mux;
			ex_alu_arith_mux <= id_alu_arith_mux;
			ex_alu_out_mux <= id_alu_out_mux;
			ex_pc_mux <= id_pc_mux;
			ex_sync <= id_sync;
			ex_shared_re <= id_shared_re;
			ex_shared_we <= id_shared_we;
			ex_use_mem_offset <= id_use_mem_offset;
			ex_mem_addr_offset <= id_mem_addr_offset;
			ex_call <= id_call;
			ex_ret_fn <= id_ret_fn;
			ex_exit <= id_exit;
			ex_atomic <= id_atomic;
		end
	reg [THREADS_PER_BLOCK - 1:0] mem_active_mask;
	reg [$clog2(NUM_WARPS) - 1:0] mem_warp_id;
	reg [PROGRAM_MEM_ADDR_BITS - 1:0] mem_pc;
	reg [4:0] mem_rd;
	reg [DATA_BITS - 1:0] mem_imm;
	reg [DATA_BITS - 1:0] mem_alu_out [0:THREADS_PER_BLOCK - 1];
	reg [(THREADS_PER_BLOCK * DATA_BITS) - 1:0] mem_rs_data;
	reg [(THREADS_PER_BLOCK * DATA_BITS) - 1:0] mem_rt_data;
	reg [(THREADS_PER_BLOCK * DATA_BITS) - 1:0] mem_rd_data;
	reg mem_reg_we;
	reg mem_mem_re;
	reg mem_mem_we;
	reg mem_shared_re;
	reg mem_shared_we;
	reg mem_ret;
	reg [1:0] mem_reg_mux;
	reg mem_use_mem_offset;
	reg [15:0] mem_mem_addr_offset;
	wire [DATA_BITS - 1:0] ex_alu_out [0:THREADS_PER_BLOCK - 1];
	wire [(THREADS_PER_BLOCK * PROGRAM_MEM_ADDR_BITS) - 1:0] ex_next_pc;
	wire [DATA_BITS - 1:0] fwd_ex_rs_data [0:THREADS_PER_BLOCK - 1];
	wire [DATA_BITS - 1:0] fwd_ex_rt_data [0:THREADS_PER_BLOCK - 1];
	wire [DATA_BITS - 1:0] fwd_ex_rd_data [0:THREADS_PER_BLOCK - 1];
	wire [THREADS_PER_BLOCK - 1:0] alu_div_by_zero;
	wire [THREADS_PER_BLOCK - 1:0] thread_mem_fault;
	wire is_global_mem_op = (ex_mem_re | ex_mem_we) | (|ex_atomic);
	wire is_shared_mem_op = ex_shared_re | ex_shared_we;
	genvar _gv_i_1;
	reg [THREADS_PER_BLOCK - 1:0] wb_active_mask;
	reg [DATA_BITS - 1:0] wb_alu_out [0:THREADS_PER_BLOCK - 1];
	reg [DATA_BITS - 1:0] wb_imm;
	reg [4:0] wb_rd;
	reg [1:0] wb_reg_mux;
	reg wb_reg_we;
	reg [$clog2(NUM_WARPS) - 1:0] wb_warp_id;
	generate
		for (_gv_i_1 = 0; _gv_i_1 < THREADS_PER_BLOCK; _gv_i_1 = _gv_i_1 + 1) begin : threads
			localparam i = _gv_i_1;
			wire fwd_mem_rs_i = ((((mem_active_mask[i] && mem_reg_we) && (mem_rd == ex_rs)) && (mem_rd < 29)) && ex_rs_re) && (mem_warp_id == ex_warp_id);
			wire fwd_mem_rt_i = ((((mem_active_mask[i] && mem_reg_we) && (mem_rd == ex_rt)) && (mem_rd < 29)) && ex_rt_re) && (mem_warp_id == ex_warp_id);
			wire fwd_mem_rd_i = ((((mem_active_mask[i] && mem_reg_we) && (mem_rd == ex_rd)) && (mem_rd < 29)) && ex_rd_re) && (mem_warp_id == ex_warp_id);
			wire fwd_wb_rs_i = (((((wb_active_mask[i] && wb_reg_we) && (wb_rd == ex_rs)) && (wb_rd < 29)) && ex_rs_re) && !fwd_mem_rs_i) && (wb_warp_id == ex_warp_id);
			wire fwd_wb_rt_i = (((((wb_active_mask[i] && wb_reg_we) && (wb_rd == ex_rt)) && (wb_rd < 29)) && ex_rt_re) && !fwd_mem_rt_i) && (wb_warp_id == ex_warp_id);
			wire fwd_wb_rd_i = (((((wb_active_mask[i] && wb_reg_we) && (wb_rd == ex_rd)) && (wb_rd < 29)) && ex_rd_re) && !fwd_mem_rd_i) && (wb_warp_id == ex_warp_id);
			wire fwd_lsu_rs_i = (((((lsu_we_array[i] && (lsu_rd_array == ex_rs)) && (lsu_rd_array < 29)) && ex_rs_re) && !fwd_mem_rs_i) && !fwd_wb_rs_i) && (lsu_warp_id_array[0] == ex_warp_id);
			wire fwd_lsu_rt_i = (((((lsu_we_array[i] && (lsu_rd_array == ex_rt)) && (lsu_rd_array < 29)) && ex_rt_re) && !fwd_mem_rt_i) && !fwd_wb_rt_i) && (lsu_warp_id_array[0] == ex_warp_id);
			wire fwd_lsu_rd_i = (((((lsu_we_array[i] && (lsu_rd_array == ex_rd)) && (lsu_rd_array < 29)) && ex_rd_re) && !fwd_mem_rd_i) && !fwd_wb_rd_i) && (lsu_warp_id_array[0] == ex_warp_id);
			wire [DATA_BITS - 1:0] fwd_mem_data_i = (mem_reg_mux == 2'b10 ? mem_imm : mem_alu_out[i]);
			wire [DATA_BITS - 1:0] fwd_wb_data_i = (wb_reg_mux == 2'b10 ? wb_imm : wb_alu_out[i]);
			assign fwd_ex_rs_data[i] = (fwd_mem_rs_i ? fwd_mem_data_i : (fwd_wb_rs_i ? fwd_wb_data_i : (fwd_lsu_rs_i ? lsu_data_array[((THREADS_PER_BLOCK - 1) - i) * DATA_BITS+:DATA_BITS] : ex_rs_data[i])));
			assign fwd_ex_rt_data[i] = (fwd_mem_rt_i ? fwd_mem_data_i : (fwd_wb_rt_i ? fwd_wb_data_i : (fwd_lsu_rt_i ? lsu_data_array[((THREADS_PER_BLOCK - 1) - i) * DATA_BITS+:DATA_BITS] : ex_rt_data[i])));
			assign fwd_ex_rd_data[i] = (fwd_mem_rd_i ? fwd_mem_data_i : (fwd_wb_rd_i ? fwd_wb_data_i : (fwd_lsu_rd_i ? lsu_data_array[((THREADS_PER_BLOCK - 1) - i) * DATA_BITS+:DATA_BITS] : ex_rd_data[i])));
			wire alu_flag_c;
			wire alu_flag_v;
			wire alu_flag_z;
			wire alu_flag_n;
			wire alu_flag_sat;
			alu #(.DATA_BITS(DATA_BITS)) alu_inst(
				.enable(ex_active_mask[i]),
				.decoded_alu_arithmetic_mux(ex_alu_arith_mux),
				.decoded_alu_output_mux(ex_alu_out_mux),
				.rs(fwd_ex_rs_data[i]),
				.rt(fwd_ex_rt_data[i]),
				.rd_val(fwd_ex_rd_data[i]),
				.alu_out(ex_alu_out[i]),
				.div_by_zero(alu_div_by_zero[i]),
				.flag_c(alu_flag_c),
				.flag_v(alu_flag_v),
				.flag_z(alu_flag_z),
				.flag_n(alu_flag_n),
				.flag_sat(alu_flag_sat)
			);
			reg thread_flag_c [0:NUM_WARPS - 1];
			reg thread_flag_v [0:NUM_WARPS - 1];
			reg thread_flag_z [0:NUM_WARPS - 1];
			reg thread_flag_n [0:NUM_WARPS - 1];
			reg thread_flag_sat [0:NUM_WARPS - 1];
			always @(posedge clk)
				if (reset) begin : sv2v_autoblock_2
					reg signed [31:0] w;
					for (w = 0; w < NUM_WARPS; w = w + 1)
						begin
							thread_flag_c[w] <= 0;
							thread_flag_v[w] <= 0;
							thread_flag_z[w] <= 0;
							thread_flag_n[w] <= 0;
							thread_flag_sat[w] <= 0;
						end
				end
				else if (ex_active_mask[i] && ex_flags_we) begin
					thread_flag_c[ex_warp_id] <= alu_flag_c;
					thread_flag_v[ex_warp_id] <= alu_flag_v;
					thread_flag_z[ex_warp_id] <= alu_flag_z;
					thread_flag_n[ex_warp_id] <= alu_flag_n;
					thread_flag_sat[ex_warp_id] <= thread_flag_sat[ex_warp_id] | alu_flag_sat;
				end
			wire [31:0] eff_addr = (ex_use_mem_offset ? fwd_ex_rs_data[i] + {{16 {ex_mem_addr_offset[15]}}, ex_mem_addr_offset} : fwd_ex_rs_data[i]);
			assign thread_mem_fault[i] = ex_active_mask[i] && ((is_global_mem_op && (eff_addr > MAX_MEM_ADDR)) || (is_shared_mem_op && (eff_addr >= SHARED_MEM_SIZE)));
			pc #(
				.DATA_MEM_DATA_BITS(DATA_BITS),
				.PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
				.NUM_WARPS(NUM_WARPS),
				.DEBUG(DEBUG)
			) pc_inst(
				.clk(clk),
				.reset(reset),
				.enable(ex_active_mask[i]),
				.warp_id(ex_warp_id),
				.decoded_nzp(ex_nzp),
				.decoded_immediate(ex_imm),
				.decoded_nzp_write_enable(ex_nzp_we),
				.decoded_pc_mux(ex_pc_mux),
				.decoded_call(ex_call),
				.decoded_ret_fn(ex_ret_fn),
				.alu_out(ex_alu_out[i]),
				.current_pc(ex_pc),
				.next_pc(ex_next_pc[((THREADS_PER_BLOCK - 1) - i) * PROGRAM_MEM_ADDR_BITS+:PROGRAM_MEM_ADDR_BITS])
			);
			wire [7:0] physical_thread_id = i;
			registers #(
				.THREADS_PER_BLOCK(THREADS_PER_BLOCK),
				.NUM_WARPS(NUM_WARPS),
				.DATA_BITS(DATA_BITS)
			) reg_inst(
				.clk(clk),
				.reset(reset),
				.enable(wb_active_mask[i]),
				.warp_id(wb_warp_id),
				.read_warp_id(id_warp_id),
				.block_id(block_id),
				.thread_id(physical_thread_id),
				.read_rd_address(id_rd),
				.decoded_rs_address(id_rs),
				.decoded_rt_address(id_rt),
				.rs(id_rs_data[i]),
				.rt(id_rt_data[i]),
				.rd_val(id_rd_data[i]),
				.decoded_rd_address(wb_rd),
				.decoded_reg_write_enable(wb_reg_we),
				.decoded_reg_input_mux(wb_reg_mux),
				.decoded_immediate(wb_imm),
				.alu_out(wb_alu_out[i]),
				.lsu_out(0),
				.lsu_we(lsu_we_array[i]),
				.lsu_warp_id(lsu_warp_id_array[0]),
				.lsu_rd(lsu_rd_array),
				.lsu_data(lsu_data_array[((THREADS_PER_BLOCK - 1) - i) * DATA_BITS+:DATA_BITS])
			);
		end
	endgenerate
	wire ex_has_div0 = |(ex_active_mask & alu_div_by_zero);
	wire ex_has_mem_fault = |(ex_active_mask & thread_mem_fault);
	wire ex_exception_valid = ex_has_div0 | ex_has_mem_fault;
	wire [3:0] ex_exception_cause = (ex_has_div0 ? 4'd1 : (ex_has_mem_fault ? 4'd2 : 4'd0));
	always @(posedge clk)
		if (reset)
			exception_raised <= 0;
		else if (ex_exception_valid && !exception_raised) begin
			exception_raised <= 1;
			exception_warp_id <= ex_warp_id;
			exception_pc <= ex_pc;
			exception_cause <= ex_exception_cause;
		end
	reg [1:0] mem_atomic;
	reg [NUM_WARPS - 1:0] mem_in_progress;
	wire is_mem_op = (((mem_mem_re | mem_mem_we) | mem_shared_re) | mem_shared_we) | (|mem_atomic);
	wire mem_req_valid = (|mem_active_mask && is_mem_op) && !mem_in_progress[mem_warp_id];
	always @(posedge clk)
		if (reset) begin
			mem_active_mask <= 0;
			mem_warp_id <= 0;
			mem_reg_we <= 0;
			mem_mem_re <= 0;
			mem_mem_we <= 0;
			mem_shared_re <= 0;
			mem_shared_we <= 0;
			mem_ret <= 0;
			mem_use_mem_offset <= 0;
			mem_atomic <= 0;
		end
		else if ((flush_warp_mask[ex_warp_id] || (mem_req_valid && (ex_warp_id == mem_warp_id))) || ex_exception_valid) begin
			mem_active_mask <= 0;
			mem_reg_we <= 0;
			mem_mem_re <= 0;
			mem_mem_we <= 0;
			mem_shared_re <= 0;
			mem_shared_we <= 0;
			mem_ret <= 0;
			mem_atomic <= 0;
		end
		else begin
			mem_active_mask <= ex_active_mask;
			mem_warp_id <= ex_warp_id;
			mem_pc <= ex_pc;
			mem_rd <= ex_rd;
			mem_imm <= ex_imm;
			begin : sv2v_autoblock_3
				reg signed [31:0] j;
				for (j = 0; j < THREADS_PER_BLOCK; j = j + 1)
					begin
						mem_alu_out[j] <= ex_alu_out[j];
						mem_rs_data[((THREADS_PER_BLOCK - 1) - j) * DATA_BITS+:DATA_BITS] <= fwd_ex_rs_data[j];
						mem_rt_data[((THREADS_PER_BLOCK - 1) - j) * DATA_BITS+:DATA_BITS] <= fwd_ex_rt_data[j];
						mem_rd_data[((THREADS_PER_BLOCK - 1) - j) * DATA_BITS+:DATA_BITS] <= fwd_ex_rd_data[j];
					end
			end
			mem_reg_we <= ex_reg_we;
			mem_mem_re <= ex_mem_re;
			mem_mem_we <= ex_mem_we;
			mem_shared_re <= ex_shared_re;
			mem_shared_we <= ex_shared_we;
			mem_reg_mux <= ex_reg_mux;
			mem_use_mem_offset <= ex_use_mem_offset;
			mem_mem_addr_offset <= ex_mem_addr_offset;
			mem_atomic <= ex_atomic;
		end
	wire [THREADS_PER_BLOCK - 1:0] sh_read_valid;
	wire [THREADS_PER_BLOCK - 1:0] sh_read_ready;
	wire [THREADS_PER_BLOCK - 1:0] sh_write_valid;
	wire [THREADS_PER_BLOCK - 1:0] sh_write_ready;
	wire [(THREADS_PER_BLOCK * DATA_MEM_ADDR_BITS) - 1:0] sh_read_address;
	wire [(THREADS_PER_BLOCK * DATA_MEM_ADDR_BITS) - 1:0] sh_write_address;
	wire [(THREADS_PER_BLOCK * DATA_MEM_DATA_BITS) - 1:0] sh_read_data;
	wire [(THREADS_PER_BLOCK * DATA_MEM_DATA_BITS) - 1:0] sh_write_data;
	shared_mem #(
		.DATA_BITS(DATA_MEM_DATA_BITS),
		.ADDR_BITS(DATA_MEM_ADDR_BITS),
		.SIZE(SHARED_MEM_SIZE),
		.THREADS_PER_BLOCK(THREADS_PER_BLOCK)
	) shared_mem_instance(
		.clk(clk),
		.reset(reset),
		.read_valid(sh_read_valid),
		.read_address(sh_read_address),
		.read_ready(sh_read_ready),
		.read_data(sh_read_data),
		.write_valid(sh_write_valid),
		.write_address(sh_write_address),
		.write_data(sh_write_data),
		.write_ready(sh_write_ready)
	);
	always @(posedge clk)
		if (reset) begin
			wb_active_mask <= 0;
			wb_warp_id <= 0;
			wb_reg_we <= 0;
		end
		else if ((((mem_mem_re || mem_mem_we) || mem_shared_re) || mem_shared_we) || |mem_atomic) begin
			wb_active_mask <= 0;
			wb_reg_we <= 0;
		end
		else begin
			wb_active_mask <= mem_active_mask;
			wb_warp_id <= mem_warp_id;
			wb_rd <= mem_rd;
			wb_imm <= mem_imm;
			wb_reg_we <= mem_reg_we;
			wb_reg_mux <= mem_reg_mux;
			begin : sv2v_autoblock_4
				reg signed [31:0] j;
				for (j = 0; j < THREADS_PER_BLOCK; j = j + 1)
					wb_alu_out[j] <= mem_alu_out[j];
			end
		end
	reg [3:0] mem_pending_cnt [0:NUM_WARPS - 1];
	wire [THREADS_PER_BLOCK - 1:0] lsu_done_pulse;
	wire [(THREADS_PER_BLOCK * $clog2(NUM_WARPS)) - 1:0] lsu_done_warp;
	reg [NUM_WARPS - 1:0] warp_mem_ready;
	integer w;
	integer t;
	integer cnt;
	always @(posedge clk)
		if (reset) begin
			mem_in_progress <= 0;
			warp_mem_ready <= 0;
			for (w = 0; w < NUM_WARPS; w = w + 1)
				mem_pending_cnt[w] <= 0;
		end
		else begin
			warp_mem_ready <= 0;
			for (w = 0; w < NUM_WARPS; w = w + 1)
				if (((|mem_active_mask && is_mem_op) && (mem_warp_id == w)) && !mem_in_progress[w]) begin
					mem_in_progress[w] <= 1;
					cnt = 0;
					for (t = 0; t < THREADS_PER_BLOCK; t = t + 1)
						if (mem_active_mask[t])
							cnt = cnt + 1;
					mem_pending_cnt[w] <= cnt;
				end
				else if (mem_in_progress[w]) begin
					cnt = 0;
					for (t = 0; t < THREADS_PER_BLOCK; t = t + 1)
						if (lsu_done_pulse[t] && (lsu_done_warp[((THREADS_PER_BLOCK - 1) - t) * $clog2(NUM_WARPS)+:$clog2(NUM_WARPS)] == w))
							cnt = cnt + 1;
					if (cnt > 0) begin
						if (mem_pending_cnt[w] <= cnt) begin
							mem_pending_cnt[w] <= 0;
							mem_in_progress[w] <= 0;
							warp_mem_ready[w] <= 1;
						end
						else
							mem_pending_cnt[w] <= mem_pending_cnt[w] - cnt;
					end
					else if (mem_pending_cnt[w] == 0) begin
						mem_in_progress[w] <= 0;
						warp_mem_ready[w] <= 1;
					end
				end
		end
	lsu #(
		.DATA_BITS(DATA_BITS),
		.NUM_WARPS(NUM_WARPS),
		.THREADS_PER_BLOCK(THREADS_PER_BLOCK),
		.WORDS_PER_BLOCK(4),
		.ADDR_BITS(DATA_MEM_ADDR_BITS)
	) lsu_inst(
		.clk(clk),
		.reset(reset),
		.enable_mask(mem_active_mask),
		.warp_id(mem_warp_id),
		.decoded_mem_read_enable(mem_mem_re),
		.decoded_mem_write_enable(mem_mem_we),
		.decoded_shared_read_enable(mem_shared_re),
		.decoded_shared_write_enable(mem_shared_we),
		.decoded_rd(mem_rd),
		.rs(mem_rs_data),
		.rt(mem_rt_data),
		.rd_val(mem_rd_data),
		.mem_read_valid(data_mem_read_valid),
		.mem_read_block_address(data_mem_read_address),
		.mem_read_ready(data_mem_read_ready),
		.mem_read_block_data(data_mem_read_data),
		.mem_write_valid(data_mem_write_valid),
		.mem_write_block_address(data_mem_write_address),
		.mem_write_block_data(data_mem_write_data),
		.mem_write_strobe(data_mem_write_strobe),
		.mem_write_ready(data_mem_write_ready),
		.shared_mem_read_valid(sh_read_valid),
		.shared_mem_read_address(sh_read_address),
		.shared_mem_read_ready(sh_read_ready),
		.shared_mem_read_data(sh_read_data),
		.shared_mem_write_valid(sh_write_valid),
		.shared_mem_write_address(sh_write_address),
		.shared_mem_write_data(sh_write_data),
		.shared_mem_write_ready(sh_write_ready),
		.lsu_we(lsu_we_array),
		.lsu_warp_id(lsu_warp_id_array[0]),
		.lsu_rd(lsu_rd_array),
		.lsu_data(lsu_data_array),
		.done_pulse(lsu_done_pulse),
		.done_warp_id(lsu_done_warp),
		.addr_offset(mem_mem_addr_offset),
		.use_offset(mem_use_mem_offset),
		.decoded_atomic(mem_atomic)
	);
	wire sched_ev_idle;
	wire sched_ev_warp_switch;
	wire sched_ev_diverge;
	wire sched_ev_stall_mem;
	wire sched_ev_stall_barrier;
	wire sched_ev_stall_noready;
	scheduler #(
		.THREADS_PER_BLOCK(THREADS_PER_BLOCK),
		.NUM_WARPS(NUM_WARPS),
		.PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS)
	) scheduler_instance(
		.clk(clk),
		.reset(reset),
		.start(start),
		.thread_count(thread_count),
		.mem_req_valid(mem_req_valid),
		.mem_warp_id(mem_warp_id),
		.mem_pc(mem_pc),
		.warp_mem_ready(warp_mem_ready),
		.mem_in_progress(mem_in_progress),
		.frontend_stall(frontend_stall),
		.flush_warp_mask(flush_warp_mask),
		.if_pc(if_pc),
		.sched_active_mask(sched_active_mask),
		.sched_warp_id(sched_warp_id),
		.valid_issue(valid_issue),
		.ex_valid(|ex_active_mask),
		.ex_warp_id(ex_warp_id),
		.ex_active_mask(ex_active_mask),
		.ex_pc(ex_pc),
		.ex_next_pc(ex_next_pc),
		.ex_exit(ex_exit),
		.ex_sync(ex_sync),
		.ex_exception_valid(ex_exception_valid),
		.done(done),
		.ev_scheduler_idle(sched_ev_idle),
		.ev_warp_switch(sched_ev_warp_switch),
		.ev_diverge(sched_ev_diverge),
		.ev_stall_mem(sched_ev_stall_mem),
		.ev_stall_barrier(sched_ev_stall_barrier),
		.ev_stall_noready(sched_ev_stall_noready)
	);
	wire ev_cycle = core_running;
	wire ev_active = core_running && |ex_active_mask;
	wire ev_issue = core_running && valid_issue;
	wire ev_fetch_stall = core_running && fetch_stall;
	wire ev_flush = core_running && |flush_warp_mask;
	wire ev_mem = ((core_running && |mem_active_mask) && is_mem_op) && !mem_in_progress[mem_warp_id];
	wire [31:0] event_bus;
	assign event_bus[31:24] = 8'd0;
	assign event_bus[23] = dc_ev_write_stall;
	assign event_bus[22] = dc_ev_write_hit;
	assign event_bus[21] = dc_ev_write_acc;
	assign event_bus[20] = dc_ev_read_stall;
	assign event_bus[19] = dc_ev_read_hit;
	assign event_bus[18] = dc_ev_read_acc;
	assign event_bus[17] = sched_ev_stall_noready;
	assign event_bus[16] = sched_ev_stall_barrier;
	assign event_bus[15] = sched_ev_stall_mem;
	assign event_bus[14] = sched_ev_diverge;
	assign event_bus[13] = sched_ev_warp_switch;
	assign event_bus[12] = sched_ev_idle;
	assign event_bus[11] = ic_ev_stall;
	assign event_bus[10] = ic_ev_hit;
	assign event_bus[9] = ic_ev_access;
	assign event_bus[8] = ev_mem;
	assign event_bus[7] = ev_flush;
	assign event_bus[6] = ev_fetch_stall;
	assign event_bus[5] = ev_issue;
	assign event_bus[4] = ev_active;
	assign event_bus[3] = ev_cycle;
	assign event_bus[2:0] = 3'd0;
	core_pmu pmu_inst(
		.clk(clk),
		.reset(global_reset),
		.events(event_bus),
		.cfg_mux_sel_0(pmu_cfg_0),
		.cfg_mux_sel_1(pmu_cfg_1),
		.cfg_mux_sel_2(pmu_cfg_2),
		.cfg_mux_sel_3(pmu_cfg_3),
		.counter_0(pmu_cnt_0),
		.counter_1(pmu_cnt_1),
		.counter_2(pmu_cnt_2),
		.counter_3(pmu_cnt_3),
		.pmu_reset(pmu_reset),
		.pmu_snapshot(pmu_snapshot),
		.snapshot_0(pmu_snap_0),
		.snapshot_1(pmu_snap_1),
		.snapshot_2(pmu_snap_2),
		.snapshot_3(pmu_snap_3)
	);
endmodule
`default_nettype none
module core_pmu (
	clk,
	reset,
	events,
	cfg_mux_sel_0,
	cfg_mux_sel_1,
	cfg_mux_sel_2,
	cfg_mux_sel_3,
	counter_0,
	counter_1,
	counter_2,
	counter_3,
	pmu_reset,
	pmu_snapshot,
	snapshot_0,
	snapshot_1,
	snapshot_2,
	snapshot_3
);
	input wire clk;
	input wire reset;
	input wire [31:0] events;
	input wire [4:0] cfg_mux_sel_0;
	input wire [4:0] cfg_mux_sel_1;
	input wire [4:0] cfg_mux_sel_2;
	input wire [4:0] cfg_mux_sel_3;
	output reg [31:0] counter_0;
	output reg [31:0] counter_1;
	output reg [31:0] counter_2;
	output reg [31:0] counter_3;
	input wire pmu_reset;
	input wire pmu_snapshot;
	output reg [31:0] snapshot_0;
	output reg [31:0] snapshot_1;
	output reg [31:0] snapshot_2;
	output reg [31:0] snapshot_3;
	always @(posedge clk) begin
		if (reset || pmu_reset) begin
			counter_0 <= 0;
			counter_1 <= 0;
			counter_2 <= 0;
			counter_3 <= 0;
		end
		else begin
			if (events[cfg_mux_sel_0])
				counter_0 <= counter_0 + 1;
			if (events[cfg_mux_sel_1])
				counter_1 <= counter_1 + 1;
			if (events[cfg_mux_sel_2])
				counter_2 <= counter_2 + 1;
			if (events[cfg_mux_sel_3])
				counter_3 <= counter_3 + 1;
		end
		if (reset) begin
			snapshot_0 <= 0;
			snapshot_1 <= 0;
			snapshot_2 <= 0;
			snapshot_3 <= 0;
		end
		else if (pmu_snapshot) begin
			snapshot_0 <= counter_0;
			snapshot_1 <= counter_1;
			snapshot_2 <= counter_2;
			snapshot_3 <= counter_3;
		end
	end
endmodule
`default_nettype none
module dcache (
	clk,
	reset,
	core_read_valid,
	core_read_block_addr,
	core_read_ready,
	core_read_block_data,
	core_write_valid,
	core_write_block_addr,
	core_write_block_data,
	core_write_strobe,
	core_write_ready,
	mem_read_valid,
	mem_read_block_addr,
	mem_read_ready,
	mem_read_block_data,
	mem_write_valid,
	mem_write_block_addr,
	mem_write_block_data,
	mem_write_strobe,
	mem_write_ready,
	flush_en,
	flush_done,
	ev_read_acc,
	ev_read_hit,
	ev_read_stall,
	ev_write_acc,
	ev_write_hit,
	ev_write_stall
);
	parameter ADDR_BITS = 32;
	parameter BLOCK_BITS = 128;
	parameter CACHE_LINES = 64;
	input wire clk;
	input wire reset;
	input wire core_read_valid;
	input wire [ADDR_BITS - 1:0] core_read_block_addr;
	output reg core_read_ready;
	output reg [BLOCK_BITS - 1:0] core_read_block_data;
	input wire core_write_valid;
	input wire [ADDR_BITS - 1:0] core_write_block_addr;
	input wire [BLOCK_BITS - 1:0] core_write_block_data;
	input wire [3:0] core_write_strobe;
	output reg core_write_ready;
	output reg mem_read_valid;
	output reg [ADDR_BITS - 1:0] mem_read_block_addr;
	input wire mem_read_ready;
	input wire [BLOCK_BITS - 1:0] mem_read_block_data;
	output reg mem_write_valid;
	output reg [ADDR_BITS - 1:0] mem_write_block_addr;
	output reg [BLOCK_BITS - 1:0] mem_write_block_data;
	output reg [3:0] mem_write_strobe;
	input wire mem_write_ready;
	input wire flush_en;
	output reg flush_done;
	output wire ev_read_acc;
	output wire ev_read_hit;
	output wire ev_read_stall;
	output wire ev_write_acc;
	output wire ev_write_hit;
	output wire ev_write_stall;
	localparam WAYS = 2;
	localparam SETS = CACHE_LINES / WAYS;
	localparam INDEX_BITS = $clog2(SETS);
	localparam TAG_BITS = ADDR_BITS - INDEX_BITS;
	reg valid_array [0:SETS - 1][0:1];
	reg [TAG_BITS - 1:0] tag_array [0:SETS - 1][0:1];
	reg [BLOCK_BITS - 1:0] data_array [0:SETS - 1][0:1];
	reg lru_bit [0:SETS - 1];
	reg [1:0] state;
	wire [INDEX_BITS - 1:0] req_index = (core_read_valid ? core_read_block_addr[INDEX_BITS - 1:0] : core_write_block_addr[INDEX_BITS - 1:0]);
	wire [TAG_BITS - 1:0] req_tag = (core_read_valid ? core_read_block_addr[ADDR_BITS - 1:INDEX_BITS] : core_write_block_addr[ADDR_BITS - 1:INDEX_BITS]);
	wire hit_w0 = valid_array[req_index][0] && (tag_array[req_index][0] == req_tag);
	wire hit_w1 = valid_array[req_index][1] && (tag_array[req_index][1] == req_tag);
	wire hit = hit_w0 || hit_w1;
	wire hit_way = hit_w1;
	wire victim_way = lru_bit[req_index];
	always @(posedge clk)
		if (reset) begin
			state <= 2'd0;
			mem_read_valid <= 0;
			mem_write_valid <= 0;
			core_read_ready <= 0;
			core_write_ready <= 0;
			flush_done <= 0;
			begin : sv2v_autoblock_1
				reg signed [31:0] s;
				for (s = 0; s < SETS; s = s + 1)
					begin
						lru_bit[s] <= 0;
						begin : sv2v_autoblock_2
							reg signed [31:0] w;
							for (w = 0; w < WAYS; w = w + 1)
								valid_array[s][w] <= 0;
						end
					end
			end
		end
		else begin
			core_read_ready <= 0;
			core_write_ready <= 0;
			flush_done <= 0;
			case (state)
				2'd0:
					if (flush_en) begin
						begin : sv2v_autoblock_3
							reg signed [31:0] s;
							for (s = 0; s < SETS; s = s + 1)
								begin : sv2v_autoblock_4
									reg signed [31:0] w;
									for (w = 0; w < WAYS; w = w + 1)
										valid_array[s][w] <= 0;
								end
						end
						flush_done <= 1;
					end
					else if (core_write_valid && !core_write_ready) begin
						mem_write_valid <= 1;
						mem_write_block_addr <= core_write_block_addr;
						mem_write_block_data <= core_write_block_data;
						mem_write_strobe <= core_write_strobe;
						state <= 2'd2;
						if (hit) begin : sv2v_autoblock_5
							reg [BLOCK_BITS - 1:0] merged_data;
							merged_data = data_array[req_index][hit_way];
							if (core_write_strobe[0])
								merged_data[31:0] = core_write_block_data[31:0];
							if (core_write_strobe[1])
								merged_data[63:32] = core_write_block_data[63:32];
							if (core_write_strobe[2])
								merged_data[95:64] = core_write_block_data[95:64];
							if (core_write_strobe[3])
								merged_data[127:96] = core_write_block_data[127:96];
							data_array[req_index][hit_way] <= merged_data;
							lru_bit[req_index] <= ~hit_way;
						end
					end
					else if (core_read_valid && !core_read_ready) begin
						if (hit) begin
							core_read_block_data <= data_array[req_index][hit_way];
							lru_bit[req_index] <= ~hit_way;
							core_read_ready <= 1;
						end
						else begin
							mem_read_valid <= 1;
							mem_read_block_addr <= core_read_block_addr;
							state <= 2'd1;
						end
					end
				2'd2:
					if (mem_write_ready) begin
						mem_write_valid <= 0;
						core_write_ready <= 1;
						state <= 2'd0;
					end
				2'd1:
					if (mem_read_ready) begin
						mem_read_valid <= 0;
						valid_array[req_index][victim_way] <= 1;
						tag_array[req_index][victim_way] <= req_tag;
						data_array[req_index][victim_way] <= mem_read_block_data;
						lru_bit[req_index] <= ~victim_way;
						core_read_block_data <= mem_read_block_data;
						core_read_ready <= 1;
						state <= 2'd0;
					end
			endcase
		end
	assign ev_read_acc = (state == 2'd0) && core_read_valid;
	assign ev_read_hit = ((state == 2'd0) && core_read_valid) && hit;
	assign ev_read_stall = core_read_valid && !core_read_ready;
	assign ev_write_acc = (state == 2'd0) && core_write_valid;
	assign ev_write_hit = ((state == 2'd0) && core_write_valid) && hit;
	assign ev_write_stall = core_write_valid && !core_write_ready;
endmodule
`default_nettype none
module dcr (
	clk,
	reset,
	device_control_write_enable,
	device_control_address,
	device_control_data,
	thread_count,
	pmu_reset,
	pmu_snapshot,
	pmu_cfg_0,
	pmu_cfg_1,
	pmu_cfg_2,
	pmu_cfg_3
);
	input wire clk;
	input wire reset;
	input wire device_control_write_enable;
	input wire [7:0] device_control_address;
	input wire [7:0] device_control_data;
	output wire [7:0] thread_count;
	output reg pmu_reset;
	output reg pmu_snapshot;
	output reg [4:0] pmu_cfg_0;
	output reg [4:0] pmu_cfg_1;
	output reg [4:0] pmu_cfg_2;
	output reg [4:0] pmu_cfg_3;
	reg [7:0] device_control_register;
	assign thread_count = device_control_register[7:0];
	always @(posedge clk)
		if (reset) begin
			device_control_register <= 8'b00000000;
			pmu_reset <= 0;
			pmu_snapshot <= 0;
			pmu_cfg_0 <= 5'd0;
			pmu_cfg_1 <= 5'd0;
			pmu_cfg_2 <= 5'd0;
			pmu_cfg_3 <= 5'd0;
		end
		else begin
			pmu_reset <= 0;
			pmu_snapshot <= 0;
			if (device_control_write_enable) begin
				if (device_control_address == 8'h00)
					device_control_register <= device_control_data;
				else if (device_control_address == 8'h01)
					pmu_reset <= 1'b1;
				else if (device_control_address == 8'h02)
					pmu_snapshot <= 1'b1;
				else if (device_control_address == 8'h10)
					pmu_cfg_0 <= device_control_data[4:0];
				else if (device_control_address == 8'h11)
					pmu_cfg_1 <= device_control_data[4:0];
				else if (device_control_address == 8'h12)
					pmu_cfg_2 <= device_control_data[4:0];
				else if (device_control_address == 8'h13)
					pmu_cfg_3 <= device_control_data[4:0];
			end
		end
endmodule
`default_nettype none
module decoder (
	instruction,
	decoded_rd_address,
	decoded_rs_address,
	decoded_rt_address,
	decoded_nzp,
	decoded_immediate,
	decoded_use_mem_offset,
	decoded_mem_addr_offset,
	decoded_rs_read_enable,
	decoded_rt_read_enable,
	decoded_rd_read_enable,
	decoded_reg_write_enable,
	decoded_mem_read_enable,
	decoded_mem_write_enable,
	decoded_nzp_write_enable,
	decoded_reg_input_mux,
	decoded_alu_arithmetic_mux,
	decoded_alu_output_mux,
	decoded_pc_mux,
	decoded_call,
	decoded_ret_fn,
	decoded_exit,
	decoded_sync,
	decoded_shared_read_enable,
	decoded_shared_write_enable,
	decoded_atomic,
	decoded_flags_write_enable
);
	reg _sv2v_0;
	parameter DATA_BITS = 32;
	input wire [31:0] instruction;
	output reg [4:0] decoded_rd_address;
	output reg [4:0] decoded_rs_address;
	output reg [4:0] decoded_rt_address;
	output reg [2:0] decoded_nzp;
	output reg [DATA_BITS - 1:0] decoded_immediate;
	output reg decoded_use_mem_offset;
	output reg [15:0] decoded_mem_addr_offset;
	output reg decoded_rs_read_enable;
	output reg decoded_rt_read_enable;
	output reg decoded_rd_read_enable;
	output reg decoded_reg_write_enable;
	output reg decoded_mem_read_enable;
	output reg decoded_mem_write_enable;
	output reg decoded_nzp_write_enable;
	output reg [1:0] decoded_reg_input_mux;
	output reg [4:0] decoded_alu_arithmetic_mux;
	output reg decoded_alu_output_mux;
	output reg decoded_pc_mux;
	output reg decoded_call;
	output reg decoded_ret_fn;
	output reg decoded_exit;
	output reg decoded_sync;
	output reg decoded_shared_read_enable;
	output reg decoded_shared_write_enable;
	output reg [1:0] decoded_atomic;
	output reg decoded_flags_write_enable;
	localparam NOP = 6'd0;
	localparam BRnzp = 6'd1;
	localparam CMP = 6'd2;
	localparam ADD = 6'd3;
	localparam SUB = 6'd4;
	localparam MUL = 6'd5;
	localparam DIV = 6'd6;
	localparam LDR = 6'd7;
	localparam STR = 6'd8;
	localparam CONST = 6'd9;
	localparam SYNC = 6'd10;
	localparam LDSH = 6'd11;
	localparam STSH = 6'd12;
	localparam CALL = 6'd13;
	localparam RET_FN = 6'd14;
	localparam EXIT = 6'd15;
	localparam ATOM_ADD = 6'd16;
	localparam AND = 6'd17;
	localparam OR = 6'd18;
	localparam XOR = 6'd19;
	localparam SHL = 6'd20;
	localparam SHR = 6'd21;
	localparam MOD = 6'd22;
	localparam MIN = 6'd23;
	localparam MAX = 6'd24;
	localparam ABS = 6'd25;
	localparam NEG = 6'd26;
	localparam MAC = 6'd27;
	localparam ATOM_CAS = 6'd28;
	localparam LUI = 6'd29;
	localparam POPCNT = 6'd30;
	localparam CLZ = 6'd31;
	localparam BREV = 6'd32;
	always @(*) begin
		if (_sv2v_0)
			;
		decoded_rd_address = instruction[25:21];
		decoded_rs_address = instruction[20:16];
		if ((instruction[31:26] == STR) || (instruction[31:26] == STSH))
			decoded_rt_address = instruction[25:21];
		else
			decoded_rt_address = instruction[15:11];
		decoded_nzp = instruction[25:23];
		decoded_immediate = {{DATA_BITS - 16 {instruction[15]}}, instruction[15:0]};
		decoded_mem_addr_offset = instruction[15:0];
		decoded_rs_read_enable = 0;
		decoded_rt_read_enable = 0;
		decoded_reg_write_enable = 0;
		decoded_mem_read_enable = 0;
		decoded_mem_write_enable = 0;
		decoded_nzp_write_enable = 0;
		decoded_reg_input_mux = 2'b00;
		decoded_alu_arithmetic_mux = 5'b00000;
		decoded_alu_output_mux = 0;
		decoded_pc_mux = 0;
		decoded_call = 0;
		decoded_ret_fn = 0;
		decoded_exit = 0;
		decoded_sync = 0;
		decoded_shared_read_enable = 0;
		decoded_shared_write_enable = 0;
		decoded_use_mem_offset = 0;
		decoded_atomic = 2'b00;
		decoded_rd_read_enable = 0;
		decoded_flags_write_enable = 0;
		case (instruction[31:26])
			BRnzp: decoded_pc_mux = 1;
			CMP: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_alu_output_mux = 1;
				decoded_nzp_write_enable = 1;
			end
			ADD: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd0;
				decoded_flags_write_enable = 1;
			end
			SUB: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd1;
				decoded_flags_write_enable = 1;
			end
			MUL: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd2;
				decoded_flags_write_enable = 1;
			end
			DIV: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd3;
				decoded_flags_write_enable = 1;
			end
			AND: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd4;
				decoded_flags_write_enable = 1;
			end
			OR: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd5;
				decoded_flags_write_enable = 1;
			end
			XOR: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd6;
				decoded_flags_write_enable = 1;
			end
			SHL: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd7;
				decoded_flags_write_enable = 1;
			end
			SHR: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd8;
				decoded_flags_write_enable = 1;
			end
			MOD: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd9;
				decoded_flags_write_enable = 1;
			end
			MIN: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd10;
				decoded_flags_write_enable = 1;
			end
			MAX: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd11;
				decoded_flags_write_enable = 1;
			end
			ABS: begin
				decoded_rs_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd12;
				decoded_flags_write_enable = 1;
			end
			NEG: begin
				decoded_rs_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd13;
				decoded_flags_write_enable = 1;
			end
			MAC: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_rd_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd14;
				decoded_flags_write_enable = 1;
			end
			LUI: begin
				decoded_reg_write_enable = 1;
				decoded_reg_input_mux = 2'b10;
				decoded_immediate = {instruction[20:1], 12'b000000000000};
			end
			POPCNT: begin
				decoded_rs_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd15;
				decoded_flags_write_enable = 1;
			end
			CLZ: begin
				decoded_rs_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd16;
				decoded_flags_write_enable = 1;
			end
			BREV: begin
				decoded_rs_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_alu_arithmetic_mux = 5'd17;
				decoded_flags_write_enable = 1;
			end
			LDR: begin
				decoded_rs_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_reg_input_mux = 2'b01;
				decoded_mem_read_enable = 1;
				decoded_use_mem_offset = 1;
			end
			STR: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_mem_write_enable = 1;
				decoded_use_mem_offset = 1;
			end
			CONST: begin
				decoded_reg_write_enable = 1;
				decoded_reg_input_mux = 2'b10;
			end
			SYNC: decoded_sync = 1;
			LDSH: begin
				decoded_rs_read_enable = 1;
				decoded_shared_read_enable = 1;
				decoded_reg_input_mux = 2'b11;
				decoded_reg_write_enable = 1;
			end
			STSH: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_shared_write_enable = 1;
			end
			CALL: begin
				decoded_call = 1;
				decoded_pc_mux = 1;
			end
			RET_FN: decoded_ret_fn = 1;
			EXIT: decoded_exit = 1;
			ATOM_ADD: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_reg_input_mux = 2'b01;
				decoded_atomic = 2'b01;
				decoded_use_mem_offset = 0;
			end
			ATOM_CAS: begin
				decoded_rs_read_enable = 1;
				decoded_rt_read_enable = 1;
				decoded_rd_read_enable = 1;
				decoded_reg_write_enable = 1;
				decoded_reg_input_mux = 2'b01;
				decoded_atomic = 2'b10;
				decoded_use_mem_offset = 0;
			end
			default:
				;
		endcase
	end
	initial _sv2v_0 = 0;
endmodule
`default_nettype none
module dispatch (
	clk,
	reset,
	start,
	thread_count,
	core_done,
	core_start,
	core_reset,
	core_block_id,
	core_thread_count,
	flush_caches,
	cache_flush_done,
	done
);
	parameter NUM_CORES = 2;
	parameter THREADS_PER_BLOCK = 4;
	parameter NUM_WARPS = 4;
	input wire clk;
	input wire reset;
	input wire start;
	input wire [7:0] thread_count;
	input wire [NUM_CORES - 1:0] core_done;
	output reg [NUM_CORES - 1:0] core_start;
	output reg [NUM_CORES - 1:0] core_reset;
	output reg [(NUM_CORES * 8) - 1:0] core_block_id;
	output reg [($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? (NUM_CORES * ($clog2(THREADS_PER_BLOCK * NUM_WARPS) + 1)) - 1 : (NUM_CORES * (1 - $clog2(THREADS_PER_BLOCK * NUM_WARPS))) + ($clog2(THREADS_PER_BLOCK * NUM_WARPS) - 1)):($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? 0 : $clog2(THREADS_PER_BLOCK * NUM_WARPS) + 0)] core_thread_count;
	output reg flush_caches;
	input wire [NUM_CORES - 1:0] cache_flush_done;
	output reg done;
	localparam THREADS_PER_CORE = THREADS_PER_BLOCK * NUM_WARPS;
	wire [7:0] total_blocks = ((thread_count + THREADS_PER_CORE) - 1) / THREADS_PER_CORE;
	reg [7:0] blocks_dispatched;
	reg [7:0] blocks_done;
	reg start_execution;
	reg is_running;
	reg flushing;
	always @(posedge clk)
		if (reset) begin
			done <= 0;
			blocks_dispatched = 0;
			blocks_done = 0;
			start_execution <= 0;
			is_running <= 0;
			flush_caches <= 0;
			flushing <= 0;
			begin : sv2v_autoblock_1
				reg signed [31:0] i;
				for (i = 0; i < NUM_CORES; i = i + 1)
					begin
						core_start[i] <= 0;
						core_reset[i] <= 1;
						core_block_id[((NUM_CORES - 1) - i) * 8+:8] <= 0;
						core_thread_count[($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? 0 : $clog2(THREADS_PER_BLOCK * NUM_WARPS)) + (((NUM_CORES - 1) - i) * ($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? $clog2(THREADS_PER_BLOCK * NUM_WARPS) + 1 : 1 - $clog2(THREADS_PER_BLOCK * NUM_WARPS)))+:($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? $clog2(THREADS_PER_BLOCK * NUM_WARPS) + 1 : 1 - $clog2(THREADS_PER_BLOCK * NUM_WARPS))] <= 0;
					end
			end
		end
		else begin
			if (start)
				is_running <= 1;
			if (start || is_running) begin
				if (!start_execution) begin
					start_execution <= 1;
					begin : sv2v_autoblock_2
						reg signed [31:0] i;
						for (i = 0; i < NUM_CORES; i = i + 1)
							core_reset[i] <= 1;
					end
				end
				begin : sv2v_autoblock_3
					reg signed [31:0] i;
					for (i = 0; i < NUM_CORES; i = i + 1)
						begin
							if (core_reset[i] && !flushing) begin
								core_reset[i] <= 0;
								if (blocks_dispatched < total_blocks) begin
									core_start[i] <= 1;
									core_block_id[((NUM_CORES - 1) - i) * 8+:8] <= blocks_dispatched;
									if ((blocks_dispatched == (total_blocks - 1)) && ((thread_count % THREADS_PER_CORE) != 0))
										core_thread_count[($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? 0 : $clog2(THREADS_PER_BLOCK * NUM_WARPS)) + (((NUM_CORES - 1) - i) * ($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? $clog2(THREADS_PER_BLOCK * NUM_WARPS) + 1 : 1 - $clog2(THREADS_PER_BLOCK * NUM_WARPS)))+:($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? $clog2(THREADS_PER_BLOCK * NUM_WARPS) + 1 : 1 - $clog2(THREADS_PER_BLOCK * NUM_WARPS))] <= thread_count % THREADS_PER_CORE;
									else
										core_thread_count[($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? 0 : $clog2(THREADS_PER_BLOCK * NUM_WARPS)) + (((NUM_CORES - 1) - i) * ($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? $clog2(THREADS_PER_BLOCK * NUM_WARPS) + 1 : 1 - $clog2(THREADS_PER_BLOCK * NUM_WARPS)))+:($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? $clog2(THREADS_PER_BLOCK * NUM_WARPS) + 1 : 1 - $clog2(THREADS_PER_BLOCK * NUM_WARPS))] <= THREADS_PER_CORE;
									blocks_dispatched = blocks_dispatched + 1;
								end
							end
							if (core_start[i] && core_done[i]) begin
								core_reset[i] <= 1;
								core_start[i] <= 0;
								blocks_done = blocks_done + 1;
							end
						end
				end
				if (((blocks_done == total_blocks) && (total_blocks > 0)) && !flushing) begin
					flush_caches <= 1;
					flushing <= 1;
				end
				if (flushing && &cache_flush_done) begin
					flush_caches <= 0;
					flushing <= 0;
					is_running <= 0;
					done <= 1;
				end
			end
			else
				done <= 0;
		end
endmodule
`default_nettype none
module fetcher (
	clk,
	reset,
	stall,
	flush,
	current_pc,
	mem_read_valid,
	mem_read_address,
	mem_read_ready,
	mem_read_data,
	instruction_valid,
	instruction
);
	parameter PROGRAM_MEM_ADDR_BITS = 8;
	parameter PROGRAM_MEM_DATA_BITS = 16;
	input wire clk;
	input wire reset;
	input wire stall;
	input wire flush;
	input wire [PROGRAM_MEM_ADDR_BITS - 1:0] current_pc;
	output reg mem_read_valid;
	output wire [PROGRAM_MEM_ADDR_BITS - 1:0] mem_read_address;
	input wire mem_read_ready;
	input wire [PROGRAM_MEM_DATA_BITS - 1:0] mem_read_data;
	output reg instruction_valid;
	output reg [PROGRAM_MEM_DATA_BITS - 1:0] instruction;
	reg [1:0] state;
	assign mem_read_address = current_pc;
	always @(posedge clk)
		if (reset || flush) begin
			state <= 2'd0;
			mem_read_valid <= 0;
			instruction_valid <= 0;
			instruction <= {PROGRAM_MEM_DATA_BITS {1'b0}};
		end
		else
			case (state)
				2'd0: begin
					instruction_valid <= 0;
					if (!stall) begin
						state <= 2'd1;
						mem_read_valid <= 1;
					end
				end
				2'd1:
					if (mem_read_ready) begin
						state <= 2'd2;
						mem_read_valid <= 0;
						instruction_valid <= 1;
						instruction <= mem_read_data;
					end
				2'd2:
					if (!stall) begin
						state <= 2'd1;
						mem_read_valid <= 1;
						instruction_valid <= 0;
					end
					else
						instruction_valid <= 1;
			endcase
endmodule
`default_nettype none
module gpu (
	clk,
	reset,
	start,
	done,
	device_control_write_enable,
	device_control_address,
	device_control_data,
	program_mem_read_valid,
	program_mem_read_address,
	program_mem_read_ready,
	program_mem_read_data,
	data_mem_read_valid,
	data_mem_read_address,
	data_mem_read_ready,
	data_mem_read_data,
	data_mem_write_valid,
	data_mem_write_address,
	data_mem_write_data,
	data_mem_write_strobe,
	data_mem_write_ready,
	pmu_snap_0,
	pmu_snap_1,
	pmu_snap_2,
	pmu_snap_3
);
	parameter DATA_MEM_ADDR_BITS = 32;
	parameter DATA_MEM_DATA_BITS = 32;
	parameter DATA_MEM_NUM_CHANNELS = 4;
	parameter PROGRAM_MEM_ADDR_BITS = 32;
	parameter PROGRAM_MEM_DATA_BITS = 32;
	parameter PROGRAM_MEM_NUM_CHANNELS = 1;
	parameter NUM_CORES = 2;
	parameter THREADS_PER_BLOCK = 4;
	parameter NUM_WARPS = 4;
	parameter DEBUG = 0;
	input wire clk;
	input wire reset;
	input wire start;
	output wire done;
	input wire device_control_write_enable;
	input wire [7:0] device_control_address;
	input wire [7:0] device_control_data;
	output wire [PROGRAM_MEM_NUM_CHANNELS - 1:0] program_mem_read_valid;
	output wire [(PROGRAM_MEM_NUM_CHANNELS * PROGRAM_MEM_ADDR_BITS) - 1:0] program_mem_read_address;
	input wire [PROGRAM_MEM_NUM_CHANNELS - 1:0] program_mem_read_ready;
	input wire [(PROGRAM_MEM_NUM_CHANNELS * (PROGRAM_MEM_DATA_BITS * 4)) - 1:0] program_mem_read_data;
	output wire [DATA_MEM_NUM_CHANNELS - 1:0] data_mem_read_valid;
	output wire [(DATA_MEM_NUM_CHANNELS * DATA_MEM_ADDR_BITS) - 1:0] data_mem_read_address;
	input wire [DATA_MEM_NUM_CHANNELS - 1:0] data_mem_read_ready;
	input wire [(DATA_MEM_NUM_CHANNELS * (DATA_MEM_DATA_BITS * 4)) - 1:0] data_mem_read_data;
	output wire [DATA_MEM_NUM_CHANNELS - 1:0] data_mem_write_valid;
	output wire [(DATA_MEM_NUM_CHANNELS * DATA_MEM_ADDR_BITS) - 1:0] data_mem_write_address;
	output wire [(DATA_MEM_NUM_CHANNELS * (DATA_MEM_DATA_BITS * 4)) - 1:0] data_mem_write_data;
	output wire [(DATA_MEM_NUM_CHANNELS * 4) - 1:0] data_mem_write_strobe;
	input wire [DATA_MEM_NUM_CHANNELS - 1:0] data_mem_write_ready;
	output wire [(NUM_CORES * 32) - 1:0] pmu_snap_0;
	output wire [(NUM_CORES * 32) - 1:0] pmu_snap_1;
	output wire [(NUM_CORES * 32) - 1:0] pmu_snap_2;
	output wire [(NUM_CORES * 32) - 1:0] pmu_snap_3;
	wire [7:0] thread_count;
	wire pmu_reset_global;
	wire pmu_snapshot_global;
	wire [4:0] pmu_cfg_0_global;
	wire [4:0] pmu_cfg_1_global;
	wire [4:0] pmu_cfg_2_global;
	wire [4:0] pmu_cfg_3_global;
	wire [NUM_CORES - 1:0] core_start;
	wire [NUM_CORES - 1:0] core_reset;
	wire [NUM_CORES - 1:0] core_done;
	wire [(NUM_CORES * 8) - 1:0] core_block_id;
	wire [($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? (NUM_CORES * ($clog2(THREADS_PER_BLOCK * NUM_WARPS) + 1)) - 1 : (NUM_CORES * (1 - $clog2(THREADS_PER_BLOCK * NUM_WARPS))) + ($clog2(THREADS_PER_BLOCK * NUM_WARPS) - 1)):($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? 0 : $clog2(THREADS_PER_BLOCK * NUM_WARPS) + 0)] core_thread_count;
	localparam NUM_FETCHERS = NUM_CORES;
	wire [NUM_FETCHERS - 1:0] core_pmem_read_valid;
	wire [PROGRAM_MEM_ADDR_BITS - 1:0] core_pmem_read_addr [0:NUM_FETCHERS - 1];
	wire [NUM_FETCHERS - 1:0] core_pmem_read_ready;
	wire [PROGRAM_MEM_DATA_BITS - 1:0] core_pmem_read_data [0:NUM_FETCHERS - 1];
	localparam NUM_LSUS = NUM_CORES;
	wire [NUM_LSUS - 1:0] core_dmem_read_valid;
	wire [DATA_MEM_ADDR_BITS - 1:0] core_dmem_read_addr [0:NUM_LSUS - 1];
	wire [NUM_LSUS - 1:0] core_dmem_read_ready;
	wire [(DATA_MEM_DATA_BITS * 4) - 1:0] core_dmem_read_data [0:NUM_LSUS - 1];
	wire [NUM_LSUS - 1:0] core_dmem_write_valid;
	wire [DATA_MEM_ADDR_BITS - 1:0] core_dmem_write_addr [0:NUM_LSUS - 1];
	wire [(DATA_MEM_DATA_BITS * 4) - 1:0] core_dmem_write_data [0:NUM_LSUS - 1];
	wire [3:0] core_dmem_write_strobe [0:NUM_LSUS - 1];
	wire [NUM_LSUS - 1:0] core_dmem_write_ready;
	wire [NUM_CORES - 1:0] icache_mem_read_valid;
	wire [(NUM_CORES * PROGRAM_MEM_ADDR_BITS) - 1:0] icache_mem_read_addr;
	wire [NUM_CORES - 1:0] icache_mem_read_ready;
	wire [(NUM_CORES * (PROGRAM_MEM_DATA_BITS * 4)) - 1:0] icache_mem_read_data;
	wire [NUM_CORES - 1:0] dcache_mem_read_valid;
	wire [(NUM_CORES * DATA_MEM_ADDR_BITS) - 1:0] dcache_mem_read_addr;
	wire [NUM_CORES - 1:0] dcache_mem_read_ready;
	wire [(NUM_CORES * (DATA_MEM_DATA_BITS * 4)) - 1:0] dcache_mem_read_data;
	wire [NUM_CORES - 1:0] dcache_mem_write_valid;
	wire [(NUM_CORES * DATA_MEM_ADDR_BITS) - 1:0] dcache_mem_write_addr;
	wire [(NUM_CORES * (DATA_MEM_DATA_BITS * 4)) - 1:0] dcache_mem_write_data;
	wire [(NUM_CORES * 4) - 1:0] dcache_mem_write_strobe;
	wire [NUM_CORES - 1:0] dcache_mem_write_ready;
	wire [0:0] l2_mem_read_valid;
	wire [DATA_MEM_ADDR_BITS - 1:0] l2_mem_read_addr;
	wire [0:0] l2_mem_read_ready;
	wire [(DATA_MEM_DATA_BITS * 4) - 1:0] l2_mem_read_data;
	wire [0:0] l2_mem_write_valid;
	wire [DATA_MEM_ADDR_BITS - 1:0] l2_mem_write_addr;
	wire [(DATA_MEM_DATA_BITS * 4) - 1:0] l2_mem_write_data;
	wire [3:0] l2_mem_write_strobe;
	wire [0:0] l2_mem_write_ready;
	wire flush_caches_global;
	wire l2_flush_done;
	wire [NUM_CORES - 1:0] l1_dcache_flush_done;
	wire [NUM_CORES - 1:0] core_cache_flush_done;
	dcr dcr_instance(
		.clk(clk),
		.reset(reset),
		.device_control_write_enable(device_control_write_enable),
		.device_control_address(device_control_address),
		.device_control_data(device_control_data),
		.thread_count(thread_count),
		.pmu_reset(pmu_reset_global),
		.pmu_snapshot(pmu_snapshot_global),
		.pmu_cfg_0(pmu_cfg_0_global),
		.pmu_cfg_1(pmu_cfg_1_global),
		.pmu_cfg_2(pmu_cfg_2_global),
		.pmu_cfg_3(pmu_cfg_3_global)
	);
	l2_cache #(
		.ADDR_BITS(DATA_MEM_ADDR_BITS),
		.BLOCK_BITS(DATA_MEM_DATA_BITS * 4),
		.CACHE_LINES(256),
		.WAYS(4),
		.SECTORS(4),
		.NUM_PORTS(NUM_CORES),
		.VWB_DEPTH(8)
	) unified_cache(
		.clk(clk),
		.reset(reset),
		.up_read_valid(dcache_mem_read_valid),
		.up_read_addr(dcache_mem_read_addr),
		.up_read_ready(dcache_mem_read_ready),
		.up_read_data(dcache_mem_read_data),
		.up_write_valid(dcache_mem_write_valid),
		.up_write_addr(dcache_mem_write_addr),
		.up_write_data(dcache_mem_write_data),
		.up_write_strobe(dcache_mem_write_strobe),
		.up_write_ready(dcache_mem_write_ready),
		.mem_read_valid(l2_mem_read_valid[0]),
		.mem_read_addr(l2_mem_read_addr[0+:DATA_MEM_ADDR_BITS]),
		.mem_read_ready(l2_mem_read_ready[0]),
		.mem_read_data(l2_mem_read_data[0+:DATA_MEM_DATA_BITS * 4]),
		.mem_write_valid(l2_mem_write_valid[0]),
		.mem_write_addr(l2_mem_write_addr[0+:DATA_MEM_ADDR_BITS]),
		.mem_write_data(l2_mem_write_data[0+:DATA_MEM_DATA_BITS * 4]),
		.mem_write_strobe(l2_mem_write_strobe[0+:4]),
		.mem_write_ready(l2_mem_write_ready[0]),
		.flush_en(flush_caches_global),
		.flush_done(l2_flush_done)
	);
	controller #(
		.ADDR_BITS(DATA_MEM_ADDR_BITS),
		.DATA_BITS(DATA_MEM_DATA_BITS),
		.BLOCK_DATA_BITS(DATA_MEM_DATA_BITS * 4),
		.NUM_CONSUMERS(1),
		.NUM_CHANNELS(DATA_MEM_NUM_CHANNELS)
	) data_memory_controller(
		.clk(clk),
		.reset(reset),
		.consumer_read_valid(l2_mem_read_valid),
		.consumer_read_address(l2_mem_read_addr),
		.consumer_read_ready(l2_mem_read_ready),
		.consumer_read_data(l2_mem_read_data),
		.consumer_write_valid(l2_mem_write_valid),
		.consumer_write_address(l2_mem_write_addr),
		.consumer_write_data(l2_mem_write_data),
		.consumer_write_strobe(l2_mem_write_strobe),
		.consumer_write_ready(l2_mem_write_ready),
		.mem_read_valid(data_mem_read_valid),
		.mem_read_address(data_mem_read_address),
		.mem_read_ready(data_mem_read_ready),
		.mem_read_data(data_mem_read_data),
		.mem_write_valid(data_mem_write_valid),
		.mem_write_address(data_mem_write_address),
		.mem_write_data(data_mem_write_data),
		.mem_write_strobe(data_mem_write_strobe),
		.mem_write_ready(data_mem_write_ready)
	);
	controller #(
		.ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
		.DATA_BITS(PROGRAM_MEM_DATA_BITS),
		.BLOCK_DATA_BITS(PROGRAM_MEM_DATA_BITS * 4),
		.NUM_CONSUMERS(NUM_FETCHERS),
		.NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
		.WRITE_ENABLE(0)
	) program_memory_controller(
		.clk(clk),
		.reset(reset),
		.consumer_read_valid(icache_mem_read_valid),
		.consumer_read_address(icache_mem_read_addr),
		.consumer_read_ready(icache_mem_read_ready),
		.consumer_read_data(icache_mem_read_data),
		.mem_read_valid(program_mem_read_valid),
		.mem_read_address(program_mem_read_address),
		.mem_read_ready(program_mem_read_ready),
		.mem_read_data(program_mem_read_data),
		.mem_write_valid(),
		.mem_write_address(),
		.mem_write_data(),
		.mem_write_strobe(),
		.mem_write_ready({PROGRAM_MEM_NUM_CHANNELS {1'b0}})
	);
	dispatch #(
		.NUM_CORES(NUM_CORES),
		.THREADS_PER_BLOCK(THREADS_PER_BLOCK),
		.NUM_WARPS(NUM_WARPS)
	) dispatch_instance(
		.clk(clk),
		.reset(reset),
		.start(start),
		.thread_count(thread_count),
		.core_done(core_done),
		.core_start(core_start),
		.core_reset(core_reset),
		.core_block_id(core_block_id),
		.core_thread_count(core_thread_count),
		.flush_caches(flush_caches_global),
		.cache_flush_done(core_cache_flush_done),
		.done(done)
	);
	genvar _gv_i_2;
	generate
		for (_gv_i_2 = 0; _gv_i_2 < NUM_CORES; _gv_i_2 = _gv_i_2 + 1) begin : core_block
			localparam i = _gv_i_2;
			wire ic_ev_acc;
			wire ic_ev_hit;
			wire ic_ev_stall;
			wire dc_ev_r_acc;
			wire dc_ev_r_hit;
			wire dc_ev_r_stall;
			wire dc_ev_w_acc;
			wire dc_ev_w_hit;
			wire dc_ev_w_stall;
			assign core_cache_flush_done[i] = l1_dcache_flush_done[i] & l2_flush_done;
			core #(
				.DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
				.DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
				.PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
				.PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
				.THREADS_PER_BLOCK(THREADS_PER_BLOCK),
				.NUM_WARPS(NUM_WARPS),
				.DEBUG(DEBUG)
			) core_inst(
				.clk(clk),
				.reset(core_reset[i]),
				.global_reset(reset),
				.start(core_start[i]),
				.done(core_done[i]),
				.block_id(core_block_id[((NUM_CORES - 1) - i) * 8+:8]),
				.thread_count(core_thread_count[($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? 0 : $clog2(THREADS_PER_BLOCK * NUM_WARPS)) + (((NUM_CORES - 1) - i) * ($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? $clog2(THREADS_PER_BLOCK * NUM_WARPS) + 1 : 1 - $clog2(THREADS_PER_BLOCK * NUM_WARPS)))+:($clog2(THREADS_PER_BLOCK * NUM_WARPS) >= 0 ? $clog2(THREADS_PER_BLOCK * NUM_WARPS) + 1 : 1 - $clog2(THREADS_PER_BLOCK * NUM_WARPS))]),
				.program_mem_read_valid(core_pmem_read_valid[i]),
				.program_mem_read_address(core_pmem_read_addr[i]),
				.program_mem_read_ready(core_pmem_read_ready[i]),
				.program_mem_read_data(core_pmem_read_data[i]),
				.data_mem_read_valid(core_dmem_read_valid[i]),
				.data_mem_read_address(core_dmem_read_addr[i]),
				.data_mem_read_ready(core_dmem_read_ready[i]),
				.data_mem_read_data(core_dmem_read_data[i]),
				.data_mem_write_valid(core_dmem_write_valid[i]),
				.data_mem_write_address(core_dmem_write_addr[i]),
				.data_mem_write_data(core_dmem_write_data[i]),
				.data_mem_write_strobe(core_dmem_write_strobe[i]),
				.data_mem_write_ready(core_dmem_write_ready[i]),
				.pmu_cfg_0(pmu_cfg_0_global),
				.pmu_cfg_1(pmu_cfg_1_global),
				.pmu_cfg_2(pmu_cfg_2_global),
				.pmu_cfg_3(pmu_cfg_3_global),
				.pmu_reset(pmu_reset_global),
				.pmu_snapshot(pmu_snapshot_global),
				.pmu_snap_0(pmu_snap_0[((NUM_CORES - 1) - i) * 32+:32]),
				.pmu_snap_1(pmu_snap_1[((NUM_CORES - 1) - i) * 32+:32]),
				.pmu_snap_2(pmu_snap_2[((NUM_CORES - 1) - i) * 32+:32]),
				.pmu_snap_3(pmu_snap_3[((NUM_CORES - 1) - i) * 32+:32]),
				.ic_ev_access(ic_ev_acc),
				.ic_ev_hit(ic_ev_hit),
				.ic_ev_stall(ic_ev_stall),
				.dc_ev_read_acc(dc_ev_r_acc),
				.dc_ev_read_hit(dc_ev_r_hit),
				.dc_ev_read_stall(dc_ev_r_stall),
				.dc_ev_write_acc(dc_ev_w_acc),
				.dc_ev_write_hit(dc_ev_w_hit),
				.dc_ev_write_stall(dc_ev_w_stall)
			);
			icache #(
				.ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
				.DATA_BITS(PROGRAM_MEM_DATA_BITS),
				.BLOCK_BITS(PROGRAM_MEM_DATA_BITS * 4),
				.CACHE_LINES(16)
			) icache_inst(
				.clk(clk),
				.reset(reset),
				.core_read_valid(core_pmem_read_valid[i]),
				.core_read_addr(core_pmem_read_addr[i]),
				.core_read_ready(core_pmem_read_ready[i]),
				.core_read_data(core_pmem_read_data[i]),
				.mem_read_valid(icache_mem_read_valid[i]),
				.mem_read_block_addr(icache_mem_read_addr[((NUM_CORES - 1) - i) * PROGRAM_MEM_ADDR_BITS+:PROGRAM_MEM_ADDR_BITS]),
				.mem_read_ready(icache_mem_read_ready[i]),
				.mem_read_block_data(icache_mem_read_data[((NUM_CORES - 1) - i) * (PROGRAM_MEM_DATA_BITS * 4)+:PROGRAM_MEM_DATA_BITS * 4]),
				.ev_access(ic_ev_acc),
				.ev_hit(ic_ev_hit),
				.ev_stall(ic_ev_stall)
			);
			dcache #(
				.ADDR_BITS(DATA_MEM_ADDR_BITS),
				.BLOCK_BITS(DATA_MEM_DATA_BITS * 4),
				.CACHE_LINES(16)
			) dcache_inst(
				.clk(clk),
				.reset(reset),
				.core_read_valid(core_dmem_read_valid[i]),
				.core_read_block_addr(core_dmem_read_addr[i]),
				.core_read_ready(core_dmem_read_ready[i]),
				.core_read_block_data(core_dmem_read_data[i]),
				.core_write_valid(core_dmem_write_valid[i]),
				.core_write_block_addr(core_dmem_write_addr[i]),
				.core_write_block_data(core_dmem_write_data[i]),
				.core_write_strobe(core_dmem_write_strobe[i]),
				.core_write_ready(core_dmem_write_ready[i]),
				.mem_read_valid(dcache_mem_read_valid[i]),
				.mem_read_block_addr(dcache_mem_read_addr[((NUM_CORES - 1) - i) * DATA_MEM_ADDR_BITS+:DATA_MEM_ADDR_BITS]),
				.mem_read_ready(dcache_mem_read_ready[i]),
				.mem_read_block_data(dcache_mem_read_data[((NUM_CORES - 1) - i) * (DATA_MEM_DATA_BITS * 4)+:DATA_MEM_DATA_BITS * 4]),
				.mem_write_valid(dcache_mem_write_valid[i]),
				.mem_write_block_addr(dcache_mem_write_addr[((NUM_CORES - 1) - i) * DATA_MEM_ADDR_BITS+:DATA_MEM_ADDR_BITS]),
				.mem_write_block_data(dcache_mem_write_data[((NUM_CORES - 1) - i) * (DATA_MEM_DATA_BITS * 4)+:DATA_MEM_DATA_BITS * 4]),
				.mem_write_strobe(dcache_mem_write_strobe[((NUM_CORES - 1) - i) * 4+:4]),
				.mem_write_ready(dcache_mem_write_ready[i]),
				.flush_en(flush_caches_global),
				.flush_done(l1_dcache_flush_done[i]),
				.ev_read_acc(dc_ev_r_acc),
				.ev_read_hit(dc_ev_r_hit),
				.ev_read_stall(dc_ev_r_stall),
				.ev_write_acc(dc_ev_w_acc),
				.ev_write_hit(dc_ev_w_hit),
				.ev_write_stall(dc_ev_w_stall)
			);
		end
	endgenerate
endmodule
`default_nettype none
module gpu_axi_wrapper (
	clk,
	reset,
	start,
	done,
	device_control_write_enable,
	device_control_address,
	device_control_data,
	pmu_snap_0,
	pmu_snap_1,
	pmu_snap_2,
	pmu_snap_3,
	m_axi_pmem_araddr,
	m_axi_pmem_arvalid,
	m_axi_pmem_arready,
	m_axi_pmem_arlen,
	m_axi_pmem_arsize,
	m_axi_pmem_arburst,
	m_axi_pmem_rdata,
	m_axi_pmem_rresp,
	m_axi_pmem_rlast,
	m_axi_pmem_rvalid,
	m_axi_pmem_rready,
	m_axi_dmem_awaddr,
	m_axi_dmem_awvalid,
	m_axi_dmem_awready,
	m_axi_dmem_awlen,
	m_axi_dmem_awsize,
	m_axi_dmem_awburst,
	m_axi_dmem_wdata,
	m_axi_dmem_wstrb,
	m_axi_dmem_wvalid,
	m_axi_dmem_wready,
	m_axi_dmem_wlast,
	m_axi_dmem_bresp,
	m_axi_dmem_bvalid,
	m_axi_dmem_bready,
	m_axi_dmem_araddr,
	m_axi_dmem_arvalid,
	m_axi_dmem_arready,
	m_axi_dmem_arlen,
	m_axi_dmem_arsize,
	m_axi_dmem_arburst,
	m_axi_dmem_rdata,
	m_axi_dmem_rresp,
	m_axi_dmem_rlast,
	m_axi_dmem_rvalid,
	m_axi_dmem_rready
);
	parameter DATA_MEM_ADDR_BITS = 32;
	parameter PROGRAM_MEM_ADDR_BITS = 32;
	parameter DATA_BITS = 32;
	parameter AXI_DATA_WIDTH = 128;
	parameter NUM_CORES = 2;
	parameter THREADS_PER_BLOCK = 4;
	parameter NUM_WARPS = 4;
	input wire clk;
	input wire reset;
	input wire start;
	output wire done;
	input wire device_control_write_enable;
	input wire [7:0] device_control_address;
	input wire [7:0] device_control_data;
	output wire [(NUM_CORES * 32) - 1:0] pmu_snap_0;
	output wire [(NUM_CORES * 32) - 1:0] pmu_snap_1;
	output wire [(NUM_CORES * 32) - 1:0] pmu_snap_2;
	output wire [(NUM_CORES * 32) - 1:0] pmu_snap_3;
	output wire [PROGRAM_MEM_ADDR_BITS - 1:0] m_axi_pmem_araddr;
	output wire m_axi_pmem_arvalid;
	input wire m_axi_pmem_arready;
	output wire [7:0] m_axi_pmem_arlen;
	output wire [2:0] m_axi_pmem_arsize;
	output wire [1:0] m_axi_pmem_arburst;
	input wire [AXI_DATA_WIDTH - 1:0] m_axi_pmem_rdata;
	input wire [1:0] m_axi_pmem_rresp;
	input wire m_axi_pmem_rlast;
	input wire m_axi_pmem_rvalid;
	output wire m_axi_pmem_rready;
	output wire [DATA_MEM_ADDR_BITS - 1:0] m_axi_dmem_awaddr;
	output wire m_axi_dmem_awvalid;
	input wire m_axi_dmem_awready;
	output wire [7:0] m_axi_dmem_awlen;
	output wire [2:0] m_axi_dmem_awsize;
	output wire [1:0] m_axi_dmem_awburst;
	output wire [AXI_DATA_WIDTH - 1:0] m_axi_dmem_wdata;
	output wire [(AXI_DATA_WIDTH / 8) - 1:0] m_axi_dmem_wstrb;
	output wire m_axi_dmem_wvalid;
	input wire m_axi_dmem_wready;
	output wire m_axi_dmem_wlast;
	input wire [1:0] m_axi_dmem_bresp;
	input wire m_axi_dmem_bvalid;
	output wire m_axi_dmem_bready;
	output wire [DATA_MEM_ADDR_BITS - 1:0] m_axi_dmem_araddr;
	output wire m_axi_dmem_arvalid;
	input wire m_axi_dmem_arready;
	output wire [7:0] m_axi_dmem_arlen;
	output wire [2:0] m_axi_dmem_arsize;
	output wire [1:0] m_axi_dmem_arburst;
	input wire [AXI_DATA_WIDTH - 1:0] m_axi_dmem_rdata;
	input wire [1:0] m_axi_dmem_rresp;
	input wire m_axi_dmem_rlast;
	input wire m_axi_dmem_rvalid;
	output wire m_axi_dmem_rready;
	wire [0:0] custom_pmem_r_valid;
	wire [0:0] custom_pmem_r_ready;
	wire [PROGRAM_MEM_ADDR_BITS - 1:0] custom_pmem_r_addr;
	wire [AXI_DATA_WIDTH - 1:0] custom_pmem_r_data;
	wire [0:0] custom_dmem_r_valid;
	wire [0:0] custom_dmem_r_ready;
	wire [DATA_MEM_ADDR_BITS - 1:0] custom_dmem_r_addr;
	wire [AXI_DATA_WIDTH - 1:0] custom_dmem_r_data;
	wire [0:0] custom_dmem_w_valid;
	wire [0:0] custom_dmem_w_ready;
	wire [DATA_MEM_ADDR_BITS - 1:0] custom_dmem_w_addr;
	wire [AXI_DATA_WIDTH - 1:0] custom_dmem_w_data;
	wire [3:0] custom_dmem_w_strobe;
	gpu #(
		.DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
		.DATA_MEM_DATA_BITS(DATA_BITS),
		.DATA_MEM_NUM_CHANNELS(1),
		.PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
		.PROGRAM_MEM_DATA_BITS(DATA_BITS),
		.PROGRAM_MEM_NUM_CHANNELS(1),
		.NUM_CORES(NUM_CORES),
		.THREADS_PER_BLOCK(THREADS_PER_BLOCK),
		.NUM_WARPS(NUM_WARPS),
		.DEBUG(0)
	) gpu_inst(
		.clk(clk),
		.reset(reset),
		.start(start),
		.done(done),
		.device_control_write_enable(device_control_write_enable),
		.device_control_address(device_control_address),
		.device_control_data(device_control_data),
		.program_mem_read_valid(custom_pmem_r_valid[0]),
		.program_mem_read_address(custom_pmem_r_addr),
		.program_mem_read_ready(custom_pmem_r_ready[0]),
		.program_mem_read_data(custom_pmem_r_data),
		.data_mem_read_valid(custom_dmem_r_valid[0]),
		.data_mem_read_address(custom_dmem_r_addr),
		.data_mem_read_ready(custom_dmem_r_ready[0]),
		.data_mem_read_data(custom_dmem_r_data),
		.data_mem_write_valid(custom_dmem_w_valid[0]),
		.data_mem_write_address(custom_dmem_w_addr),
		.data_mem_write_data(custom_dmem_w_data),
		.data_mem_write_strobe(custom_dmem_w_strobe),
		.data_mem_write_ready(custom_dmem_w_ready[0]),
		.pmu_snap_0(pmu_snap_0),
		.pmu_snap_1(pmu_snap_1),
		.pmu_snap_2(pmu_snap_2),
		.pmu_snap_3(pmu_snap_3)
	);
	axi4_adapter #(
		.ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
		.DATA_BITS(AXI_DATA_WIDTH),
		.CUSTOM_STROBE_BITS(4)
	) pmem_adapter(
		.clk(clk),
		.reset(reset),
		.custom_read_valid(custom_pmem_r_valid[0]),
		.custom_read_addr(custom_pmem_r_addr[0+:PROGRAM_MEM_ADDR_BITS]),
		.custom_read_ready(custom_pmem_r_ready[0]),
		.custom_read_data(custom_pmem_r_data[0+:AXI_DATA_WIDTH]),
		.custom_write_valid(1'b0),
		.custom_write_addr(32'd0),
		.custom_write_data(128'd0),
		.custom_write_strobe(4'd0),
		.custom_write_ready(),
		.m_axi_awaddr(),
		.m_axi_awvalid(),
		.m_axi_awready(1'b0),
		.m_axi_awlen(),
		.m_axi_awsize(),
		.m_axi_awburst(),
		.m_axi_wdata(),
		.m_axi_wstrb(),
		.m_axi_wvalid(),
		.m_axi_wready(1'b0),
		.m_axi_wlast(),
		.m_axi_bresp(2'b00),
		.m_axi_bvalid(1'b0),
		.m_axi_bready(),
		.m_axi_araddr(m_axi_pmem_araddr),
		.m_axi_arvalid(m_axi_pmem_arvalid),
		.m_axi_arready(m_axi_pmem_arready),
		.m_axi_arlen(m_axi_pmem_arlen),
		.m_axi_arsize(m_axi_pmem_arsize),
		.m_axi_arburst(m_axi_pmem_arburst),
		.m_axi_rdata(m_axi_pmem_rdata),
		.m_axi_rresp(m_axi_pmem_rresp),
		.m_axi_rlast(m_axi_pmem_rlast),
		.m_axi_rvalid(m_axi_pmem_rvalid),
		.m_axi_rready(m_axi_pmem_rready)
	);
	axi4_adapter #(
		.ADDR_BITS(DATA_MEM_ADDR_BITS),
		.DATA_BITS(AXI_DATA_WIDTH),
		.CUSTOM_STROBE_BITS(4)
	) dmem_adapter(
		.clk(clk),
		.reset(reset),
		.custom_read_valid(custom_dmem_r_valid[0]),
		.custom_read_addr(custom_dmem_r_addr[0+:DATA_MEM_ADDR_BITS]),
		.custom_read_ready(custom_dmem_r_ready[0]),
		.custom_read_data(custom_dmem_r_data[0+:AXI_DATA_WIDTH]),
		.custom_write_valid(custom_dmem_w_valid[0]),
		.custom_write_addr(custom_dmem_w_addr[0+:DATA_MEM_ADDR_BITS]),
		.custom_write_data(custom_dmem_w_data[0+:AXI_DATA_WIDTH]),
		.custom_write_strobe(custom_dmem_w_strobe[0+:4]),
		.custom_write_ready(custom_dmem_w_ready[0]),
		.m_axi_awaddr(m_axi_dmem_awaddr),
		.m_axi_awvalid(m_axi_dmem_awvalid),
		.m_axi_awready(m_axi_dmem_awready),
		.m_axi_awlen(m_axi_dmem_awlen),
		.m_axi_awsize(m_axi_dmem_awsize),
		.m_axi_awburst(m_axi_dmem_awburst),
		.m_axi_wdata(m_axi_dmem_wdata),
		.m_axi_wstrb(m_axi_dmem_wstrb),
		.m_axi_wvalid(m_axi_dmem_wvalid),
		.m_axi_wready(m_axi_dmem_wready),
		.m_axi_wlast(m_axi_dmem_wlast),
		.m_axi_bresp(m_axi_dmem_bresp),
		.m_axi_bvalid(m_axi_dmem_bvalid),
		.m_axi_bready(m_axi_dmem_bready),
		.m_axi_araddr(m_axi_dmem_araddr),
		.m_axi_arvalid(m_axi_dmem_arvalid),
		.m_axi_arready(m_axi_dmem_arready),
		.m_axi_arlen(m_axi_dmem_arlen),
		.m_axi_arsize(m_axi_dmem_arsize),
		.m_axi_arburst(m_axi_dmem_arburst),
		.m_axi_rdata(m_axi_dmem_rdata),
		.m_axi_rresp(m_axi_dmem_rresp),
		.m_axi_rlast(m_axi_dmem_rlast),
		.m_axi_rvalid(m_axi_dmem_rvalid),
		.m_axi_rready(m_axi_dmem_rready)
	);
endmodule
`default_nettype none
module icache (
	clk,
	reset,
	core_read_valid,
	core_read_addr,
	core_read_ready,
	core_read_data,
	mem_read_valid,
	mem_read_block_addr,
	mem_read_ready,
	mem_read_block_data,
	ev_access,
	ev_hit,
	ev_stall
);
	parameter ADDR_BITS = 32;
	parameter DATA_BITS = 32;
	parameter BLOCK_BITS = 128;
	parameter CACHE_LINES = 16;
	input wire clk;
	input wire reset;
	input wire core_read_valid;
	input wire [ADDR_BITS - 1:0] core_read_addr;
	output reg core_read_ready;
	output reg [DATA_BITS - 1:0] core_read_data;
	output reg mem_read_valid;
	output reg [ADDR_BITS - 1:0] mem_read_block_addr;
	input wire mem_read_ready;
	input wire [BLOCK_BITS - 1:0] mem_read_block_data;
	output wire ev_access;
	output wire ev_hit;
	output wire ev_stall;
	localparam INDEX_BITS = $clog2(CACHE_LINES);
	localparam TAG_BITS = (ADDR_BITS - 2) - INDEX_BITS;
	reg valid_array [0:CACHE_LINES - 1];
	reg [TAG_BITS - 1:0] tag_array [0:CACHE_LINES - 1];
	reg [BLOCK_BITS - 1:0] data_array [0:CACHE_LINES - 1];
	wire [1:0] word_offset = core_read_addr[1:0];
	wire [INDEX_BITS - 1:0] index = core_read_addr[INDEX_BITS + 1:2];
	wire [TAG_BITS - 1:0] tag = core_read_addr[ADDR_BITS - 1:INDEX_BITS + 2];
	wire hit = valid_array[index] && (tag_array[index] == tag);
	reg state;
	always @(posedge clk)
		if (reset) begin
			state <= 1'd0;
			mem_read_valid <= 0;
			core_read_ready <= 0;
			begin : sv2v_autoblock_1
				reg signed [31:0] i;
				for (i = 0; i < CACHE_LINES; i = i + 1)
					valid_array[i] <= 0;
			end
		end
		else begin
			core_read_ready <= 0;
			case (state)
				1'd0:
					if (core_read_valid && !core_read_ready) begin
						if (hit) begin
								core_read_data <= data_array[index] >> (word_offset * 32);
							core_read_ready <= 1;
						end
						else begin
							mem_read_valid <= 1;
							mem_read_block_addr <= core_read_addr >> 2;
							state <= 1'd1;
						end
					end
				1'd1:
					if (mem_read_ready) begin
						mem_read_valid <= 0;
						valid_array[index] <= 1;
						tag_array[index] <= tag;
						data_array[index] <= mem_read_block_data;
							core_read_data <= mem_read_block_data >> (word_offset * 32);
						core_read_ready <= 1;
						state <= 1'd0;
					end
			endcase
		end
	assign ev_access = (state == 1'd0) && core_read_valid;
	assign ev_hit = ((state == 1'd0) && core_read_valid) && hit;
	assign ev_stall = core_read_valid && !core_read_ready;
endmodule
`default_nettype none
module l2_cache (
	clk,
	reset,
	up_read_valid,
	up_read_addr,
	up_read_ready,
	up_read_data,
	up_write_valid,
	up_write_addr,
	up_write_data,
	up_write_strobe,
	up_write_ready,
	mem_read_valid,
	mem_read_addr,
	mem_read_ready,
	mem_read_data,
	mem_write_valid,
	mem_write_addr,
	mem_write_data,
	mem_write_strobe,
	mem_write_ready,
	flush_en,
	flush_done,
	ev_read_acc,
	ev_read_hit,
	ev_read_miss,
	ev_write_acc,
	ev_write_hit,
	ev_write_miss,
	ev_stall,
	ev_evict
);
	reg _sv2v_0;
	parameter ADDR_BITS = 32;
	parameter BLOCK_BITS = 128;
	parameter CACHE_LINES = 256;
	parameter WAYS = 4;
	parameter SECTORS = 4;
	parameter NUM_PORTS = 2;
	parameter VWB_DEPTH = 8;
	input wire clk;
	input wire reset;
	input wire [NUM_PORTS - 1:0] up_read_valid;
	input wire [(NUM_PORTS * ADDR_BITS) - 1:0] up_read_addr;
	output reg [NUM_PORTS - 1:0] up_read_ready;
	output reg [(NUM_PORTS * BLOCK_BITS) - 1:0] up_read_data;
	input wire [NUM_PORTS - 1:0] up_write_valid;
	input wire [(NUM_PORTS * ADDR_BITS) - 1:0] up_write_addr;
	input wire [(NUM_PORTS * BLOCK_BITS) - 1:0] up_write_data;
	input wire [(NUM_PORTS * SECTORS) - 1:0] up_write_strobe;
	output reg [NUM_PORTS - 1:0] up_write_ready;
	output reg mem_read_valid;
	output reg [ADDR_BITS - 1:0] mem_read_addr;
	input wire mem_read_ready;
	input wire [BLOCK_BITS - 1:0] mem_read_data;
	output wire mem_write_valid;
	output wire [ADDR_BITS - 1:0] mem_write_addr;
	output wire [BLOCK_BITS - 1:0] mem_write_data;
	output wire [SECTORS - 1:0] mem_write_strobe;
	input wire mem_write_ready;
	input wire flush_en;
	output wire flush_done;
	output reg ev_read_acc;
	output reg ev_read_hit;
	output reg ev_read_miss;
	output reg ev_write_acc;
	output reg ev_write_hit;
	output reg ev_write_miss;
	output wire ev_stall;
	output wire ev_evict;
	localparam SETS = CACHE_LINES / WAYS;
	localparam INDEX_BITS = $clog2(SETS);
	localparam TAG_BITS = ADDR_BITS - INDEX_BITS;
	localparam SECTOR_BITS = BLOCK_BITS / SECTORS;
	reg valid_array [0:SETS - 1][0:WAYS - 1];
	reg [SECTORS - 1:0] sector_dirty [0:SETS - 1][0:WAYS - 1];
	reg [TAG_BITS - 1:0] tag_array [0:SETS - 1][0:WAYS - 1];
	reg [BLOCK_BITS - 1:0] data_array [0:SETS - 1][0:WAYS - 1];
	reg [WAYS - 2:0] plru_bits [0:SETS - 1];
	reg [$clog2(NUM_PORTS) - 1:0] active_port;
	reg req_is_write;
	reg [ADDR_BITS - 1:0] req_addr;
	reg [BLOCK_BITS - 1:0] req_data;
	reg [SECTORS - 1:0] req_strobe;
	wire [INDEX_BITS - 1:0] req_index = req_addr[INDEX_BITS - 1:0];
	wire [TAG_BITS - 1:0] req_tag = req_addr[ADDR_BITS - 1:INDEX_BITS];
	reg hit;
	reg [$clog2(WAYS) - 1:0] hit_way;
	reg [$clog2(WAYS) - 1:0] victim_way;
	always @(*) begin
		if (_sv2v_0)
			;
		hit = 0;
		hit_way = 0;
		begin : sv2v_autoblock_1
			reg signed [31:0] w;
			for (w = 0; w < WAYS; w = w + 1)
				if (valid_array[req_index][w] && (tag_array[req_index][w] == req_tag)) begin
					hit = 1;
					hit_way = w[$clog2(WAYS) - 1:0];
				end
		end
		if (!plru_bits[req_index][0])
			victim_way = (!plru_bits[req_index][1] ? 2'd0 : 2'd1);
		else
			victim_way = (!plru_bits[req_index][2] ? 2'd2 : 2'd3);
	end
	reg vwb_push_valid;
	reg [ADDR_BITS - 1:0] vwb_push_addr;
	reg [BLOCK_BITS - 1:0] vwb_push_data;
	reg [SECTORS - 1:0] vwb_push_sector_dirty;
	wire vwb_push_ready;
	wire vwb_empty;
	wire vwb_probe_hit;
	wire [BLOCK_BITS - 1:0] vwb_probe_data;
	wire [SECTORS - 1:0] vwb_probe_sector_valid;
	reg vwb_probe_pop;
	reg [ADDR_BITS - 1:0] vwb_pop_addr;
	victim_write_buffer #(
		.ADDR_BITS(ADDR_BITS),
		.BLOCK_BITS(BLOCK_BITS),
		.SECTORS(SECTORS),
		.DEPTH(VWB_DEPTH)
	) vwb(
		.clk(clk),
		.reset(reset),
		.push_valid(vwb_push_valid),
		.push_addr(vwb_push_addr),
		.push_data(vwb_push_data),
		.push_sector_dirty(vwb_push_sector_dirty),
		.push_ready(vwb_push_ready),
		.probe_valid(!hit),
		.probe_addr(req_addr),
		.probe_hit(vwb_probe_hit),
		.probe_data(vwb_probe_data),
		.probe_sector_valid(vwb_probe_sector_valid),
		.probe_pop(vwb_probe_pop),
		.pop_addr(vwb_pop_addr),
		.mem_write_valid(mem_write_valid),
		.mem_write_addr(mem_write_addr),
		.mem_write_data(mem_write_data),
		.mem_write_strobe(mem_write_strobe),
		.mem_write_ready(mem_write_ready),
		.flush_en(flush_en),
		.empty(vwb_empty),
		.full()
	);
	reg [2:0] state;
	reg [$clog2(NUM_PORTS) - 1:0] arb_ptr;
	reg [INDEX_BITS - 1:0] flush_set;
	reg [$clog2(WAYS) - 1:0] flush_way_iter;
	assign flush_done = (state == 3'd4) && vwb_empty;
	always @(posedge clk)
		if (reset) begin
			state <= 3'd0;
			mem_read_valid <= 0;
			up_read_ready <= 0;
			up_write_ready <= 0;
			arb_ptr <= 0;
			vwb_push_valid <= 0;
			vwb_probe_pop <= 0;
			begin : sv2v_autoblock_2
				reg signed [31:0] s;
				for (s = 0; s < SETS; s = s + 1)
					begin
						plru_bits[s] <= 0;
						begin : sv2v_autoblock_3
							reg signed [31:0] w;
							for (w = 0; w < WAYS; w = w + 1)
								begin
									valid_array[s][w] <= 0;
									sector_dirty[s][w] <= 0;
								end
						end
					end
			end
		end
		else begin
			up_read_ready <= 0;
			up_write_ready <= 0;
			vwb_push_valid <= 0;
			vwb_probe_pop <= 0;
			case (state)
				3'd0:
					if (flush_en) begin
						flush_set <= 0;
						flush_way_iter <= 0;
						state <= 3'd3;
					end
					else begin : sv2v_autoblock_4
						reg found;
						found = 0;
						begin : sv2v_autoblock_5
							reg signed [31:0] p;
							for (p = 0; p < NUM_PORTS; p = p + 1)
								begin : sv2v_autoblock_6
									reg signed [31:0] check_p;
									check_p = (arb_ptr + p) % NUM_PORTS;
									if (!found) begin
										if (up_read_valid[check_p] && !up_read_ready[check_p]) begin
											active_port <= check_p;
											req_is_write <= 0;
											req_addr <= up_read_addr[((NUM_PORTS - 1) - check_p) * ADDR_BITS+:ADDR_BITS];
											found = 1;
											state <= 3'd1;
											arb_ptr <= (check_p + 1) % NUM_PORTS;
										end
										else if (up_write_valid[check_p] && !up_write_ready[check_p]) begin
											active_port <= check_p;
											req_is_write <= 1;
											req_addr <= up_write_addr[((NUM_PORTS - 1) - check_p) * ADDR_BITS+:ADDR_BITS];
											req_data <= up_write_data[((NUM_PORTS - 1) - check_p) * BLOCK_BITS+:BLOCK_BITS];
											req_strobe <= up_write_strobe[((NUM_PORTS - 1) - check_p) * SECTORS+:SECTORS];
											found = 1;
											state <= 3'd1;
											arb_ptr <= (check_p + 1) % NUM_PORTS;
										end
									end
								end
						end
					end
				3'd1:
					if (hit) begin
						if (req_is_write) begin : sv2v_autoblock_7
							reg [BLOCK_BITS - 1:0] next_data;
							reg [SECTORS - 1:0] next_dirty;
							next_data = data_array[req_index][hit_way];
							next_dirty = sector_dirty[req_index][hit_way];
							begin : sv2v_autoblock_8
								reg signed [31:0] sec;
								reg [BLOCK_BITS - 1:0] sector_mask;
								for (sec = 0; sec < SECTORS; sec = sec + 1) begin
									sector_mask = {SECTOR_BITS{1'b1}};
									if (req_strobe[sec]) begin
										next_data = (next_data & ~(sector_mask << (sec * SECTOR_BITS))) | (req_data & (sector_mask << (sec * SECTOR_BITS)));
										next_dirty[sec] = 1'b1;
									end
									end
							end
							data_array[req_index][hit_way] <= next_data;
							sector_dirty[req_index][hit_way] <= next_dirty;
							up_write_ready[active_port] <= 1;
						end
						else begin
							up_read_data[((NUM_PORTS - 1) - active_port) * BLOCK_BITS+:BLOCK_BITS] <= data_array[req_index][hit_way];
							up_read_ready[active_port] <= 1;
						end
						case (hit_way)
							2'd0: begin
								plru_bits[req_index][0] <= 1;
								plru_bits[req_index][1] <= 1;
							end
							2'd1: begin
								plru_bits[req_index][0] <= 1;
								plru_bits[req_index][1] <= 0;
							end
							2'd2: begin
								plru_bits[req_index][0] <= 0;
								plru_bits[req_index][2] <= 1;
							end
							2'd3: begin
								plru_bits[req_index][0] <= 0;
								plru_bits[req_index][2] <= 0;
							end
						endcase
						state <= 3'd0;
					end
					else if (vwb_probe_hit) begin
						if ((valid_array[req_index][victim_way] && |sector_dirty[req_index][victim_way]) && !vwb_push_ready)
							;
						else begin
							if (valid_array[req_index][victim_way] && |sector_dirty[req_index][victim_way]) begin
								vwb_push_valid <= 1;
								vwb_push_addr <= {tag_array[req_index][victim_way], req_index};
								vwb_push_data <= data_array[req_index][victim_way];
								vwb_push_sector_dirty <= sector_dirty[req_index][victim_way];
							end
							vwb_probe_pop <= 1;
							vwb_pop_addr <= req_addr;
							valid_array[req_index][victim_way] <= 1;
							tag_array[req_index][victim_way] <= req_tag;
							if (req_is_write) begin : sv2v_autoblock_9
								reg [BLOCK_BITS - 1:0] merged;
								merged = vwb_probe_data;
								begin : sv2v_autoblock_10
									reg signed [31:0] sec;
									reg [BLOCK_BITS - 1:0] sector_mask;
									for (sec = 0; sec < SECTORS; sec = sec + 1) begin
										sector_mask = {SECTOR_BITS{1'b1}};
										if (req_strobe[sec])
											merged = (merged & ~(sector_mask << (sec * SECTOR_BITS))) | (req_data & (sector_mask << (sec * SECTOR_BITS)));
									end
								end
								data_array[req_index][victim_way] <= merged;
								sector_dirty[req_index][victim_way] <= vwb_probe_sector_valid | req_strobe;
								up_write_ready[active_port] <= 1;
							end
							else begin
								data_array[req_index][victim_way] <= vwb_probe_data;
								sector_dirty[req_index][victim_way] <= vwb_probe_sector_valid;
								up_read_data[((NUM_PORTS - 1) - active_port) * BLOCK_BITS+:BLOCK_BITS] <= vwb_probe_data;
								up_read_ready[active_port] <= 1;
							end
							case (victim_way)
								2'd0: begin
									plru_bits[req_index][0] <= 1;
									plru_bits[req_index][1] <= 1;
								end
								2'd1: begin
									plru_bits[req_index][0] <= 1;
									plru_bits[req_index][1] <= 0;
								end
								2'd2: begin
									plru_bits[req_index][0] <= 0;
									plru_bits[req_index][2] <= 1;
								end
								2'd3: begin
									plru_bits[req_index][0] <= 0;
									plru_bits[req_index][2] <= 0;
								end
							endcase
							state <= 3'd0;
						end
					end
					else if ((valid_array[req_index][victim_way] && |sector_dirty[req_index][victim_way]) && !vwb_push_ready)
						;
					else begin
						if (valid_array[req_index][victim_way] && |sector_dirty[req_index][victim_way]) begin
							vwb_push_valid <= 1;
							vwb_push_addr <= {tag_array[req_index][victim_way], req_index};
							vwb_push_data <= data_array[req_index][victim_way];
							vwb_push_sector_dirty <= sector_dirty[req_index][victim_way];
							sector_dirty[req_index][victim_way] <= 0;
						end
						mem_read_valid <= 1;
						mem_read_addr <= req_addr;
						state <= 3'd2;
					end
				3'd2:
					if (mem_read_ready) begin
						mem_read_valid <= 0;
						valid_array[req_index][victim_way] <= 1;
						tag_array[req_index][victim_way] <= req_tag;
						if (req_is_write) begin : sv2v_autoblock_11
							reg [BLOCK_BITS - 1:0] merged;
							merged = mem_read_data;
							begin : sv2v_autoblock_12
								reg signed [31:0] sec;
								reg [BLOCK_BITS - 1:0] sector_mask;
								for (sec = 0; sec < SECTORS; sec = sec + 1) begin
									sector_mask = {SECTOR_BITS{1'b1}};
									if (req_strobe[sec])
										merged = (merged & ~(sector_mask << (sec * SECTOR_BITS))) | (req_data & (sector_mask << (sec * SECTOR_BITS)));
								end
							end
							data_array[req_index][victim_way] <= merged;
							sector_dirty[req_index][victim_way] <= req_strobe;
							up_write_ready[active_port] <= 1;
						end
						else begin
							data_array[req_index][victim_way] <= mem_read_data;
							sector_dirty[req_index][victim_way] <= 0;
							up_read_data[((NUM_PORTS - 1) - active_port) * BLOCK_BITS+:BLOCK_BITS] <= mem_read_data;
							up_read_ready[active_port] <= 1;
						end
						case (victim_way)
							2'd0: begin
								plru_bits[req_index][0] <= 1;
								plru_bits[req_index][1] <= 1;
							end
							2'd1: begin
								plru_bits[req_index][0] <= 1;
								plru_bits[req_index][1] <= 0;
							end
							2'd2: begin
								plru_bits[req_index][0] <= 0;
								plru_bits[req_index][2] <= 1;
							end
							2'd3: begin
								plru_bits[req_index][0] <= 0;
								plru_bits[req_index][2] <= 0;
							end
						endcase
						state <= 3'd0;
					end
				3'd3:
					if (!flush_en)
						state <= 3'd0;
					else if (valid_array[flush_set][flush_way_iter] && |sector_dirty[flush_set][flush_way_iter]) begin
						if (vwb_push_ready) begin
							vwb_push_valid <= 1;
							vwb_push_addr <= {tag_array[flush_set][flush_way_iter], flush_set};
							vwb_push_data <= data_array[flush_set][flush_way_iter];
							vwb_push_sector_dirty <= sector_dirty[flush_set][flush_way_iter];
							sector_dirty[flush_set][flush_way_iter] <= 0;
							if (flush_way_iter == (WAYS - 1)) begin
								if (flush_set == (SETS - 1))
									state <= 3'd4;
								else begin
									flush_set <= flush_set + 1;
									flush_way_iter <= 0;
								end
							end
							else
								flush_way_iter <= flush_way_iter + 1;
						end
					end
					else if (flush_way_iter == (WAYS - 1)) begin
						if (flush_set == (SETS - 1))
							state <= 3'd4;
						else begin
							flush_set <= flush_set + 1;
							flush_way_iter <= 0;
						end
					end
					else
						flush_way_iter <= flush_way_iter + 1;
				3'd4:
					if (vwb_empty && !flush_en)
						state <= 3'd0;
			endcase
		end
	initial _sv2v_0 = 0;
endmodule
`default_nettype none
module lsu (
	clk,
	reset,
	enable_mask,
	warp_id,
	decoded_mem_read_enable,
	decoded_mem_write_enable,
	decoded_shared_read_enable,
	decoded_shared_write_enable,
	decoded_atomic,
	decoded_rd,
	rs,
	rt,
	rd_val,
	addr_offset,
	use_offset,
	mem_read_valid,
	mem_read_block_address,
	mem_read_ready,
	mem_read_block_data,
	mem_write_valid,
	mem_write_block_address,
	mem_write_block_data,
	mem_write_strobe,
	mem_write_ready,
	shared_mem_read_valid,
	shared_mem_read_address,
	shared_mem_read_ready,
	shared_mem_read_data,
	shared_mem_write_valid,
	shared_mem_write_address,
	shared_mem_write_data,
	shared_mem_write_ready,
	lsu_we,
	lsu_warp_id,
	lsu_rd,
	lsu_data,
	done_pulse,
	done_warp_id
);
	parameter DATA_BITS = 32;
	parameter NUM_WARPS = 4;
	parameter THREADS_PER_BLOCK = 4;
	parameter WORDS_PER_BLOCK = 4;
	parameter ADDR_BITS = 32;
	parameter DEBUG = 1;
	input wire clk;
	input wire reset;
	input wire [THREADS_PER_BLOCK - 1:0] enable_mask;
	input wire [$clog2(NUM_WARPS) - 1:0] warp_id;
	input wire decoded_mem_read_enable;
	input wire decoded_mem_write_enable;
	input wire decoded_shared_read_enable;
	input wire decoded_shared_write_enable;
	input wire [1:0] decoded_atomic;
	input wire [4:0] decoded_rd;
	input wire [(THREADS_PER_BLOCK * DATA_BITS) - 1:0] rs;
	input wire [(THREADS_PER_BLOCK * DATA_BITS) - 1:0] rt;
	input wire [(THREADS_PER_BLOCK * DATA_BITS) - 1:0] rd_val;
	input wire [15:0] addr_offset;
	input wire use_offset;
	output reg mem_read_valid;
	output reg [ADDR_BITS - 1:0] mem_read_block_address;
	input wire mem_read_ready;
	input wire [(DATA_BITS * WORDS_PER_BLOCK) - 1:0] mem_read_block_data;
	output reg mem_write_valid;
	output reg [ADDR_BITS - 1:0] mem_write_block_address;
	output reg [(DATA_BITS * WORDS_PER_BLOCK) - 1:0] mem_write_block_data;
	output reg [WORDS_PER_BLOCK - 1:0] mem_write_strobe;
	input wire mem_write_ready;
	output reg [THREADS_PER_BLOCK - 1:0] shared_mem_read_valid;
	output reg [(THREADS_PER_BLOCK * ADDR_BITS) - 1:0] shared_mem_read_address;
	input wire [THREADS_PER_BLOCK - 1:0] shared_mem_read_ready;
	input wire [(THREADS_PER_BLOCK * DATA_BITS) - 1:0] shared_mem_read_data;
	output reg [THREADS_PER_BLOCK - 1:0] shared_mem_write_valid;
	output reg [(THREADS_PER_BLOCK * ADDR_BITS) - 1:0] shared_mem_write_address;
	output reg [(THREADS_PER_BLOCK * DATA_BITS) - 1:0] shared_mem_write_data;
	input wire [THREADS_PER_BLOCK - 1:0] shared_mem_write_ready;
	output reg [THREADS_PER_BLOCK - 1:0] lsu_we;
	output reg [$clog2(NUM_WARPS) - 1:0] lsu_warp_id;
	output reg [4:0] lsu_rd;
	output reg [(THREADS_PER_BLOCK * DATA_BITS) - 1:0] lsu_data;
	output reg [THREADS_PER_BLOCK - 1:0] done_pulse;
	output reg [(THREADS_PER_BLOCK * $clog2(NUM_WARPS)) - 1:0] done_warp_id;
	reg req_valid [0:NUM_WARPS - 1];
	reg [2:0] req_type [0:NUM_WARPS - 1];
	reg [1:0] req_atomic_op [0:NUM_WARPS - 1];
	reg [THREADS_PER_BLOCK - 1:0] req_mask [0:NUM_WARPS - 1];
	reg [ADDR_BITS - 1:0] req_addr [0:NUM_WARPS - 1][0:THREADS_PER_BLOCK - 1];
	reg [DATA_BITS - 1:0] req_data_val [0:NUM_WARPS - 1][0:THREADS_PER_BLOCK - 1];
	reg [DATA_BITS - 1:0] req_exp_val [0:NUM_WARPS - 1][0:THREADS_PER_BLOCK - 1];
	reg [4:0] req_rd [0:NUM_WARPS - 1];
	wire [ADDR_BITS - 1:0] incoming_effective_addr [0:THREADS_PER_BLOCK - 1];
	genvar _gv_i_3;
	generate
		for (_gv_i_3 = 0; _gv_i_3 < THREADS_PER_BLOCK; _gv_i_3 = _gv_i_3 + 1) begin : genblk1
			localparam i = _gv_i_3;
			assign incoming_effective_addr[i] = (use_offset ? rs[((THREADS_PER_BLOCK - 1) - i) * DATA_BITS+:DATA_BITS] + {{ADDR_BITS - 16 {addr_offset[15]}}, addr_offset} : rs[((THREADS_PER_BLOCK - 1) - i) * DATA_BITS+:DATA_BITS]);
		end
	endgenerate
	reg [3:0] state;
	reg [$clog2(NUM_WARPS) - 1:0] active_warp;
	reg [THREADS_PER_BLOCK - 1:0] pending_threads;
	reg [ADDR_BITS - 1:0] current_block_addr;
	reg [2:0] active_t;
	wire [ADDR_BITS - 1:0] active_block_addr [0:THREADS_PER_BLOCK - 1];
	wire [1:0] active_word_offset [0:THREADS_PER_BLOCK - 1];
	generate
		for (_gv_i_3 = 0; _gv_i_3 < THREADS_PER_BLOCK; _gv_i_3 = _gv_i_3 + 1) begin : genblk2
			localparam i = _gv_i_3;
			assign active_block_addr[i] = req_addr[active_warp][i] >> $clog2(WORDS_PER_BLOCK);
			assign active_word_offset[i] = req_addr[active_warp][i] & (WORDS_PER_BLOCK - 1);
		end
	endgenerate
	integer w;
	integer t;
	always @(posedge clk) begin : lsu_fsm
		reg signed [31:0] selected_w;
		reg signed [31:0] first_pending;
		if (reset) begin
			state <= 4'd0;
			mem_read_valid <= 0;
			mem_write_valid <= 0;
			shared_mem_read_valid <= 0;
			shared_mem_write_valid <= 0;
			lsu_we <= 0;
			done_pulse <= 0;
			for (w = 0; w < NUM_WARPS; w = w + 1)
				req_valid[w] <= 0;
		end
		else begin
			lsu_we <= 0;
			done_pulse <= 0;
			if (|enable_mask && ((((decoded_mem_read_enable || decoded_mem_write_enable) || decoded_shared_read_enable) || decoded_shared_write_enable) || |decoded_atomic)) begin
				req_valid[warp_id] <= 1;
				req_mask[warp_id] <= enable_mask;
				req_rd[warp_id] <= decoded_rd;
				req_atomic_op[warp_id] <= decoded_atomic;
				for (t = 0; t < THREADS_PER_BLOCK; t = t + 1)
					begin
						req_addr[warp_id][t] <= incoming_effective_addr[t];
						req_data_val[warp_id][t] <= rt[((THREADS_PER_BLOCK - 1) - t) * DATA_BITS+:DATA_BITS];
						req_exp_val[warp_id][t] <= rd_val[((THREADS_PER_BLOCK - 1) - t) * DATA_BITS+:DATA_BITS];
					end
				if (|decoded_atomic)
					req_type[warp_id] <= 3'd4;
				else if (decoded_mem_read_enable)
					req_type[warp_id] <= 3'd0;
				else if (decoded_mem_write_enable)
					req_type[warp_id] <= 3'd1;
				else if (decoded_shared_read_enable)
					req_type[warp_id] <= 3'd2;
				else
					req_type[warp_id] <= 3'd3;
			end
			case (state)
				4'd0: begin
					selected_w = -1;
					for (w = 0; w < NUM_WARPS; w = w + 1)
						if ((selected_w == -1) && req_valid[w])
							selected_w = w;
					if (selected_w != -1) begin
						active_warp <= selected_w;
						pending_threads <= req_mask[selected_w];
						lsu_warp_id <= selected_w;
						lsu_rd <= req_rd[selected_w];
						if (req_type[selected_w] == 3'd0)
							state <= 4'd1;
						else if (req_type[selected_w] == 3'd1)
							state <= 4'd3;
						else if (req_type[selected_w] == 3'd4)
							state <= 4'd6;
						else begin
							for (t = 0; t < THREADS_PER_BLOCK; t = t + 1)
								if (req_mask[selected_w][t]) begin
									if (req_type[selected_w] == 3'd2) begin
										shared_mem_read_valid[t] <= 1;
										shared_mem_read_address[((THREADS_PER_BLOCK - 1) - t) * ADDR_BITS+:ADDR_BITS] <= req_addr[selected_w][t];
									end
									else begin
										shared_mem_write_valid[t] <= 1;
										shared_mem_write_address[((THREADS_PER_BLOCK - 1) - t) * ADDR_BITS+:ADDR_BITS] <= req_addr[selected_w][t];
										shared_mem_write_data[((THREADS_PER_BLOCK - 1) - t) * DATA_BITS+:DATA_BITS] <= req_data_val[selected_w][t];
									end
								end
							state <= 4'd5;
						end
					end
				end
				4'd1:
					if (|pending_threads) begin
						first_pending = -1;
						for (t = 0; t < THREADS_PER_BLOCK; t = t + 1)
							if ((first_pending == -1) && pending_threads[t])
								first_pending = t;
						current_block_addr <= active_block_addr[first_pending];
						mem_read_block_address <= active_block_addr[first_pending];
						mem_read_valid <= 1;
						state <= 4'd2;
					end
					else begin
						req_valid[active_warp] <= 0;
						state <= 4'd0;
					end
				4'd2:
					if (mem_read_ready) begin
						mem_read_valid <= 0;
						for (t = 0; t < THREADS_PER_BLOCK; t = t + 1)
							if (pending_threads[t] && (active_block_addr[t] == current_block_addr)) begin
								pending_threads[t] <= 0;
								lsu_we[t] <= 1;
								lsu_data[((THREADS_PER_BLOCK - 1) - t) * DATA_BITS+:DATA_BITS] <= mem_read_block_data >> (active_word_offset[t] * DATA_BITS);
								done_pulse[t] <= 1;
								done_warp_id[((THREADS_PER_BLOCK - 1) - t) * $clog2(NUM_WARPS)+:$clog2(NUM_WARPS)] <= lsu_warp_id;
							end
						state <= 4'd1;
					end
				4'd3:
					if (|pending_threads) begin
						first_pending = -1;
						for (t = 0; t < THREADS_PER_BLOCK; t = t + 1)
							if ((first_pending == -1) && pending_threads[t])
								first_pending = t;
						current_block_addr <= active_block_addr[first_pending];
						mem_write_block_address <= active_block_addr[first_pending];
						begin : coalesce_wr
							reg [(DATA_BITS * WORDS_PER_BLOCK) - 1:0] next_wd;
							reg [WORDS_PER_BLOCK - 1:0] next_strobe;
							reg [(DATA_BITS * WORDS_PER_BLOCK) - 1:0] padded_val;
							next_wd = 0;
							next_strobe = 0;
							for (t = 0; t < THREADS_PER_BLOCK; t = t + 1)
								if (pending_threads[t] && (active_block_addr[t] == active_block_addr[first_pending])) begin
									padded_val = req_data_val[active_warp][t];
									next_wd = next_wd | (padded_val << (active_word_offset[t] * DATA_BITS));
									next_strobe = next_strobe | (1'b1 << active_word_offset[t]);
								end
							mem_write_block_data <= next_wd;
							mem_write_strobe <= next_strobe;
						end
						mem_write_valid <= 1;
						state <= 4'd4;
					end
					else begin
						req_valid[active_warp] <= 0;
						state <= 4'd0;
					end
				4'd4:
					if (mem_write_ready) begin
						mem_write_valid <= 0;
						for (t = 0; t < THREADS_PER_BLOCK; t = t + 1)
							if (pending_threads[t] && (active_block_addr[t] == current_block_addr)) begin
								pending_threads[t] <= 0;
								done_pulse[t] <= 1;
								done_warp_id[((THREADS_PER_BLOCK - 1) - t) * $clog2(NUM_WARPS)+:$clog2(NUM_WARPS)] <= lsu_warp_id;
							end
						state <= 4'd3;
					end
				4'd6:
					if (|pending_threads) begin
						first_pending = -1;
						for (t = 0; t < THREADS_PER_BLOCK; t = t + 1)
							if ((first_pending == -1) && pending_threads[t])
								first_pending = t;
						active_t <= first_pending;
						current_block_addr <= active_block_addr[first_pending];
						mem_read_block_address <= active_block_addr[first_pending];
						mem_read_valid <= 1;
						state <= 4'd7;
					end
					else begin
						req_valid[active_warp] <= 0;
						state <= 4'd0;
					end
				4'd7:
					if (mem_read_ready) begin
						mem_read_valid <= 0;
						begin : atomic_math
							reg [DATA_BITS - 1:0] old_val;
							reg [DATA_BITS - 1:0] sum;
							old_val = (mem_read_block_data >> (active_word_offset[active_t] * DATA_BITS)) & 32'hffffffff;
							if (req_atomic_op[active_warp] == 2'b10) begin
								if (old_val == req_exp_val[active_warp][active_t])
									sum = req_data_val[active_warp][active_t];
								else
									sum = old_val;
							end
							else
								sum = old_val + req_data_val[active_warp][active_t];
							lsu_data[((THREADS_PER_BLOCK - 1) - active_t) * DATA_BITS+:DATA_BITS] <= old_val;
							mem_write_block_address <= current_block_addr;
							mem_write_strobe <= 4'b0001 << active_word_offset[active_t];
							mem_write_block_data <= {96'd0, sum} << (active_word_offset[active_t] * DATA_BITS);
						end
						mem_write_valid <= 1;
						state <= 4'd8;
					end
				4'd8:
					if (mem_write_ready) begin
						mem_write_valid <= 0;
						pending_threads <= pending_threads & ~(1 << active_t);
						lsu_we[active_t] <= 1;
						done_pulse[active_t] <= 1;
						done_warp_id[((THREADS_PER_BLOCK - 1) - active_t) * $clog2(NUM_WARPS)+:$clog2(NUM_WARPS)] <= lsu_warp_id;
						state <= 4'd6;
					end
				4'd5: begin
					for (t = 0; t < THREADS_PER_BLOCK; t = t + 1)
						if (pending_threads[t]) begin
							if (shared_mem_read_ready[t]) begin
								lsu_we[t] <= 1;
								lsu_data[((THREADS_PER_BLOCK - 1) - t) * DATA_BITS+:DATA_BITS] <= shared_mem_read_data[((THREADS_PER_BLOCK - 1) - t) * DATA_BITS+:DATA_BITS];
								pending_threads[t] <= 0;
								shared_mem_read_valid[t] <= 0;
								done_pulse[t] <= 1;
								done_warp_id[((THREADS_PER_BLOCK - 1) - t) * $clog2(NUM_WARPS)+:$clog2(NUM_WARPS)] <= lsu_warp_id;
							end
							else if (shared_mem_write_ready[t]) begin
								pending_threads[t] <= 0;
								shared_mem_write_valid[t] <= 0;
								done_pulse[t] <= 1;
								done_warp_id[((THREADS_PER_BLOCK - 1) - t) * $clog2(NUM_WARPS)+:$clog2(NUM_WARPS)] <= lsu_warp_id;
							end
						end
					if (pending_threads == 0) begin
						req_valid[active_warp] <= 0;
						state <= 4'd0;
					end
				end
			endcase
		end
	end
endmodule
`default_nettype none
module pc (
	clk,
	reset,
	enable,
	warp_id,
	decoded_nzp,
	decoded_immediate,
	decoded_nzp_write_enable,
	decoded_pc_mux,
	decoded_call,
	decoded_ret_fn,
	alu_out,
	current_pc,
	next_pc
);
	parameter DATA_MEM_DATA_BITS = 16;
	parameter PROGRAM_MEM_ADDR_BITS = 32;
	parameter NUM_WARPS = 4;
	parameter DEBUG = 0;
	input wire clk;
	input wire reset;
	input wire enable;
	input wire [$clog2(NUM_WARPS) - 1:0] warp_id;
	input wire [2:0] decoded_nzp;
	input wire [DATA_MEM_DATA_BITS - 1:0] decoded_immediate;
	input wire decoded_nzp_write_enable;
	input wire decoded_pc_mux;
	input wire decoded_call;
	input wire decoded_ret_fn;
	input wire [DATA_MEM_DATA_BITS - 1:0] alu_out;
	input wire [PROGRAM_MEM_ADDR_BITS - 1:0] current_pc;
	output reg [PROGRAM_MEM_ADDR_BITS - 1:0] next_pc;
	reg [2:0] nzp [0:NUM_WARPS - 1];
	localparam STACK_DEPTH = 8;
	reg [PROGRAM_MEM_ADDR_BITS - 1:0] return_stack [0:NUM_WARPS - 1][0:7];
	reg [2:0] stack_ptr [0:NUM_WARPS - 1];
	always @(*)
		if (!enable)
			next_pc = current_pc;
		else if (decoded_call)
			next_pc = decoded_immediate[PROGRAM_MEM_ADDR_BITS - 1:0];
		else if (decoded_ret_fn)
			next_pc = return_stack[warp_id][stack_ptr[warp_id] - 1];
		else if (decoded_pc_mux && ((nzp[warp_id] & decoded_nzp) != 3'b000))
			next_pc = decoded_immediate[PROGRAM_MEM_ADDR_BITS - 1:0];
		else
			next_pc = current_pc + 1;
	integer i;
	always @(posedge clk)
		if (reset)
			for (i = 0; i < NUM_WARPS; i = i + 1)
				begin
					nzp[i] <= 3'b000;
					stack_ptr[i] <= 0;
				end
		else if (enable) begin
			if (decoded_nzp_write_enable) begin
				nzp[warp_id] <= alu_out[2:0];
				if (DEBUG)
					$display("[%0t] [PC] Warp %0d NZP <- %b", $time, warp_id, alu_out[2:0]);
			end
			if (decoded_call) begin
				return_stack[warp_id][stack_ptr[warp_id]] <= current_pc + 1;
				stack_ptr[warp_id] <= stack_ptr[warp_id] + 1;
				if (DEBUG)
					$display("[%0t] [PC] Warp %0d CALL: storing ret addr %0d (sp=%0d -> %0d)", $time, warp_id, current_pc + 1, stack_ptr[warp_id], stack_ptr[warp_id] + 1);
			end
			if (decoded_ret_fn) begin
				stack_ptr[warp_id] <= stack_ptr[warp_id] - 1;
				if (DEBUG)
					$display("[%0t] [PC] Warp %0d RET: popping, sp %0d -> %0d, ret to %0d", $time, warp_id, stack_ptr[warp_id], stack_ptr[warp_id] - 1, return_stack[warp_id][stack_ptr[warp_id] - 1]);
			end
			if (decoded_pc_mux && !decoded_call) begin
				if (DEBUG)
					$display("[%0t] [PC] Warp %0d BR: NZP=%b Cond=%b %s", $time, warp_id, nzp[warp_id], decoded_nzp, ((nzp[warp_id] & decoded_nzp) != 3'b000 ? "TAKEN" : "FALLTHROUGH"));
			end
		end
endmodule
`default_nettype none
module registers (
	clk,
	reset,
	enable,
	warp_id,
	read_warp_id,
	block_id,
	thread_id,
	decoded_rd_address,
	read_rd_address,
	decoded_rs_address,
	decoded_rt_address,
	decoded_reg_write_enable,
	decoded_reg_input_mux,
	decoded_immediate,
	alu_out,
	lsu_out,
	lsu_we,
	lsu_warp_id,
	lsu_rd,
	lsu_data,
	rs,
	rt,
	rd_val
);
	parameter THREADS_PER_BLOCK = 4;
	parameter NUM_WARPS = 4;
	parameter DATA_BITS = 32;
	input wire clk;
	input wire reset;
	input wire enable;
	input wire [$clog2(NUM_WARPS) - 1:0] warp_id;
	input wire [$clog2(NUM_WARPS) - 1:0] read_warp_id;
	input wire [7:0] block_id;
	input wire [7:0] thread_id;
	input wire [4:0] decoded_rd_address;
	input wire [4:0] read_rd_address;
	input wire [4:0] decoded_rs_address;
	input wire [4:0] decoded_rt_address;
	input wire decoded_reg_write_enable;
	input wire [1:0] decoded_reg_input_mux;
	input wire [DATA_BITS - 1:0] decoded_immediate;
	input wire [DATA_BITS - 1:0] alu_out;
	input wire [DATA_BITS - 1:0] lsu_out;
	input wire lsu_we;
	input wire [$clog2(NUM_WARPS) - 1:0] lsu_warp_id;
	input wire [4:0] lsu_rd;
	input wire [DATA_BITS - 1:0] lsu_data;
	output wire [DATA_BITS - 1:0] rs;
	output wire [DATA_BITS - 1:0] rt;
	output wire [DATA_BITS - 1:0] rd_val;
	localparam ARITHMETIC = 2'b00;
	localparam MEMORY = 2'b01;
	localparam CONSTANT = 2'b10;
	localparam SHARED = 2'b11;
	reg [DATA_BITS - 1:0] registers [0:NUM_WARPS - 1][0:31];
	wire [DATA_BITS - 1:0] write_data = (decoded_reg_input_mux == ARITHMETIC ? alu_out : (decoded_reg_input_mux == MEMORY ? lsu_out : (decoded_reg_input_mux == CONSTANT ? decoded_immediate : lsu_out)));
	wire is_writing = (enable && decoded_reg_write_enable) && (decoded_rd_address < 29);
	wire is_lsu_writing = lsu_we && (lsu_rd < 29);
	assign rs = ((is_writing && (decoded_rs_address == decoded_rd_address)) && (read_warp_id == warp_id) ? write_data : ((is_lsu_writing && (decoded_rs_address == lsu_rd)) && (read_warp_id == lsu_warp_id) ? lsu_data : registers[read_warp_id][decoded_rs_address]));
	assign rt = ((is_writing && (decoded_rt_address == decoded_rd_address)) && (read_warp_id == warp_id) ? write_data : ((is_lsu_writing && (decoded_rt_address == lsu_rd)) && (read_warp_id == lsu_warp_id) ? lsu_data : registers[read_warp_id][decoded_rt_address]));
	assign rd_val = ((is_writing && (read_rd_address == decoded_rd_address)) && (read_warp_id == warp_id) ? write_data : ((is_lsu_writing && (read_rd_address == lsu_rd)) && (read_warp_id == lsu_warp_id) ? lsu_data : registers[read_warp_id][read_rd_address]));
	integer w;
	integer i;
	always @(posedge clk)
		if (reset)
			for (w = 0; w < NUM_WARPS; w = w + 1)
				begin
					for (i = 0; i < 29; i = i + 1)
						registers[w][i] <= 0;
					registers[w][29] <= 0;
					registers[w][30] <= THREADS_PER_BLOCK * NUM_WARPS;
					registers[w][31] <= (w * THREADS_PER_BLOCK) + thread_id;
				end
		else begin
			for (w = 0; w < NUM_WARPS; w = w + 1)
				registers[w][29] <= {{DATA_BITS - 8 {1'b0}}, block_id};
			if (lsu_we && (lsu_rd < 29))
				registers[lsu_warp_id][lsu_rd] <= lsu_data;
			if (is_writing)
				registers[warp_id][decoded_rd_address] <= write_data;
		end
endmodule
`default_nettype none
module scheduler (
	clk,
	reset,
	start,
	thread_count,
	mem_req_valid,
	mem_warp_id,
	mem_pc,
	warp_mem_ready,
	mem_in_progress,
	frontend_stall,
	flush_warp_mask,
	if_pc,
	sched_active_mask,
	sched_warp_id,
	valid_issue,
	ex_valid,
	ex_warp_id,
	ex_active_mask,
	ex_pc,
	ex_next_pc,
	ex_exit,
	ex_sync,
	ex_exception_valid,
	done,
	ev_scheduler_idle,
	ev_warp_switch,
	ev_diverge,
	ev_stall_mem,
	ev_stall_barrier,
	ev_stall_noready
);
	reg _sv2v_0;
	parameter THREADS_PER_BLOCK = 4;
	parameter NUM_WARPS = 4;
	parameter PROGRAM_MEM_ADDR_BITS = 32;
	input wire clk;
	input wire reset;
	input wire start;
	input wire [$clog2(NUM_WARPS * THREADS_PER_BLOCK):0] thread_count;
	input wire mem_req_valid;
	input wire [$clog2(NUM_WARPS) - 1:0] mem_warp_id;
	input wire [PROGRAM_MEM_ADDR_BITS - 1:0] mem_pc;
	input wire [NUM_WARPS - 1:0] warp_mem_ready;
	input wire [NUM_WARPS - 1:0] mem_in_progress;
	input wire frontend_stall;
	output reg [NUM_WARPS - 1:0] flush_warp_mask;
	output reg [PROGRAM_MEM_ADDR_BITS - 1:0] if_pc;
	output reg [THREADS_PER_BLOCK - 1:0] sched_active_mask;
	output reg [$clog2(NUM_WARPS) - 1:0] sched_warp_id;
	output reg valid_issue;
	input wire ex_valid;
	input wire [$clog2(NUM_WARPS) - 1:0] ex_warp_id;
	input wire [THREADS_PER_BLOCK - 1:0] ex_active_mask;
	input wire [PROGRAM_MEM_ADDR_BITS - 1:0] ex_pc;
	input wire [(THREADS_PER_BLOCK * PROGRAM_MEM_ADDR_BITS) - 1:0] ex_next_pc;
	input wire ex_exit;
	input wire ex_sync;
	input wire ex_exception_valid;
	output reg done;
	output wire ev_scheduler_idle;
	output wire ev_warp_switch;
	output wire ev_diverge;
	output wire ev_stall_mem;
	output wire ev_stall_barrier;
	output wire ev_stall_noready;
	reg [2:0] warp_state [0:NUM_WARPS - 1];
	localparam STACK_DEPTH = 4;
	reg [PROGRAM_MEM_ADDR_BITS - 1:0] current_pc [0:NUM_WARPS - 1];
	reg [THREADS_PER_BLOCK - 1:0] current_mask [0:NUM_WARPS - 1];
	reg [PROGRAM_MEM_ADDR_BITS - 1:0] stack_pc [0:NUM_WARPS - 1][0:3];
	reg [THREADS_PER_BLOCK - 1:0] stack_mask [0:NUM_WARPS - 1][0:3];
	reg [2:0] stack_ptr [0:NUM_WARPS - 1];
	reg [$clog2(NUM_WARPS) - 1:0] rr_ptr;
	reg [$clog2(NUM_WARPS + 1):0] barrier_count;
	reg [$clog2(NUM_WARPS + 1):0] num_active_warps_comb;
	reg all_warps_done;
	reg [NUM_WARPS - 1:0] warp_flush_inhibit;
	reg ex_is_branch;
	reg ex_has_divergence;
	always @(*) begin : sv2v_autoblock_1
		reg [PROGRAM_MEM_ADDR_BITS - 1:0] comb_target_a;
		reg comb_target_a_valid;
		if (_sv2v_0)
			;
		ex_is_branch = 1'b0;
		ex_has_divergence = 1'b0;
		comb_target_a_valid = 1'b0;
		warp_flush_inhibit = 1'sb0;
		num_active_warps_comb = 0;
		begin : sv2v_autoblock_2
			reg signed [31:0] i;
			for (i = 0; i < NUM_WARPS; i = i + 1)
				if (((warp_state[i] != 3'd0) && (warp_state[i] != 3'd4)) && (warp_state[i] != 3'd5))
					num_active_warps_comb = num_active_warps_comb + 1;
		end
		if (ex_valid && (ex_active_mask != 0)) begin : sv2v_autoblock_3
			reg signed [31:0] t;
			for (t = 0; t < THREADS_PER_BLOCK; t = t + 1)
				if (ex_active_mask[t]) begin
					if (!ex_exit) begin
						if (!comb_target_a_valid) begin
							comb_target_a = ex_next_pc[((THREADS_PER_BLOCK - 1) - t) * PROGRAM_MEM_ADDR_BITS+:PROGRAM_MEM_ADDR_BITS];
							comb_target_a_valid = 1'b1;
						end
						else if (ex_next_pc[((THREADS_PER_BLOCK - 1) - t) * PROGRAM_MEM_ADDR_BITS+:PROGRAM_MEM_ADDR_BITS] != comb_target_a)
							ex_has_divergence = 1;
						if (ex_next_pc[((THREADS_PER_BLOCK - 1) - t) * PROGRAM_MEM_ADDR_BITS+:PROGRAM_MEM_ADDR_BITS] != (ex_pc + 1))
							ex_is_branch = 1;
					end
				end
		end
		if (((ex_valid && (ex_active_mask != 0)) && !(mem_req_valid && (mem_warp_id == ex_warp_id))) && (warp_state[ex_warp_id] != 3'd2)) begin
			if ((((ex_exception_valid || ex_exit) || ex_has_divergence) || ex_is_branch) || ex_sync)
				warp_flush_inhibit[ex_warp_id] = 1'b1;
		end
		if (mem_req_valid && (warp_state[mem_warp_id] != 3'd2))
			warp_flush_inhibit[mem_warp_id] = 1'b1;
	end
	integer w;
	integer t;
	always @(posedge clk) begin : sched_seq
		reg signed [31:0] threads_for_this_warp;
		reg found_var;
		reg [$clog2(NUM_WARPS) - 1:0] next_rr_var;
		reg [$clog2(NUM_WARPS) - 1:0] check_w_var;
		if (reset) begin
			done <= 0;
			valid_issue <= 0;
			flush_warp_mask <= 0;
			rr_ptr <= 0;
			if_pc <= 0;
			sched_active_mask <= 0;
			sched_warp_id <= 0;
			barrier_count <= 0;
			for (w = 0; w < NUM_WARPS; w = w + 1)
				begin
					warp_state[w] <= 3'd0;
					current_pc[w] <= 0;
					current_mask[w] <= 0;
					stack_ptr[w] <= 0;
				end
		end
		else begin
			valid_issue <= 0;
			flush_warp_mask <= 0;
			if ((start && (warp_state[0] == 3'd0)) && !done)
				for (w = 0; w < NUM_WARPS; w = w + 1)
					begin
						threads_for_this_warp = thread_count - (w * THREADS_PER_BLOCK);
						if (threads_for_this_warp > THREADS_PER_BLOCK)
							threads_for_this_warp = THREADS_PER_BLOCK;
						if (threads_for_this_warp > 0) begin
							warp_state[w] <= 3'd1;
							current_pc[w] <= 0;
							stack_ptr[w] <= 0;
							current_mask[w] <= (1 << threads_for_this_warp) - 1;
						end
						else begin
							warp_state[w] <= 3'd4;
							current_mask[w] <= 0;
						end
					end
			for (w = 0; w < NUM_WARPS; w = w + 1)
				if ((warp_state[w] == 3'd2) && warp_mem_ready[w])
					warp_state[w] <= 3'd1;
			if (mem_req_valid && (warp_state[mem_warp_id] != 3'd2)) begin
				warp_state[mem_warp_id] <= 3'd2;
				flush_warp_mask[mem_warp_id] <= 1'b1;
				current_pc[mem_warp_id] <= mem_pc + 1;
			end
			if (((ex_valid && (ex_active_mask != 0)) && !(mem_req_valid && (mem_warp_id == ex_warp_id))) && (warp_state[ex_warp_id] != 3'd2)) begin
				if (ex_exception_valid) begin
					warp_state[ex_warp_id] <= 3'd5;
					flush_warp_mask[ex_warp_id] <= 1'b1;
				end
				else begin : sv2v_autoblock_4
					reg [PROGRAM_MEM_ADDR_BITS - 1:0] target_a;
					reg [PROGRAM_MEM_ADDR_BITS - 1:0] target_b;
					reg [THREADS_PER_BLOCK - 1:0] mask_a;
					reg [THREADS_PER_BLOCK - 1:0] mask_b;
					reg is_divergent;
					reg is_branch;
					reg is_reconverge;
					reg target_a_valid;
					reg target_b_valid;
					target_a_valid = 1'b0;
					target_b_valid = 1'b0;
					mask_a = 0;
					mask_b = 0;
					is_divergent = 0;
					is_branch = 0;
					for (t = 0; t < THREADS_PER_BLOCK; t = t + 1)
						if (ex_active_mask[t]) begin
							if (!ex_exit) begin
								if (!target_a_valid) begin
									target_a = ex_next_pc[((THREADS_PER_BLOCK - 1) - t) * PROGRAM_MEM_ADDR_BITS+:PROGRAM_MEM_ADDR_BITS];
									mask_a[t] = 1'b1;
									target_a_valid = 1'b1;
								end
								else if (ex_next_pc[((THREADS_PER_BLOCK - 1) - t) * PROGRAM_MEM_ADDR_BITS+:PROGRAM_MEM_ADDR_BITS] == target_a)
									mask_a[t] = 1'b1;
								else begin
									target_b = ex_next_pc[((THREADS_PER_BLOCK - 1) - t) * PROGRAM_MEM_ADDR_BITS+:PROGRAM_MEM_ADDR_BITS];
									mask_b[t] = 1'b1;
									is_divergent = 1;
									target_b_valid = 1'b1;
								end
								if (ex_next_pc[((THREADS_PER_BLOCK - 1) - t) * PROGRAM_MEM_ADDR_BITS+:PROGRAM_MEM_ADDR_BITS] != (ex_pc + 1))
									is_branch = 1;
							end
						end
					if (ex_exit) begin
						if (stack_ptr[ex_warp_id] > 0) begin
							stack_ptr[ex_warp_id] <= stack_ptr[ex_warp_id] - 1;
							current_pc[ex_warp_id] <= stack_pc[ex_warp_id][stack_ptr[ex_warp_id] - 1];
							current_mask[ex_warp_id] <= stack_mask[ex_warp_id][stack_ptr[ex_warp_id] - 1];
							flush_warp_mask[ex_warp_id] <= 1'b1;
						end
						else begin
							warp_state[ex_warp_id] <= 3'd4;
							current_mask[ex_warp_id] <= 0;
							flush_warp_mask[ex_warp_id] <= 1'b1;
						end
					end
					else if (is_divergent) begin
						stack_pc[ex_warp_id][stack_ptr[ex_warp_id]] <= target_b;
						stack_mask[ex_warp_id][stack_ptr[ex_warp_id]] <= mask_b;
						stack_ptr[ex_warp_id] <= stack_ptr[ex_warp_id] + 1;
						current_pc[ex_warp_id] <= target_a;
						current_mask[ex_warp_id] <= mask_a;
						flush_warp_mask[ex_warp_id] <= 1'b1;
					end
					else begin
						is_reconverge = ((stack_ptr[ex_warp_id] > 0) && target_a_valid) && (target_a == stack_pc[ex_warp_id][stack_ptr[ex_warp_id] - 1]);
						if (is_reconverge) begin
							current_pc[ex_warp_id] <= target_a;
							current_mask[ex_warp_id] <= mask_a | stack_mask[ex_warp_id][stack_ptr[ex_warp_id] - 1];
							stack_ptr[ex_warp_id] <= stack_ptr[ex_warp_id] - 1;
							flush_warp_mask[ex_warp_id] <= 1'b1;
						end
						else if (is_branch || ex_sync) begin
							current_pc[ex_warp_id] <= target_a;
							current_mask[ex_warp_id] <= mask_a;
							flush_warp_mask[ex_warp_id] <= 1'b1;
							if (ex_sync) begin
								if (warp_state[ex_warp_id] != 3'd3) begin
									warp_state[ex_warp_id] <= 3'd3;
									barrier_count <= barrier_count + 1;
								end
							end
						end
					end
				end
			end
			if ((barrier_count >= num_active_warps_comb) && (num_active_warps_comb > 0)) begin
				begin : sv2v_autoblock_5
					reg signed [31:0] w_rel;
					for (w_rel = 0; w_rel < NUM_WARPS; w_rel = w_rel + 1)
						if (warp_state[w_rel] == 3'd3)
							warp_state[w_rel] <= 3'd1;
				end
				barrier_count <= 0;
			end
			if ((start && !done) && (!frontend_stall || flush_warp_mask[sched_warp_id])) begin
				found_var = 1'b0;
				next_rr_var = rr_ptr;
				begin : sv2v_autoblock_6
					reg signed [31:0] i;
					for (i = 0; i < NUM_WARPS; i = i + 1)
						begin
							check_w_var = (rr_ptr + i) % NUM_WARPS;
							if (((!found_var && (warp_state[check_w_var] == 3'd1)) && (current_mask[check_w_var] != 0)) && !warp_flush_inhibit[check_w_var]) begin
								found_var = 1'b1;
								next_rr_var = check_w_var;
							end
						end
				end
				if (found_var) begin
					if_pc <= current_pc[next_rr_var];
					sched_active_mask <= current_mask[next_rr_var];
					sched_warp_id <= next_rr_var;
					valid_issue <= 1;
					current_pc[next_rr_var] <= current_pc[next_rr_var] + 1;
					rr_ptr <= (next_rr_var + 1) % NUM_WARPS;
				end
				else begin
					sched_active_mask <= 0;
					valid_issue <= 0;
				end
			end
			all_warps_done = 1;
			for (w = 0; w < NUM_WARPS; w = w + 1)
				begin
					if (((warp_state[w] != 3'd4) && (warp_state[w] != 3'd0)) && (warp_state[w] != 3'd5))
						all_warps_done = 0;
					if (mem_in_progress[w])
						all_warps_done = 0;
				end
			if ((start && all_warps_done) && (warp_state[0] != 3'd0))
				done <= 1;
			if (!start) begin
				done <= 0;
				for (w = 0; w < NUM_WARPS; w = w + 1)
					warp_state[w] <= 3'd0;
			end
		end
	end
	reg [$clog2(NUM_WARPS) - 1:0] prev_issued_warp;
	always @(posedge clk)
		if (reset)
			prev_issued_warp <= 0;
		else if ((start && !done) && valid_issue)
			prev_issued_warp <= sched_warp_id;
	reg any_waiting_mem;
	reg any_waiting_barrier;
	always @(*) begin
		if (_sv2v_0)
			;
		any_waiting_mem = 0;
		any_waiting_barrier = 0;
		begin : sv2v_autoblock_7
			reg signed [31:0] i;
			for (i = 0; i < NUM_WARPS; i = i + 1)
				begin
					if (warp_state[i] == 3'd2)
						any_waiting_mem = 1;
					if (warp_state[i] == 3'd3)
						any_waiting_barrier = 1;
				end
		end
	end
	assign ev_scheduler_idle = ((start && !done) && !valid_issue) && !frontend_stall;
	assign ev_warp_switch = ((start && !done) && valid_issue) && (sched_warp_id != prev_issued_warp);
	assign ev_diverge = (((((((start && !done) && ex_valid) && (ex_active_mask != 0)) && !(mem_req_valid && (mem_warp_id == ex_warp_id))) && (warp_state[ex_warp_id] != 3'd2)) && !ex_exception_valid) && !ex_exit) && ex_has_divergence;
	assign ev_stall_mem = (start && !done) && any_waiting_mem;
	assign ev_stall_barrier = (start && !done) && any_waiting_barrier;
	assign ev_stall_noready = (((start && !done) && !valid_issue) && !frontend_stall) && !(any_waiting_mem || any_waiting_barrier);
	initial _sv2v_0 = 0;
endmodule
`default_nettype none
module shared_mem (
	clk,
	reset,
	read_valid,
	read_address,
	read_ready,
	read_data,
	write_valid,
	write_data,
	write_address,
	write_ready
);
	reg _sv2v_0;
	parameter DATA_BITS = 32;
	parameter ADDR_BITS = 32;
	parameter SIZE = 256;
	parameter THREADS_PER_BLOCK = 4;
	parameter N_BANKS = 4;
	input wire clk;
	input wire reset;
	input wire [THREADS_PER_BLOCK - 1:0] read_valid;
	input wire [(THREADS_PER_BLOCK * ADDR_BITS) - 1:0] read_address;
	output reg [THREADS_PER_BLOCK - 1:0] read_ready;
	output reg [(THREADS_PER_BLOCK * DATA_BITS) - 1:0] read_data;
	input wire [THREADS_PER_BLOCK - 1:0] write_valid;
	input wire [(THREADS_PER_BLOCK * DATA_BITS) - 1:0] write_data;
	input wire [(THREADS_PER_BLOCK * ADDR_BITS) - 1:0] write_address;
	output reg [THREADS_PER_BLOCK - 1:0] write_ready;
	localparam BANK_DEPTH = SIZE / N_BANKS;
	localparam BANK_BITS = $clog2(N_BANKS);
	localparam OFF_BITS = $clog2(BANK_DEPTH);
	reg [DATA_BITS - 1:0] mem [0:N_BANKS - 1][0:BANK_DEPTH - 1];
	reg [BANK_BITS - 1:0] r_bank [0:THREADS_PER_BLOCK - 1];
	reg [OFF_BITS - 1:0] r_offset [0:THREADS_PER_BLOCK - 1];
	reg [BANK_BITS - 1:0] w_bank [0:THREADS_PER_BLOCK - 1];
	reg [OFF_BITS - 1:0] w_offset [0:THREADS_PER_BLOCK - 1];
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_1
			reg signed [31:0] i;
			for (i = 0; i < THREADS_PER_BLOCK; i = i + 1)
				begin
					r_bank[i] = read_address[(((THREADS_PER_BLOCK - 1) - i) * ADDR_BITS) + (BANK_BITS - 1)-:BANK_BITS];
					r_offset[i] = read_address[(((THREADS_PER_BLOCK - 1) - i) * ADDR_BITS) + BANK_BITS+:OFF_BITS];
					w_bank[i] = write_address[(((THREADS_PER_BLOCK - 1) - i) * ADDR_BITS) + (BANK_BITS - 1)-:BANK_BITS];
					w_offset[i] = write_address[(((THREADS_PER_BLOCK - 1) - i) * ADDR_BITS) + BANK_BITS+:OFF_BITS];
				end
		end
	end
	reg [THREADS_PER_BLOCK - 1:0] w_bank_conflict;
	reg [THREADS_PER_BLOCK - 1:0] r_bank_conflict;
	reg [THREADS_PER_BLOCK - 1:0] raw_conflict;
	reg [THREADS_PER_BLOCK - 1:0] r_broadcast;
	always @(*) begin
		if (_sv2v_0)
			;
		w_bank_conflict = 1'sb0;
		r_bank_conflict = 1'sb0;
		raw_conflict = 1'sb0;
		r_broadcast = 1'sb0;
		begin : sv2v_autoblock_2
			reg signed [31:0] i;
			for (i = 0; i < THREADS_PER_BLOCK; i = i + 1)
				begin : sv2v_autoblock_3
					reg signed [31:0] j;
					for (j = 0; j < i; j = j + 1)
						begin
							if ((write_valid[i] && write_valid[j]) && (w_bank[i] == w_bank[j]))
								w_bank_conflict[i] = 1'b1;
							if (((read_valid[i] && read_valid[j]) && (r_bank[i] == r_bank[j])) && (read_address[((THREADS_PER_BLOCK - 1) - i) * ADDR_BITS+:ADDR_BITS] != read_address[((THREADS_PER_BLOCK - 1) - j) * ADDR_BITS+:ADDR_BITS]))
								r_bank_conflict[i] = 1'b1;
							if ((read_valid[i] && read_valid[j]) && (read_address[((THREADS_PER_BLOCK - 1) - i) * ADDR_BITS+:ADDR_BITS] == read_address[((THREADS_PER_BLOCK - 1) - j) * ADDR_BITS+:ADDR_BITS]))
								r_broadcast[i] = 1'b1;
							if (((read_valid[i] && write_valid[j]) && (r_bank[i] == w_bank[j])) && (r_offset[i] == w_offset[j]))
								raw_conflict[i] = 1'b1;
						end
				end
		end
	end
	integer k;
	integer b;
	always @(posedge clk)
		if (reset) begin
			read_ready <= 1'sb0;
			write_ready <= 1'sb0;
			for (b = 0; b < N_BANKS; b = b + 1)
				for (k = 0; k < BANK_DEPTH; k = k + 1)
					mem[b][k] <= 1'sb0;
		end
		else begin
			read_ready <= 1'sb0;
			write_ready <= 1'sb0;
			begin : sv2v_autoblock_4
				reg signed [31:0] i;
				for (i = 0; i < THREADS_PER_BLOCK; i = i + 1)
					begin
						if (write_valid[i] && !w_bank_conflict[i]) begin
							mem[w_bank[i]][w_offset[i]] <= write_data[((THREADS_PER_BLOCK - 1) - i) * DATA_BITS+:DATA_BITS];
							write_ready[i] <= 1'b1;
						end
						if (((read_valid[i] && !r_bank_conflict[i]) && !raw_conflict[i]) && !r_broadcast[i]) begin
							read_data[((THREADS_PER_BLOCK - 1) - i) * DATA_BITS+:DATA_BITS] <= mem[r_bank[i]][r_offset[i]];
							read_ready[i] <= 1'b1;
						end
						if ((read_valid[i] && r_broadcast[i]) && !raw_conflict[i]) begin : sv2v_autoblock_5
							reg signed [31:0] j;
							for (j = 0; j < i; j = j + 1)
								if (read_valid[j] && (read_address[((THREADS_PER_BLOCK - 1) - j) * ADDR_BITS+:ADDR_BITS] == read_address[((THREADS_PER_BLOCK - 1) - i) * ADDR_BITS+:ADDR_BITS])) begin
									read_data[((THREADS_PER_BLOCK - 1) - i) * DATA_BITS+:DATA_BITS] <= mem[r_bank[j]][r_offset[j]];
									read_ready[i] <= 1'b1;
								end
						end
					end
			end
		end
	initial _sv2v_0 = 0;
endmodule
`default_nettype none
module victim_write_buffer (
	clk,
	reset,
	push_valid,
	push_addr,
	push_data,
	push_sector_dirty,
	push_ready,
	probe_valid,
	probe_addr,
	probe_hit,
	probe_data,
	probe_sector_valid,
	probe_pop,
	pop_addr,
	mem_write_valid,
	mem_write_addr,
	mem_write_data,
	mem_write_strobe,
	mem_write_ready,
	flush_en,
	empty,
	full
);
	reg _sv2v_0;
	parameter ADDR_BITS = 32;
	parameter BLOCK_BITS = 128;
	parameter SECTORS = 4;
	parameter DEPTH = 4;
	input wire clk;
	input wire reset;
	input wire push_valid;
	input wire [ADDR_BITS - 1:0] push_addr;
	input wire [BLOCK_BITS - 1:0] push_data;
	input wire [SECTORS - 1:0] push_sector_dirty;
	output wire push_ready;
	input wire probe_valid;
	input wire [ADDR_BITS - 1:0] probe_addr;
	output reg probe_hit;
	output reg [BLOCK_BITS - 1:0] probe_data;
	output reg [SECTORS - 1:0] probe_sector_valid;
	input wire probe_pop;
	input wire [ADDR_BITS - 1:0] pop_addr;
	output reg mem_write_valid;
	output reg [ADDR_BITS - 1:0] mem_write_addr;
	output reg [BLOCK_BITS - 1:0] mem_write_data;
	output reg [SECTORS - 1:0] mem_write_strobe;
	input wire mem_write_ready;
	input wire flush_en;
	output wire empty;
	output wire full;
	localparam SECTOR_BITS = BLOCK_BITS / SECTORS;
	reg valid [0:DEPTH - 1];
	reg [ADDR_BITS - 1:0] addr [0:DEPTH - 1];
	reg [BLOCK_BITS - 1:0] data [0:DEPTH - 1];
	reg [SECTORS - 1:0] dirty [0:DEPTH - 1];
	reg [15:0] count;
	reg [15:0] next_count;
	reg [4:0] idle_counter;
	assign empty = count == 0;
	assign full = count == DEPTH;
	assign push_ready = !full;
	reg merge_found;
	reg [$clog2(DEPTH) - 1:0] merge_idx;
	reg free_found;
	reg [$clog2(DEPTH) - 1:0] free_idx;
	reg v_next;
	always @(*) begin
		if (_sv2v_0)
			;
		merge_found = 1'b0;
		merge_idx = 1'sb0;
		free_found = 1'b0;
		free_idx = 1'sb0;
		begin : sv2v_autoblock_1
			reg signed [31:0] i;
			for (i = 0; i < DEPTH; i = i + 1)
				begin
					if ((valid[i] && (addr[i] == push_addr)) && !merge_found) begin
						merge_found = 1'b1;
						merge_idx = i[$clog2(DEPTH) - 1:0];
					end
					if (!valid[i] && !free_found) begin
						free_found = 1'b1;
						free_idx = i[$clog2(DEPTH) - 1:0];
					end
				end
		end
	end
	always @(*) begin
		if (_sv2v_0)
			;
		probe_hit = 1'b0;
		probe_data = 1'sb0;
		probe_sector_valid = 1'sb0;
		if (probe_valid) begin : sv2v_autoblock_2
			reg signed [31:0] i;
			for (i = 0; i < DEPTH; i = i + 1)
				if (valid[i] && (addr[i] == probe_addr)) begin
					probe_hit = 1'b1;
					probe_data = data[i];
					probe_sector_valid = dirty[i];
				end
		end
	end
	reg drain_pending;
	reg [$clog2(DEPTH) - 1:0] drain_idx;
	always @(*) begin
		if (_sv2v_0)
			;
		drain_pending = 1'b0;
		drain_idx = 1'sb0;
		begin : sv2v_autoblock_3
			reg signed [31:0] i;
			for (i = 0; i < DEPTH; i = i + 1)
				if (valid[i] && !drain_pending) begin
					drain_pending = 1'b1;
					drain_idx = i[$clog2(DEPTH) - 1:0];
				end
		end
	end
	reg [1:0] state;
	reg [$clog2(DEPTH) - 1:0] active_drain_idx;
	reg active_drain_valid;
	always @(posedge clk)
		if (reset) begin
			state <= 2'd0;
			mem_write_valid <= 0;
			count <= 0;
			active_drain_idx <= 0;
			active_drain_valid <= 0;
			idle_counter <= 0;
			begin : sv2v_autoblock_4
				reg signed [31:0] k;
				for (k = 0; k < DEPTH; k = k + 1)
					begin
						valid[k] <= 0;
						dirty[k] <= 0;
					end
			end
		end
		else begin
			if (push_valid || probe_valid)
				idle_counter <= 0;
			else if (idle_counter != 5'h1f)
				idle_counter <= idle_counter + 1;
			if (push_valid && push_ready) begin
				if (merge_found) begin : sv2v_autoblock_5
					reg [BLOCK_BITS - 1:0] merged_data;
					merged_data = data[merge_idx];
					begin : sv2v_autoblock_6
						reg signed [31:0] s;
							reg [BLOCK_BITS - 1:0] sector_mask;
							for (s = 0; s < SECTORS; s = s + 1) begin
								sector_mask = {SECTOR_BITS{1'b1}};
							if (push_sector_dirty[s])
									merged_data = (merged_data & ~(sector_mask << (s * SECTOR_BITS))) | (push_data & (sector_mask << (s * SECTOR_BITS)));
							end
					end
					data[merge_idx] <= merged_data;
					dirty[merge_idx] <= dirty[merge_idx] | push_sector_dirty;
				end
				else if (free_found) begin
					addr[free_idx] <= push_addr;
					data[free_idx] <= push_data;
					dirty[free_idx] <= push_sector_dirty;
				end
			end
			case (state)
				2'd0:
					if (drain_pending && ((flush_en || (count >= (DEPTH / 2))) || (idle_counter == 5'h1f))) begin
						if (!(probe_pop && (addr[drain_idx] == pop_addr))) begin
							mem_write_valid <= 1;
							mem_write_addr <= addr[drain_idx];
							mem_write_data <= data[drain_idx];
							mem_write_strobe <= dirty[drain_idx];
							active_drain_idx <= drain_idx;
							active_drain_valid <= 1'b1;
							state <= 2'd1;
						end
					end
				2'd1: begin
					if ((probe_pop && valid[active_drain_idx]) && (addr[active_drain_idx] == pop_addr))
						active_drain_valid <= 1'b0;
					if (mem_write_ready) begin
						mem_write_valid <= 0;
						state <= 2'd0;
					end
				end
			endcase
			next_count = 0;
			begin : sv2v_autoblock_7
				reg signed [31:0] i;
				for (i = 0; i < DEPTH; i = i + 1)
					begin
						v_next = valid[i];
						if ((((push_valid && push_ready) && !merge_found) && free_found) && (i == free_idx))
							v_next = 1'b1;
						if ((((state == 2'd1) && mem_write_ready) && (i == active_drain_idx)) && active_drain_valid) begin
							v_next = 1'b0;
							dirty[i] <= 0;
						end
						if ((probe_pop && valid[i]) && (addr[i] == pop_addr)) begin
							v_next = 1'b0;
							dirty[i] <= 0;
						end
						valid[i] <= v_next;
						if (v_next)
							next_count = next_count + 1;
					end
			end
			count <= next_count;
		end
	initial _sv2v_0 = 0;
endmodule
`resetall
`default_nettype none
module axi_ram (
	clk,
	rst,
	s_axi_awid,
	s_axi_awaddr,
	s_axi_awlen,
	s_axi_awsize,
	s_axi_awburst,
	s_axi_awlock,
	s_axi_awcache,
	s_axi_awprot,
	s_axi_awvalid,
	s_axi_awready,
	s_axi_wdata,
	s_axi_wstrb,
	s_axi_wlast,
	s_axi_wvalid,
	s_axi_wready,
	s_axi_bid,
	s_axi_bresp,
	s_axi_bvalid,
	s_axi_bready,
	s_axi_arid,
	s_axi_araddr,
	s_axi_arlen,
	s_axi_arsize,
	s_axi_arburst,
	s_axi_arlock,
	s_axi_arcache,
	s_axi_arprot,
	s_axi_arvalid,
	s_axi_arready,
	s_axi_rid,
	s_axi_rdata,
	s_axi_rresp,
	s_axi_rlast,
	s_axi_rvalid,
	s_axi_rready
);
	parameter DATA_WIDTH = 32;
	parameter ADDR_WIDTH = 32;
	parameter STRB_WIDTH = DATA_WIDTH / 8;
	parameter ID_WIDTH = 8;
	parameter PIPELINE_OUTPUT = 0;
	parameter DDR_tCAS = 15;
	parameter DDR_tRCD = 15;
	parameter DDR_tRP = 15;
	parameter DDR_BANK_BITS = 2;
	parameter DDR_COL_BITS = 10;
	input wire clk;
	input wire rst;
	input wire [ID_WIDTH - 1:0] s_axi_awid;
	input wire [ADDR_WIDTH - 1:0] s_axi_awaddr;
	input wire [7:0] s_axi_awlen;
	input wire [2:0] s_axi_awsize;
	input wire [1:0] s_axi_awburst;
	input wire s_axi_awlock;
	input wire [3:0] s_axi_awcache;
	input wire [2:0] s_axi_awprot;
	input wire s_axi_awvalid;
	output wire s_axi_awready;
	input wire [DATA_WIDTH - 1:0] s_axi_wdata;
	input wire [STRB_WIDTH - 1:0] s_axi_wstrb;
	input wire s_axi_wlast;
	input wire s_axi_wvalid;
	output wire s_axi_wready;
	output wire [ID_WIDTH - 1:0] s_axi_bid;
	output wire [1:0] s_axi_bresp;
	output wire s_axi_bvalid;
	input wire s_axi_bready;
	input wire [ID_WIDTH - 1:0] s_axi_arid;
	input wire [ADDR_WIDTH - 1:0] s_axi_araddr;
	input wire [7:0] s_axi_arlen;
	input wire [2:0] s_axi_arsize;
	input wire [1:0] s_axi_arburst;
	input wire s_axi_arlock;
	input wire [3:0] s_axi_arcache;
	input wire [2:0] s_axi_arprot;
	input wire s_axi_arvalid;
	output wire s_axi_arready;
	output wire [ID_WIDTH - 1:0] s_axi_rid;
	output wire [DATA_WIDTH - 1:0] s_axi_rdata;
	output wire [1:0] s_axi_rresp;
	output wire s_axi_rlast;
	output wire s_axi_rvalid;
	input wire s_axi_rready;
	parameter VALID_ADDR_WIDTH = ADDR_WIDTH - $clog2(STRB_WIDTH);
	parameter WORD_WIDTH = STRB_WIDTH;
	parameter WORD_SIZE = DATA_WIDTH / WORD_WIDTH;
	initial begin
		if ((WORD_SIZE * STRB_WIDTH) != DATA_WIDTH) begin
			$error("Error: AXI data width not evenly divisble (instance %m)");
			$finish;
		end
		if ((2 ** $clog2(WORD_WIDTH)) != WORD_WIDTH) begin
			$error("Error: AXI word width must be even power of two (instance %m)");
			$finish;
		end
	end
	localparam NUM_BANKS = 2 ** DDR_BANK_BITS;
	localparam ROW_BITS = (ADDR_WIDTH > (DDR_BANK_BITS + DDR_COL_BITS) ? (ADDR_WIDTH - DDR_BANK_BITS) - DDR_COL_BITS : 1);
	reg [ROW_BITS - 1:0] open_row_read [0:NUM_BANKS - 1];
	reg [ROW_BITS - 1:0] open_row_write [0:NUM_BANKS - 1];
	reg [7:0] read_delay_reg = 8'd0;
	reg [7:0] read_delay_next;
	reg [7:0] write_delay_reg = 8'd0;
	reg [7:0] write_delay_next;
	wire [DDR_BANK_BITS - 1:0] r_bank = s_axi_araddr[DDR_COL_BITS+:DDR_BANK_BITS];
	wire [ROW_BITS - 1:0] r_row = s_axi_araddr[DDR_COL_BITS + DDR_BANK_BITS+:ROW_BITS];
	wire [DDR_BANK_BITS - 1:0] w_bank = s_axi_awaddr[DDR_COL_BITS+:DDR_BANK_BITS];
	wire [ROW_BITS - 1:0] w_row = s_axi_awaddr[DDR_COL_BITS + DDR_BANK_BITS+:ROW_BITS];
	localparam [1:0] READ_STATE_IDLE = 2'd0;
	localparam [1:0] READ_STATE_WAIT = 2'd1;
	localparam [1:0] READ_STATE_BURST = 2'd2;
	reg [1:0] read_state_reg = READ_STATE_IDLE;
	reg [1:0] read_state_next;
	localparam [2:0] WRITE_STATE_IDLE = 3'd0;
	localparam [2:0] WRITE_STATE_WAIT = 3'd1;
	localparam [2:0] WRITE_STATE_BURST = 3'd2;
	localparam [2:0] WRITE_STATE_RESP = 3'd3;
	reg [2:0] write_state_reg = WRITE_STATE_IDLE;
	reg [2:0] write_state_next;
	reg mem_wr_en;
	reg mem_rd_en;
	reg [ID_WIDTH - 1:0] read_id_reg = {ID_WIDTH {1'b0}};
	reg [ID_WIDTH - 1:0] read_id_next;
	reg [ADDR_WIDTH - 1:0] read_addr_reg = {ADDR_WIDTH {1'b0}};
	reg [ADDR_WIDTH - 1:0] read_addr_next;
	reg [7:0] read_count_reg = 8'd0;
	reg [7:0] read_count_next;
	reg [2:0] read_size_reg = 3'd0;
	reg [2:0] read_size_next;
	reg [1:0] read_burst_reg = 2'd0;
	reg [1:0] read_burst_next;
	reg [ID_WIDTH - 1:0] write_id_reg = {ID_WIDTH {1'b0}};
	reg [ID_WIDTH - 1:0] write_id_next;
	reg [ADDR_WIDTH - 1:0] write_addr_reg = {ADDR_WIDTH {1'b0}};
	reg [ADDR_WIDTH - 1:0] write_addr_next;
	reg [7:0] write_count_reg = 8'd0;
	reg [7:0] write_count_next;
	reg [2:0] write_size_reg = 3'd0;
	reg [2:0] write_size_next;
	reg [1:0] write_burst_reg = 2'd0;
	reg [1:0] write_burst_next;
	reg s_axi_awready_reg = 1'b0;
	reg s_axi_awready_next;
	reg s_axi_wready_reg = 1'b0;
	reg s_axi_wready_next;
	reg [ID_WIDTH - 1:0] s_axi_bid_reg = {ID_WIDTH {1'b0}};
	reg [ID_WIDTH - 1:0] s_axi_bid_next;
	reg s_axi_bvalid_reg = 1'b0;
	reg s_axi_bvalid_next;
	reg s_axi_arready_reg = 1'b0;
	reg s_axi_arready_next;
	reg [ID_WIDTH - 1:0] s_axi_rid_reg = {ID_WIDTH {1'b0}};
	reg [ID_WIDTH - 1:0] s_axi_rid_next;
	reg [DATA_WIDTH - 1:0] s_axi_rdata_reg = {DATA_WIDTH {1'b0}};
	reg [DATA_WIDTH - 1:0] s_axi_rdata_next;
	reg s_axi_rlast_reg = 1'b0;
	reg s_axi_rlast_next;
	reg s_axi_rvalid_reg = 1'b0;
	reg s_axi_rvalid_next;
	reg [ID_WIDTH - 1:0] s_axi_rid_pipe_reg = {ID_WIDTH {1'b0}};
	reg [DATA_WIDTH - 1:0] s_axi_rdata_pipe_reg = {DATA_WIDTH {1'b0}};
	reg s_axi_rlast_pipe_reg = 1'b0;
	reg s_axi_rvalid_pipe_reg = 1'b0;
	reg [DATA_WIDTH - 1:0] mem [(2 ** VALID_ADDR_WIDTH) - 1:0];
	wire [VALID_ADDR_WIDTH - 1:0] s_axi_awaddr_valid = s_axi_awaddr >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
	wire [VALID_ADDR_WIDTH - 1:0] s_axi_araddr_valid = s_axi_araddr >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
	wire [VALID_ADDR_WIDTH - 1:0] read_addr_valid = read_addr_reg >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
	wire [VALID_ADDR_WIDTH - 1:0] write_addr_valid = write_addr_reg >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
	assign s_axi_awready = s_axi_awready_reg;
	assign s_axi_wready = s_axi_wready_reg;
	assign s_axi_bid = s_axi_bid_reg;
	assign s_axi_bresp = 2'b00;
	assign s_axi_bvalid = s_axi_bvalid_reg;
	assign s_axi_arready = s_axi_arready_reg;
	assign s_axi_rid = (PIPELINE_OUTPUT ? s_axi_rid_pipe_reg : s_axi_rid_reg);
	assign s_axi_rdata = (PIPELINE_OUTPUT ? s_axi_rdata_pipe_reg : s_axi_rdata_reg);
	assign s_axi_rresp = 2'b00;
	assign s_axi_rlast = (PIPELINE_OUTPUT ? s_axi_rlast_pipe_reg : s_axi_rlast_reg);
	assign s_axi_rvalid = (PIPELINE_OUTPUT ? s_axi_rvalid_pipe_reg : s_axi_rvalid_reg);
	integer i;
	integer j;
	integer b;
	initial begin
		for (b = 0; b < NUM_BANKS; b = b + 1)
			begin
				open_row_read[b] = {ROW_BITS {1'b1}};
				open_row_write[b] = {ROW_BITS {1'b1}};
			end
		// synthesis translate_off
		for (i = 0; i < (2 ** VALID_ADDR_WIDTH); i = i + (2 ** (VALID_ADDR_WIDTH / 2)))
			for (j = i; j < (i + (2 ** (VALID_ADDR_WIDTH / 2))); j = j + 1)
				mem[j] = 0;
		// synthesis translate_on
	end
	always @(*) begin
		write_state_next = WRITE_STATE_IDLE;
		write_delay_next = write_delay_reg;
		mem_wr_en = 1'b0;
		write_id_next = write_id_reg;
		write_addr_next = write_addr_reg;
		write_count_next = write_count_reg;
		write_size_next = write_size_reg;
		write_burst_next = write_burst_reg;
		s_axi_awready_next = 1'b0;
		s_axi_wready_next = 1'b0;
		s_axi_bid_next = s_axi_bid_reg;
		s_axi_bvalid_next = s_axi_bvalid_reg && !s_axi_bready;
		case (write_state_reg)
			WRITE_STATE_IDLE: begin
				s_axi_awready_next = 1'b1;
				if (s_axi_awready && s_axi_awvalid) begin
					write_id_next = s_axi_awid;
					write_addr_next = s_axi_awaddr;
					write_count_next = s_axi_awlen;
					write_size_next = (s_axi_awsize < $clog2(STRB_WIDTH) ? s_axi_awsize : $clog2(STRB_WIDTH));
					write_burst_next = s_axi_awburst;
					if (open_row_write[w_bank] == w_row)
						write_delay_next = DDR_tCAS;
					else
						write_delay_next = (DDR_tCAS + DDR_tRCD) + DDR_tRP;
					s_axi_awready_next = 1'b0;
					write_state_next = WRITE_STATE_WAIT;
				end
				else
					write_state_next = WRITE_STATE_IDLE;
			end
			WRITE_STATE_WAIT:
				if (write_delay_reg > 0) begin
					write_delay_next = write_delay_reg - 1;
					write_state_next = WRITE_STATE_WAIT;
				end
				else begin
					s_axi_wready_next = 1'b1;
					write_state_next = WRITE_STATE_BURST;
				end
			WRITE_STATE_BURST: begin
				s_axi_wready_next = 1'b1;
				if (s_axi_wready && s_axi_wvalid) begin
					mem_wr_en = 1'b1;
					if (write_burst_reg != 2'b00)
						write_addr_next = write_addr_reg + (1 << write_size_reg);
					write_count_next = write_count_reg - 1;
					if (write_count_reg > 0)
						write_state_next = WRITE_STATE_BURST;
					else begin
						s_axi_wready_next = 1'b0;
						if (s_axi_bready || !s_axi_bvalid) begin
							s_axi_bid_next = write_id_reg;
							s_axi_bvalid_next = 1'b1;
							s_axi_awready_next = 1'b1;
							write_state_next = WRITE_STATE_IDLE;
						end
						else
							write_state_next = WRITE_STATE_RESP;
					end
				end
				else
					write_state_next = WRITE_STATE_BURST;
			end
			WRITE_STATE_RESP:
				if (s_axi_bready || !s_axi_bvalid) begin
					s_axi_bid_next = write_id_reg;
					s_axi_bvalid_next = 1'b1;
					s_axi_awready_next = 1'b1;
					write_state_next = WRITE_STATE_IDLE;
				end
				else
					write_state_next = WRITE_STATE_RESP;
		endcase
	end
	always @(posedge clk) begin
		write_state_reg <= write_state_next;
		write_delay_reg <= write_delay_next;
		write_id_reg <= write_id_next;
		write_addr_reg <= write_addr_next;
		write_count_reg <= write_count_next;
		write_size_reg <= write_size_next;
		write_burst_reg <= write_burst_next;
		s_axi_awready_reg <= s_axi_awready_next;
		s_axi_wready_reg <= s_axi_wready_next;
		s_axi_bid_reg <= s_axi_bid_next;
		s_axi_bvalid_reg <= s_axi_bvalid_next;
		if (s_axi_awready && s_axi_awvalid)
			open_row_write[w_bank] <= w_row;
		for (i = 0; i < WORD_WIDTH; i = i + 1)
			if (mem_wr_en & s_axi_wstrb[i])
				mem[write_addr_valid][WORD_SIZE * i+:WORD_SIZE] <= s_axi_wdata[WORD_SIZE * i+:WORD_SIZE];
		if (rst) begin
			write_state_reg <= WRITE_STATE_IDLE;
			s_axi_awready_reg <= 1'b0;
			s_axi_wready_reg <= 1'b0;
			s_axi_bvalid_reg <= 1'b0;
		end
	end
	always @(*) begin
		read_state_next = READ_STATE_IDLE;
		read_delay_next = read_delay_reg;
		mem_rd_en = 1'b0;
		s_axi_rid_next = s_axi_rid_reg;
		s_axi_rlast_next = s_axi_rlast_reg;
		s_axi_rvalid_next = s_axi_rvalid_reg && !(s_axi_rready || (PIPELINE_OUTPUT && !s_axi_rvalid_pipe_reg));
		read_id_next = read_id_reg;
		read_addr_next = read_addr_reg;
		read_count_next = read_count_reg;
		read_size_next = read_size_reg;
		read_burst_next = read_burst_reg;
		s_axi_arready_next = 1'b0;
		case (read_state_reg)
			READ_STATE_IDLE: begin
				s_axi_arready_next = 1'b1;
				if (s_axi_arready && s_axi_arvalid) begin
					read_id_next = s_axi_arid;
					read_addr_next = s_axi_araddr;
					read_count_next = s_axi_arlen;
					read_size_next = (s_axi_arsize < $clog2(STRB_WIDTH) ? s_axi_arsize : $clog2(STRB_WIDTH));
					read_burst_next = s_axi_arburst;
					if (open_row_read[r_bank] == r_row)
						read_delay_next = DDR_tCAS;
					else
						read_delay_next = (DDR_tCAS + DDR_tRCD) + DDR_tRP;
					s_axi_arready_next = 1'b0;
					read_state_next = READ_STATE_WAIT;
				end
				else
					read_state_next = READ_STATE_IDLE;
			end
			READ_STATE_WAIT:
				if (read_delay_reg > 0) begin
					read_delay_next = read_delay_reg - 1;
					read_state_next = READ_STATE_WAIT;
				end
				else
					read_state_next = READ_STATE_BURST;
			READ_STATE_BURST:
				if ((s_axi_rready || (PIPELINE_OUTPUT && !s_axi_rvalid_pipe_reg)) || !s_axi_rvalid_reg) begin
					mem_rd_en = 1'b1;
					s_axi_rvalid_next = 1'b1;
					s_axi_rid_next = read_id_reg;
					s_axi_rlast_next = read_count_reg == 0;
					if (read_burst_reg != 2'b00)
						read_addr_next = read_addr_reg + (1 << read_size_reg);
					read_count_next = read_count_reg - 1;
					if (read_count_reg > 0)
						read_state_next = READ_STATE_BURST;
					else begin
						s_axi_arready_next = 1'b1;
						read_state_next = READ_STATE_IDLE;
					end
				end
				else
					read_state_next = READ_STATE_BURST;
		endcase
	end
	always @(posedge clk) begin
		read_state_reg <= read_state_next;
		read_delay_reg <= read_delay_next;
		read_id_reg <= read_id_next;
		read_addr_reg <= read_addr_next;
		read_count_reg <= read_count_next;
		read_size_reg <= read_size_next;
		read_burst_reg <= read_burst_next;
		s_axi_arready_reg <= s_axi_arready_next;
		s_axi_rid_reg <= s_axi_rid_next;
		s_axi_rlast_reg <= s_axi_rlast_next;
		s_axi_rvalid_reg <= s_axi_rvalid_next;
		if (s_axi_arready && s_axi_arvalid)
			open_row_read[r_bank] <= r_row;
		if (mem_rd_en)
			s_axi_rdata_reg <= mem[read_addr_valid];
		if (!s_axi_rvalid_pipe_reg || s_axi_rready) begin
			s_axi_rid_pipe_reg <= s_axi_rid_reg;
			s_axi_rdata_pipe_reg <= s_axi_rdata_reg;
			s_axi_rlast_pipe_reg <= s_axi_rlast_reg;
			s_axi_rvalid_pipe_reg <= s_axi_rvalid_reg;
		end
		if (rst) begin
			read_state_reg <= READ_STATE_IDLE;
			s_axi_arready_reg <= 1'b0;
			s_axi_rvalid_reg <= 1'b0;
			s_axi_rvalid_pipe_reg <= 1'b0;
		end
	end
endmodule