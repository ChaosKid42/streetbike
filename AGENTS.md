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
- Local labels use the `.name` form and are scoped to the preceding global
  label. Reuse `.name` freely under different global labels.
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

These are load-bearing; changing them breaks the game. The sprite layout
below describes the current pre-refactor code; Phase 1 of `PLAN.md` expands
it.

- Code loads at `$0801` after a BASIC stub (`10 SYS 2061`). The `!to ..., cbm`
  directive emits the two-byte PRG load address.
- Sprite data lives at `$2000` and `$2040` and must stay 64-byte aligned.
  Sprite pointers at `$07F8`/`$07F9` hold `$80`/`$81`; if you move sprite
  data, update the `!fill`/`!pseudopc` addresses and those pointers.
- Do not place data in `$1000-$1FFF`: that window is character ROM, not RAM.
- The score is stored as two BCD bytes and drawn directly to screen memory.
  Use decimal-mode arithmetic or adjust `draw_score` if the representation
  changes.
- Joystick input is active low: a clear bit means pressed.
- The program takes over the machine (interrupts disabled, own frame loop).
  Code must not depend on KERNAL or BASIC routines.
- Target is the stock 6502; do not use illegal opcodes.

## Commits

Use short imperative subject lines (50 characters or less), capitalized, with
no trailing punctuation. Add a body only when it conveys information the
subject cannot.
