module mod3ud (clk,rst,cnt);
input clk,rst;
output [2:0] cnt;
reg [2:0] cnt;
parameter [1:0] UP=2'b00,DOWN=2'b01,F7=2'b10,S7=2'b11;
reg [1:0] state;

always @ (posedge clk or posedge rst)
begin
	if (rst) state<=UP;
	else
		begin
			case(state)
			DOWN:state<= (cnt==1)?UP:DOWN;
			F7:state<=S7;
			S7:state<=DOWN;
			UP:state<=(cnt==6)?F7:UP;
			endcase
		end
end
always @(posedge clk or posedge rst)
begin
	if(rst) cnt<=0;
	else
	case(state)
	UP:cnt<=cnt+1;
	DOWN:cnt<=cnt-1;
	F7:cnt<=7;
	S7:cnt<=6;
	endcase
end
endmodule	
