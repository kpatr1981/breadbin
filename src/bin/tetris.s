; tetris.s: basic terminal Tetris for Unix Breadbin, about half the size of the first version.
; Uses ESC = row+32 col+32 cursor positioning (no direct screen write).
;
; Keys: a/left = left, d/right = right, w/up = rotate, s/down = step down,
;       space = hard drop, q = quit
; Pieces fall by themselves (GRAV_TICKS); each type has its own glyph.
;
; Differences from the first version: the PRNG is seeded from the jiffy clock (SYS_TIME) instead of
; the wall clock (SYS_CLOCK), with no constant fallback; the screens, keys and scoring are the same.
;
; How it got small (a CX program pays 2 bytes of relocation for every absolute reference to its own
; image, so a `jsr label`, `jmp label`, `lda label` or `lda #>label` costs 2 more than it looks):
;
;  * The hot scalars live in zero page ($23-$2F): no relocations, 2-byte instructions. The score, the
;    gravity timer and the serial flag are in BSS, which the loader zeroes, so they need no setup.
;  * No user library: print/print_dec would pull lib.s and num.s (about 500 bytes). Output is one
;    SYS_WRITE per screen update from `out`; the score is printed by a 5-entry subtraction table.
;  * ZP `cb` is the write buffer "ESC = row col glyph": plotting a cell is `out`(cb, 5).
;  * The 28 x 4 offset tables are 28 bytes: one 4-cell shape per piece, rotated at run time by
;    (x,y) -> (k-y, x), k = 2 (3 for I). O never rotates (its table row never changed).
;  * Left/right/rotate/down/hard drop are one `step`: add a delta to rot/px/py, undo if it collides.
;  * The well's walls are drawn by draw_board together with the cells; the board is BSS.
;  * `bit abs` skips (.byte $2c) fall through into the shared tails; loops count down and test N.

.include "../../include/breadbin.inc"

BOARD_W     = 10
BOARD_H     = 20
BOARD_TOP   = 2
BOARD_LEFT  = 14
SCORE_ROW   = 2
SCORE_COL   = 28

KBNDX       = $c6       ; keys in the keyboard buffer (stock address, only read)
JIFFY       = $a2       ; low byte of the jiffy clock, 60 Hz (stock address, only read)
GRAV_TICKS  = 30        ; jiffies per automatic step down (0.5 s)

; zero page: $23-$2F, the program's own
j           = $23       ; second counter / lines cleared by the piece that just landed
piece       = $24       ; 1..7 = I O T S Z J L (also the glyph index; 0 = empty)
rot         = $25       ; \  adjacent: `step` addresses them as rot+0, +1, +2
px          = $26       ; |  piece column of the 4x4 box (signed: the box may overhang the wall)
py          = $27       ; /  row
rng         = $28       ; 8-bit LFSR, never 0
i           = $29       ; loop counter
cb          = $2a       ; 5 bytes: ESC '=' row+32 col+32 glyph (the cell write buffer)
act         = $2f       ; the key's action (see `keys`)

.segment "CODE"

start:  jsr SYS_TIME            ; seed from the jiffy clock
        ora #1                  ; never 0
        sta rng
        lda #ESC
        sta cb
        lda #'='
        sta cb+1
        ; On the serial line the KERNAL keyboard buffer stays empty: read the line through /dev/tty
        ; opened O_NONBLOCK instead (EAGAIN = no key). `ser` says we are on the serial line; kfd is
        ; the fd to read keys from, and stays 0 if the open fails: fd 0 still works there, but each
        ; read then waits for a key (no gravity until one comes).
        lda #0
        jsr SYS_ISATTY
        bcs @con
        cpx #1
        bne @con
        stx ser
        lda #<tty_path
        sta r0
        lda #>tty_path
        sta r0+1
        lda #(O_RDONLY | O_NONBLOCK)
        jsr SYS_OPEN
        bcs @con
        sta kfd
@con:   lda #1
        jsr SYS_CONMODE         ; raw: single keys take effect at once
        lda #<frame
        ldx #>frame
        ldy #FRAME_LEN
        jsr out                 ; clear the screen, draw the top and bottom borders
redraw: jsr draw_board
        jsr draw_score

; the next piece: an LFSR step, 0..6 only (so all seven are equally likely), at the top
newp:   lda rng
        asl a
        bcc @n
        eor #$1d
@n:     sta rng
        and #7
        cmp #7
        bcs newp
        adc #1                  ; (carry is clear)
        sta piece
        lda #0
        sta rot
        sta py
        lda #3
        sta px
        jsr check
        bcs quit                ; does not fit: game over
        jsr draw_piece
        lda JIFFY
        sta tick

; never block in read: on the console a key is read only when the keyboard buffer has one; on the
; serial line the read itself says (carry set: none yet)
ml:     lda ser
        bne @ser
        lda KBNDX
        bne rdkey
        beq @idle
@ser:   jsr read_key
        bcc got
@idle:  jsr SYS_YIELD           ; idle: let other processes run
        lda JIFFY
        sec
        sbc tick                ; elapsed jiffies (wraps correctly mod 256)
        cmp #GRAV_TICKS
        bcc ml
        ldx #4                  ; gravity is the "down" action
        bne go

quit:   lda #<msg_over
        ldx #>msg_over
        ldy #OVER_LEN
        jsr out
        lda #0
        jsr SYS_CONMODE         ; cooked again
        lda #0
        jmp SYS_EXIT

rdkey:  jsr read_key
got:    ldx #10
@f:     cmp keys,x
        beq @found
        dex
        bpl @f
        bmi ml                  ; not a key we know
@found: txa
        lsr a                   ; two keys per action
        tax
go:     beq quit                ; action 0
        stx act
        cpx #3
        bne @nr
        lda piece
        cmp #2
        beq ml                  ; O: rotating changes nothing
@nr:    cpx #4
        bcc @nt
        lda JIFFY               ; down and hard drop restart the gravity timer
        sta tick
@nt:    jsr erase_piece
@lp:    jsr step                ; C = blocked
        ldx act
        bcs @blk
        cpx #5
        beq @lp                 ; hard drop: keep falling
@dr:    jsr draw_piece
        jmp ml
@blk:   cpx #4
        bcc @dr                 ; a blocked left/right/rotate just stays
        jsr draw_piece

; the piece has landed: lock it, take full rows out (bottom to top), score them
        lda #3
        sta i
@lk:    jsr cell
        jsr bidx
        lda piece
        sta board,y
        dec i
        bpl @lk
        lda #0
        sta j
        lda #BOARD_W*(BOARD_H-1)
        sta i                   ; (index of the first cell of the row being looked at)
@row:   ldy i
        ldx #BOARD_W
@c:     lda board,y
        beq @next               ; a hole: not full
        iny
        dex
        bne @c
        inc j
        inc sl
        bne @s
        inc sh
@s:     ldy i
        beq @clr
@sh:    dey                     ; the rows above move down one
        lda board,y
        sta board+BOARD_W,y
        tya
        bne @sh
@clr:   ldx #BOARD_W-1
        lda #0
@z:     sta board,x
        dex
        bpl @z
        bmi @row                ; (N set) the same row holds new cells now: look again
@next:  lda i
        sec
        sbc #BOARD_W
        sta i
        bcs @row
        lda j
        bne @rd
        jmp newp
@rd:    jmp redraw              ; something cleared: redraw the well and the score

; step: add delta to the variable at rot+vt, and take it back if the piece collides. C = blocked.
step:   ldx act
        ldy vt-1,x
        lda rot,y
        pha                     ; the old value
        clc
        adc dt-1,x
        sta rot,y
        jsr check
        pla                     ; (leaves C alone)
        bcc @r
        ldx act
        ldy vt-1,x
        sta rot,y
        sec
@r:     rts

; check: C = 1 if the piece overlaps a wall, the floor or a locked cell
check:  lda #3
        sta i
@l:     jsr cell
        cmp #BOARD_W            ; a negative column is >= 128
        bcs @hit
        cpx #BOARD_H
        bcs @hit
        jsr bidx
        lda board,y
        bne @hit
        dec i
        bpl @l
        clc
        rts
@hit:   sec
        rts

; cell: cell i of the piece -> A = board column, X = board row. The shape's cell is rotated `rot` times
; by (x,y) -> (k-y, x); r2 holds x and r2+1 y, j the constant k. Trashes r2, r2+1, j.
cell:   lda piece
        asl a
        asl a
        ora i
        tax
        lda shapes-4,x          ; x*4 + y
        pha
        lsr a
        lsr a
        sta r2
        pla
        and #3
        sta r2+1
        lda #2
        ldx piece
        cpx #1
        bne @k
        lda #3                  ; the I piece turns around a point between cells
@k:     sta j
        lda rot
        and #3
        tax
        beq @d
@r:     lda j
        sec
        sbc r2+1
        ldy r2
        sty r2+1
        sta r2
        dex
        bne @r
@d:     lda r2
        clc
        adc px
        pha
        lda r2+1
        clc
        adc py
        tax
        pla
        rts

; bidx: A = column, X = row -> Y = row*10 + column. Trashes r2.
bidx:   sta r2
        txa
        asl a
        sta r2+1
        asl a
        asl a                   ; row*8 < 256: carry is clear
        adc r2+1                ; row*10
        adc r2
        tay
        rts

; erase_piece / draw_piece: plot the piece's cells as blanks / as its glyph
erase_piece:
        ldy #0
        .byte $2c               ; bit abs: skips the next ldy
draw_piece:
        ldy piece
        lda glyphs,y
        sta cb+4
        lda #3
        sta i
@l:     jsr cell
        jsr put_at
        dec i
        bpl @l
        rts

; draw_board: the whole well, walls included (columns -1 and 10)
draw_board:
        lda #BOARD_H-1
        sta i
@row:   lda #BOARD_W
        sta j
@col:   lda j
        cmp #BOARD_W            ; 10, or -1 (= 255)
        bcs @wall
        ldx i
        jsr bidx
        lda board,y
        tay
        lda glyphs,y
        .byte $2c               ; bit abs: skips the next lda
@wall:  lda #'|'
        sta cb+4
        lda j
        ldx i
        jsr put_at
        dec j
        lda j
        cmp #$fe
        bne @col
        dec i
        bpl @row
        rts

; draw_score: the label and the number, no leading zeros (digit by subtraction of 10000 .. 1)
draw_score:
        lda #<msg_score
        ldx #>msg_score
        ldy #SCORE_LEN
        jsr out
        lda sl
        sta cb+2                ; (the remainder: row and column are not needed now)
        lda sh
        sta cb+3
        lda #0
        sta j                   ; nonzero once a digit was printed
        lda #8
        sta i                   ; 2 * power of ten
@dig:   ldx i
        ldy #'0'-1
@sub:   iny
        lda cb+2
        sec
        sbc pw,x
        sta r2
        lda cb+3
        sbc pw+1,x
        bcc @got
        sta cb+3
        lda r2
        sta cb+2
        bcs @sub                ; (always)
@got:   tya
        ldx i
        beq @pr                 ; the units digit is always printed
        cmp #'0'
        bne @pr
        ldx j
        beq @nx                 ; a leading zero
@pr:    sta j
        sta cb+4
        lda #cb+4
        ldx #0
        ldy #1
        jsr out
@nx:    dec i
        dec i
        bpl @dig
        rts

; put_at: A = board column, X = board row, glyph already in cb+4: draw it. Falls into out.
put_at: clc
        adc #BOARD_LEFT+32
        sta cb+3
        txa
        clc
        adc #BOARD_TOP+32
        sta cb+2
        lda #cb
        ldx #0
        ldy #5
; out: write Y bytes at A/X to the console (fd 1)
out:    sta r0
        stx r0+1
        sty r1
        ldx #0
        stx r1+1
        inx
        txa
        jmp SYS_WRITE

; read_key: one byte from fd kfd -> A, carry clear; 'q' if the read fails or hits end of file;
; carry set (A = 'q', ignored) if nothing has been typed yet (EAGAIN: O_NONBLOCK only)
read_key:
        lda #'q'
        sta cb+4
        lda #cb+4
        sta r0
        lda #0
        sta r0+1
        sta r1+1
        lda #1
        sta r1
        lda kfd
        jsr SYS_READ
        bcs @err
        clc                     ; (end of file wrote nothing: still 'q')
        lda cb+4
        rts
@err:   cmp #EAGAIN
        beq @none
        clc
@none:  lda cb+4
        rts

; ----------------------------------------------------------------------
tty_path: .byte "/dev/tty", 0
frame:  .byte K_CLR
        .byte ESC,'=',BOARD_TOP-1+32,BOARD_LEFT-1+32,"+----------+"
        .byte ESC,'=',BOARD_TOP+BOARD_H+32,BOARD_LEFT-1+32,"+----------+"
FRAME_LEN = * - frame
msg_score:
        .byte ESC,'=',SCORE_ROW+32,SCORE_COL+32,"SCORE: "
SCORE_LEN = * - msg_score
msg_over:
        .byte ESC,'=',BOARD_TOP+10+32,BOARD_LEFT+1+32,"GAME OVER"
        .byte ESC,'=',BOARD_TOP+22+32,32                ; leave the cursor below the well
OVER_LEN = * - msg_over

; two keys per action: 0 quit, 1 left, 2 right, 3 rotate, 4 down, 5 hard drop
keys:   .byte 'q','Q','a',K_LEFT,'d',K_RIGHT,'w',K_UP,'s',K_DOWN,' '
vt:     .byte 1,1,0,2,2         ; the variable at rot+n that each action changes: px px rot py py
dt:     .byte $ff,1,1,1,1       ; and by how much

pw:     .word 1,10,100,1000,10000       ; read with X = 2 * power of ten: pw,x low, pw+1,x high

; glyph for each cell value: empty, then I O T S Z J L
glyphs: .byte ' ','#','O','@','%','&','*','='

; the four cells of each piece (x*4 + y, in its 4x4 box), rotation 0
.macro pt xx, yy
        .byte (xx)*4 + (yy)
.endmacro
shapes: pt 0,1
        pt 1,1
        pt 2,1
        pt 3,1                   ; I
        pt 1,0
        pt 2,0
        pt 1,1
        pt 2,1                   ; O
        pt 1,0
        pt 0,1
        pt 1,1
        pt 2,1                   ; T
        pt 1,0
        pt 2,0
        pt 0,1
        pt 1,1                   ; S
        pt 0,0
        pt 1,0
        pt 1,1
        pt 2,1                   ; Z
        pt 0,0
        pt 0,1
        pt 1,1
        pt 2,1                   ; J
        pt 2,0
        pt 0,1
        pt 1,1
        pt 2,1                   ; L

.segment "BSS"
sl:     .res 1                  ; score, low
sh:     .res 1                  ; score, high
tick:   .res 1                  ; jiffy clock at the last step down
ser:    .res 1                  ; nonzero on the serial line (keys are polled with read_key)
kfd:    .res 1                  ; the fd keys are read from: 0 = fd 0, or /dev/tty opened O_NONBLOCK
board:  .res BOARD_W * BOARD_H
