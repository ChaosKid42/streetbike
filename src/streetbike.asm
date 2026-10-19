; ============================================================
;  STREETBIKE  -  a C64 game in 6502 assembly
;
;  Assembler : ACME
;  Build     : ninja                 (acme -> build\streetbike.prg)
;  Run       : x64sc build\streetbike.prg
;  Controls  : Joystick in port 2
;              left / right = move, fire = start / restart
;
;  The program takes over the machine: it disables interrupts,
;  owns the VIC-II sprites and runs its own frame loop.
;
;  Phase 0 renamed the project and its build outputs. Phase 1
;  replaced the sprite data with the supplied bike images. The
;  original asteroid gameplay is still present; see PLAN.md for
;  the bike-game refactor.
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
;  Zero page variables
; ------------------------------------------------------------
zp_player_x  = $02
zp_player_y  = $03
zp_score_l   = $04          ; BCD : tens / units
zp_score_h   = $05          ; BCD : thousands / hundreds
zp_rand      = $06
zp_state     = $07          ; 0 title, 1 play, 2 game over
zp_src       = $08          ; 2 bytes, string pointer
zp_dst       = $0a          ; 2 bytes, screen pointer
zp_joy       = $0c
zp_cool      = $0d          ; game-over restart delay
zp_snd       = $0e          ; sound countdown
zp_anim      = $0f          ; title-screen image countdown (temporary)
zp_enemy_x   = $10          ; 4 bytes
zp_enemy_y   = $14          ; 4 bytes
zp_enemy_spd = $18          ; 4 bytes
zp_bike_frame = $1c         ; title-screen bike image index (temporary)

PLAYER_Y     = 220
PLAYER_MIN_X = 24
PLAYER_MAX_X = 248
ENEMY_TOP_Y  = 50
ENEMY_BOT_Y  = 240

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

    lda #7                  ; border : yellow
    sta VIC_BORDER
    lda #0
    sta VIC_BG

    lda #$15                ; screen $0400, uppercase/graphics charset $1000
    sta $d018

    jsr clear_screen

    lda #1
    jsr fill_color

    ; sprite data pointers -----------------------------------
    lda #$80                ; $2000 / 64 : bike frame A
    sta SPR_PTR+0           ; sprite 0 : player
    lda #$81                ; $2040 / 64 : bike frame B
    sta SPR_PTR+1           ; sprites 1-4 : placeholder until
    sta SPR_PTR+2           ; obstacle sprites exist (Phase 4)
    sta SPR_PTR+3
    sta SPR_PTR+4

    ; sprite colours -----------------------------------------
    lda #1
    sta VIC_SPR0_COL        ; player : white
    lda #2
    sta VIC_SPR0_COL+1
    sta VIC_SPR0_COL+2
    sta VIC_SPR0_COL+3
    sta VIC_SPR0_COL+4      ; enemies : red

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

    ; reset player
    lda #150
    sta zp_player_x
    lda #PLAYER_Y
    sta zp_player_y
    jsr write_player

    ; reset state
    lda #0
    sta zp_state
    sta zp_score_l
    sta zp_score_h
    sta zp_cool
    sta zp_snd
    sta zp_bike_frame
    lda #32
    sta zp_anim
    lda #$a7
    sta zp_rand

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

    lda zp_snd               ; sound envelope countdown
    beq .nosnd
    dec zp_snd
    bne .nosnd
    lda #0
    sta SID_V1_CTRL
.nosnd:

    lda zp_state
    cmp #1
    beq .playing
    cmp #2
    beq .gameover
    jmp .title

.playing:
    jsr move_player
    jsr update_enemies
    jsr check_collision
    jsr write_sprites
    jsr draw_score
    jmp main_loop

.title:
    dec zp_anim
    bne .tjoy
    lda #32
    sta zp_anim
    ldx zp_bike_frame
    inx
    cpx #3
    bcc .tset
    ldx #0
.tset:
    stx zp_bike_frame
    lda bike_frames,x
    sta SPR_PTR+0
.tjoy:
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

    lda #$80                ; bike frame A
    sta SPR_PTR+0

    lda #150
    sta zp_player_x
    lda #PLAYER_Y
    sta zp_player_y

    ldx #0
.sg_en:
    lda #ENEMY_TOP_Y
    sta zp_enemy_y,x
    jsr rand_byte
    and #$df
    clc
    adc #24
    sta zp_enemy_x,x
    lda #1
    sta zp_enemy_spd,x
    inx
    cpx #4
    bne .sg_en

    lda #%00011111          ; enable player + 4 enemies
    sta VIC_SPR_ENA

    jsr clear_screen
    +print_at SCREEN+1*40+0, txt_score

    lda #1
    sta zp_state
    lda #0
    sta zp_cool
    jsr write_sprites
    jsr draw_score
    rts

; ============================================================
;  PLAYER
; ============================================================
read_joystick:
    lda CIA1_PA
    sta zp_joy
    rts

move_player:
    lda zp_joy
    and #%00000100          ; left
    bne .no_left
    lda zp_player_x
    sec
    sbc #3
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
    adc #3
    cmp #PLAYER_MAX_X
    bcc .sr
    lda #PLAYER_MAX_X
.sr:
    sta zp_player_x
.no_right:
    rts

write_player:
    lda zp_player_x
    sta VIC_SPR0_X
    lda zp_player_y
    sta VIC_SPR0_Y
    rts

; ============================================================
;  ENEMIES
; ============================================================
update_enemies:
    ldx #0
.ue:
    lda zp_enemy_y,x
    clc
    adc zp_enemy_spd,x
    sta zp_enemy_y,x
    cmp #ENEMY_BOT_Y
    bcc .unext
    jsr spawn_enemy
    jsr add_score
.unext:
    inx
    cpx #4
    bne .ue
    rts

; respawn enemy X at the top with a new position & speed
spawn_enemy:
    lda #ENEMY_TOP_Y
    sta zp_enemy_y,x
    jsr rand_byte
    and #$df
    clc
    adc #24
    sta zp_enemy_x,x
    lda zp_score_h          ; difficulty from hundreds digit
    and #$0f
    lsr
    clc
    adc #1
    cmp #4
    bcc .sp
    lda #4
.sp:
    sta zp_enemy_spd,x
    rts

write_sprites:
    lda zp_player_x
    sta VIC_SPR0_X
    lda zp_player_y
    sta VIC_SPR0_Y
    ldx #0
.ws:
    txa
    asl
    tay
    lda zp_enemy_x,x
    sta VIC_SPR0_X+2,y      ; sprite (x+1) X
    lda zp_enemy_y,x
    sta VIC_SPR0_X+3,y      ; sprite (x+1) Y
    inx
    cpx #4
    bne .ws
    rts

; ============================================================
;  COLLISION  (VIC-II sprite/sprite register)
; ============================================================
check_collision:
    lda VIC_SPR_COLL        ; reading clears the latch
    and #%00000001          ; did sprite 0 (player) hit anything?
    beq .cc_ok
    lda #2
    sta zp_state
    lda #50
    sta zp_cool
    jsr beep_hit
    +print_at SCREEN+12*40+15, txt_over
    +print_at SCREEN+16*40+12, txt_again
.cc_ok:
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
    iny
    bne .pl
.pd:
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

; fill colour RAM with the colour already in A
fill_color:
    ldx #0
.fc1:
    sta COLOR,x
    sta COLOR+$100,x
    sta COLOR+$200,x
    inx
    bne .fc1
    ldx #0
.fc2:
    sta COLOR+$300,x
    inx
    cpx #232
    bne .fc2
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
;  SPRITE POINTERS
; ============================================================
bike_frames:
    !byte $80, $81, $82     ; bike frame A, frame B, jump

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
