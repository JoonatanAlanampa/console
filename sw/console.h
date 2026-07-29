// console.h — the console's hardware, as C sees it.
//
// Addresses come straight from src/sysregs.sv and src/vga_fetch.sv. The MMIO
// block is a word map in the RTL, so every offset here is that word index
// times four.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

#ifndef CONSOLE_H
#define CONSOLE_H

typedef unsigned int  u32;
typedef unsigned char u8;

#define MMIO_BASE 0x01FF0000u

// OAM[0..7]  {7'b0, en, tile[8], y[8], x[8]} — x,y in logical 160x120 space
#define OAM(i)   (*(volatile u32 *)(MMIO_BASE + 0x00 + (i) * 4))
// SYSCTL     bit0 = video_en, bits2:1 = QSPI quad config (0 = safe 1-bit)
#define SYSCTL   (*(volatile u32 *)(MMIO_BASE + 0x20))
// AUDIO[0..3] {.., vol[3:0], wave[1:0], freq[15:0]}
#define AUDIO(i) (*(volatile u32 *)(MMIO_BASE + 0x40 + (i) * 4))
// PADS (read-only) {8'b0, pad1[11:0], pad0[11:0]}
#define PADS     (*(volatile u32 *)(MMIO_BASE + 0x60))

#define VIDEO_EN 1u

#define OAM_ENTRY(en, tile, y, x) \
    (((u32)(en) << 24) | ((u32)(tile) << 16) | ((u32)(y) << 8) | (u32)(x))

#define AUDIO_VOICE(vol, wave, freq) \
    (((u32)(vol) << 18) | ((u32)(wave) << 16) | (u32)(freq))

// The tile map lives in PSRAM at device offset 0x010000 (vga_fetch's
// TILEMAP_BASE); the CPU sees PSRAM based at 0x01000000.
#define TILES_W 20
#define TILES_H 15
#define TILEMAP ((volatile u8 *)0x01010000u)

// Buttons, as they arrive on ui_in. The ULX3S harness decodes a real SNES pad
// and presents the low 8 of its 12 buttons; the chip's ui pins are plain
// inputs. A, X, L and R are NOT reachable through an 8-bit input budget.
#define BTN_B      (1u << 0)
#define BTN_Y      (1u << 1)
#define BTN_SELECT (1u << 2)
#define BTN_START  (1u << 3)
#define BTN_UP     (1u << 4)
#define BTN_DOWN   (1u << 5)
#define BTN_LEFT   (1u << 6)
#define BTN_RIGHT  (1u << 7)

#define PAD0() (PADS & 0xFFFu)

#endif
