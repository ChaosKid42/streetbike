# Streetbike — a C64 game in 6502 assembly

A Commodore 64 sprite game written for the
[ACME](https://sourceforge.net/projects/acme-crossass/) cross-assembler and
tested in **VICE** (`x64sc.exe`).

> **Status:** the project has been renamed to Streetbike and the bike sprite
> data is in place. The current build still contains the original
> asteroid-dodge gameplay; the side-scrolling bike game is being developed
> according to [`PLAN.md`](PLAN.md).

The original game: you pilot a ship along the bottom of the screen and dodge
falling asteroids. Each asteroid that passes you scores a point; touching one
ends the round. The asteroids get faster as your score climbs.

## Files

| File | Purpose |
|------|---------|
| `src/streetbike.asm` | Full commented source (ACME syntax) |
| `build/streetbike.prg` | Assembled program, ready to load (generated) |
| `build/streetbike.d64` | 1541 disk image containing `streetbike` (generated) |
| `build.ninja` | Ninja build file: assembles with ACME, packs with c1541.exe |
| `PLAN.md` | Development plan for the Streetbike refactor |

## Build & run

The build is driven by [Ninja](https://ninja-build.org/). `acme.exe`,
`c1541.exe` (from VICE) and `ninja` must be on your `PATH`.

```bat
ninja
ninja run
ninja clean
```

`ninja` assembles `src/streetbike.asm` directly into `build/streetbike.prg`
with ACME, and then packs that PRG into the disk image
`build/streetbike.d64` with `c1541.exe`;
`ninja run` builds first if needed, then starts the game in VICE and returns
when you close the emulator; `ninja clean` removes the generated build
artifacts.

Or manually:

```bat
acme src\streetbike.asm
c1541.exe -format "streetbike,sb" d64 build\streetbike.d64 -write build\streetbike.prg streetbike
"x64sc.exe" -autostart build\streetbike.prg
```

The source's `!to "build/streetbike.prg", cbm` directive selects ACME's CBM
output format, which emits the two-byte PRG load address. The code is
assembled at `$0801`; a `!fill` pads the output to `$2000`, where the sprite
data is assembled with `!pseudopc`, so ACME always writes a ready-to-run
`build/streetbike.prg`.

`build/streetbike.prg` is a normal C64 program you can drop into VICE or run
on real hardware. `build/streetbike.d64` is a standard 1541 image with the
program saved as `streetbike`, ready to attach in VICE (**File → Attach disk
image**) or write to a real floppy.

## Controls

* Joystick in **port 2**
* Left / right = move
* Fire = start / return to title

In VICE, joystick port 2 is normally the numeric keypad
(`4` / `6` to move, `0` to fire) or the arrow keys, depending on your
settings. If nothing responds, open **Settings → Joystick** and map
port 2 to the keys you like.

## How it works

The program takes over the machine: it disables the KERNAL interrupt
sources, sets up five hardware sprites and runs its own frame loop. The
following describes the current (pre-refactor) asteroid gameplay.

```
$0801  BASIC stub:  10 SYS 2061
$080D  machine code
$2000  bike frame A (player), 64-byte aligned
$2040  bike frame B (player), 64-byte aligned
$2080  bike jump pose (player), 64-byte aligned
$0400  screen matrix
$D800  colour RAM
```

Key pieces of the source:

* **`main_loop`** — waits for raster line 250, reads the joystick,
  then runs the title / playing / game-over state machine.
* **`move_player`** — clamps the ship between `PLAYER_MIN_X` and
  `PLAYER_MAX_X`.
* **`update_enemies`** — moves each of the four asteroid sprites down;
  when one leaves the bottom it is respawned at the top with a new
  random X and a speed based on the score.
* **`check_collision`** — reads the VIC-II sprite/sprite collision
  register `$D01E`; bit 0 means the player hit something.
* **`add_score` / `draw_score`** — score is kept as two BCD bytes and
  drawn straight into screen memory.
* **`rand_byte`** — an 8-bit LFSR used for asteroid positions.
* **`beep_hit`** — a short SID noise burst on collision.

Sprites live in VIC bank 0 RAM at `$2000`–`$20BF` (pointers `$80`–`$82`),
deliberately outside the `$1000–$1FFF` character-ROM window. The player is
multicolor; the title screen cycles through the three bike images.

## Ideas for extending it

* Add a starfield in the background.
* Give the player three lives and a short invulnerability flash.
* Add a title-screen tune and explosion sound.
* Use a raster interrupt for a split screen or smooth parallax.
* Add a second enemy type that moves diagonally.
* Save a high score in a spare byte and show it on the title screen.

Have fun hacking on it — the whole game is one commented file.

## Credits

**Author:** Christoph Scholz <christoph.scholz@gmail.com>

Streetbike was created with intensive use of AI. The code was written in
close collaboration with AI coding agents (Zed's agent, powered by DeepSeek
V4.1 Flash), with the human author directing the design, reviewing the
changes and testing the game.

**Bike animations:** Oliver Stephan <contact@creaturelab3d.com>

* Website: <https://www.creaturelab3d.com/>
* itch.io: <https://o-ossel.itch.io/>

## License

Released under the [MIT License](LICENSE) — see `LICENSE` for the full text.
