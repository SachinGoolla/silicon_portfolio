module tb_mod3ud;
reg clk,rst;
wire [2:0] cnt;

mod3ud varanasi (.clk(clk),.rst(rst),.cnt(cnt));

initial
	begin
		clk=0;
		rst=1;
		#2;
		rst=0;
		#2000000;
		$finish;
		end
		
always #5 clk=!clk;

endmodule