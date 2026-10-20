; ============================================================
;  STREETBIKE  -  a C64 game in 6502 assembly
;
;  Assembler : ACME
;  Build     : ninja                 (acme -> build\streetbike.prg)
;  Run       : x64sc build\streetbike.prg
;  Controls  : Joystick in port 2
;              left / right = move along the street
;              up / down    = change lane
;              fire         = jump / start / restart
;
;  The program takes over the machine: it disables interrupts,
;  owns the VIC-II sprites and runs its own frame loop.
;
;  Phase 0 renamed the project and its build outputs. Phase 1
;  replaced the sprite data with the supplied bike images.
;  Phase 2 adds bike movement, pedalling animation and jumping.
;  Phase 3a adds the scrolling street background.
;  Obstacles, scoring and lives follow in later phases; see
;  PLAN.md.
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
zp_cool       = $0f         ; game-over restart delay
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

PLAYER_MIN_X = 40
PLAYER_MAX_X = 224
PLAYER_MIN_Y = 128
PLAYER_MAX_Y = 224
PLAYER_SPEED = 2
JUMP_FRAMES  = 16

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
    sta $d01a               ; disable VIC raster interrupts too

    lda #$00
    sta CIA1_DDRA           ; joystick port 2 = input

    lda #0                  ; border and background : black
    sta VIC_BORDER
    sta VIC_BG

    lda #$15                ; screen $0400, uppercase/graphics charset $1000
    sta $d018

    jsr draw_background

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

    lda #%00000001          ; title screen : only player visible
    sta VIC_SPR_ENA

    ; reset state --------------------------------------------
    lda #0
    sta zp_state
    sta zp_score_l
    sta zp_score_h
    sta zp_cool
    sta zp_snd
    sta zp_jump_t
    sta zp_jump_lift
    sta zp_bike_frame
    sta zp_fire_prev
    sta zp_inv
    sta zp_frame
    lda #1
    sta zp_speed
    lda #4
    sta zp_anim
    lda #3
    sta zp_lives
    lda #$a7
    sta zp_rand

    lda #80
    sta zp_player_x
    lda #160
    sta zp_player_y
    jsr write_player

    ; title text
    +print_at SCREEN+10*40+13, txt_title
    +print_at SCREEN+14*40+11, txt_press
    +print_at SCREEN+16*40+12, txt_joy

; ============================================================
;  MAIN LOOP  (one iteration = one video frame)
; ============================================================
main_loop:
    jsr wait_frame
    jsr read_joystick
    jsr update_sound

    lda zp_state
    cmp #1
    beq .playing
    cmp #2
    beq .gameover
    jmp .title

.playing:
    jsr move_player
    jsr update_jump
    jsr animate_bike
    jsr update_scroll
    jsr write_player
    jsr draw_score
    jmp main_loop

.title:
    jsr animate_bike
    jsr write_player
    lda zp_joy
    and #%00010000          ; fire (active low)
    beq .start
    jmp main_loop
.start:
    jsr start_game
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
    jsr start_game
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
    lda #1
    sta zp_speed
    lda #4
    sta zp_anim
    lda #3
    sta zp_lives
    lda #1
    sta zp_fire_prev        ; fire is still held when the game starts

    lda #80
    sta zp_player_x
    lda #160
    sta zp_player_y

    lda #%00000001          ; only the player sprite for now
    sta VIC_SPR_ENA

    jsr draw_background
    +print_at SCREEN+1*40+0, txt_score

    lda #1
    sta zp_state
    jsr write_player
    jsr draw_score
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
;  BACKGROUND  (Phase 3a: coarse scrolling street)
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

; Advance the coarse scroll accumulator by zp_speed pixels. Every
; time it reaches one character (8 pixels) the screen is shifted.
update_scroll:
    lda zp_frame
    clc
    adc zp_speed
    sta zp_frame
    cmp #8
    bcc .usc_done
    sec
    sbc #8
    sta zp_frame
    jsr scroll_background
.usc_done:
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
txt_over:    !text "GAME OVER"
             !byte 0
txt_again:   !text "FIRE TO RESTART"
             !byte 0

; ============================================================
;  TABLES
; ============================================================
bike_frames:
    !byte $80, $81          ; pedalling frames A and B

jump_lift:
    !byte 0,4,8,12,16,20,24,28,28,24,20,16,12,8,4,0

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
;
;  The images are multicolor: 01 = $D025 (green),
;  10 = $D027 (sprite colour), 11 = $D026 (light blue).
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
}
