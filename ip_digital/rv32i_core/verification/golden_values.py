#!/usr/bin/env python3
"""Computes gen_test_program.py's expected final register/memory values
independently of any hand arithmetic in comments elsewhere -- same
cross-check discipline as decode_check.py, applied to program OUTPUTS
instead of instruction ENCODINGS. Prints a table meant to be pasted into
tb_rv32i_core.sv's golden-value localparams.
"""

def u32(x):
    return x & 0xFFFFFFFF

def s32(x):
    x = u32(x)
    return x - (1 << 32) if x & 0x80000000 else x

x = {0: 0}
x[1] = 0
x[2] = 5
x[3] = 7
x[4] = u32(x[2] + x[3])
x[5] = u32(x[4] - x[2])
x[6] = x[2] & x[3]
x[7] = x[2] | x[3]
x[8] = x[2] ^ x[3]
x[9] = u32(x[2] << 1)
x[10] = u32(x[4]) >> 2
x[11] = u32(-8)
x[12] = u32(s32(x[11]) >> 1)          # arithmetic shift, Python >> on negative int is already arithmetic
x[13] = 1 if s32(x[2]) < s32(x[3]) else 0
x[14] = 1 if u32(x[3]) < u32(x[2]) else 0
x[15] = 1 if s32(x[2]) < 10 else 0
x[16] = x[3] & 3
x[17] = x[2] | 8
x[18] = x[3] ^ 1
x[19] = u32(0x12345 << 12)
x[20] = 0x04c                          # AUIPC's own pc (word idx 19 * 4)
x[21] = x[4]                           # LW mem[0] == x4
x[22] = u32(x[21] + x[21])
x[23] = 99
x[25] = 0x0c4 + 4                      # JAL link = pc_of_JAL + 4
x[27] = 0x0dc + 4                      # JALR link = pc_of_JALR + 4
x[31] = 1

mem = {
    0:  x[4],
    4:  x[9],
    8:  x[6],          # halfword store, upper 16 bits of the word stay 0
    12: x[8],           # byte store, other 3 bytes of the word stay 0
    16: x[22],
    20: x[23],
    24: x[25],
    28: x[27],
    32: x[19],
    36: x[20],
    100: x[31],
}

print("-- registers --")
for r in sorted(x):
    print(f"x{r:<3d}= 0x{u32(x[r]):08X}  ({s32(x[r])})")

print("\n-- memory (byte addr: word value) --")
for a in sorted(mem):
    print(f"mem[{a:3d}] = 32'h{u32(mem[a]):08X}")
