//============================================================================
//  Jupiter Ace replica for MiSTer
//  Copyright (C) 2018-2019 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [45:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	output  [7:0] VIDEO_ARX,
	output  [7:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output  [1:0] VGA_SL,

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;

assign LED_USER  = ioctl_download;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

assign VIDEO_ARX = status[1] ? 8'd16 : 8'd4;
assign VIDEO_ARY = status[1] ? 8'd9  : 8'd3; 

wire [1:0] scale = status[3:2];

`include "build_id.v"
parameter CONF_STR = {
	"Jupiter;;",
	"-;",
	"F,ACE;",
	"-;",
	"O1,Aspect ratio,4:3,16:9;",
	"O23,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"-;",
	"O45,CPU Speed,Normal,x2,x4;",
	"R0,Reset;",
	"J,Fire;",
	"V,v",`BUILD_DATE
};

/////////////////  CLOCKS  ////////////////////////

wire clk_sys;

pll pll
(
	.refclk(CLK_50M),
	.outclk_0(clk_sys)
);

wire [1:0] turbo = status[5:4];

reg ce_pix;
reg ce_cpu;
always @(negedge clk_sys) begin
	reg [3:0] div;

	div <= div + 1'd1;
	ce_pix <= !div[2:0];
	ce_cpu <= (!div[3:0] && !turbo) | (!div[2:0] && turbo[0]) | turbo[1];
end

/////////////////  HPS  ///////////////////////////

wire [31:0] status;
wire  [1:0] buttons;

wire [15:0] joya, joyb;
wire [10:0] ps2_key;

wire        ioctl_download;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
reg         ioctl_wait = 0;
wire        forced_scandoubler;

hps_io #(.STRLEN($size(CONF_STR)>>3)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.conf_str(CONF_STR),

	.buttons(buttons),
	.status(status),
	.forced_scandoubler(forced_scandoubler),

	.ps2_key(ps2_key),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joya),
	.joystick_1(joyb)
);

reg [15:0] loader_addr;
reg  [7:0] loader_data;
reg        loader_wr;
reg        loader_en;
reg        loader_reset = 0;

always @(posedge clk_sys) begin
	reg [7:0] cnt = 0;
	reg [1:0] status = 0;
	reg       old_download;
	integer   timeout = 0;

	old_download <= ioctl_download;
	
	loader_reset <= 0;
	if(~old_download && ioctl_download && ioctl_index) begin
		loader_addr <= 'h2000;
		status <= 0;
		loader_reset <=1;
		ioctl_wait <= 1;
		timeout <= 3000000;
		cnt <= 0;
	end
	
	loader_wr <= 0;
	if(loader_wr) loader_addr <= loader_addr + 1'd1;

	if(ioctl_wr && ioctl_index) begin
		loader_en <= 1;
		case(status)
			0: if(ioctl_dout == 'hED) status <= 1;
				else begin
					loader_wr <= 1;
					loader_data <= ioctl_dout;
				end
			1: begin
					cnt <= ioctl_dout;
					status <= ioctl_dout ? 2'd2 : 2'd3; // cnt = 0 => stop
				end
			2: begin
					loader_data <= ioctl_dout;
					ioctl_wait <= 1;
				end
		endcase
	end

	if(ioctl_wait && !loader_wr) begin
		if(cnt) begin
			cnt <= cnt - 1'd1;
			loader_wr <= 1;
		end
		else if(timeout) timeout <= timeout - 1;
		else {status,ioctl_wait} <= 0;
	end

	if(old_download & ~ioctl_download) loader_en <= 0;
	if(reset) ioctl_wait <= 0;
end

///////////////////////////////////////////////////

wire reset = RESET | status[0] | buttons[1];

wire mic,spk;

wire [7:0] kbd_row;
wire [4:0] kbd_col;
wire       video_out;

ace ace
(
	.*,
	.clk(clk_sys),
	.no_wait(|turbo),
	.reset(reset|loader_reset)
);

keyboard keyboard (.*);

assign AUDIO_L = {1'b0, spk, mic, 13'd0};
assign AUDIO_R = AUDIO_L;
assign AUDIO_MIX = 0;
assign AUDIO_S = 0;

wire hsync, vsync, hblank, vblank;
assign CLK_VIDEO = clk_sys;
assign VGA_SL = scale ? scale - 1'd1 : 2'd0;
assign VGA_F1 = 0;

video_mixer #(280, 1) mixer
(
	.clk_vid(CLK_VIDEO),

	.ce_pix(ce_pix),
	.ce_pix_out(CE_PIXEL),

	.hq2x(scale == 1),
	.scanlines(0),
	.scandoubler(scale || forced_scandoubler),

	.R({4{video_out}}),
	.G({4{video_out}}),
	.B({4{video_out}}),

	.mono(0),

	.HSync(~hsync),
	.VSync(~vsync),
	.HBlank(hblank),
	.VBlank(vblank),

	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_VS(VGA_VS),
	.VGA_HS(VGA_HS),
	.VGA_DE(VGA_DE)
);

endmodule
