`timescale 1ns/1ps

module be_tb_top;
  import mock_rtl_pkg::*;
  import be_tb_pkg::*;

  localparam time CLK_PERIOD = 10ns;

  logic clk;
  logic rstn;
  bit cfg_ready;
  bit sim_done;
  be_config cfg;
  fe_agent fe_agent_h;
  be_agent be_agent_h;
  cache_agent cache_agent_h;

  orbe_fe_if fe_vif(clk, rstn);
  or_be_lsu_if lsu_vif(clk);
  ob_if ob_vif(clk);
  getter_if getter_vif(clk);
  assign lsu_vif.rst_n = rstn;

  mock_rtl u_mock_rtl (
    .rst_n (rstn),
    .fe    (fe_vif),
    .lsu   (lsu_vif),
    .ob    (ob_vif),
    .getter(getter_vif)
  );

  initial begin : clock_generator
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  initial begin : configure
    cfg_ready = 1'b0;
    sim_done = 1'b0;
    cfg = new();
    cfg.apply_plusargs();
    cfg.validate(MOCK_ISSUE_NUM);
    cfg.print();
    cfg_ready = 1'b1;
  end

  initial begin : sim_watchdog
    int unsigned timeout_cycles;
    time timeout_time;

    wait (cfg_ready);
    timeout_cycles = cfg.timeout_cycles;
    timeout_time = timeout_cycles * CLK_PERIOD;
    @(posedge rstn);
    #(timeout_time);
    #1;
    if (!sim_done)
      cfg.reporter.fatal($sformatf(
          "[TB] simulation timeout after %0d clock cycles (%0t)",
          timeout_cycles, timeout_time));
  end

  initial begin : reset_and_run
    wait (cfg_ready);
    rstn = 1'b0;
    repeat (5) @(posedge clk);
    rstn = 1'b1;

    fe_agent_h = new(fe_vif, cfg);
    be_agent_h = new(ob_vif, fe_vif, getter_vif, cfg);
    cache_agent_h = new(lsu_vif, ob_vif, cfg);

    fork
      fe_agent_h.run();
      be_agent_h.run();
      cache_agent_h.run();
    join

    fe_agent_h.finish_model();
    sim_done = 1'b1;
    $finish;
  end

  final begin
    if (cfg != null)
      cfg.reporter.print_summary();
  end
endmodule
