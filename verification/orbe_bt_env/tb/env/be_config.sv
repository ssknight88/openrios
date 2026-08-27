class be_config;
  int unsigned issue_width;
  int unsigned verbosity;
  string test_name;
  int unsigned timeout_cycles;
  int unsigned smoke_wait_cycles;
  int unsigned cache_load_return_delay_cycles;
  int unsigned cache_store_done_delay_cycles;
  int unsigned reporter_error_fatal_threshold;
  be_reporter reporter;

  function new();
    issue_width = MOCK_ISSUE_NUM;
    verbosity = 1;
    test_name = "elf";
    timeout_cycles = 2000000;
    smoke_wait_cycles = 1000;
    cache_load_return_delay_cycles = 0;
    cache_store_done_delay_cycles = 0;
    reporter_error_fatal_threshold = 0;
    reporter = new("BE_TB", verbosity);
  endfunction

  function void print_fe(int unsigned level, string message);
    reporter.print(level, message);
  endfunction

  function void print_be(int unsigned level, string message);
    reporter.print(level, message);
  endfunction

  function void print_cache(int unsigned level, string message);
    reporter.print(level, message);
  endfunction

  function void print_tb(int unsigned level, string message);
    reporter.print(level, message);
  endfunction

  function void apply_plusargs();
    int value;
    string value_string;

    if ($value$plusargs("VERBOSITY=%d", value)) verbosity = value;
    if ($value$plusargs("TEST=%s", value_string)) test_name = value_string;
    if ($value$plusargs("SIM_TIMEOUT_CYCLES=%d", value)) timeout_cycles = value;
    if ($value$plusargs("SMOKE_WAIT_CYCLES=%d", value))
      smoke_wait_cycles = value;
    if ($value$plusargs("CACHE_LOAD_RETURN_DELAY_CYCLES=%d", value)) begin
      if (value < 0)
        reporter.fatal($sformatf("CACHE_LOAD_RETURN_DELAY_CYCLES must be non-negative; got %0d",
                                 value));
      else
        cache_load_return_delay_cycles = value;
    end
    if ($value$plusargs("CACHE_STORE_DONE_DELAY_CYCLES=%d", value)) begin
      if (value < 0)
        reporter.fatal($sformatf("CACHE_STORE_DONE_DELAY_CYCLES must be non-negative; got %0d",
                                 value));
      else
        cache_store_done_delay_cycles = value;
    end
    if ($value$plusargs("ISSUE_WIDTH=%d", value)) issue_width = value;
    if ($value$plusargs("ERROR_LIMIT=%d", value)) begin
      if (value < 0)
        reporter.fatal($sformatf("ERROR_LIMIT must be non-negative; got %0d",
                                 value));
      else
        reporter_error_fatal_threshold = value;
    end
  endfunction

  function void validate_verbosity(string name, int unsigned value);
    if ((value < 1) || (value > 3))
      reporter.fatal($sformatf("%s must be 1, 2, or 3; got %0d", name, value));
  endfunction

  function void validate(int unsigned compiled_issue_width);
    validate_verbosity("verbosity", verbosity);
    if (issue_width != compiled_issue_width)
      reporter.fatal($sformatf("issue_width=%0d does not match compiled MOCK_ISSUE_NUM=%0d",
                               issue_width, compiled_issue_width));
    if (smoke_wait_cycles == 0)
      reporter.fatal("smoke_wait_cycles must be non-zero");
    if (timeout_cycles == 0)
      reporter.fatal("timeout_cycles must be non-zero");
    reporter.configure(verbosity, 1'b1, reporter_error_fatal_threshold);
  endfunction

  function void print();
    print_tb(1, "---------------- BE verification config ----------------");
    print_tb(1, $sformatf("test=%s issue_width=%0d timeout_cycles=%0d smoke_wait_cycles=%0d cache_load_return_delay_cycles=%0d cache_store_done_delay_cycles=%0d reporter_error_fatal_threshold=%0d",
                          test_name, issue_width, timeout_cycles, smoke_wait_cycles,
                          cache_load_return_delay_cycles, cache_store_done_delay_cycles,
                          reporter_error_fatal_threshold));
    print_tb(1, $sformatf("verbosity: global=%0d", verbosity));
    print_tb(1, "----------------------------------------------------------");
  endfunction
endclass
