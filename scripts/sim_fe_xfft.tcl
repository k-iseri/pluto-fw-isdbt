# 実物の xfft IP を含む前段のシミュレーション（Vivado batch）
#   vivado -mode batch -source scripts/sim_fe_xfft.tcl -tclargs <rtl_dir> <work_dir>
set rtl [lindex $argv 0]
set work [lindex $argv 1]
file mkdir $work
create_project -force sim_fe $work/sim_fe -part xc7z010clg400-1
create_ip -name xfft -vendor xilinx.com -library ip -version 9.1 -module_name xfft_8192
set_property -dict [list \
  CONFIG.transform_length 8192 \
  CONFIG.implementation_options pipelined_streaming_io \
  CONFIG.data_format fixed_point \
  CONFIG.input_width 16 \
  CONFIG.phase_factor_width 16 \
  CONFIG.scaling_options block_floating_point \
  CONFIG.rounding_modes convergent_rounding \
  CONFIG.output_ordering natural_order \
  CONFIG.throttle_scheme realtime \
  CONFIG.xk_index true \
  CONFIG.aresetn true] [get_ips xfft_8192]
generate_target {instantiation_template simulation} [get_ips xfft_8192]
add_files -norecurse [list $rtl/isdbt_fe_win.v $rtl/isdbt_fe_out.v $rtl/isdbt_fe_xfft_tb.v]
set_property top isdbt_fe_xfft_tb [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
launch_simulation
close_sim
