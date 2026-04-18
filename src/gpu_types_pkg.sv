`default_nettype none

package gpu_types_pkg;
    parameter DATA_BITS = 16;
    parameter ADDR_BITS = 8;

    // Control signals extracted during Decode
    typedef struct packed {
        logic reg_write_enable;
        logic mem_read_enable;
        logic mem_write_enable;
        logic nzp_write_enable;
        logic [1:0] reg_input_mux;
        logic [2:0] alu_arithmetic_mux;
        logic alu_output_mux;
        logic pc_mux;
        logic is_ret;
        logic sync;
        logic shared_read_enable;
        logic shared_write_enable;
    } control_signals_t;

    // IF/ID Pipeline Register
    typedef struct packed {
        logic valid;
        logic [ADDR_BITS-1:0] pc;
        logic [15:0] instruction;
    } if_id_reg_t;

    // ID/EX Pipeline Register
    typedef struct packed {
        logic valid;
        control_signals_t ctrl;
        logic [ADDR_BITS-1:0] pc;
        logic [DATA_BITS-1:0] rs_data;
        logic [DATA_BITS-1:0] rt_data;
        logic [DATA_BITS-1:0] immediate;
        logic [3:0] rd_addr;
        logic [2:0] nzp_cond; 
    } id_ex_reg_t;

    // EX/MEM Pipeline Register
    typedef struct packed {
        logic valid;
        control_signals_t ctrl;
        logic [DATA_BITS-1:0] alu_out;
        logic [DATA_BITS-1:0] rt_data; 
        logic [3:0] rd_addr;
    } ex_mem_reg_t;

    // MEM/WB Pipeline Register
    typedef struct packed {
        logic valid;
        control_signals_t ctrl;
        logic [DATA_BITS-1:0] mem_data;
        logic [DATA_BITS-1:0] alu_out;
        logic [3:0] rd_addr;
    } mem_wb_reg_t;

endpackage