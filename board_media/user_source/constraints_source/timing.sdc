create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
# MF168 sensor lines are asynchronous UART inputs, sampled after synchronizers.
set_false_path -from [get_ports {laser_left_rx laser_right_rx}]
