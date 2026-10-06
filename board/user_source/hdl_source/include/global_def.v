


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// ext_mem_clk is 100 MHz: one cycle is 10 ns. Keep the refresh macro grouped;
// an unparenthesized 1e9/125e6 expansion made the integer division below zero.
`define   SDR_CLK_PERIOD                10
`define   SELF_REFRESH_INTERVAL         (64000000 / (`SDR_CLK_PERIOD * (2 ** (`ROW_WIDTH))))

