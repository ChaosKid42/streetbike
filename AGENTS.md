# AGENTS.md

Guidance for coding agents working on this repository.

## Project

Streetbike is a Commodore 64 game written in 6502 assembly for the `acme`
cross-assembler. It is assembled into a single PRG file and runs in the VICE
emulator (`x64sc.exe`). The project is being refactored from the original
asteroid-dodge gameplay into a side-scrolling bike game; see `PLAN.md`.

## Commands

Run all commands from the repository root.

```sh
ninja          # assemble src/streetbike.asm -> build/streetbike.prg, then build/streetbike.d64
ninja run      # build, then launch the game in VICE
ninja clean    # remove build artifacts
```

Equivalent manual build:

```sh
acme src/streetbike.asm
c1541.exe -format "streetbike,sb" d64 build/streetbike.d64 -write build/streetbike.prg streetbike
```

`acme`, `c1541.exe`, `ninja`, and `x64sc.exe` must be on `PATH`.

There is no automated test suite. Validation means the build succeeds and the
game behaves correctly in VICE. `build/` is generated and git-ignored.

## Testing in VICE

`x64sc.exe` is a GUI program on Windows and prints nothing to the console, so
the practical way to check a change is a headless run that saves a screenshot:

```sh
x64sc.exe -autostart build/streetbike.prg -limitcycles 30000000 \
    -exitscreenshot build/shot.png -warp
```

- `-warp` runs as fast as possible; `-limitcycles` stops the emulator after
  that many emulated cycles (about 1M per second of PAL time).
- `-exitscreenshot` writes a PNG on exit. Open it with the `read_file` tool.
- Autostart spends roughly 25M cycles loading, so use 30M or more to see the
  game rather than the READY prompt.

The game waits for the fire button, which a headless run cannot press. Patch a
throwaway copy of the source in `build/` (git-ignored) instead of changing
`src/streetbike.asm`. Every recipe below starts from the real source, writes
`build/test.asm`, then redirects the output and auto-starts the game:

```sh
sed -i -e 's|build/streetbike.prg|build/test.prg|' \
       -e 's/^    cli$/    jsr start_game\n    cli/' build/test.asm
acme build/test.asm
x64sc.exe -autostart build/test.prg -limitcycles 40000000 \
    -exitscreenshot build/shot.png -warp
```

(`sed -i` with `\n` in the replacement needs GNU sed, which WSL provides.)

### Auto-jump

Force the fire bit low for one frame every 32 frames, right after the joystick
is read. This exercises the jump arc and the jump-over bonus with realistic
timing:

```sh
awk '{print} /jsr read_joystick/ {print "    lda zp_frame"; print "    and #31"; print "    bne .autotest"; print "    lda zp_joy"; print "    and #%11101111"; print "    sta zp_joy"; print ".autotest:"}' \
    src/streetbike.asm > build/test.asm
```

### Always afloat

Hold the bike at the top of the jump arc to check the jump sprite, the lift
and the airborne hitbox:

```sh
awk '{print} /jsr read_joystick/ {print "    lda #8"; print "    sta zp_jump_t"; print "    lda #28"; print "    sta zp_jump_lift"}' \
    src/streetbike.asm > build/test.asm
```

### Other useful patches

- Long run without game over: insert `lda #99` before `sta zp_lives` with
  `awk '/sta zp_lives/ {print "    lda #99"} {print}'`. The HUD only draws one
  digit, so lives above 9 show a graphics character.
- Fast obstacle spawns: `sed 's/SPAWN_FRAMES = 90/SPAWN_FRAMES = 20/'`.
- A fixed lane: patch the `lda #152` / `sta zp_player_y` pair in
  `start_game`.

Delete `build/test.asm`, `build/test.prg` and the screenshots when done. Never
commit them; `build/` is git-ignored.

## Layout

| Path | Purpose |
|------|---------|
| `src/streetbike.asm` | Entire game: directives, registers, zero page, code, text, sprite data |
| `build.ninja` | Build rules |
| `README.md` | Player-facing documentation and design overview |
| `PLAN.md` | Development plan for the Streetbike refactor |

## Code conventions

- ACME syntax. Mnemonics and directives are lowercase; constants and labels
  are uppercase or `snake_case` as already used. Directives start with `!`
  (`!byte`, `!word`, `!text`, `!fill`, `!pseudopc`).
- Four-space indentation. Instructions are indented; labels start at column 0.
- Local labels use the `.name` form. ACME scopes them to the current zone,
  not to the preceding global label, so every `.name` must be unique within
  the file. Do not reuse a local label under a different global label.
- Macros use `!macro name arg, arg { ... }` and are invoked as `+name arg, arg`.
  Parameters are referenced by bare name inside the body.
- Hardware registers are named constants at the top of `src/streetbike.asm`
  (`VIC_*`, `CIA1_*`, `SID_*`). Add new ones there instead of using raw
  addresses inline.
- Zero page variables are prefixed `zp_` and allocated explicitly in the
  zero-page block. Do not reuse an address without checking the comment.
- Section banners use `; ===...` comment blocks. Keep new code grouped under
  a banner.
- Comments explain intent and hardware behavior, not the obvious effect of
  each instruction.

## Hardware constraints

These are load-bearing; changing them breaks the game.

- Code loads at `$0801` after a BASIC stub (`10 SYS 2061`). The `!to ..., cbm`
  directive emits the two-byte PRG load address.
- Sprite data lives at `$2000`–`$21BF`, one 64-byte block per image, and must
  stay 64-byte aligned. Pointers at `$07F8`–`$07FE` hold `$80`–`$86`:
  bike A/B/jump, then cone, trash can, barrier, pothole. If you move sprite
  data, update the `!fill`/`!pseudopc` addresses, the pointers and `obs_ptr`.
- Sprite 0 is the player (multicolor); sprites 1–6 are the obstacle slots
  (hires). `write_obstacles` builds the `$D015` enable mask each frame.
- Obstacle X is 16-bit. The VIC sprite X is 9 bits (0–511), so the 9th bit in
  `$D010` must be set while `x >= 256`; a sprite cannot be drawn at a negative
  X, so obstacles are freed as soon as `x < 0`.
- Collision is software AABB (`check_collisions`), not the VIC sprite/sprite
  register. The hitboxes are smaller than the sprite cells; see the
  `obs_hit_*` tables and `set_player_box`.
- Do not place data in `$1000-$1FFF`: that window is character ROM, not RAM.
- The score is stored as two BCD bytes and drawn directly to screen memory.
  Use decimal-mode arithmetic or adjust `draw_score` if the representation
  changes.
- Joystick input is active low: a clear bit means pressed.
- The program takes over the machine (interrupts disabled, own frame loop).
  Code must not depend on KERNAL or BASIC routines.
- The raster split (`irq_hud`/`irq_play`) owns `$D016`; the main loop must not
  write it. The KERNAL is banked out, so `$FFFE/$FFFF` must always point at a
  valid IRQ handler.
- Target is the stock 6502; do not use illegal opcodes.

## Commits

Use short imperative subject lines (50 characters or less), capitalized, with
no trailing punctuation. Add a body only when it conveys information the
subject cannot.
