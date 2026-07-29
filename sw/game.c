// game.c — the demo cartridge: tiles on screen, a sprite you can drive with a
// SNES pad, and a tone that tracks it.
//
// Deliberately small. Its job is to prove the whole chain end to end — SD card
// to flash to XIP boot to video, audio and input — not to be a game. If this
// runs, every block in the SoC is talking to every other one.
//
// 2bpp PLANAR pattern encoding (from src/vga_fetch.sv + test/test_vengine.py):
// each tile row is TWO bytes, the first carrying bit 1 of all eight pixels and
// the second carrying bit 0, MSB = leftmost pixel. So a pixel's palette index
// is (hi >> (7-col) & 1) << 1 | (lo >> (7-col) & 1).
//
// Palette (vga_engine parameters, RGB222): 0 black, 1 red, 2 green, 3 white.
// Sprite colour 0 is transparent, which is why the ship is drawn in 3 on 0.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

#include "console.h"

#define TILE_EMPTY  0
#define TILE_WALL   1
#define TILE_CHECK  2
#define TILE_SHIP   3
#define TILE_BRICK  4

// The video engine reads this table as raw bytes over QSPI; nothing in the
// program references it by symbol, hence the section + KEEP in link.ld.
__attribute__((section(".patterns"), used))
const u8 patterns[4096] = {
    // ---- tile 0: empty (all palette 0) ----
    0x00,0x00, 0x00,0x00, 0x00,0x00, 0x00,0x00,
    0x00,0x00, 0x00,0x00, 0x00,0x00, 0x00,0x00,

    // ---- tile 1: solid red wall (index 1 = hi 0, lo 1) ----
    0x00,0xFF, 0x00,0xFF, 0x00,0xFF, 0x00,0xFF,
    0x00,0xFF, 0x00,0xFF, 0x00,0xFF, 0x00,0xFF,

    // ---- tile 2: green checker (index 2 = hi 1, lo 0) ----
    0xAA,0x00, 0x55,0x00, 0xAA,0x00, 0x55,0x00,
    0xAA,0x00, 0x55,0x00, 0xAA,0x00, 0x55,0x00,

    // ---- tile 3: the ship, white (index 3) on transparent ----
    //   ...##...
    //   ..####..
    //   .######.
    //   ########
    //   ########
    //   .######.
    //   ..####..
    //   ...##...
    0x18,0x18, 0x3C,0x3C, 0x7E,0x7E, 0xFF,0xFF,
    0xFF,0xFF, 0x7E,0x7E, 0x3C,0x3C, 0x18,0x18,

    // ---- tile 4: brick, red body with white mortar lines ----
    0xFF,0xFF, 0x00,0xFF, 0x00,0xFF, 0x00,0xFF,
    0xFF,0xFF, 0x00,0xFF, 0x00,0xFF, 0x00,0xFF,
    // the remaining 251 tiles stay zero
};

static void draw_map(void)
{
    for (int r = 0; r < TILES_H; r++) {
        for (int c = 0; c < TILES_W; c++) {
            u8 t;
            if (r == 0 || r == TILES_H - 1 || c == 0 || c == TILES_W - 1)
                t = TILE_BRICK;                       // border
            else if (((r + c) & 3) == 0)
                t = TILE_CHECK;                       // scattered texture
            else
                t = TILE_EMPTY;
            TILEMAP[r * TILES_W + c] = t;
        }
    }
}

int main(void)
{
    draw_map();

    // Sprites: one player plus three static markers, so the overlay and the
    // lowest-index-wins rule are both visible on screen.
    OAM(1) = OAM_ENTRY(1, TILE_SHIP, 16, 24);
    OAM(2) = OAM_ENTRY(1, TILE_SHIP, 16, 128);
    OAM(3) = OAM_ENTRY(1, TILE_SHIP, 96, 76);
    for (int i = 4; i < 8; i++)
        OAM(i) = 0;

    SYSCTL = VIDEO_EN;                                // QSPI stays 1-bit safe

    int x = 76, y = 56;                               // logical 160x120 space

    for (;;) {
        u32 p = PAD0();

        if ((p & BTN_LEFT)  && x > 8)   x--;
        if ((p & BTN_RIGHT) && x < 144) x++;
        if ((p & BTN_UP)    && y > 8)   y--;
        if ((p & BTN_DOWN)  && y < 104) y++;

        OAM(0) = OAM_ENTRY(1, TILE_SHIP, y, x);

        // Hold B for a tone whose pitch follows the ship. Square wave, mid
        // volume; releasing B silences the voice.
        if (p & BTN_B)
            AUDIO(0) = AUDIO_VOICE(8, 0, 200 + x * 4);
        else
            AUDIO(0) = 0;

        // Crude pacing. There is no vblank flag in sysregs, so movement speed
        // is tied to CPU speed rather than to the frame rate; a status bit
        // would be the right fix if this ever became a real game.
        for (volatile int d = 0; d < 1500; d++) { }
    }
}
