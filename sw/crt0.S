# crt0.S — C runtime zero for the console cartridge.
#
# Lifted from tt-riscv/sw/crt0.S; the memory map is the same shape (code XIP
# from flash, writable data in PSRAM) so the boot job is the same: point the
# stack at the top of PSRAM, copy the .data image from its flash LMA to its
# PSRAM VMA, zero .bss, enter main. The flash image alone therefore boots the
# machine with no loader involved — which is exactly what the sd_loader writes.
#
# RV32E: the core has 16 registers (NREGS=16), so only x0..x15 may be touched.
    .section .text.init
    .globl _start
_start:
    li   sp, 0x01800000        # top of 8 MB PSRAM, grows down
    la   a0, __data_load       # copy .data image: flash -> PSRAM
    la   a1, __data_start
    la   a2, __data_end
1:  bgeu a1, a2, 2f
    lw   t0, 0(a0)
    sw   t0, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    j    1b
2:  la   a0, __bss_start       # zero .bss — C assumes it
    la   a1, __bss_end
3:  bgeu a0, a1, 4f
    sw   zero, 0(a0)
    addi a0, a0, 4
    j    3b
4:  call main
    ecall                      # a game never returns; if it does, halt
