/* link.ld — console cartridge memory map.
 *
 * The flash layout is not free: `console_soc`'s PATTERN_BASE parameter tells
 * the video engine that tile patterns live at flash 0x8000, and the CPU boots
 * by XIP from flash 0. Those two facts pin everything below, and the ASSERTs
 * at the bottom are what stop a growing program from silently overrunning the
 * tile table and turning the screen to noise.
 *
 *   0x0000_0000..0x0000_7FFF  .text + .rodata      code, XIP from flash
 *   0x0000_8000..0x0000_8FFF  .patterns            256 tiles x 16 B, 2bpp
 *   0x0000_9000..0x0000_FFFF  .data load image     copied to PSRAM by crt0
 *   0x0001_0000               (the core's own MMIO carve-out begins)
 *
 *   0x0100_0000..0x0100_FFFF  .data + .bss         PSRAM, below the tile map
 *   0x0101_0000               TILEMAP_BASE         20x15 map, written by the game
 *   0x0180_0000               top of PSRAM         stack grows down from here
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 32K
  PATT  (r)   : ORIGIN = 0x00008000, LENGTH = 4K
  LOAD  (r)   : ORIGIN = 0x00009000, LENGTH = 28K
  RAM   (rwx) : ORIGIN = 0x01000000, LENGTH = 8M
}

SECTIONS
{
  .text : { *(.text.init) *(.text*) } > FLASH
  .rodata : { *(.rodata*) *(.srodata*) } > FLASH

  /* KEEP: nothing references this by symbol — the video engine reads it as
   * raw bytes over QSPI — so --gc-sections would otherwise drop it. */
  .patterns : { KEEP(*(.patterns)) } > PATT

  .data : {
    . = ALIGN(4);
    __data_start = .;
    *(.data*) *(.sdata*)
    . = ALIGN(4);
    __data_end = .;
  } > RAM AT> LOAD
  __data_load = LOADADDR(.data);

  .bss : {
    . = ALIGN(4);
    __bss_start = .;
    *(.bss*) *(.sbss*) *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM
}

ASSERT(__bss_end <= 0x01010000,
  "data+bss reach the tile map at PSRAM 0x010000 — shrink them or move TILEMAP_BASE")
