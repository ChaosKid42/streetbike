; ============================================================
;  STREETBIKE  -  a C64 game in 6502 assembly
;
;  Assembler : ACME
;  Build     : ninja                 (acme -> build\streetbike.prg)
;  Run       : x64sc build\streetbike.prg
;  Controls  : Joystick in port 2
;              left / right = move along the street
;              up / down    = change lane
;              fire         = jump / start / return to title
;
;  The program takes over the machine: it disables interrupts,
;  owns the VIC-II sprites and runs its own frame loop.
;
;  Phase 0 renamed the project and its build outputs. Phase 1
;  replaced the sprite data with the supplied bike images.
;  Phase 2 adds bike movement, pedalling animation and jumping.
;  Phase 3a adds the scrolling street background. Phase 3b
;  scrolls it at pixel granularity with the $D016 fine scroll.
;  Phase 3c adds a raster split so the HUD rows stay still.
;  Phase 4 adds the obstacles, the software hitboxes, the
;  jump-over bonus and the three lives. Scoring and difficulty
;  follow in Phase 5; see PLAN.md.
; ============================================================

; The C64's 6510 is a 6502 core with an added I/O port at $00/$01; its
; documented instruction set is identical. `!cpu 6510` would also enable
; undocumented opcodes, which this program deliberately avoids.
!cpu 6502
!to "build/streetbike.prg", cbm

; ------------------------------------------------------------
;  VIC-II / CIA / SID registers
; ------------------------------------------------------------
VIC_SPR0_X   = $d000
VIC_SPR0_Y   = $d001
VIC_SPR_XHI  = $d010        ; 9th X bit for sprites 0-7
VIC_SPR_ENA  = $d015
VIC_SPR_BPRI = $d01b
VIC_SPR_MCOL = $d01c
VIC_SPR_XEXP = $d01d
VIC_SPR_COLL = $d01e
VIC_SPR_MC1  = $d025
VIC_SPR_MC2  = $d026
VIC_SPR0_COL = $d027
VIC_RASTER   = $d012
VIC_BORDER   = $d020
VIC_BG       = $d021
VIC_CTRL1    = $d011        ; bit 7 : raster compare MSB
VIC_CTRL2    = $d016        ; bits 0-2 : horizontal fine scroll, bit 3 : 40 columns
VIC_IRQ      = $d019        ; interrupt status (write 1 to acknowledge)
VIC_IRQ_ENA  = $d01a        ; bit 0 : raster interrupt enable

CIA1_PA      = $dc00
CIA1_DDRA    = $dc02

SID_V1_FLO   = $d400
SID_V1_FHI   = $d401
SID_V1_CTRL  = $d404
SID_V1_AD    = $d405
SID_V1_SR    = $d406
SID_VOL      = $d418

SCREEN       = $0400
COLOR        = $d800
SPR_PTR      = $07f8        ; sprite pointers (outside 40x25 matrix)

; ------------------------------------------------------------
;  Zero page variables  (see PLAN.md section 3.4)
; ------------------------------------------------------------
zp_player_x   = $02
zp_player_y   = $03         ; base (ground) Y; jump lift is subtracted
zp_jump_t     = $04         ; jump animation index, 0 = grounded
zp_jump_lift  = $05         ; current lift in pixels
zp_anim       = $06         ; pedalling animation counter
zp_bike_frame = $07         ; 0 / 1 pedalling frame
zp_state      = $08         ; 0 title, 1 play, 2 game over
zp_score_l    = $09         ; BCD : tens / units
zp_score_h    = $0a         ; BCD : thousands / hundreds
zp_lives      = $0b
zp_inv        = $0c         ; invulnerability countdown
zp_fire_prev  = $0d         ; previous fire state (edge detect)
zp_joy        = $0e
zp_cool       = $0f         ; game-over input delay
zp_snd        = $10         ; sound countdown
zp_rand       = $11
zp_fine       = $12         ; fine scroll value (0-7)
zp_col        = $13         ; world column counter
zp_spawn      = $14         ; obstacle spawn timer
zp_speed      = $15         ; world scroll speed (px/frame)
zp_frame      = $16         ; frame counter
zp_src        = $17         ; 2 bytes, string pointer
zp_dst        = $19         ; 2 bytes, screen pointer
zp_obs_x_lo   = $1b         ; 6 bytes
zp_obs_x_hi   = $21         ; 6 bytes
zp_obs_y      = $27         ; 6 bytes
zp_obs_type   = $2d         ; 6 bytes
zp_obs_active = $33         ; 6 bytes
zp_obs_scored = $39         ; 6 bytes
zp_tmp        = $3f         ; scratch / low byte of temp pointer
zp_tmp2       = $40         ; high byte of temp pointer
zp_px1        = $41         ; player hitbox : left
zp_px2        = $42         ; player hitbox : right
zp_py1        = $43         ; player hitbox : top
zp_py2        = $44         ; player hitbox : bottom
zp_ox1        = $45         ; obstacle hitbox : left
zp_ox2        = $46         ; obstacle hitbox : right
zp_oy1        = $47         ; obstacle hitbox : top
zp_oy2        = $48         ; obstacle hitbox : bottom
zp_idx        = $49         ; obstacle slot being spawned
zp_mask       = $4a         ; sprite enable mask for $D015

PLAYER_MIN_X = 40
PLAYER_MAX_X = 224
PLAYER_MIN_Y = 128
PLAYER_MAX_Y = 179         ; ground line y+20 stays on the road (y <= 199)
PLAYER_SPEED = 2
JUMP_FRAMES  = 20

LANE_COUNT   = 3            ; obstacle lanes, see lane_y
SPAWN_FRAMES = 90           ; frames between spawns (Phase 5: dynamic)
INV_FRAMES   = 60           ; invulnerability after a hit
BONUS_POINTS = $25          ; BCD 25, awarded for a jump-over

; Raster split lines (PAL). Row 0 starts on line 51 and row 2 on
; line 67; both are bad lines, so the interrupts are placed on the
; lines just before/inside them where a mid-line write cannot show:
; line 50 is still top border, line 68 is inside the blank sky row.
IRQ_LINE_HUD  = 50          ; $D016 fine scroll = 0 for rows 0-1
IRQ_LINE_PLAY = 68          ; $D016 fine scroll = zp_fine below

; ------------------------------------------------------------
;  Macro: print a zero-terminated string at a screen address
;  Must be defined before it is used.
; ------------------------------------------------------------
!macro print_at addr, txt {
    lda #<txt
    sta zp_src
    lda #>txt
    sta zp_src+1
    lda #<addr
    sta zp_dst
    lda #>addr
    sta zp_dst+1
    jsr print
}

; ------------------------------------------------------------
;  BASIC loader:  10 SYS 2061
;  ACME's cbm output format writes the two-byte PRG load
;  address ($01 $08) in front of the data.
; ------------------------------------------------------------
* = $0801

    !word $080b             ; link to end-of-program marker
    !word 10                ; line number
    !byte $9e               ; SYS token
    !text "2061"
    !byte 0
    !word 0

; $080d                   ; 2061 decimal -> machine code

; ============================================================
;  INIT
; ============================================================
start:
    sei
    lda #$7f
    sta $dc0d               ; disable CIA1 interrupts
    sta $dd0d               ; disable CIA2 interrupts
    lda $dc0d               ; acknowledge
    lda $dd0d

    lda #0
    sta VIC_IRQ_ENA         ; disable VIC raster interrupts for now

    ; Bank out BASIC and KERNAL so the CPU vectors at $FFFA-$FFFF
    ; are RAM and can point straight at our handlers. I/O stays
    ; mapped at $D000-$DFFF. Nothing here uses the ROMs.
    lda #$35
    sta $01
    lda #<nmi_handler
    sta $fffa
    lda #>nmi_handler
    sta $fffb
    lda #<irq_hud
    sta $fffe
    lda #>irq_hud
    sta $ffff

    lda #$00
    sta CIA1_DDRA           ; joystick port 2 = input

    lda #0                  ; border and background : black
    sta VIC_BORDER
    sta VIC_BG

    lda #$15                ; screen $0400, uppercase/graphics charset $1000
    sta $d018

    ; sprite data pointers -----------------------------------
    ldx #0
    lda #$80                ; $2000 / 64 : bike frame A
.sp_ptr:
    sta SPR_PTR,x
    inx
    cpx #8
    bne .sp_ptr

    ; sprite colours -----------------------------------------
    lda #1
    sta VIC_SPR0_COL        ; player : white

    ; player multicolor, obstacles hires
    lda #5
    sta VIC_SPR_MC1         ; multicolor 1 : green
    lda #14
    sta VIC_SPR_MC2         ; multicolor 2 : light blue
    lda #%00000001
    sta VIC_SPR_MCOL        ; sprite 0 multicolor, sprites 1-7 hires

    ; no expansion, sprites in front
    lda #0
    sta VIC_SPR_XEXP
    sta VIC_SPR_BPRI

    jsr title_screen

    ; raster split -------------------------------------------
    lda #$1b                ; screen on, 25 rows, Y scroll 3, raster MSB 0
    sta VIC_CTRL1
    lda #%11001000          ; 40 columns, no fine scroll (bits 6-7 read as 1)
    sta VIC_CTRL2
    lda #IRQ_LINE_HUD
    sta VIC_RASTER
    lda #$01
    sta VIC_IRQ             ; clear anything pending
    sta VIC_IRQ_ENA         ; raster interrupt on
    cli

; ============================================================
;  MAIN LOOP  (one iteration = one video frame)
; ============================================================
main_loop:
    jsr wait_frame
    inc zp_frame
    jsr read_joystick
    jsr update_sound

    lda zp_state
    cmp #1
    beq .playing
    cmp #2
    beq .gameover
    jmp .title

.playing:
    jsr update_scroll       ; first: the coarse shift needs the whole vblank
    jsr move_player
    jsr update_jump
    jsr animate_bike
    jsr update_obstacles
    jsr update_spawn
    jsr update_inv
    jsr check_collisions
    lda zp_state
    cmp #1
    bne main_loop           ; the last life was lost : skip the rest
    jsr check_bonus
    jsr write_player
    jsr write_obstacles
    jsr draw_score
    jmp main_loop

.title:
    jsr animate_bike
    jsr write_player
    lda zp_joy
    and #%00010000          ; fire (active low)
    bne .title_release
    lda zp_fire_prev
    bne .title_wait         ; still held from the game-over screen
    jsr start_game
    jmp main_loop
.title_release:
    lda #0
    sta zp_fire_prev
.title_wait:
    jmp main_loop

.gameover:
    lda zp_cool
    beq .fireok
    dec zp_cool
    jmp main_loop
.fireok:
    lda zp_joy
    and #%00010000
    beq .restart
    jmp main_loop
.restart:
    jsr title_screen
    jmp main_loop

; ============================================================
;  START / RESET A GAME
; ============================================================
start_game:
    lda #0
    sta zp_score_l
    sta zp_score_h
    sta zp_jump_t
    sta zp_jump_lift
    sta zp_bike_frame
    sta zp_inv
    sta zp_cool
    sta zp_frame
    sta zp_fine
    sta zp_snd
    ldx #0
.sg_clear:
    sta zp_obs_active,x
    sta zp_obs_scored,x
    inx
    cpx #6
    bne .sg_clear
    lda #2
    sta zp_speed
    lda #4
    sta zp_anim
    lda #3
    sta zp_lives
    lda #SPAWN_FRAMES
    sta zp_spawn
    lda #1
    sta zp_fire_prev        ; fire is still held when the game starts

    lda #80
    sta zp_player_x
    lda #152                ; start in the middle lane
    sta zp_player_y

    lda #%00000001          ; player only; obstacles enable themselves
    sta VIC_SPR_ENA

    jsr draw_background
    +print_at SCREEN+1*40+0, txt_score
    +print_at SCREEN+1*40+30, txt_lives

    lda #1
    sta zp_state
    jsr write_player
    jsr draw_score
    jsr draw_lives
    rts

; ============================================================
;  TITLE SCREEN
;  Rebuilds the complete title state. Used at boot and when
;  the player leaves the game-over screen.
; ============================================================
title_screen:
    lda #0
    sta zp_state
    sta zp_score_l
    sta zp_score_h
    sta zp_cool
    sta zp_snd
    sta zp_jump_t
    sta zp_jump_lift
    sta zp_bike_frame
    sta zp_inv
    sta zp_frame
    sta zp_fine
    ldx #0
.ts_clear:
    sta zp_obs_active,x
    sta zp_obs_scored,x
    inx
    cpx #6
    bne .ts_clear
    lda #2
    sta zp_speed
    lda #4
    sta zp_anim
    lda #3
    sta zp_lives
    lda #SPAWN_FRAMES
    sta zp_spawn
    lda #$a7
    sta zp_rand
    lda #1
    sta zp_fire_prev        ; fire may still be held : wait for release

    lda #80
    sta zp_player_x
    lda #152                ; start in the middle lane
    sta zp_player_y

    lda #%00000001          ; title screen : only player visible
    sta VIC_SPR_ENA

    jsr draw_background
    +print_at SCREEN+10*40+13, txt_title
    +print_at SCREEN+14*40+11, txt_press
    +print_at SCREEN+16*40+12, txt_joy
    jsr write_player
    rts

; ============================================================
;  GAME OVER
;  The world is frozen by the state machine; hide every sprite
;  and free the obstacle slots so the title screen starts clean.
; ============================================================
game_over:
    lda #2
    sta zp_state
    lda #120
    sta zp_cool
    lda #0
    sta VIC_SPR_ENA
    ldx #0
.go_clear:
    sta zp_obs_active,x
    inx
    cpx #6
    bne .go_clear
    +print_at SCREEN+10*40+15, txt_over
    +print_at SCREEN+14*40+15, txt_again
    rts

; ============================================================
;  PLAYER
; ============================================================
read_joystick:
    lda CIA1_PA
    sta zp_joy
    rts

; Up/down move the bike across the road; left/right along it.
; Up/down are ignored while airborne.
move_player:
    lda zp_jump_t
    bne .horizontal

    lda zp_joy
    and #%00000001          ; up
    bne .no_up
    lda zp_player_y
    sec
    sbc #PLAYER_SPEED
    cmp #PLAYER_MIN_Y
    bcs .su
    lda #PLAYER_MIN_Y
.su:
    sta zp_player_y
.no_up:
    lda zp_joy
    and #%00000010          ; down
    bne .no_down
    lda zp_player_y
    clc
    adc #PLAYER_SPEED
    cmp #PLAYER_MAX_Y+1
    bcc .sd
    lda #PLAYER_MAX_Y
.sd:
    sta zp_player_y
.no_down:

.horizontal:
    lda zp_joy
    and #%00000100          ; left
    bne .no_left
    lda zp_player_x
    sec
    sbc #PLAYER_SPEED
    cmp #PLAYER_MIN_X
    bcs .sl
    lda #PLAYER_MIN_X
.sl:
    sta zp_player_x
.no_left:
    lda zp_joy
    and #%00001000          ; right
    bne .no_right
    lda zp_player_x
    clc
    adc #PLAYER_SPEED
    cmp #PLAYER_MAX_X+1
    bcc .sr
    lda #PLAYER_MAX_X
.sr:
    sta zp_player_x
.no_right:
    rts

; Fire starts a jump. The button is edge-detected so holding it
; does not repeat, and an airborne bike cannot jump again.
update_jump:
    lda zp_joy
    and #%00010000          ; fire (active low)
    beq .pressed
    lda #0
    sta zp_fire_prev
    jmp .advance
.pressed:
    lda zp_fire_prev
    bne .advance
    lda #1
    sta zp_fire_prev
    lda zp_jump_t
    bne .advance            ; no double jump
    lda #1
    sta zp_jump_t
.advance:
    lda zp_jump_t
    beq .uj_done
    tax
    lda jump_lift,x
    sta zp_jump_lift
    inc zp_jump_t
    lda zp_jump_t
    cmp #JUMP_FRAMES
    bcc .uj_done
    lda #0
    sta zp_jump_t
    sta zp_jump_lift
.uj_done:
    rts

; Toggle the pedalling frame every 4 frames while grounded.
animate_bike:
    lda zp_jump_t
    bne .ab_done
    dec zp_anim
    bne .ab_done
    lda #4
    sta zp_anim
    lda zp_bike_frame
    eor #1
    sta zp_bike_frame
.ab_done:
    rts

write_player:
    lda zp_jump_t
    beq .grounded
    lda #$82                ; jump pose
    jmp .ptr
.grounded:
    ldx zp_bike_frame
    lda bike_frames,x
.ptr:
    sta SPR_PTR+0

    lda zp_player_x
    ldx #0                  ; sprite 0
    clc                     ; X < 256
    jsr set_sprite_x

    lda zp_player_y
    sec
    sbc zp_jump_lift        ; constant lift, independent of ground Y
    sta VIC_SPR0_Y
    rts

; X = sprite index 0-7, A = X low byte, carry = 9th X bit.
set_sprite_x:
    sta zp_tmp
    bcc .clear
    txa
    tay
    lda sprite_bit,y
    ora VIC_SPR_XHI
    sta VIC_SPR_XHI
    jmp .store
.clear:
    txa
    tay
    lda sprite_bit,y
    eor #$ff
    and VIC_SPR_XHI
    sta VIC_SPR_XHI
.store:
    txa
    asl
    tax
    lda zp_tmp
    sta VIC_SPR0_X,x
    rts

; ============================================================
;  OBSTACLES  (Phase 4)
;
;  Six slots, one per hardware sprite 1-6. A slot is either free
;  (zp_obs_active = 0) or holds an obstacle scrolling left at
;  zp_speed. X is 16 bits: obstacles enter at 320, so the 9th
;  sprite X bit is set until they cross x = 255.
;
;  Collision is software AABB, not the VIC sprite/sprite
;  register: the hitboxes are smaller than the 24x21 cells and
;  must match the artwork (see obs_hit_* tables).
; ============================================================

; Scroll every active obstacle left and free the slots that have
; left the screen. The VIC sprite X is 9 bits (0-511), so a
; sprite cannot be drawn at a negative X: the slot is freed as
; soon as x goes below 0, so the sprite disappears at the left
; edge of the display, far from the player.
update_obstacles:
    ldx #0
.uo_slot:
    lda zp_obs_active,x
    beq .uo_next
    lda zp_obs_x_lo,x
    sec
    sbc zp_speed
    sta zp_obs_x_lo,x
    lda zp_obs_x_hi,x
    sbc #0
    sta zp_obs_x_hi,x
    cmp #$ff
    bne .uo_next            ; still on screen (x >= 0)
    lda #0
    sta zp_obs_active,x
.uo_next:
    inx
    cpx #6
    bne .uo_slot
    rts

; Spawn timer. Phase 5 derives the interval from the score.
update_spawn:
    dec zp_spawn
    bne .usp_done
    lda #SPAWN_FRAMES
    sta zp_spawn
    jmp spawn_obstacle
.usp_done:
    rts

; Put one obstacle at x = 320 in a free slot. The lane is picked
; at random, but a lane that already has an obstacle entering is
; skipped so two obstacles never arrive on top of each other.
spawn_obstacle:
    ldx #0
.so_find:
    lda zp_obs_active,x
    beq .so_free
    inx
    cpx #6
    bne .so_find
    rts                     ; all slots busy
.so_free:
    stx zp_idx
    ldy #LANE_COUNT
.so_lane:
    jsr rand_byte
    and #3
    cmp #LANE_COUNT
    bcc .so_lane_ok
    lda #0                  ; fold 3 back onto lane 0
.so_lane_ok:
    sta zp_tmp
    tya
    pha                     ; lane_blocked clobbers Y
    jsr lane_blocked
    pla
    tay
    bcc .so_place
    dey
    bne .so_lane
    rts                     ; every lane is busy : skip this spawn
.so_place:
    ldx zp_idx
    lda #1
    sta zp_obs_active,x
    lda #0
    sta zp_obs_scored,x
    lda #<320
    sta zp_obs_x_lo,x
    lda #>320
    sta zp_obs_x_hi,x
    ldy zp_tmp
    lda lane_y,y
    sta zp_obs_y,x
    jsr rand_byte
    and #3
    sta zp_obs_type,x
    rts

; Carry set if an active obstacle is already entering in the lane
; whose index is in zp_tmp. "Entering" means x >= 240: still off
; screen or just emerging from under the right border.
lane_blocked:
    ldy zp_tmp
    lda lane_y,y
    sta zp_tmp2             ; lane Y
    ldx #0
.lb_slot:
    lda zp_obs_active,x
    beq .lb_next
    lda zp_obs_x_hi,x
    beq .lb_low
    cmp #1
    bne .lb_next            ; negative x : already past
    jmp .lb_check           ; x >= 256 : still entering
.lb_low:
    lda zp_obs_x_lo,x
    cmp #240
    bcc .lb_next            ; far enough to the right
.lb_check:
    lda zp_obs_y,x
    sec
    sbc zp_tmp2
    bcs .lb_diff
    eor #$ff
    adc #1                  ; absolute difference
.lb_diff:
    cmp #24
    bcc .lb_blocked
.lb_next:
    inx
    cpx #6
    bne .lb_slot
    clc
    rts
.lb_blocked:
    sec
    rts

; Compute the player's hitbox. Riding, it covers the bike's body
; and wheels. Airborne, it covers only the bike in the jump pose,
; which sits higher in the sprite cell, so the lift is subtracted.
; The airborne box is narrower than the riding one so the jump
; has a usable timing window against the wide obstacles.
set_player_box:
    lda zp_jump_t
    beq .spb_ground
    lda zp_player_x
    clc
    adc #8
    sta zp_px1
    lda zp_player_x
    clc
    adc #16
    sta zp_px2
    lda zp_player_y
    sec
    sbc zp_jump_lift
    clc
    adc #10
    sta zp_py1
    lda zp_player_y
    sec
    sbc zp_jump_lift
    clc
    adc #16
    sta zp_py2
    rts
.spb_ground:
    lda zp_player_x
    clc
    adc #4
    sta zp_px1
    lda zp_player_x
    clc
    adc #20
    sta zp_px2
    lda zp_player_y
    clc
    adc #8
    sta zp_py1
    lda zp_player_y
    clc
    adc #20
    sta zp_py2
    rts

; AABB test against every active obstacle. Only obstacles with a
; zero high byte can overlap the player: x >= 256 is still to the
; right and x < 0 is already past the left edge.
check_collisions:
    lda zp_inv
    beq .cc_go
    rts                     ; still invulnerable
.cc_go:
    jsr set_player_box
    ldx #0
.cc_slot:
    lda zp_obs_active,x
    beq .cc_next
    lda zp_obs_x_hi,x
    bne .cc_next
    lda zp_obs_x_lo,x
    cmp #245
    bcs .cc_next            ; right of the player's box
    ldy zp_obs_type,x
    lda zp_obs_x_lo,x
    clc
    adc obs_hit_l,y
    sta zp_ox1
    lda zp_obs_x_lo,x
    clc
    adc #23
    sec
    sbc obs_hit_r,y
    sta zp_ox2
    lda zp_obs_y,x
    clc
    adc obs_hit_t,y
    sta zp_oy1
    lda zp_obs_y,x
    clc
    adc #20
    sec
    sbc obs_hit_b,y
    sta zp_oy2
    lda zp_ox1
    cmp zp_px2
    beq .cc_x
    bcs .cc_next            ; ox1 > px2
.cc_x:
    lda zp_px1
    cmp zp_ox2
    beq .cc_y
    bcs .cc_next            ; px1 > ox2
.cc_y:
    lda zp_oy1
    cmp zp_py2
    beq .cc_hit
    bcs .cc_next            ; oy1 > py2
    lda zp_py1
    cmp zp_oy2
    beq .cc_hit
    bcs .cc_next            ; py1 > oy2
.cc_hit:
    jmp hit_obstacle
.cc_next:
    inx
    cpx #6
    bne .cc_slot
    rts

; One life lost. The obstacle that was hit is removed so it cannot
; hit the player again, and zp_inv keeps the player safe while the
; sprite flashes.
hit_obstacle:
    lda #0
    sta zp_obs_active,x
    dec zp_lives
    lda #INV_FRAMES
    sta zp_inv
    jsr beep_hit
    jsr draw_lives
    lda zp_lives
    bne .ho_done
    jmp game_over
.ho_done:
    rts

update_inv:
    lda zp_inv
    beq .ui_done
    dec zp_inv
.ui_done:
    rts

; Award the jump-over bonus once per obstacle, when its right
; edge has passed the player's left edge. Only a jump in the
; obstacle's lane counts; zp_obs_scored is set either way.
check_bonus:
    jsr set_player_box
    ldx #0
.cb_slot:
    lda zp_obs_active,x
    beq .cb_next
    lda zp_obs_scored,x
    bne .cb_next
    lda zp_obs_x_hi,x
    beq .cb_on_screen
    cmp #$ff
    beq .cb_passed          ; already off the left edge
    jmp .cb_next            ; x >= 256 : still to the right
.cb_on_screen:
    ldy zp_obs_type,x
    lda zp_obs_x_lo,x
    clc
    adc #23
    bcs .cb_next            ; right edge > 255 : still to the right
    sec
    sbc obs_hit_r,y
    cmp zp_px1
    bcs .cb_next            ; right edge not past the player yet
.cb_passed:
    lda #1
    sta zp_obs_scored,x
    lda zp_jump_t
    beq .cb_next            ; not jumping : no bonus
    lda zp_obs_y,x
    sec
    sbc zp_player_y
    bcs .cb_diff
    eor #$ff
    adc #1                  ; absolute difference
.cb_diff:
    cmp #20
    bcs .cb_next            ; different lane
    jsr add_bonus
.cb_next:
    inx
    cpx #6
    bne .cb_slot
    rts

; Write the obstacle sprites and build the sprite enable mask:
; bit 0 is the player, bits 1-6 are the obstacle slots.
write_obstacles:
    lda #1
    sta zp_mask
    ldx #0
.wo_slot:
    lda zp_obs_active,x
    beq .wo_next
    txa
    pha                     ; set_sprite_x clobbers X and Y
    lda zp_obs_x_hi,x
    cmp #1                  ; carry set when x >= 256
    lda zp_obs_x_lo,x
    inx                     ; sprite index = slot + 1
    jsr set_sprite_x
    pla
    tax
    ldy zp_obs_type,x
    lda obs_ptr,y
    sta SPR_PTR+1,x
    lda obs_color,y
    sta VIC_SPR0_COL+1,x
    txa
    asl
    tay
    lda zp_obs_y,x
    sta VIC_SPR0_Y+2,y      ; sprite i Y = $D001 + 2i
    lda sprite_bit+1,x
    ora zp_mask
    sta zp_mask
.wo_next:
    inx
    cpx #6
    bne .wo_slot
    lda zp_inv
    beq .wo_enable
    lda zp_frame
    and #%00000100
    beq .wo_enable
    lda zp_mask
    and #%11111110          ; flash the player while invulnerable
    sta zp_mask
.wo_enable:
    lda zp_mask
    sta VIC_SPR_ENA
    rts

; ============================================================
;  SCORE  (4 digit BCD)
; ============================================================
add_score:
    sed
    lda zp_score_l
    clc
    adc #$01
    sta zp_score_l
    lda zp_score_h
    adc #$00
    sta zp_score_h
    cld
    rts

; +25 points for clearing an obstacle, in BCD.
add_bonus:
    sed
    lda zp_score_l
    clc
    adc #BONUS_POINTS
    sta zp_score_l
    lda zp_score_h
    adc #$00
    sta zp_score_h
    cld
    jsr beep_bonus
    rts

draw_score:
    lda zp_score_h
    lsr
    lsr
    lsr
    lsr
    ora #$30
    sta SCREEN+1*40+6
    lda zp_score_h
    and #$0f
    ora #$30
    sta SCREEN+1*40+7
    lda zp_score_l
    lsr
    lsr
    lsr
    lsr
    ora #$30
    sta SCREEN+1*40+8
    lda zp_score_l
    and #$0f
    ora #$30
    sta SCREEN+1*40+9
    rts

; Lives are a single digit; the label is drawn once by start_game.
draw_lives:
    lda zp_lives
    ora #$30
    sta SCREEN+1*40+36
    rts

; ============================================================
;  SOUND  (short SID noise burst)
; ============================================================
beep_hit:
    lda #0
    sta SID_V1_CTRL
    lda #$0f
    sta SID_VOL
    lda #0
    sta SID_V1_FLO
    lda #$30
    sta SID_V1_FHI
    lda #0
    sta SID_V1_AD
    lda #$f0
    sta SID_V1_SR
    lda #$81                ; noise waveform + gate
    sta SID_V1_CTRL
    lda #20
    sta zp_snd
    rts

; Short high beep for the jump-over bonus.
beep_bonus:
    lda #0
    sta SID_V1_CTRL
    lda #$0f
    sta SID_VOL
    lda #0
    sta SID_V1_FLO
    lda #$40
    sta SID_V1_FHI
    lda #0
    sta SID_V1_AD
    lda #$f0
    sta SID_V1_SR
    lda #$11                ; triangle waveform + gate
    sta SID_V1_CTRL
    lda #12
    sta zp_snd
    rts

update_sound:
    lda zp_snd
    beq .us_done
    dec zp_snd
    bne .us_done
    lda #0
    sta SID_V1_CTRL
.us_done:
    rts

; ============================================================
;  FRAME SYNC  (wait for raster line 250)
; ============================================================
wait_frame:
    lda VIC_RASTER
    cmp #250
    bne wait_frame
    rts

; ============================================================
;  RASTER SPLIT  (Phase 3c)
;
;  Two chained raster interrupts keep the HUD rows 0-1 free of
;  the horizontal fine scroll. Each handler writes $D016, points
;  the raster compare and the IRQ vector at the other handler and
;  acknowledges the VIC. Only A is used, so only A is saved.
;  The main loop no longer touches $D016; it just keeps zp_fine
;  up to date and irq_play applies it once per frame.
;
;  The HUD rows use 40 columns so text at column 0 is fully
;  visible. The scrolling rows use 38 columns: the side borders
;  grow by one character and hide columns 0 and 39, which are
;  only partially on screen while the fine scroll is non-zero.
;  Without this the left edge of the street visibly slides and
;  snaps back on every coarse shift.
; ============================================================
irq_hud:
    pha
    lda VIC_CTRL2
    and #%11110000
    ora #%00001000          ; rows 0-1 : 40 columns, no fine scroll
    sta VIC_CTRL2
    lda #IRQ_LINE_PLAY
    sta VIC_RASTER
    lda #<irq_play
    sta $fffe
    lda #>irq_play
    sta $ffff
    lda #$01
    sta VIC_IRQ
    pla
    rti

irq_play:
    pha
    jsr write_fine_scroll   ; rows 2-24 : 38 columns, scroll by zp_fine
    lda #IRQ_LINE_HUD
    sta VIC_RASTER
    lda #<irq_hud
    sta $fffe
    lda #>irq_hud
    sta $ffff
    lda #$01
    sta VIC_IRQ
    pla
    rti

; RESTORE key: with the KERNAL banked out the NMI vector is ours.
nmi_handler:
    rti

; ============================================================
;  RANDOM  (8 bit LFSR)
; ============================================================
rand_byte:
    lda zp_rand
    asl
    bcc .rb
    eor #$1d
.rb:
    sta zp_rand
    rts

; ============================================================
;  PRINT  (ASCII/PETSCII -> screen codes, uppercase only)
; ============================================================
print:
    lda zp_dst
    sta zp_tmp
    lda zp_dst+1
    clc
    adc #$d4                ; COLOR - SCREEN
    sta zp_tmp2
    ldy #0
.pl:
    lda (zp_src),y
    beq .pd
    cmp #$41                ; 'A'
    bcc .ps
    cmp #$5b                ; 'Z'+1
    bcs .ps
    sec
    sbc #$40                ; A-Z -> screen codes 1..26
.ps:
    sta (zp_dst),y
    lda #1                  ; white text
    sta (zp_tmp),y
    iny
    bne .pl
.pd:
    rts

; ============================================================
;  BACKGROUND  (Phase 3a-3c: coarse + fine scrolling street)
;
;  Rows 2-5   sky (black)
;  Rows 6-11  skyline, height from building_heights
;  Rows 12-24 road, checkerboard texture and lane dashes
;  Rows 0-1   HUD, never scrolled
; ============================================================

; Draw the complete background and reset the world column counter.
draw_background:
    jsr clear_screen
    lda #0
    sta zp_col
    ldx #0
.db_col:
    jsr draw_column
    inc zp_col
    inx
    cpx #40
    bne .db_col
    jsr set_row_colors
    rts

; Draw one screen column. X = screen column 0-39, zp_col = world
; column used for the skyline height and the lane-dash pattern.
; Only rows 2-24 are touched, so the HUD stays fixed.
draw_column:
    stx zp_tmp              ; screen column
    txa
    pha                     ; preserve the caller's screen column
    lda #<SCREEN+2*40
    clc
    adc zp_tmp
    sta zp_dst
    lda #>SCREEN+2*40
    adc #0
    sta zp_dst+1

    lda zp_col
    and #$3f
    tax
    lda building_heights,x
    sta zp_tmp              ; building height 0-6

    ldx #2                  ; screen row 2
.dc_row:
    cpx #6
    bcc .dc_sky             ; rows 2-5 : sky
    cpx #12
    bcs .dc_road            ; rows 12-24 : road
    txa                     ; rows 6-11 : skyline
    clc
    adc zp_tmp
    cmp #12
    bcc .dc_sky
    lda #160                ; solid block : building
    jmp .dc_store
.dc_sky:
    lda #32                 ; space
    jmp .dc_store
.dc_road:
    cpx #17
    bne .dc_dither
    lda zp_col
    and #$03
    cmp #2
    bcs .dc_dither
    lda #160                ; lane dash
    jmp .dc_store
.dc_dither:
    lda #102                ; checkerboard road texture
.dc_store:
    ldy #0
    sta (zp_dst),y
    lda zp_dst
    clc
    adc #40
    sta zp_dst
    bcc .dc_noc
    inc zp_dst+1
.dc_noc:
    inx
    cpx #25
    bne .dc_row
    pla
    tax
    rts

; Shift rows 6-24 one character to the left. The sky rows 2-5
; are always blank, so they do not need to be shifted. Column 39
; is left for draw_column to fill with the new world column.
shift_rows:
    lda #<SCREEN+6*40
    sta zp_dst
    lda #>SCREEN+6*40
    sta zp_dst+1
    ldx #19                 ; rows 6-24
.sr_row:
    lda zp_dst
    clc
    adc #1
    sta zp_src
    lda zp_dst+1
    adc #0
    sta zp_src+1
    ldy #0
.sr_byte:
    lda (zp_src),y
    sta (zp_dst),y
    iny
    lda (zp_src),y
    sta (zp_dst),y
    iny
    lda (zp_src),y
    sta (zp_dst),y
    iny
    lda (zp_src),y
    sta (zp_dst),y
    iny
    lda (zp_src),y
    sta (zp_dst),y
    iny
    lda (zp_src),y
    sta (zp_dst),y
    iny
    lda (zp_src),y
    sta (zp_dst),y
    iny
    lda (zp_src),y
    sta (zp_dst),y
    iny
    cpy #40
    bne .sr_byte
    lda zp_dst
    clc
    adc #40
    sta zp_dst
    bcc .sr_noc
    inc zp_dst+1
.sr_noc:
    dex
    bne .sr_row
    rts

; Shift the street left and append the next world column.
scroll_background:
    jsr shift_rows
    ldx #39
    jsr draw_column
    inc zp_col
    rts

; Advance the fine scroll by zp_speed pixels. $D016 shifts the
; picture right by its low three bits, so the value counts down to
; move the street left. When it would pass zero the screen is
; shifted one character and the value wraps to 7, which keeps the
; motion continuous across the coarse shift.
;
; Timing: the coarse shift takes ~170 raster lines, so it runs
; past the top border and well into the next frame's picture. The
; new zp_fine is picked up by irq_play on line 68, and the rows
; are shifted top to bottom ahead of the beam: rows 6-11 are done
; before line 99 and rows 12-24 before line 147. zp_fine must be
; stored before the shift so the value and the memory agree when
; the interrupt reads it.
update_scroll:
    lda zp_fine
    sec
    sbc zp_speed
    bcs .usc_store
    clc
    adc #8
    sta zp_fine
    jmp scroll_background
.usc_store:
    sta zp_fine
    rts

; Apply zp_fine to $D016 and select 38-column mode, leaving the
; other bits (reset, text multicolor) untouched. Called from
; irq_play, so this is the mode for the scrolling rows only.
write_fine_scroll:
    lda VIC_CTRL2
    and #%11110000
    ora zp_fine
    sta VIC_CTRL2
    rts

; Colour RAM is set per row; the road blocks use the grey nibble.
set_row_colors:
    lda #<COLOR
    sta zp_dst
    lda #>COLOR
    sta zp_dst+1
    ldx #0
.sc_row:
    lda row_colors,x
    ldy #0
.sc_cell:
    sta (zp_dst),y
    iny
    cpy #40
    bne .sc_cell
    lda zp_dst
    clc
    adc #40
    sta zp_dst
    bcc .sc_noc
    inc zp_dst+1
.sc_noc:
    inx
    cpx #25
    bne .sc_row
    rts

; ============================================================
;  CLEAR SCREEN  (1000 bytes, leaves sprite pointers alone)
; ============================================================
clear_screen:
    lda #$20
    ldx #0
.cs1:
    sta SCREEN,x
    sta SCREEN+$100,x
    sta SCREEN+$200,x
    inx
    bne .cs1
    ldx #0
.cs2:
    sta SCREEN+$300,x
    inx
    cpx #232
    bne .cs2
    rts

; ============================================================
;  TEXT
; ============================================================
txt_title:   !text "ASTEROID DODGE"
             !byte 0
txt_press:   !text "PRESS FIRE TO PLAY"
             !byte 0
txt_joy:     !text "JOYSTICK PORT 2"
             !byte 0
txt_score:   !text "SCORE"
             !byte 0
txt_lives:   !text "LIVES"
             !byte 0
txt_over:    !text "GAME OVER"
             !byte 0
txt_again:   !text "PRESS FIRE"
             !byte 0

; ============================================================
;  TABLES
; ============================================================
bike_frames:
    !byte $80, $81          ; pedalling frames A and B

jump_lift:
    !byte 0,4,8,12,16,20,24,28,28,28,28,28,28,24,20,16,12,8,4,0

; Obstacle lanes: the sprite Y of each lane. The sprite's bottom
; row is the ground line, so an obstacle in the player's lane uses
; the same Y as the bike.
lane_y:
    !byte 128, 152, 176

; Obstacle type tables, indexed by zp_obs_type.
;   sprite pointer, colour, hitbox insets (left, right, top, bottom)
; The insets are relative to the 24x21 sprite cell and are
; deliberately smaller than the artwork so the hitboxes are fair.
obs_ptr:
    !byte $83, $84, $85, $86
obs_color:
    !byte 8, 15, 2, 11
obs_hit_l:
    !byte 8, 6, 6, 4
obs_hit_r:
    !byte 8, 6, 6, 4
obs_hit_t:
    !byte 6, 6, 6, 14
obs_hit_b:
    !byte 0, 0, 0, 0

sprite_bit:
    !byte 1,2,4,8,16,32,64,128

building_heights:
    !byte 3,5,2,6,4,0,3,5,2,4,6,3,1,2,5,4
    !byte 6,2,3,0,4,5,2,6,3,4,1,5,2,3,6,4
    !byte 2,5,1,4,3,6,2,3,5,0,4,2,6,3,1,5
    !byte 4,2,6,3,1,5,4,2,3,6,1,4,5,2,3,0

row_colors:
    !byte 1,1               ; rows 0-1  HUD
    !byte 0,0,0,0           ; rows 2-5  sky
    !byte 6,6,6,6,6,6       ; rows 6-11 skyline
    !byte 12,12,12,12,12,12,12,12,12,12,12,12,12  ; rows 12-24 road

; ============================================================
;  SPRITE DATA  (must live in VIC bank 0 RAM, not $1000-$1fff)
;  Each sprite is 24x21 pixels = 63 bytes plus one padding
;  byte, so every image occupies a 64-byte block.
;
;  $2000  bike frame A   ptr $80
;  $2040  bike frame B   ptr $81
;  $2080  bike jump      ptr $82
;  $20c0  cone           ptr $83
;  $2100  trash can      ptr $84
;  $2140  barrier        ptr $85
;  $2180  pothole        ptr $86
;
;  The bike images are multicolor: 01 = $D025 (green),
;  10 = $D027 (sprite colour), 11 = $D026 (light blue).
;  The obstacles are hires: one colour each, from obs_color.
; ============================================================
!fill $2000 - *, 0

!pseudopc $2000 {
spr_bike_a:
    !byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
    !byte $28,$00,$00,$2a,$00,$00,$3c,$00,$00,$3c,$00,$00,$3c,$00,$00,$f0
    !byte $00,$00,$fc,$00,$00,$ff,$c0,$00,$f2,$80,$00,$f0,$80,$0a,$fa,$80
    !byte $02,$30,$80,$0a,$30,$a0,$20,$be,$08,$20,$aa,$08,$0a,$00,$a0,$8b

spr_bike_b:
    !byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
    !byte $00,$00,$00,$00,$00,$00,$28,$00,$00,$2a,$00,$00,$fc,$00,$00,$fc
    !byte $00,$03,$f0,$00,$03,$ff,$00,$03,$c2,$80,$03,$c0,$80,$0a,$fa,$80
    !byte $02,$f0,$80,$0a,$30,$a0,$20,$b2,$08,$20,$be,$08,$0a,$00,$a0,$8b

spr_bike_jump:
    !byte $00,$a0,$00,$00,$a8,$00,$00,$f0,$00,$00,$f0,$00,$00,$c0,$00,$00
    !byte $f0,$00,$00,$fc,$00,$00,$f3,$00,$00,$f2,$80,$00,$30,$80,$0a,$ba
    !byte $80,$02,$30,$a0,$0a,$32,$08,$20,$be,$08,$20,$a8,$a0,$20,$80,$00
    !byte $0a,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$8b

; Traffic cone: triangle with a transparent band for the stripe.
spr_cone:
    !byte $00,$00,$00       ; 0
    !byte $00,$00,$00       ; 1
    !byte $00,$00,$00       ; 2
    !byte $00,$00,$00       ; 3
    !byte $00,$00,$00       ; 4
    !byte $00,$00,$00       ; 5
    !byte $00,$18,$00       ; 6  tip
    !byte $00,$18,$00       ; 7
    !byte $00,$3c,$00       ; 8
    !byte $00,$3c,$00       ; 9
    !byte $00,$7e,$00       ; 10
    !byte $00,$7e,$00       ; 11
    !byte $00,$00,$00       ; 12 stripe gap
    !byte $00,$00,$00       ; 13 stripe gap
    !byte $01,$ff,$80       ; 14
    !byte $01,$ff,$80       ; 15
    !byte $03,$ff,$c0       ; 16
    !byte $03,$ff,$c0       ; 17
    !byte $07,$ff,$e0       ; 18
    !byte $0f,$ff,$f0       ; 19 base
    !byte $0f,$ff,$f0       ; 20
    !byte $00               ; padding : keeps the block 64 bytes

; Trash can: lid with a handle and a ribbed body.
spr_trash:
    !byte $00,$00,$00       ; 0
    !byte $00,$3c,$00       ; 1  handle
    !byte $00,$3c,$00       ; 2
    !byte $0f,$ff,$f0       ; 3  lid
    !byte $0f,$ff,$f0       ; 4
    !byte $0f,$ff,$f0       ; 5
    !byte $07,$ff,$e0       ; 6  body
    !byte $07,$ff,$e0       ; 7
    !byte $07,$ff,$e0       ; 8
    !byte $07,$00,$e0       ; 9  rib
    !byte $07,$ff,$e0       ; 10
    !byte $07,$ff,$e0       ; 11
    !byte $07,$ff,$e0       ; 12
    !byte $07,$ff,$e0       ; 13
    !byte $07,$00,$e0       ; 14 rib
    !byte $07,$ff,$e0       ; 15
    !byte $07,$ff,$e0       ; 16
    !byte $07,$ff,$e0       ; 17
    !byte $07,$ff,$e0       ; 18
    !byte $07,$ff,$e0       ; 19
    !byte $0f,$ff,$f0       ; 20 base
    !byte $00               ; padding : keeps the block 64 bytes

; Road barrier: striped board on two legs.
spr_barrier:
    !byte $00,$00,$00       ; 0
    !byte $00,$00,$00       ; 1
    !byte $00,$00,$00       ; 2
    !byte $00,$00,$00       ; 3
    !byte $ff,$ff,$ff       ; 4  board
    !byte $ff,$ff,$ff       ; 5
    !byte $00,$00,$00       ; 6  stripe gap
    !byte $ff,$ff,$ff       ; 7
    !byte $ff,$ff,$ff       ; 8
    !byte $00,$00,$00       ; 9  stripe gap
    !byte $ff,$ff,$ff       ; 10
    !byte $0c,$00,$30       ; 11 legs
    !byte $0c,$00,$30       ; 12
    !byte $0c,$00,$30       ; 13
    !byte $0c,$00,$30       ; 14
    !byte $0c,$00,$30       ; 15
    !byte $0c,$00,$30       ; 16
    !byte $0c,$00,$30       ; 17
    !byte $0c,$00,$30       ; 18
    !byte $0c,$00,$30       ; 19
    !byte $1e,$00,$78       ; 20 feet
    !byte $00               ; padding : keeps the block 64 bytes

; Pothole: flat irregular oval near the bottom of the cell.
spr_pothole:
    !byte $00,$00,$00       ; 0
    !byte $00,$00,$00       ; 1
    !byte $00,$00,$00       ; 2
    !byte $00,$00,$00       ; 3
    !byte $00,$00,$00       ; 4
    !byte $00,$00,$00       ; 5
    !byte $00,$00,$00       ; 6
    !byte $00,$00,$00       ; 7
    !byte $00,$00,$00       ; 8
    !byte $00,$00,$00       ; 9
    !byte $00,$00,$00       ; 10
    !byte $00,$00,$00       ; 11
    !byte $00,$00,$00       ; 12
    !byte $00,$00,$00       ; 13
    !byte $00,$7e,$00       ; 14
    !byte $03,$ff,$c0       ; 15
    !byte $1f,$ff,$f8       ; 16
    !byte $3f,$ff,$fc       ; 17
    !byte $3f,$ff,$fc       ; 18
    !byte $0f,$ff,$f0       ; 19
    !byte $03,$ff,$c0       ; 20
    !byte $00               ; padding : keeps the block 64 bytes
}
