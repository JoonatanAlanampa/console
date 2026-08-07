// mario.c — a one-stage platformer in the spirit of Super Mario Bros. (1985).
//
// An original homage, not a port: the artwork is drawn from scratch in
// sw/mkart.py against this console's four-colour palette, the level is laid out
// below, and the sounds are original. What is borrowed is the GRAMMAR — run,
// jump, stomp, head-bump the blocks, mind the pits, reach the flag — which is
// what makes it recognisable.
//
// WHAT THE HARDWARE GIVES YOU, AND WHAT IT DOES NOT
// -------------------------------------------------
// 20x15 tiles of 8x8 = 160x120 logical pixels, scaled 4x to 640x480. Eight 8x8
// sprites, colour 0 transparent, sprite 0 on top. Four colours for everything.
//
//  * NO SCROLL REGISTER. The video engine reads a 20x15 map and nothing offsets
//    it, so the camera can only move in whole tiles: the world steps 8 logical
//    pixels at a time while Mario himself moves smoothly, because he is a
//    sprite with 1-pixel placement. Scrolling therefore means rewriting the
//    tile map, which is why blit() exists and why it only runs when something
//    actually changed.
//  * NO VBLANK FLAG. Nothing in sysregs reports the raster, so the frame rate
//    is whatever the loop takes plus FRAME_DELAY. Every constant below is
//    therefore in units of "one pass of the loop", not seconds.
//  * NO MULTIPLY. The core is RV32E with no M extension, so multiplies become
//    libgcc calls. LEVEL_W is a power of two so level[r][c] is a shift, and the
//    fixed-point maths uses shifts throughout.
//
// Fixed point: positions and velocities are in 1/16 logical pixels (FP = 4).
// At 8 pixels per tile a full tile is 128 units, and MAX_FALL is capped well
// under that so nothing can tunnel through a floor in one step.
//
// ===========================================================================
// 🅿️ PARKED 2026-08-07 (user), PLAYTESTED ON HARDWARE FIRST. WHAT IS WRONG,
// AND WHAT TO CHANGE. Read this before touching anything below.
// ===========================================================================
//
// It runs, it draws, it scrolls, the goombas walk and the sounds fire. Three
// faults were seen on the monitor, and they are ONE BUG:
//
//   * Mario is drawn in the jump pose while walking ("walking on air").
//   * He jitters vertically by a pixel while standing.
//   * Jumps are dropped most of the time, so the end staircase cannot be
//     climbed and the flagpole is unreachable -- the level appears to just
//     stop with Mario unable to go forward.
//
// ROOT CAUSE: on_ground is only true on the frame the sub-pixel fall crosses a
// tile boundary. Standing still, gravity adds GRAV = 2/16 px per frame, which
// does not change py = my >> FP for several frames, so solid(px, py + 7) is
// false and move_mario() leaves on_ground = 0. It becomes true for exactly one
// frame in eight, and BTN jump is only honoured on that frame.
//
// THE FIX (do this first, it is the whole thing):
//   - Set on_ground from the tile DIRECTLY BENEATH the feet, independently of
//     vy and of whether a landing happened this frame:
//         on_ground = solid(px, py + 8) || solid(px + 7, py + 8);
//     evaluated after the vertical move, with my snapped to the tile top when
//     it is true and vy > 0.
//   - Snap my to (py & ~7) << FP on landing so the resting position is exact
//     and the jitter disappears.
//   - Consider a one-frame jump buffer (remember the press, consume it on the
//     next grounded frame) -- standard, and cheap insurance.
//
// CONTROLS TO CHANGE (user, 2026-08-07):
//   UP    = jump      (currently BTN_Y / FIRE2 -- move it to BTN_UP)
//   DOWN  = crouch    (not implemented at all yet)
//   B1    = run       (already correct, BTN_B)
//   B2    = punch / throw a fireball. RESERVED, deliberately unused for now:
//           it is for a future power-up taken from a '?' block, which is why
//           bump() already distinguishes T_QBLOCK from T_BRICK.
//
// Note BTN_UP is currently free and BTN_Y is not, so this is a small edit in
// move_mario() plus a crouch state that shrinks the hitbox and swaps the tile.
//
// ⚠ The controls above are the ULX3S buttons via fpga/ulx3s_top.sv's
// BTN_ONBOARD mapping; nothing in the chip changes.
// ===========================================================================
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

#include "console.h"

// ---------------------------------------------------------------- tile ids
// Must match the ORDER list in sw/mkart.py.
#define T_EMPTY   0
#define T_GROUND  1
#define T_GFILL   2
#define T_BRICK   3
#define T_QBLOCK  4
#define T_USED    5
#define T_PIPETL  6
#define T_PIPETR  7
#define T_PIPEBL  8
#define T_PIPEBR  9
#define T_CLOUDL 10
#define T_CLOUDR 11
#define T_BUSH   12
#define T_HILL   13
#define T_STONE  14
#define T_COIN   15
#define T_POLE   16
#define T_FLAG   17

#define S_STAND  32
#define S_WALK1  33
#define S_WALK2  34
#define S_JUMP   35
#define S_GOOMBA1 36
#define S_GOOMBA2 37
#define S_GOOMBA_FLAT 38

// The video engine reads this table as raw bytes over QSPI; nothing in the
// program references it by symbol, hence the section + KEEP in link.ld.
__attribute__((section(".patterns"), used))
const u8 patterns[4096] = {
#include "patterns.inc"
};

// ------------------------------------------------------------------- level
#define LEVEL_W 128           // power of two: level[r][c] indexes with a shift

// Laid out in eight chunks of sixteen columns so the geometry can be counted
// rather than guessed. Legend:
//   space empty   G ground   g fill    B brick   ? question   S stone
//   [ ] pipe top  { } pipe body        c C cloud b bush  h hill
//   o coin        P flagpole           F flag
// A 2D array, NOT an array of pointers: this way a row that is not exactly
// LEVEL_W characters is a compile error ("initializer-string too long") rather
// than a run past the end of a short string, which would show up as random
// tiles somewhere far away and be blamed on the tile map code.
static const char level_src[TILES_H][LEVEL_W + 1] = {
/* 0*/ "                " "                " "                " "                "
       "                " "                " "                " "                ",
/* 1*/ "                " "                " "                " "                "
       "                " "                " "                " "                ",
/* 2*/ "        cC      " "                " "  cC            " "            cC  "
       "                " "          cC    " "                " "      cC        ",
/* 3*/ "                " "                " "                " "                "
       "                " "                " "                " "                ",
/* 4*/ "                " "                " "                " "                "
       "                " "                " "                " "                ",
/* 5*/ "                " "                " "                " "                "
       "            BBBB" "                " "                " "  F             ",
/* 6*/ "                " "                " "                " "                "
       "                " "                " "                " "  P             ",
/* 7*/ "                " "                " "                " "                "
       "                " "                " "                " "  P             ",
/* 8*/ "                " "    o o o       " "                " "                "
       "            o o " "                " "                " "  P             ",
/* 9*/ "                " "    ?B?B?       " "              []" "         []   BB"
       "BBB         B?B?" "                " "         SS     " "  P             ",
/*10*/ "                " "                " "      []      {}" "         {}     "
       "                " "                " "        SSSS    " "  P             ",
/*11*/ "                " "            []  " " ooo  {}      {}" "         {}     "
       "                " "                " "       SSSSSS   " "  P             ",
/*12*/ "      b     h   " "            {}  " "      {}      {}" "         {}     "
       "          b     " "    b           " "      SSSSSSSS  " "  P     b       ",
/*13*/ "GGGGGGGGGGGGGGGG" "GGGGGGGGGGGGGGGG" "GGGGGGGGGGGGGGGG" "GGGGGGGGGGGGGGGG"
       "GGGG   GGGGGGGGG" "GGGGGGGGGGGGGGGG" "   GGGGGGGGGGGGG" "GGGGGGGGGGGGGGGG",
/*14*/ "gggggggggggggggg" "gggggggggggggggg" "gggggggggggggggg" "gggggggggggggggg"
       "gggg   ggggggggg" "gggggggggggggggg" "   ggggggggggggg" "gggggggggggggggg",
};

// The mutable copy. In .bss, so it costs nothing in the cartridge image and is
// zeroed by crt0; blocks that get hit and coins that get taken are written here.
static u8 level[TILES_H][LEVEL_W];

static u8 tile_of(char c)
{
    switch (c) {
    case 'G': return T_GROUND;
    case 'g': return T_GFILL;
    case 'B': return T_BRICK;
    case '?': return T_QBLOCK;
    case 'S': return T_STONE;
    case '[': return T_PIPETL;
    case ']': return T_PIPETR;
    case '{': return T_PIPEBL;
    case '}': return T_PIPEBR;
    case 'c': return T_CLOUDL;
    case 'C': return T_CLOUDR;
    case 'b': return T_BUSH;
    case 'h': return T_HILL;
    case 'o': return T_COIN;
    case 'P': return T_POLE;
    case 'F': return T_FLAG;
    default:  return T_EMPTY;
    }
}

// ------------------------------------------------------------------ physics
#define FP        4                  // fixed-point fraction bits (1/16 pixel)
#define GRAV      2
#define JUMP_V  (-45)                // v^2/2g = 506/16 = ~32 px, i.e. four tiles
#define MAX_FALL  48                 // 3 px/frame, far under a tile: no tunnelling
#define WALK_MAX  12
#define RUN_MAX   22
#define ACCEL     2
#define FRICTION  1
#define BOUNCE  (-30)                // the little hop after stomping a goomba

#define MARIO_START_X (2 * 8)
#define MARIO_START_Y (12 * 8)

// How long one pass of the main loop is padded by. There is no vblank to wait
// on, so this is the only pacing there is; raise it if the game runs fast.
#define FRAME_DELAY 900

static int mx, my, vx, vy;           // 1/16 px
static int on_ground, facing, anim;
static int cam_tx, cam_dirty;
static int dead_timer, win_timer;

#define NGOOMBA 4
static struct {
    int x, y, vx;
    int alive, flat;
} gmb[NGOOMBA];

// Where the goombas start, in tiles. Kept short deliberately: eight sprites
// exist and Mario owns one, but more than a few on screen at once is not the
// bottleneck here -- the tile-map rewrite is.
static const u8 gmb_start[NGOOMBA][2] = {
    { 34, 12 }, { 52, 12 }, { 80, 12 }, { 92, 12 },
};

static int solid(int px, int py)
{
    int tx, ty;
    u8 t;

    if (py < 0)
        return 0;                    // above the ceiling is open sky
    tx = px >> 3;
    ty = py >> 3;
    if (tx < 0 || tx >= LEVEL_W || ty >= TILES_H)
        return 0;                    // off the sides / below is a pit, not a wall
    t = level[ty][tx];
    return t == T_GROUND || t == T_GFILL || t == T_BRICK || t == T_QBLOCK ||
           t == T_USED || t == T_STONE ||
           (t >= T_PIPETL && t <= T_PIPEBR);
}

// ------------------------------------------------------------------- sound
// freq is a phase increment on a 16-bit accumulator sampled at ~48.8 kHz
// (src/audio.sv), so a note in hertz is hz * 65536 / 48828 = hz * 1.342. The
// multiply is on a literal, so the compiler folds it -- there is no hardware
// multiplier on this core.
#define NOTE(hz) ((hz) * 1342u / 1000u)

static int sfx_timer;

static void sfx(unsigned freq, int wave, int frames)
{
    AUDIO(0) = AUDIO_VOICE(9, wave, freq);
    sfx_timer = frames;
}

static void sfx_tick(void)
{
    if (sfx_timer > 0 && --sfx_timer == 0)
        AUDIO(0) = 0;
}

// ------------------------------------------------------------------- screen
// Copy the 20x15 window at cam_tx into the hardware tile map. Written as u32
// stores because every byte store is a whole QSPI transaction: 20 is divisible
// by four and each row starts 4-byte aligned, so this is 75 transactions per
// refresh instead of 300.
static void blit(void)
{
    int r, c;

    for (r = 0; r < TILES_H; r++) {
        const u8 *src = &level[r][cam_tx];
        volatile u32 *dst = (volatile u32 *)&TILEMAP[r * TILES_W];

        for (c = 0; c < TILES_W; c += 4)
            dst[c >> 2] = (u32)src[c] | ((u32)src[c + 1] << 8) |
                          ((u32)src[c + 2] << 16) | ((u32)src[c + 3] << 24);
    }
    cam_dirty = 0;
}

static void reset_stage(void)
{
    int r, c, i;

    for (r = 0; r < TILES_H; r++)
        for (c = 0; c < LEVEL_W; c++)
            level[r][c] = tile_of(level_src[r][c]);

    mx = MARIO_START_X << FP;
    my = MARIO_START_Y << FP;
    vx = vy = 0;
    on_ground = 1;
    facing = 1;
    anim = 0;
    cam_tx = 0;
    dead_timer = 0;
    win_timer = 0;

    for (i = 0; i < NGOOMBA; i++) {
        gmb[i].x = (gmb_start[i][0] * 8) << FP;
        gmb[i].y = (gmb_start[i][1] * 8) << FP;
        gmb[i].vx = -5;
        gmb[i].alive = 1;
        gmb[i].flat = 0;
    }

    AUDIO(0) = 0;
    AUDIO(1) = 0;
    sfx_timer = 0;
    cam_dirty = 1;
}

// A block took a hit from below. Question blocks turn used and pay out a
// sound; bricks only shudder, because this Mario is the small one.
static void bump(int px, int py)
{
    int tx = px >> 3, ty = py >> 3;

    if (tx < 0 || tx >= LEVEL_W || ty < 0 || ty >= TILES_H)
        return;
    if (level[ty][tx] == T_QBLOCK) {
        level[ty][tx] = T_USED;
        cam_dirty = 1;
        sfx(NOTE(1047), 0, 6);
    }
}

// Coins are tiles rather than sprites: there are only eight sprites and the
// goombas want them. Anything Mario's box overlaps is collected.
static void take_coins(void)
{
    int px = mx >> FP, py = my >> FP;
    int tx, ty;

    for (ty = py >> 3; ty <= (py + 7) >> 3; ty++) {
        if (ty < 0 || ty >= TILES_H)
            continue;
        for (tx = px >> 3; tx <= (px + 7) >> 3; tx++) {
            if (tx < 0 || tx >= LEVEL_W)
                continue;
            if (level[ty][tx] == T_COIN) {
                level[ty][tx] = T_EMPTY;
                cam_dirty = 1;
                sfx(NOTE(1568), 1, 5);
            } else if (level[ty][tx] == T_POLE || level[ty][tx] == T_FLAG) {
                if (!win_timer)
                    win_timer = 90;
            }
        }
    }
}

static void move_mario(u32 pad)
{
    int px, py, top;
    int want = (pad & BTN_B) ? RUN_MAX : WALK_MAX;

    // ---- horizontal intent
    if (pad & BTN_LEFT) {
        vx -= ACCEL;
        if (vx < -want)
            vx = -want;
        facing = -1;
    } else if (pad & BTN_RIGHT) {
        vx += ACCEL;
        if (vx > want)
            vx = want;
        facing = 1;
    } else {
        if (vx > 0)
            vx = (vx > FRICTION) ? vx - FRICTION : 0;
        else if (vx < 0)
            vx = (vx < -FRICTION) ? vx + FRICTION : 0;
    }

    // ---- horizontal move, then push out of whatever we entered
    mx += vx;
    px = mx >> FP;
    py = my >> FP;
    if (px < 0) {
        px = 0;
        mx = 0;
        vx = 0;
    }
    if (vx > 0 && (solid(px + 7, py) || solid(px + 7, py + 7))) {
        px = ((px + 7) & ~7) - 8;
        mx = px << FP;
        vx = 0;
    } else if (vx < 0 && (solid(px, py) || solid(px, py + 7))) {
        px = (px & ~7) + 8;
        mx = px << FP;
        vx = 0;
    }

    // ---- jump
    if ((pad & BTN_Y) && on_ground) {
        vy = JUMP_V;
        on_ground = 0;
        sfx(NOTE(392), 1, 8);
    }

    // ---- vertical
    vy += GRAV;
    if (vy > MAX_FALL)
        vy = MAX_FALL;
    my += vy;
    px = mx >> FP;
    py = my >> FP;
    on_ground = 0;

    if (vy > 0 && (solid(px, py + 7) || solid(px + 7, py + 7))) {
        py = ((py + 7) & ~7) - 8;
        my = py << FP;
        vy = 0;
        on_ground = 1;
    } else if (vy < 0) {
        top = py;
        if (solid(px, top) || solid(px + 7, top)) {
            bump(px, top);
            bump(px + 7, top);
            py = (top & ~7) + 8;
            my = py << FP;
            vy = 0;
        }
    }

    // ---- fell down a pit
    if ((my >> FP) > TILES_H * 8)
        dead_timer = 45;

    take_coins();

    if (vx > 1 || vx < -1)
        anim++;
}

static void move_goombas(void)
{
    int i, px, py, mpx, mpy;

    mpx = mx >> FP;
    mpy = my >> FP;

    for (i = 0; i < NGOOMBA; i++) {
        if (!gmb[i].alive)
            continue;

        if (gmb[i].flat) {
            if (--gmb[i].flat == 0)
                gmb[i].alive = 0;
            continue;
        }

        gmb[i].x += gmb[i].vx;
        px = gmb[i].x >> FP;
        py = gmb[i].y >> FP;

        // Turn at a wall, and at the edge of a ledge so they stay on their
        // platform. The ledge test only applies while standing on something --
        // a goomba already falling into a pit has no ground under either foot,
        // and would otherwise flip direction every frame on the way down.
        {
            int grounded = solid(px, py + 8) || solid(px + 7, py + 8);

            if (gmb[i].vx < 0) {
                if (solid(px, py) || solid(px, py + 7) ||
                    (grounded && !solid(px, py + 8))) {
                    px = (px & ~7) + 8;
                    gmb[i].x = px << FP;
                    gmb[i].vx = -gmb[i].vx;
                }
            } else {
                if (solid(px + 7, py) || solid(px + 7, py + 7) ||
                    (grounded && !solid(px + 7, py + 8))) {
                    px = ((px + 7) & ~7) - 8;
                    gmb[i].x = px << FP;
                    gmb[i].vx = -gmb[i].vx;
                }
            }
        }

        // gravity, so a goomba walked off a pit edge falls out of the world
        gmb[i].y += MAX_FALL / 3;
        py = gmb[i].y >> FP;
        if (solid(px, py + 7) || solid(px + 7, py + 7)) {
            py = ((py + 7) & ~7) - 8;
            gmb[i].y = py << FP;
        }
        if (py > TILES_H * 8) {
            gmb[i].alive = 0;
            continue;
        }

        // ---- Mario vs goomba, as boxes
        if (mpx + 7 >= px && mpx <= px + 7 && mpy + 7 >= py && mpy <= py + 7) {
            // Coming down onto the top half is a stomp; anything else hurts.
            if (vy > 0 && (mpy + 7) <= py + 4) {
                gmb[i].flat = 20;
                vy = BOUNCE;
                my = (py - 8) << FP;
                sfx(NOTE(196), 2, 6);
            } else if (!win_timer) {
                dead_timer = 45;
            }
        }
    }
}

static void draw(void)
{
    int i, px, py, sx, sy, tile;

    // Camera: keep Mario about nine tiles from the left, clamped to the level.
    // Whole tiles only -- there is no fine scroll register.
    px = mx >> FP;
    i = (px >> 3) - 9;
    if (i < 0)
        i = 0;
    if (i > LEVEL_W - TILES_W)
        i = LEVEL_W - TILES_W;
    if (i != cam_tx) {
        cam_tx = i;
        cam_dirty = 1;
    }

    if (cam_dirty)
        blit();

    // ---- Mario is sprite 0, so he draws over everything
    py = my >> FP;
    sx = px - (cam_tx << 3);
    sy = py;
    if (!on_ground)
        tile = S_JUMP;
    else if (vx > 1 || vx < -1)
        tile = (anim & 4) ? S_WALK1 : S_WALK2;
    else
        tile = S_STAND;

    if (sx < 0 || sx > 159 || sy < 0 || sy > 119)
        OAM(0) = 0;
    else
        OAM(0) = OAM_ENTRY(1, tile, sy, sx);

    // ---- goombas take sprites 1..4
    for (i = 0; i < NGOOMBA; i++) {
        if (!gmb[i].alive) {
            OAM(1 + i) = 0;
            continue;
        }
        sx = (gmb[i].x >> FP) - (cam_tx << 3);
        sy = gmb[i].y >> FP;
        if (sx < 0 || sx > 159 || sy < 0 || sy > 119) {
            OAM(1 + i) = 0;
            continue;
        }
        tile = gmb[i].flat ? S_GOOMBA_FLAT
                           : ((anim & 8) ? S_GOOMBA1 : S_GOOMBA2);
        OAM(1 + i) = OAM_ENTRY(1, tile, sy, sx);
    }

    for (i = NGOOMBA + 1; i < 8; i++)
        OAM(i) = 0;
}

int main(void)
{
    u32 pad;
    volatile int d;
    int i;

    reset_stage();
    SYSCTL = VIDEO_EN;                       // QSPI stays 1-bit safe
    blit();

    for (;;) {
        pad = PAD0();

        if (dead_timer) {
            // A short fall-and-freeze, then back to the start of the stage.
            if (dead_timer == 45)
                sfx(NOTE(147), 1, 30);
            my += 24;
            OAM(0) = OAM_ENTRY(1, S_JUMP, (my >> FP) & 0xFF,
                               ((mx >> FP) - (cam_tx << 3)) & 0xFF);
            if (--dead_timer == 0)
                reset_stage();
        } else if (win_timer) {
            // Slide down the pole, then a short original fanfare.
            if (win_timer == 90)
                sfx(NOTE(523), 1, 10);
            else if (win_timer == 70)
                sfx(NOTE(659), 1, 10);
            else if (win_timer == 50)
                sfx(NOTE(784), 1, 10);
            else if (win_timer == 30)
                sfx(NOTE(1047), 1, 25);
            if ((my >> FP) < 12 * 8)
                my += 16;
            vx = 0;
            draw();
            if (--win_timer == 0)
                reset_stage();
        } else {
            move_mario(pad);
            move_goombas();
            draw();
        }

        sfx_tick();

        // The only frame pacing there is: no vblank flag exists to wait on.
        for (i = 0; i < FRAME_DELAY; i++)
            d = i;
        (void)d;
    }
}
