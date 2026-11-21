// Shared storage API. Include inside a memory module after MEM_WORD_WIDTH is defined.
`ifdef USE_DPI_DRAM
`ifndef __ICARUS__
  import "DPI-C" function void memory_read_line(input int id, input longint unsigned address,
      output bit [MEM_WORD_WIDTH-1:0] data, input int unsigned width, endian, mode);
  import "DPI-C" function void memory_write_line(input int id, input longint unsigned address,
      input bit [MEM_WORD_WIDTH-1:0] data, input int unsigned width, endian, mode);
  import "DPI-C" function void memory_clear(input int id);
  import "DPI-C" function int memory_load(input int id, input string filename,
      input int unsigned width, endian, mode);
  import "DPI-C" function int memory_dump(input int id, input string filename,
      input int unsigned width, endian, mode);
  import "DPI-C" function int memory_byte_exists(input int id, input longint unsigned address);
  import "DPI-C" function int memory_line_exists(input int id, input longint unsigned address,
      input int unsigned width, mode);
  import "DPI-C" function int unsigned memory_address_count(input int id);
  import "DPI-C" function void memory_address_at(input int id, input int unsigned index,
      output bit [63:0] address);
`endif
`else
  logic [MEM_WORD_WIDTH-1:0] mem [longint];
`endif

  function bit byteExists(input longint unsigned address);
`ifdef USE_DPI_DRAM
`ifdef __ICARUS__
    byteExists=$memory_byte_exists(MEMORY_ID,address);
`else
    byteExists=memory_byte_exists(MEMORY_ID,address);
`endif
`else
    byteExists=mem.exists((address / (MEM_WORD_WIDTH/8)) * (MEM_WORD_WIDTH/8));
`endif
  endfunction

  function bit existsMem(input longint unsigned address);
`ifdef USE_DPI_DRAM
`ifdef __ICARUS__
    existsMem=$memory_line_exists(MEMORY_ID,address,MEM_WORD_WIDTH,1);
`else
    existsMem=memory_line_exists(MEMORY_ID,address,MEM_WORD_WIDTH,1);
`endif
`else
    existsMem=mem.exists(address);
`endif
  endfunction

  // Static scratch vectors also work with Icarus VPI output arguments.
  function [MEM_WORD_WIDTH-1:0] readMem(input longint unsigned address);
    reg [MEM_WORD_WIDTH-1:0] data;
`ifdef USE_DPI_DRAM
`ifdef __ICARUS__
    $memory_read_line(MEMORY_ID,address,data,MEM_WORD_WIDTH,1,1);
`else
    memory_read_line(MEMORY_ID,address,data,MEM_WORD_WIDTH,1,1);
`endif
    readMem=data;
`else
    readMem=mem.exists(address) ? mem[address] : '0;
`endif
  endfunction

  task writeMem(input longint unsigned address, input logic [MEM_WORD_WIDTH-1:0] data);
`ifdef USE_DPI_DRAM
    if ($isunknown(data)) $fatal(1,"C++ storage cannot store X/Z at %h",address);
`ifdef __ICARUS__
    $memory_write_line(MEMORY_ID,address,data,MEM_WORD_WIDTH,1,1);
`else
    memory_write_line(MEMORY_ID,address,data,MEM_WORD_WIDTH,1,1);
`endif
`else
    mem[address]=data;
`endif
  endtask

  task clearMem;
`ifdef USE_DPI_DRAM
`ifdef __ICARUS__
    $memory_clear(MEMORY_ID);
`else
    memory_clear(MEMORY_ID);
`endif
`else
    mem.delete();
`endif
  endtask

  task loadMem(input string filename);
    integer status;
    clearMem();
`ifdef USE_DPI_DRAM
`ifdef __ICARUS__
    status=$memory_load(MEMORY_ID,filename,MEM_WORD_WIDTH,1,1);
`else
    status=memory_load(MEMORY_ID,filename,MEM_WORD_WIDTH,1,1);
`endif
    if (!status) $fatal(1,"Cannot load %s",filename);
`else
    status=$fopen(filename,"r");
    if (!status) $fatal(1,"Cannot load %s",filename);
    $fclose(status);
    $readmemh(filename,mem);
`endif
    $display("INFO[dram]: Reading memory file: '%s'",filename);
  endtask

  task dumpMem(input string filename);
    integer status;
`ifdef USE_DPI_DRAM
`ifdef __ICARUS__
    status=$memory_dump(MEMORY_ID,filename,MEM_WORD_WIDTH,1,1);
`else
    status=memory_dump(MEMORY_ID,filename,MEM_WORD_WIDTH,1,1);
`endif
    if (!status) $fatal(1,"Cannot dump %s",filename);
`else
    $writememh(filename,mem);
`endif
  endtask

`ifndef __ICARUS__
  task automatic snapshotMem(ref logic [MEM_WORD_WIDTH-1:0] snapshot [longint]);
`ifdef USE_DPI_DRAM
    bit [63:0] address;
    longint word_address;
    snapshot.delete();
    for (int unsigned index=0; index<memory_address_count(MEMORY_ID); index++) begin
      memory_address_at(MEMORY_ID,index,address);
      word_address=(address / (MEM_WORD_WIDTH/8)) * (MEM_WORD_WIDTH/8);
      if (!snapshot.exists(word_address)) begin
        snapshot[word_address]=readMem(word_address);
        // Absent bytes are X, so partial words cannot falsely match stored zeros.
        for (int b=0; b<MEM_WORD_WIDTH/8; b++)
          if (!byteExists(word_address+b)) snapshot[word_address][8*b +: 8]='x;
      end
    end
`else
    snapshot=mem;
`endif
  endtask
`endif
