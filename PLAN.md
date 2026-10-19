# Streetbike — Development Plan

## 1. Goal

Replace the asteroid-dodge game with a side-scrolling bike game called
**Streetbike**.

- The player rides a bike from left to right.
- The street and all obstacles enter from the right and move towards the
  player.
- Joystick up/down/left/right moves the bike.
- The fire button jumps.
- Touching an obstacle costs one life. The player starts with three lives.
- Surviving earns points over time; jumping over an obstacle earns bonus
  points.
- The game gets faster and spawns obstacles more often as the score rises.

The game remains a single PRG built with ACME and run in VICE, with no KERNAL
or BASIC dependencies.

---

## 2. Current state

| Area | Today | Change needed |
|------|-------|---------------|
| Source | `src/dodger.asm` | Rename to `src/streetbike.asm`, replace game logic |
| Build | `build/dodger.prg`, `build/dodger.d64` | Rename to `streetbike` everywhere |
| Player | One sprite, left/right only | Bike animation, 4-way movement, jump |
| Enemies | 4 asteroid sprites falling down | 6 obstacle slots scrolling left |
| Collision | VIC sprite/sprite register, first hit ends game | Software AABB hitboxes, 3 lives, invulnerability |
| Score | 1 point per asteroid passed | Survival score + jump-over bonus |
| Background | Empty screen | Scrolling street, skyline, fixed HUD |
| Sprites | 2 images at `$2000`/`$2040` | 9 images at `$2000`–`$223F` |

### 2.1 The supplied sprite images

The supplied sprite set was SpritePad output in 64TASS syntax. Phase 1
converted it to ACME syntax and inlined it in `src/streetbike.asm`; the
original `src/sprites.asm` has been removed. Analysis of the three images:

| Image | Label | Use | Notes |
|-------|-------|-----|-------|
| 0 | `sprite_image_0` | Bike frame A | Multicolor, faces right |
| 1 | `sprite_image_1` | Bike frame B | Alternate pedalling frame |
| 2 | `sprite_image_2` | Jump pose | Rider is higher in the cell; bike sits lower |

- All three are **multicolor** sprites (attribute `$8b`).
- Shared palette: `mc1 = 5` (green), `mc2 = 14` (light blue). The artwork uses
  the sprite colour (`$D027`) for the bike frame and wheels; Phase 1 sets it to
  white for contrast.
- Each image is 64 bytes (63 visible bytes + 1 padding byte). The 64th byte is
  `$8b` in all three images and is not displayed.
- The bike faces **right**, which matches the direction of travel.
- The jump image's bike is roughly 5 pixels higher inside the cell than the
  riding frames, so the jump lift and hitbox must be calibrated in VICE.

The data now lives in the `!pseudopc $2000 { ... }` block in
`src/streetbike.asm`, with labels `spr_bike_a`, `spr_bike_b` and
`spr_bike_jump`. The SpritePad attribute block was dropped; the per-image
64th byte (`$8b`) is retained as padding and is not displayed.

---

## 3. Target design

### 3.1 Screen layout

The C64 screen is 40 × 25 characters (320 × 200 pixels).

```
row  0-1    HUD (fixed):  SCORE 0000            LIVES 3
row  2-5    sky (black)
row  6-11   skyline / buildings (blue or dark grey)
row 12-24   road surface + lane markings (grey)
```

- HUD rows are never scrolled.
- The scrolling area is rows 2–24 (23 rows).
- Road pixel range: `y = 96..199`.
- Player sprite Y range: `96..179` (sprite is 21 px tall; content ends at
  `y + 20`).
- Player sprite X range: `40..120` (bike content spans `x + 2 .. x + 23`).
- Obstacles spawn at `x = 320` (just off the right edge) and move left.
- Obstacles despawn when `x < -24`.

### 3.2 Sprite budget and data layout

The VIC-II has 8 hardware sprites. Use them as follows:

| Sprite | Pointer | Data | Use |
|--------|---------|------|-----|
| 0 | `$07F8` | `$2000` / `$2040` / `$2080` | Player: frame A / frame B / jump |
| 1 | `$07F9` | `$20C0` | Obstacle slot 0 |
| 2 | `$07FA` | `$2100` | Obstacle slot 1 |
| 3 | `$07FB` | `$2140` | Obstacle slot 2 |
| 4 | `$07FC` | `$2180` | Obstacle slot 3 |
| 5 | `$07FD` | `$21C0` | Obstacle slot 4 |
| 6 | `$07FE` | `$2200` | Obstacle slot 5 |
| 7 | `$07FF` | — | Reserved (disabled) |

Sprite data map:

```
$2000  bike frame A   ptr $80
$2040  bike frame B   ptr $81
$2080  bike jump      ptr $82
$20C0  cone           ptr $83
$2100  trash can      ptr $84
$2140  barrier        ptr $85
$2180  pothole        ptr $86
$21C0  car (optional) ptr $87
$2200  spare / extra  ptr $88
```

- Every block is 64 bytes and 64-byte aligned.
- The player pointer is switched between `$80`, `$81` and `$82`.
- Obstacle slot `i` uses sprite `i + 1`; its pointer is set from the obstacle
  type table.
- Do not place data in `$1000–$1FFF` (character ROM).
- The code + data before `$2000` must stay below `$2000`. ACME's
  `!fill $2000 - *, 0` will fail the build if the code grows too large; if that
  happens, move the sprite block to `$3000` and update the pointers.

### 3.3 Sprite modes and colours

- Player sprites: **multicolor**. Set bit 0 of `$D01C`.
- Obstacle sprites: **hires** (single colour each). Clear bits 1–6 of `$D01C`.
- Shared multicolor registers:
  - `$D025` (mc1) = `5` (green)
  - `$D026` (mc2) = `14` (light blue)
- Player colour register `$D027` = `1` (white; the artwork uses this slot for
  the bike frame and wheels).
- Obstacle colours are set per slot from a type table:

| Type | Obstacle | Suggested colour |
|------|----------|------------------|
| 0 | Traffic cone | `8` (orange) |
| 1 | Trash can | `15` (light grey) |
| 2 | Road barrier | `2` (red) |
| 3 | Pothole / oil slick | `11` (dark grey) |
| 4 | Oncoming car (optional) | `12` (medium grey) |

- Background colour `$D021` = `0` (black); border `$D020` = `0` or `6` (blue).
- Colour RAM is set **per row**, not per cell, so scrolling screen memory does
  not require shifting colour RAM:
  - rows 0–1: white
  - rows 2–5: black
  - rows 6–11: blue (or dark grey)
  - rows 12–24: grey

### 3.4 Zero-page map

Allocate explicitly and keep the comments accurate. Avoid `$00/$01` (CPU
port). Suggested layout:

| Address | Name | Size | Purpose |
|---------|------|------|---------|
| `$02` | `zp_player_x` | 1 | Player screen X |
| `$03` | `zp_player_y` | 1 | Player base (ground) Y |
| `$04` | `zp_jump_t` | 1 | Jump animation index (0 = grounded) |
| `$05` | `zp_jump_lift` | 1 | Current lift in pixels |
| `$06` | `zp_anim` | 1 | Pedalling animation counter |
| `$07` | `zp_bike_frame` | 1 | 0 / 1 pedalling frame |
| `$08` | `zp_state` | 1 | 0 title, 1 play, 2 game over |
| `$09` | `zp_score_l` | 1 | BCD tens / units |
| `$0A` | `zp_score_h` | 1 | BCD thousands / hundreds |
| `$0B` | `zp_lives` | 1 | Remaining lives |
| `$0C` | `zp_inv` | 1 | Invulnerability countdown |
| `$0D` | `zp_fire_prev` | 1 | Previous fire state (edge detect) |
| `$0E` | `zp_joy` | 1 | Current joystick byte |
| `$0F` | `zp_cool` | 1 | Game-over restart delay |
| `$10` | `zp_snd` | 1 | Sound effect countdown |
| `$11` | `zp_rand` | 1 | LFSR state |
| `$12` | `zp_fine` | 1 | Fine scroll value (0–7) |
| `$13` | `zp_col` | 1 | World column counter |
| `$14` | `zp_spawn` | 1 | Obstacle spawn timer |
| `$15` | `zp_speed` | 1 | World scroll speed (px/frame) |
| `$16` | `zp_frame` | 1 | Frame counter |
| `$17` | `zp_src` | 2 | String pointer |
| `$19` | `zp_dst` | 2 | Screen pointer |
| `$1B` | `zp_obs_x_lo` | 6 | Obstacle X low bytes |
| `$21` | `zp_obs_x_hi` | 6 | Obstacle X high bytes |
| `$27` | `zp_obs_y` | 6 | Obstacle Y |
| `$2D` | `zp_obs_type` | 6 | Obstacle type |
| `$33` | `zp_obs_active` | 6 | 0 = free, 1 = active |
| `$39` | `zp_obs_scored` | 6 | Jump-over bonus already awarded |

### 3.5 Game states

Keep the existing three-state machine:

| State | Value | Behaviour |
|-------|-------|-----------|
| Title | 0 | Background scrolls slowly, bike animates, no obstacles, fire starts |
| Play | 1 | Full game loop |
| Game over | 2 | World frozen, final score shown, fire restarts after a delay |

### 3.6 Frame loop

```
wait for frame
read joystick
update sound countdown
switch on state:
  title:     animate bike, scroll background slowly, wait for fire
  play:      update player (move, jump, animate)
             update background scroll
             update obstacles (move, spawn, despawn)
             check collisions
             check jump-over bonuses
             update score / difficulty
             write sprites (X/Y, pointers, enable mask, 9th X bit)
             update HUD
  game over: count down restart delay, wait for fire
```

---

## 4. Refactor steps

### Phase 0 — Rename and build

**Status: complete.**

1. Rename `src/dodger.asm` → `src/streetbike.asm`.
2. Change `!to "build/dodger.prg", cbm` → `!to "build/streetbike.prg", cbm`.
3. Update `build.ninja`:
   - `build build/streetbike.prg: acme src/streetbike.asm`
   - `build build/streetbike.d64: d64 build/streetbike.prg`
   - Disk name `"streetbike,sb"`, file name `streetbike`
   - `build run: vice build/streetbike.prg`
4. Update the header comment in the source and the project name in
   `README.md` and `AGENTS.md`.
5. Keep the `$0801` load address, the `10 SYS 2061` BASIC stub and
   `!cpu 6502`; do not use illegal opcodes.
6. Build with `ninja` and confirm the renamed game still runs in VICE.

**Acceptance:** `ninja` produces `build/streetbike.prg` and
`build/streetbike.d64`; `ninja run` launches the old game under the new name.

### Phase 1 — Sprite pipeline

**Status: complete.**

1. Convert `src/sprites.asm` to ACME syntax (`.byte` → `!byte`, remove the
   `* = addr_spriteset_*` directives).
2. Add labels `spr_bike_a`, `spr_bike_b`, `spr_bike_jump`.
3. Inline the data in `streetbike.asm` after `!fill $2000 - *, 0`, inside
   `!pseudopc $2000 { ... }`; delete `src/sprites.asm`.
4. Set `$D025 = 5`, `$D026 = 14`, `$D01C` bit 0 = 1, and the player pointer to
   `$80`.
5. Temporarily cycle the player pointer through `$80`, `$81`, `$82` on the
   title screen to verify the images, colours and orientation.

**Acceptance:** The bike appears in the correct colours, faces right, and the
three images can be displayed without corruption.

### Phase 2 — Player, movement and jump

1. Replace the asteroid player logic with the bike:
   - `zp_player_x` / `zp_player_y` with clamping to `40..120` and `96..179`.
   - Up/down/left/right movement at 2 px/frame.
   - Pedalling animation: toggle `zp_bike_frame` every 4 frames while
     grounded; set the sprite pointer to `$80`/`$81`.
2. Implement the jump:
   - Fire edge detection using `zp_fire_prev`.
   - 16-entry lift table, e.g. `0,4,8,12,16,20,24,28,28,24,20,16,12,8,4,0`.
   - `zp_jump_t` indexes the table; `zp_jump_lift` is subtracted from
     `zp_player_y` when writing the sprite.
   - While airborne, use pointer `$82`; ignore up/down input; allow
     left/right.
   - No double jumps.
3. Write a `set_sprite_x` helper that handles the 9th X bit in `$D010`
   (needed later for obstacles).
4. Use a simple static road for now (e.g., a solid colour band) so movement
   and jumping can be tested before the scrolling background exists.

**Acceptance:** The bike moves in all four directions, animates while riding,
jumps with the jump sprite, lands cleanly, and cannot double-jump.

### Phase 3 — Street background and scrolling

#### 3a. Coarse scroll (baseline)

1. Add `draw_background`:
   - Fill rows 2–5 with spaces (sky).
   - Draw a skyline in rows 6–11 from a building-height table.
   - Draw the road surface in rows 12–24 with a dither character.
   - Draw lane dashes at a chosen row every few columns.
   - Set colour RAM per row (see §3.3).
2. Add `scroll_background`:
   - Shift rows 2–24 left by one column.
   - Draw a new column at column 39 using `draw_column`.
   - Increment `zp_col`.
3. Call `scroll_background` every `8 / zp_speed` frames.
4. Keep the HUD rows 0–1 fixed.

**Acceptance:** The street scrolls left smoothly enough to read, the HUD does
not move, and the pattern repeats without gaps.

#### 3b. Fine scroll (recommended polish)

1. Set up a raster split so the HUD is not affected by `$D016`:
   - IRQ at the start of row 0 (raster line 51, PAL): `$D016` fine scroll = 0.
   - IRQ at the start of row 2 (raster line 67, PAL): `$D016` fine scroll =
     `zp_fine`.
   - Use a small IRQ handler that saves registers, writes `$D016`,
     acknowledges `$D019`, restores and returns. Chain the two lines: the
     row-0 handler sets 0 and reprograms the raster compare to row 2; the
     row-2 handler sets `zp_fine` and reprograms the compare back to row 0.
2. Enable interrupts (`cli`) and keep the CIA interrupt sources disabled.
3. Each frame, advance `zp_fine` by `zp_speed`; when it wraps past 7, reset it
   and call `scroll_background`.
4. Calibrate the scroll direction in VICE: if the screen moves the wrong way,
   swap the shift direction and the new-column position.

**Acceptance:** The background scrolls smoothly at pixel granularity, the HUD
stays perfectly still, and the screen shift happens without visible tearing.

### Phase 4 — Obstacles, collision and lives

1. Design the obstacle sprites (see §5). Export each as a 64-byte hires block
   and add it to the sprite data block in `src/streetbike.asm`.
2. Add the obstacle type table:
   - sprite pointer
   - colour
   - hitbox insets (left, right, top, bottom)
3. Implement obstacle slots:
   - `spawn_obstacle`: find a free slot, set X = 320, pick a random lane Y and
     type, reset `zp_obs_scored`.
   - `update_obstacles`: subtract `zp_speed` from the 16-bit X; deactivate
     when `x < -24`.
   - `write_obstacles`: write X low byte, Y, pointer, colour, and the 9th X
     bit in `$D010`.
4. Implement the sprite enable mask:
   - Bit 0 always on during play.
   - Bits 1–6 set for active obstacle slots.
   - Write the mask to `$D015` each frame.
5. Implement software AABB collision:
   - Player hitbox: riding `x+4..x+20`, `y+8..y+20`; jumping uses the bike
     content near `y+10..y+16` plus the lift.
   - Obstacle hitbox from the type table.
   - On overlap: decrement `zp_lives`, set `zp_inv = 60`, deactivate the
     collided obstacle, play the hit sound, update the HUD.
   - While `zp_inv > 0`, skip collision checks and flash sprite 0 by toggling
     its enable bit every 4 frames.
   - At `zp_lives = 0`, enter game over.
6. Implement jump-over bonus detection:
   - When an obstacle's right edge passes the player's left edge and
     `zp_obs_scored` is clear:
     - If `zp_jump_t > 0` and the obstacle is in the player's lane
       (`abs(obs_y - player_y) < 20`), add 25 points and play the bonus sound.
     - Set `zp_obs_scored`.
7. Prevent unfair spawns: if an active obstacle is already near the right edge
   in the chosen lane, try another lane or skip the spawn.

**Acceptance:** Obstacles enter from the right edge (not from x = 255), move
left, can be jumped over for bonus points, cost a life on contact, and never
drain all lives in a single overlap.

### Phase 5 — Scoring, HUD and difficulty

1. Survival score: add 1 point every 8 frames while playing.
2. Jump bonus: +25 per obstacle jumped over.
3. HUD:
   - Row 0: `SCORE 0000` at columns 0–9 and `LIVES 3` at columns 30–36.
   - Keep the static text drawn once; update only the digits.
   - Adapt `draw_score` to the new positions and add `draw_lives`.
4. Difficulty:
   - `zp_speed` starts at 2 and rises to 4 as the score grows.
   - `zp_spawn` starts around 80 frames and falls to a floor of about 24.
   - Derive both from the score's hundreds digit or from a `zp_level`
     counter that increments every 500 points.
5. Reset all variables in `start_game`: score, lives, speed, spawn timer,
   obstacles, jump state, animation, invulnerability, `zp_col`, `zp_fine`.

**Acceptance:** The score rises while surviving, jumping over obstacles adds
bonus points, the HUD updates correctly, and the game visibly speeds up.

### Phase 6 — Title screen, game over, sound and polish

1. Title screen:
   - `STREETBIKE` centred.
   - `PRESS FIRE TO PLAY`.
   - `JOYSTICK PORT 2`.
   - A short control hint: `UP/DOWN/LEFT/RIGHT MOVE  FIRE JUMP`.
   - Bike animates in place; background scrolls slowly; no obstacles.
2. Game over:
   - Freeze the world.
   - Show `GAME OVER`, the final score, and `FIRE TO RESTART`.
   - Keep the restart delay (`zp_cool`) to avoid accidental restarts.
3. Sound:
   - Reuse `beep_hit` for collisions.
   - Add `beep_jump` (short rising pulse) and `beep_bonus` (short high beep).
   - Optional: a low engine tone on SID voice 2 whose frequency follows
     `zp_speed`.
4. Optional polish:
   - Fine scroll (Phase 3b) if not already done.
   - A second obstacle sprite for wide obstacles (e.g., a car).
   - A high-score byte shown on the title screen.

**Acceptance:** The title, play and game-over flows are complete and the game
feels responsive.

### Phase 7 — Testing and documentation

1. Run the manual test checklist in §7.
2. Update `README.md`:
   - New game description and controls.
   - New build paths and disk name.
   - How the scrolling street, obstacles, jump and scoring work.
3. Update `AGENTS.md`:
   - Project name and layout.
   - New commands and file paths.
   - Sprite data layout, 9-bit X handling, and the raster split.
4. Check the assembled size and confirm the `$2000` boundary is not crossed.

---

## 5. Obstacle sprite designs

All obstacles are hires 24 × 21 sprites with a single colour. The hitbox
insets are relative to the 24 × 21 sprite cell.

| Type | Name | Visual | Colour | Hitbox (L/R/T/B) | Notes |
|------|------|--------|--------|------------------|-------|
| 0 | Traffic cone | Triangle with a wide base and a transparent band for a stripe | Orange `8` | 7/7/6/0 | Small, easy to jump |
| 1 | Trash can | Cylinder with a lid and a handle | Light grey `15` | 4/4/3/0 | Medium height |
| 2 | Road barrier | Striped board on two legs | Red `2` | 0/0/4/0 | Wide; needs a well-timed jump |
| 3 | Pothole / oil slick | Flat irregular oval near the bottom | Dark grey `11` | 2/2/14/0 | Must be jumped; moving to another lane also works |
| 4 | Oncoming car (optional) | Small car facing left | Medium grey `12` | 1/1/4/0 | Stretch goal; may need two sprites for a longer body |

Design notes:

- Keep the silhouette readable at 24 × 21 pixels.
- Use transparent gaps rather than extra colours for details (stripes, lids,
  handles).
- The pothole should sit low in the cell so it reads as a ground hazard.
- The barrier should be tall enough that a late jump fails, but not so tall
  that it is impossible to clear.
- If a car is added, it should face left (oncoming traffic) and may move
  slightly faster than the world scroll.

---

## 6. Technical pitfalls

1. **9-bit sprite X.** The VIC-II X coordinate is 9 bits: low byte in
   `$D000+n`, high bit in `$D010` bit `n`. Obstacles spawn at x = 320, so the
   high bit must be set. Without it, the sprite appears at the wrong X (for
   example x = 64) instead of entering from the right edge.
2. **Sprite alignment.** Every sprite block must be 64-byte aligned; the
   pointer is `address / 64`. Do not place sprite data in `$1000–$1FFF`.
3. **Screen shift vs. HUD.** Shift only rows 2–24. If fine scroll is used, a
   raster split is required to keep rows 0–1 still.
4. **Colour RAM.** Use row-based colours so colour RAM does not need to be
   shifted with the screen. If per-cell colours are introduced later, shift
   colour RAM too.
5. **Multicolor vs. hires.** Set `$D01C` per sprite: player bit = 1, obstacle
   bits = 0. The player artwork uses only mc1/mc2, so `$D027` does not affect
   its visible pixels; flash the player by toggling its enable bit.
6. **Jump sprite offset.** The jump image's bike is higher in the cell than the
   riding frames. Calibrate the lift table and the jump hitbox in VICE so the
   visual and the collision box agree.
7. **Collision order.** Check collisions before awarding jump-over bonuses.
   Deactivate the collided obstacle so the player cannot be hit repeatedly
   during invulnerability.
8. **Spawn fairness.** Do not spawn two obstacles in the same lane at the same
   time. Try another lane or skip the spawn.
9. **ACME syntax.** Convert SpritePad's `.byte` to `!byte` and remove the
   `* = addr_spriteset_*` directives. The `!fill $2000 - *, 0` will fail the
   build if the code grows past `$2000`.
10. **Frame budget.** The screen shift is the most expensive routine. Shift
    only when the fine scroll wraps (every 4–8 frames), not every frame.
11. **Raster split timing.** If fine scroll is implemented, keep the IRQ
    handler minimal and acknowledge `$D019`. Test on PAL timing in VICE.
12. **Text routine.** `print` converts A–Z to screen codes and leaves digits
    and spaces unchanged, which is correct for the HUD. Check any new
    punctuation against the screen-code table.

---

## 7. Manual test checklist

Build and run with `ninja` / `ninja run`, then verify:

- [ ] The title screen shows `STREETBIKE`, the controls and an animated bike.
- [ ] Fire starts the game.
- [ ] Up/down/left/right move the bike and clamp at the road edges.
- [ ] The bike alternates between the two pedalling frames.
- [ ] Fire jumps; the jump sprite is used; the bike lands cleanly.
- [ ] Double-jumping is impossible.
- [ ] Obstacles enter from the right edge, not from x = 255.
- [ ] All obstacle types appear and scroll left at the world speed.
- [ ] The background scrolls smoothly and the HUD stays fixed.
- [ ] Touching an obstacle costs one life, flashes the player and does not
      drain multiple lives in one overlap.
- [ ] Three hits end the game.
- [ ] Jumping over an obstacle in the same lane awards bonus points.
- [ ] Dodging an obstacle in another lane does not award bonus points.
- [ ] The score rises while surviving and the HUD updates.
- [ ] The game speeds up and spawns obstacles more often as the score rises.
- [ ] Game over shows the final score and fire restarts the game.
- [ ] The frame loop keeps up; no visible slowdown or sprite flicker.
- [ ] The assembled PRG stays below the `$2000` sprite-data boundary.

---

## 8. Assumptions and open questions

- **Lives:** three lives (the brief says "loses one life" but not how many to
  start with).
- **Left/right:** moves the bike within a screen-space band (`40..120`); it
  does not change the world scroll speed.
- **Jump:** a fixed 16-frame arc; up/down input is ignored while airborne.
- **Obstacles:** static street objects that scroll with the road. Moving cars
  are a stretch goal.
- **Score:** four-digit BCD, survival points plus a +25 jump bonus. Extend to
  six digits if longer sessions are desired.
- **Background:** coarse character scrolling is the baseline; fine scrolling
  with a raster split is the recommended polish.
- **Sprite orientation:** the supplied bike faces right, which matches the
  direction of travel. Obstacles are orientation-neutral; a car should face
  left.
