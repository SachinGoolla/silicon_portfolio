# rv32i_soc real test program -- the P3/P4 test vector for this SoC.
#
# Exercises every slave on the bus in one straight-line program (no loops
# needed beyond the final halt):
#   1. FPU:  FADD(1.0, 1.0) = 2.0 via fpu_axi_periph's register protocol
#            (write OPA/OPB/OPC/INT_OPA, CTRL last -> launches; poll
#            BUSY=1 first, then DONE=1, per fpu_axi_periph's own established
#            sequencing -- polling DONE immediately after the CTRL write can
#            observe a stale DONE=1 left over from a prior op).
#   2. RAM:  store the FPU result, read it back (round-trip through the
#            address decoder's RAM slave port).
#   3. UART: transmit one byte; the testbench loops uart_rx_i <= uart_tx_o
#            externally (matching uart_axi_periph's own TB precedent), so
#            this program also waits for RX_VALID and reads the byte back,
#            closing the loop instead of just writing a register and
#            hoping.
#   4. DECERR: deliberately touches an unmapped address (page 0x3, no
#            slave lives there) to prove the address decoder's DECERR path
#            actually propagates back through the whole composition, not
#            just in the decoder's own standalone formal proof. rv32i_lsu
#            ignores bresp_i/rresp_i by design (see its own header comment)
#            so the core is expected to keep running normally afterward.
#   5. A completion marker is stored to RAM last, so the testbench can
#            golden-check RAM[0]/RAM[1]/RAM[2] once the halt loop is
#            reached, rather than needing to trace individual instructions.
#
# Address map (ip_digital/rv32i_soc/rtl/rv32i_addr_decoder.sv):
#   0x0000_0000-0x0000_0FFF RAM  (axi_lite_slave, 256 words / 1KB used)
#   0x0000_1000-0x0000_1FFF UART (uart_axi_periph)
#   0x0000_2000-0x0000_2FFF FPU  (fpu_axi_periph)
#   0x0000_3000              unmapped -> DECERR

# ---- FPU: FADD(1.0, 1.0) = 2.0 ----
li   x5, 0x2000         # FPU_BASE
li   x6, 0x3F800000     # 1.0f
sw   x6, 4(x5)           # OPA = 1.0
sw   x6, 8(x5)           # OPB = 1.0
sw   x0, 12(x5)          # OPC = 0 (unused by FADD)
sw   x0, 16(x5)          # INT_OPA = 0 (unused by FADD)
li   x7, 0                # ctrl_word(op=OP_FADD=0, fmt=0, rm=RNE=0) = 0
sw   x7, 0(x5)              # CTRL write launches FADD

fpu_wait_busy:
lw   x8, 28(x5)              # STATUS
andi x9, x8, 1                # BUSY
beqz x9, fpu_wait_busy

fpu_wait_done:
lw   x8, 28(x5)
andi x9, x8, 2                 # DONE
beqz x9, fpu_wait_done

lw   x10, 20(x5)                # RESULT -- expect 0x40000000 (2.0f)

# ---- RAM: store the FPU result, read it back ----
li   x11, 0x0000                 # RAM_BASE
sw   x10, 0(x11)                   # RAM[word 0] = FPU result
lw   x12, 0(x11)                    # readback (unused beyond proving the path works)

# ---- UART: transmit one byte ----
li   x13, 0x1000                     # UART_BASE
uart_wait_txready:
lw   x14, 8(x13)                      # STATUS
andi x15, x14, 1                       # TX_READY
beqz x15, uart_wait_txready
li   x16, 0x41                          # 'A'
sw   x16, 0(x13)                          # TXDATA = 'A' -> transmits

# ---- UART: wait for the loopback byte, read it, stash it, pop the FIFO ----
uart_wait_rxvalid:
lw   x14, 8(x13)
andi x15, x14, 2                           # RX_VALID
beqz x15, uart_wait_rxvalid
lw   x17, 4(x13)                             # RXDATA -- expect 0x41
sw   x17, 8(x11)                               # RAM[word 2] = received byte
li   x18, 1
sw   x18, 12(x13)                                # CTRL = RX_POP

# ---- DECERR: touch an unmapped address, confirm the core keeps running ----
li   x19, 0x3000                                  # unmapped page
li   x20, 0xDEAD
sw   x20, 0(x19)                                    # store to unmapped -> SLVERR, core continues
lw   x21, 0(x19)                                     # load from unmapped -> decoder returns rdata=0

# ---- completion marker (testbench golden-checks RAM[0]/[1]/[2] once here) ----
li   x22, 0xCAFEF00D
sw   x22, 4(x11)                                       # RAM[word 1] = completion marker

halt:
j halt
