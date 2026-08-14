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
#   4. MAC:   loads a 4x4 diagonal weight matrix W=5*I into mac_tile_axi via
#            its AXI4-Lite register sequence, then pushes TWO activation
#            vectors, A1=[1,2,3,4] then A2=[6,7,8,9], through the CPU-
#            facing MMIO push/pop bridge (DATA_IN/RESULT0-3) -- this SoC
#            has no AXI4-Stream master anywhere, so the MMIO bridge is the
#            only path the CPU has to drive the tile (see mac_tile_axi.sv's
#            own header). Since W=5*I, Y=5*A exactly, so RESULT0 (Y[0])
#            must read 5 then 30 -- small, hand-verifiable values that
#            still exercise the full register sequence (mode select,
#            weight load + poll, DATA_IN push, poll, RESULT0 read), same
#            "isolate every element individually" discipline as the tile's
#            own standalone identity-probe test. The SECOND push (with an
#            explicit CTRL.RESULT_ACK between them) is a regression for a
#            real one-shot MMIO deadlock bug found by adversarial review --
#            see the MAC section below for the full incident. The array's
#            real pipelined multi-vector throughput is already proven by
#            the tile's own standalone P3/P4 harness; this only proves the
#            SoC-level MMIO wiring and address-decoder routing to the tile.
#   5. CLUSTER: loads tile0's W=5*I via mac_cluster's own internal CSR page
#            (same convention as the MAC section above), then pushes ONE
#            activation through tile0's NI CPU-entry path with
#            mesh_egress_en left at its reset default (0 -- CPU-exit
#            capture mode), so the result comes straight back out the
#            SAME tile's own m_axis into the NI's exit_result_q with no
#            mesh hop needed for this smoke test. This only proves the
#            SoC-level address-decoder routing to the new CLUSTER page and
#            the NI's CPU-entry/exit CSR wiring -- mac_cluster's own
#            standalone P3/P4 harness already proves real multi-tile mesh
#            routing and the exit_seq discriminator (NI_STATUS bit3,
#            REQUIRED reading once a tile has consumed a prior result --
#            see mac_cluster.sv's own header comment and REPORT.md for the
#            real stale-read race this was added to close). Not checked
#            here: this is tile0's FIRST-EVER exit capture since reset, so
#            its post-capture exit_seq_q value is unambiguously non-zero --
#            no prior consumed result exists to produce a stale echo. A
#            program pushing a SECOND result through the same tile would
#            need the same reject-stale-seq discipline
#            test_mac_cluster.py/tb_mac_cluster.sv both implement.
#   6. DECERR: deliberately touches an unmapped address (page 0x5, no
#            slave lives there) to prove the address decoder's DECERR path
#            actually propagates back through the whole composition, not
#            just in the decoder's own standalone formal proof. rv32i_lsu
#            ignores bresp_i/rresp_i by design (see its own header comment)
#            so the core is expected to keep running normally afterward.
#            Moved from page 0x4 (Phase 2's own probe address) to page 0x5
#            this phase -- 0x4 is now the real CLUSTER page.
#   7. A completion marker is stored to RAM last, so the testbench can
#            golden-check RAM[0]-RAM[5] once the halt loop is reached,
#            rather than needing to trace individual instructions.
#
# Address map (ip_digital/rv32i_soc/rtl/rv32i_addr_decoder.sv):
#   0x0000_0000-0x0000_0FFF RAM     (axi_lite_slave, 256 words / 1KB used)
#   0x0000_1000-0x0000_1FFF UART    (uart_axi_periph)
#   0x0000_2000-0x0000_2FFF FPU     (fpu_axi_periph)
#   0x0000_3000-0x0000_3FFF MAC     (mac_tile_axi)
#   0x0000_4000-0x0000_47FF CLUSTER (mac_cluster, own internal 5-way sub-decode)
#   0x0000_5000              unmapped -> DECERR

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

# ---- MAC: load W=5*I, push A=[1,2,3,4] via MMIO, read RESULT0 (expect 5) ----
li   x23, 0x3000                                     # MAC_BASE
li   x24, 0x4                                          # CTRL.INPUT_SRC_MMIO (bit2)
sw   x24, 0(x23)                                        # select MMIO mode (no weight load yet)

# W = 5*I packed {w3,w2,w1,w0} per row (same byte-per-element convention
# as mac_tile_axi's own standalone TB/cocotb harness).
li   x25, 0x00000005
sw   x25, 8(x23)                                        # WEIGHT_ROW0 = [5,0,0,0]
li   x25, 0x00000500
sw   x25, 12(x23)                                       # WEIGHT_ROW1 = [0,5,0,0]
li   x25, 0x00050000
sw   x25, 16(x23)                                       # WEIGHT_ROW2 = [0,0,5,0]
li   x25, 0x05000000
sw   x25, 20(x23)                                       # WEIGHT_ROW3 = [0,0,0,5]

li   x24, 0x5                                          # LOAD_WEIGHTS(bit0) | INPUT_SRC_MMIO(bit2)
sw   x24, 0(x23)                                        # CTRL: pulse LOAD_WEIGHTS

mac_wait_loaded:
lw   x26, 4(x23)                                        # STATUS
andi x27, x26, 1                                        # WEIGHTS_LOADED
beqz x27, mac_wait_loaded

li   x24, 0x6                                          # TLAST_NEXT(bit1) | INPUT_SRC_MMIO(bit2)
sw   x24, 0(x23)                                        # CTRL: arm TLAST_NEXT for the next DATA_IN write
li   x28, 0x04030201                                    # A = {a3=4,a2=3,a1=2,a0=1}
sw   x28, 24(x23)                                       # DATA_IN -- pushes one s_axis-equivalent beat

mac_wait_result:
lw   x26, 4(x23)
andi x27, x26, 4                                        # RESULT_VALID (bit2)
beqz x27, mac_wait_result

lw   x29, 28(x23)                                       # RESULT0 -- expect 5 (Y=5*A, Y[0]=5*1)
sw   x29, 12(x11)                                       # RAM[word 3] = MAC RESULT0

# ---- MAC: RESULT_ACK + a SECOND push, regression for a real one-shot MMIO
# deadlock bug found by adversarial review (see mac_tile_axi.sv's own
# header comment for the full incident): the tile's MMIO bridge could
# originally accept exactly one push per reset, ever -- STATUS.INPUT_BUSY
# would latch high permanently on any second operation with no software-
# visible way to clear it. Fixed with an explicit CTRL.RESULT_ACK bit
# (bit3). Exercising a second push here, at the SoC level and not just in
# mac_tile_axi's own standalone regression test, proves the fix holds
# through the real address-decoder/MMIO-bridge path software would
# actually use.
li   x24, 0xC                                          # RESULT_ACK(bit3) | INPUT_SRC_MMIO(bit2)
sw   x24, 0(x23)                                        # CTRL: ack the first result

li   x24, 0x6                                          # TLAST_NEXT(bit1) | INPUT_SRC_MMIO(bit2)
sw   x24, 0(x23)                                        # CTRL: arm TLAST_NEXT for the second push
li   x30, 0x09080706                                    # A2 = {a3=9,a2=8,a1=7,a0=6}
sw   x30, 24(x23)                                       # DATA_IN -- second push (would hang forever pre-fix)

mac_wait_result2:
lw   x26, 4(x23)
andi x27, x26, 4                                        # RESULT_VALID (bit2)
beqz x27, mac_wait_result2

lw   x31, 28(x23)                                       # RESULT0 -- expect 30 (Y2=5*A2, Y2[0]=5*6)
sw   x31, 16(x11)                                       # RAM[word 4] = second MAC RESULT0

# ---- CLUSTER: load tile0's W=5*I, push A=[1,2,3,4] via the NI's CPU-entry
# path, read the result straight back out CPU-exit capture (no mesh hop) ----
li   x5, 0x4000                                        # CLUSTER_BASE (tile0's own CTRL page)
li   x6, 0x00000005
sw   x6, 8(x5)                                          # tile0 WEIGHT_ROW0 = [5,0,0,0]
li   x6, 0x00000500
sw   x6, 12(x5)                                         # tile0 WEIGHT_ROW1 = [0,5,0,0]
li   x6, 0x00050000
sw   x6, 16(x5)                                         # tile0 WEIGHT_ROW2 = [0,0,5,0]
li   x6, 0x05000000
sw   x6, 20(x5)                                         # tile0 WEIGHT_ROW3 = [0,0,0,5]
li   x7, 1
sw   x7, 0(x5)                                          # tile0 CTRL: pulse LOAD_WEIGHTS

cluster_wait_loaded:
lw   x8, 4(x5)                                          # tile0 STATUS
andi x9, x8, 1                                          # WEIGHTS_LOADED
beqz x9, cluster_wait_loaded

li   x5, 0x4400                                         # CLUSTER_BASE + NI-CSR page, tile0's own regs
li   x10, 0x04030201                                    # A = {a3=4,a2=3,a1=2,a0=1}
sw   x10, 12(x5)                                        # tile0 NI_ENTRY_DATA
li   x7, 0x3                                            # ENTRY_PUSH(bit0) | TLAST_NEXT(bit1)
sw   x7, 0(x5)                                          # tile0 NI_CTRL: push

cluster_wait_entry:
lw   x8, 4(x5)                                          # tile0 NI_STATUS
andi x9, x8, 1                                          # ENTRY_BUSY
bnez x9, cluster_wait_entry

cluster_wait_exit:
lw   x8, 4(x5)
andi x9, x8, 2                                          # EXIT_VALID
beqz x9, cluster_wait_exit

lw   x10, 16(x5)                                        # tile0 NI_EXIT_RESULT0 -- expect 5
sw   x10, 20(x11)                                       # RAM[word 5] = CLUSTER RESULT0
li   x7, 0x8                                            # EXIT_ACK(bit3)
sw   x7, 0(x5)                                          # tile0 NI_CTRL: ack

# ---- DECERR: touch an unmapped address, confirm the core keeps running ----
li   x19, 0x5000                                  # unmapped page (moved from 0x4000 -- CLUSTER lives there now)
li   x20, 0xDEAD
sw   x20, 0(x19)                                    # store to unmapped -> SLVERR, core continues
lw   x21, 0(x19)                                     # load from unmapped -> decoder returns rdata=0

# ---- completion marker (testbench golden-checks RAM[0]-[5] once here) ----
li   x22, 0xCAFEF00D
sw   x22, 4(x11)                                       # RAM[word 1] = completion marker

halt:
j halt
