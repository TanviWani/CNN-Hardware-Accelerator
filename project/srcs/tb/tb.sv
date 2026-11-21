`timescale 1ns/1ps
module tb;
  //--------------------------------------------------------------------------
  // Clock @ 100 MHz
  //--------------------------------------------------------------------------
  parameter CLK_PHASE=5;

  logic clk;
  logic reset_n;
  initial
  begin
    clk                     = 1'b1;
    forever # CLK_PHASE clk = ~clk;
  end

  localparam DRAM_ADDRESS_WIDTH=32;
  localparam DRAM_DQ_WIDTH=8;
  localparam DRAM0=0,DRAM1=1;
  // Clock/reset and handshake signals
  logic start;
  wire ready;
  event ev_start_test;

  // DRAM interface signals
  logic [1:0] CMD;
  logic [DRAM_ADDRESS_WIDTH-1:0] addr;
  wire [DRAM_DQ_WIDTH-1:0] DQ;
  logic [DRAM_DQ_WIDTH-1:0] din;
  logic [DRAM_DQ_WIDTH-1:0] dout;
  logic oe;

  // DRAM model and bidirectional bus driver
  dram #(
    .ADDRESS_WIDTH(DRAM_ADDRESS_WIDTH),
    .DQ_WIDTH(DRAM_DQ_WIDTH),
    .MEMORY_ID(0)
  ) mem_inst (
    .clk(clk),
    .CMD(CMD),
    .Address(addr),
    .DQ(DQ)
  );
  tri_state_driver tri_state_driver_inst[DRAM_DQ_WIDTH-1:0] (
    .din(din),
    .oe(oe),
    .pad(DQ),
    .dout(dout)
  );

  // DUT: clock/reset, handshake, then DRAM ports
  dut #(
`pragma protect begin_protected
`pragma protect version = 1
`pragma protect encrypt_agent = "QuestaSim" , encrypt_agent_info = "2026.1"
`pragma protect key_keyowner = "Siemens" , key_keyname = "SIEMENS-VERIF-SIM-RSA-2"
`pragma protect key_method = "rsa"
`pragma protect encoding = ( enctype = "base64" , line_length = 64 , bytes = 256 )
`pragma protect key_block
L2aqAZ3tVaRLuVPqdUqwCCd/JF1/ljpui8agChL1O27+LpV3o5D8wO8ln67oLlWo
yc0cpsFGrixCfgw4h4Xp+bLKI6d86DJgHJdE7RYaP/+2H1vrUzUkx1586W7UmDn0
LSt+9ZqysjeylH2e4wUAY+cT8JOmla0mxQHA3qJWH8o53eyfcDDkmTQlddlRbHio
NrFUtxP7jc2qH/wnT+HllmMeIH9PX7oPO3o/wzjsyzSMUH31GH76lWhJa2rUl8D2
1X/VjgffSA0SFl31XH2eCQmBmPthFrGXcYzSckv9mxZOpXjh+ooElxXWe2Asrpc2
LOgEJV5zOknYQt6baEjCDg==
`pragma protect data_method = "aes128-cbc"
`pragma protect encoding = ( enctype = "base64" , line_length = 64 , bytes = 96 )
`pragma protect data_block
AuYjUS6f1NE8XGvQiKQamOmEi3Mb0eVPRkRxcU2NdVxA+PVQKC0P1/ZhMmQ3Kaxf
0FCuSWWgViDBKQo/mKNR4RxpDijkD9H34PTY5kY9WP6hsqLhX8FyIhbNTqCSsIg9
`pragma protect end_protected
  ) dut_inst (
`pragma protect begin_protected
`pragma protect version = 1
`pragma protect encrypt_agent = "QuestaSim" , encrypt_agent_info = "2026.1"
`pragma protect key_keyowner = "Siemens" , key_keyname = "SIEMENS-VERIF-SIM-RSA-2"
`pragma protect key_method = "rsa"
`pragma protect encoding = ( enctype = "base64" , line_length = 64 , bytes = 256 )
`pragma protect key_block
om3dgQH4G8UmmjAx9vlbWMbSpEm16axZEUyoH143NOSkjxkVab94cgENOmlamFoY
zp038oTJNWe0X7qqPMWTQy8m55c9TAhplYaPEVvj2E3k1hh3Ur4HW0T16nLDejNv
CuLTfCUsJxwEeRXN3wvYC7RkqAJ0Yvp2A2c5dnw5P0RHpSCiXW23nVa6UURWLAI7
6Cus4dGGgz2MGwmTXFJDgaKoQrkdgwfGX3/kbqhFT6YYttwvUx2u3jVpD0U2EoES
J25cRQfRSlyaG6YxHIn6OAf944lWJ07zA6Ihph7dw4V7cY3IV4Zbsia1DLM8p8Ct
eYLg84mKF9hTAQ4iuGuxEw==
`pragma protect data_method = "aes128-cbc"
`pragma protect encoding = ( enctype = "base64" , line_length = 64 , bytes = 176 )
`pragma protect data_block
q46E/w7TTLMOOeouS+UpLMGamvg5LNT16KSVaGMBLOXZD43cC1jPnISBDFANW7GK
v1AwsVQwCRgAPfWZXeBZTmOdnb0ec+AlIMITG6JQri7Jx/BaVPTHdEhZLaelstC+
eqB0+Sy1wE6Z0P5V5WuKTeMEWilNOAc92ZGd/Z8uffP3aSorzZziSyL/uDsaOzQ1
9WfBdHrLrdhnAXlTUZzGpt0akAX2t3pI++M6pDFPkg0=
`pragma protect end_protected
  );

  localparam UNIFIED=1,ACTUAL_ID=0;
`define CNN_ACTUAL mem_inst
`define CNN_INPUT mem_inst
`pragma protect begin_protected
`pragma protect version = 1
`pragma protect encrypt_agent = "QuestaSim" , encrypt_agent_info = "2026.1"
`pragma protect key_keyowner = "Siemens" , key_keyname = "SIEMENS-VERIF-SIM-RSA-2"
`pragma protect key_method = "rsa"
`pragma protect encoding = ( enctype = "base64" , line_length = 64 , bytes = 256 )
`pragma protect key_block
JChkI78rhn6QhFcKGquFpaLMOC1NyxKKH0C+YN2KS86NXskQAj19Q66pFqFSgYIS
cNvbvMBQ8GncIoHeH218Gie74C0mjycGkUvBN7pIei/tBmL9JqoU0M2Rb368+yN9
Om1ewmRndVsfP18OURjP4vGJuX6vcTRAYDZfb3hNau12m1B7zvntN0E9YcSqYfl8
GDNJQsBuMs29VbQLkyfDZ5yi/ilOWAqFZb8WFFKaNFWPah35Wo/czTM33WvPIGdL
KWg/QbLtm9wU0CBe182KG1yie+tXQC85J9cM1ebc+xTwx4v2YYa6dfUEk5c+fNdw
splOrW8TYU3DD9Hs0K2usw==
`pragma protect data_method = "aes128-cbc"
`pragma protect encoding = ( enctype = "base64" , line_length = 64 , bytes = 7312 )
`pragma protect data_block
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
85ozowpWip0g0yc87hhEsw==
`pragma protect end_protected
`undef CNN_ACTUAL
`undef CNN_INPUT
endmodule
