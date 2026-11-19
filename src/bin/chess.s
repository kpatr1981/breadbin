; Ported from upstream Breadbin (https://github.com/kpatr1981/breadbin, MIT; Copyright 2026 Konstantinos Patronas),
; chess.s by Elena (upstream commits f87a46b, c5b8b93, 1d6e3a7; the repo's own words: "vibed by Lenu").
; Rewritten for size; same game, same screens, same save file, same AI choices.
;
; How it is small:
;  - One generator (gen) serves move entry, the AI and check detection. Directions come from the tables
;    st/en/dt (knight, diagonals, orthogonals, white pawn, black pawn); pawn moves are told apart by the
;    parity of the delta (captures are odd) and the double step by "from minus two steps is off the board".
;  - Check: from the king's square, generate as each piece type and look for an enemy piece of that type
;    (want has bit 7 set = report a hit instead of appending).
;  - Scores are 8-bit, in tenths of a pawn, +2 bias; g returns the negated worth (the d/e-file bonus is the
;    borrow of the file test), so eval is subtractions only.
;  - One slot of undo (pc, cap, from, to); the king is found by scanning, not tracked.
;  - Board gaps (the 0x88 half) always hold 0, so scans need no &$88. Zero-page bytes are shared by lifetime.
;  - Strings are one blob indexed from X; the first-screen newline is shared with the footer.
; Behaviour kept on purpose: any input starting with a, q, s or l is that command (so "a2a3" is an AI move).
; Differences from upstream, all only reachable from a hand-made (illegal) save: a pawn on its far back rank
; may double-step; with a king missing there is no "check!" (upstream's answer came from an $FF sentinel);
; several kings, piece type 7, junk in the board gaps or a turn byte other than 0/$80 play differently.
; Legal games are identical (differential-tested against upstream, mate and stalemate included).
; ============================================================================
; chess: 0x88 chess against a 1-ply AI.  e2e4 moves, a = the AI moves, s/l = save/load /tmp/chess.sav, q quits.
; ============================================================================

.include "../../include/breadbin.inc"
.setcpu "6502"
.export _start

; zero page $20-$2F: one byte each, shared by lifetime (the aliases)
turn  = $20     ; $00 white, $80 black
from  = $21     ; parse stores through from,x: x = 0 -> from, x = 2 -> to
pc    = $22     ; the piece that moved (before promotion)
to    = $23
cap   = $24     ; what stood on `to`
sq    = $25     ; gen: the square being looked at
xe    = $26     ; gen: end of its run in dt
ray   = $27     ; gen: bit 7 clear = slides
tgt   = $28     ; gen: what stands on sq (the one before it, for a pawn's double step)
want  = $29     ; gen: type (append), or $80+type (look for that enemy piece)
ncand = $2A     ; candidates in cand
ci    = $2B     ; the AI's index into cand
best  = $2C     ; the best score so far (0: none yet)
bf    = $2D
bt    = $2E
ct    = $2F     ; in_check's piece type counter
ch    = sq      ; output only: putc's byte
si    = xe      ;               puts' index
ri    = ci      ;               render's square
rc    = ncand   ;               render's rank label
sc    = ct      ; eval's running sum

KING  = 6

.segment "CODE"

_start:
    ldx #7
@i: lda back,x
    sta board+$70,x
    ora #$80
    sta board,x
    lda #1
    sta board+$60,x
    ora #$80
    sta board+$10,x
    dex
    bpl @i
    inx
    stx turn
    beq loop

quit:
    lda #0
    jmp SYS_EXIT

loop:
    jsr render
    jsr in_check
    bcc @nc
    ldx #m_check
    jsr puts
@nc:
    ldx #m_wp
    lda turn
    bpl @p
    ldx #m_bp
@p: jsr puts

    lda #<in_buf
    sta r0
    lda #>in_buf
    sta r0+1
    lda #15
    sta r1
    ldx #0
    stx r1+1
    txa
    jsr SYS_READ
    bcs quit
    ldx r1
    beq quit
    lda #0
    sta in_buf,x

    lda in_buf
    cmp #'q'
    beq quit
    cmp #'s'
    bne :+
    jmp save
:
    cmp #'l'
    bne :+
    jmp load
:
    cmp #'a'
    bne :+
    jmp ai
:

    ldx #3
@pr:
    lda in_buf,x
    sec
    sbc #'1'
    cmp #8
    bcs err_syn
    eor #7
    asl a
    asl a
    asl a
    asl a
    sta sc
    dex
    lda in_buf,x
    sec
    sbc #'a'
    cmp #8
    bcs err_syn
    ora sc
    sta from,x
    dex
    bpl @pr
    lda in_buf+4
    beq @ok
    cmp #10
    beq @ok
    cmp #13
    bne err_syn
@ok:
    ldx from
    lda board,x
    beq err_ill
    eor turn
    bmi err_ill
    ldx #0
    stx ncand
    jsr gen
    ldx ncand
@s: dex
    bmi err_ill
    lda cand,x
    cmp to
    bne @s
    jsr trymv
    bcs err_ill
flip:
    lda turn
    eor #$80
    sta turn
    jmp loop

err_syn:
    ldx #m_syn
    .byte $2c
err_ill:
    ldx #m_ill
show:
    jsr puts
    jmp loop

; ---------------------------------------------------------------------------
ai:
    ldx #0
    stx best
    stx from
@f: ldx from
    lda board,x
    beq @nf
    eor turn
    bmi @nf
    ldx #0
    stx ncand
    stx ci
    jsr gen
@c: ldx ci
    cpx ncand
    beq @nf
    lda cand,x
    sta to
    jsr trymv
    bcs @inc
    jsr eval
    sta sc
    lda best
    cmp sc
    bcs @undo
    lda sc
    sta best
    lda from
    sta bf
    lda to
    sta bt
@undo:
    jsr unmake
@inc:
    inc ci
    bne @c
@nf:
    inc from
    bpl @f
    lda best
    beq @none
    lda bf
    sta from
    lda bt
    sta to
    jsr trymv
    jmp flip
@none:
    jsr in_check
    ldx #m_mate
    bcs show
    ldx #m_stale
    bne show

; ---------------------------------------------------------------------------
; trymv: make from-to, refuse (and undo) it if it leaves our king in check. C=1: refused.
trymv:
    ldy from
    lda board,y
    sta pc
    ldx to
    lda board,x
    sta cap
    lda pc
    eor #1
    and #7
    bne @np
    lda to
    and #$70
    beq @pro
    cmp #$70
    bne @np
@pro:
    lda pc
    clc
    adc #4
    bne @put
@np:
    lda pc
@put:
    sta board,x
    lda #0
    sta board,y
    jsr in_check
    bcc tm_rts
unmake:
    ldy from
    lda pc
    sta board,y
    ldy to
    lda cap
    sta board,y
    sec
tm_rts:
    rts

; in_check: C=1 if the king of `turn` is attacked: from the king's square, look for an enemy
; piece of each type reachable the way that type moves.
in_check:
    ldx #0
@f: lda board,x
    eor turn
    cmp #KING
    beq @k
    inx
    bpl @f
    clc
    rts
@k: lda from
    pha
    stx from
    ldy #6
@t: sty ct
    tya
    ora #$80
    jsr gen
    bcs @o
    ldy ct
    dey
    bne @t
@o: pla
    sta from
    rts

; gen: want = type (bit 7 clear) -> cand[ncand++] = the squares the piece of `turn` on `from` can move to;
;      want = $80+type -> C=1 if one of them holds an enemy piece of that type, else C=0.
gen:
    sta want
    and #7
    tax
    cpx #1
    bne @t
    lda turn
    bpl @t
    ldx #7
@t: lda en,x
    sta xe
    txa
    sec
    sbc #3
    cmp #3
    ror ray
    lda st,x
    tax
@dir:
    lda from
    sta sq
@step:
    lda sq
    clc
    adc dt,x
    sta sq
    and #$88
    bne @nxt
    ldy sq
    lda board,y
    cpx #16
    bcs @pawn
    sta tgt
@chk:
    lda tgt
    beq @acc
    eor turn
    bpl @nxt
@acc:
    lda want
    bpl @add
    lda tgt
    eor turn
    cmp want
    bne @aft
    sec
    rts
@add:
    ldy ncand
    lda sq
    sta cand,y
    inc ncand
@aft:
    lda tgt
    bne @nxt
    bit ray
    bpl @step
@nxt:
    inx
    cpx xe
    bne @dir
    clc
    rts
@pawn:
    ldy tgt
    sta tgt
    lda dt,x
    lsr a
    bcs @pcap
    lda tgt
    bne @nxt
    txa
    and #3
    cmp #1
    bne @acc
    tya
    bne @nxt
    lda from
    sec
    sbc dt,x
    and #$88
    beq @nxt
    bne @acc
@pcap:
    lda tgt
    beq @nxt
    bne @chk

; eval: A = 2 + what the move just made gains `turn`, in tenths of a pawn (see g)
eval:
    ldy to
    lda board,y
    jsr g
    sta sc
    lda cap
    beq @nc
    ldy to
    jsr g
    clc
    adc sc
    sta sc
@nc:
    lda pc
    ldy from
    jsr g
    sec
    sbc sc
    clc
    adc #2
    rts

; g: A = piece, Y = square -> A = minus its worth: the value in tenths of a pawn, plus one on the d or e file
g:
    and #7
    tax
    tya
    and #7
    sec
    sbc #3
    cmp #2
    lda nb,x
    sbc #0
    rts

; ---------------------------------------------------------------------------
render:
    ldx #m_hdr
    jsr puts
    lda #'8'
    sta rc
    ldx #0
    stx ri
@r: lda rc
    jsr pp
@c: ldx ri
    lda board,x
    tay
    and #7
    tax
    tya
    asl a
    lda chars,x
    bcc @w
    ora #$20
@w: jsr pp
    inc ri
    lda ri
    and #7
    bne @c
    lda #10
    jsr putc
    dec rc
    lda ri
    clc
    adc #8
    sta ri
    bpl @r
    ldx #m_foot
puts:
    stx si
@l: ldx si
    lda msgs,x
    beq @r2
    inc si
    jsr putc
    bcc @l
@r2:
    rts

pp:
    jsr putc
    lda #' '
putc:
    sta ch
    lda #ch
    sta r0
    ldx #0
    stx r0+1
    stx r1+1
    inx
    stx r1
    txa
    jmp SYS_WRITE

; ---------------------------------------------------------------------------
save:
    lda turn
    sta bturn
    lda #(O_WRONLY | O_CREAT | O_TRUNC)
    jsr open
    bcs io_err
    sta want
    jsr buf
    lda want
    jsr SYS_WRITE
    jsr close
    bcs io_err
    ldx #m_saved
    jmp show
load:
    lda #O_RDONLY
    jsr open
    bcs io_err
    sta want
    jsr buf
    lda want
    jsr SYS_READ
    jsr close
    bcs io_err
    lda bturn
    sta turn
    ldx #m_loaded
    jmp show
io_err:
    ldx #m_io
    jmp show

open:
    ldx #<(msgs + m_path)
    stx r0
    ldx #>(msgs + m_path)
    stx r0+1
    jmp SYS_OPEN
buf:
    lda #<board
    sta r0
    lda #>board
    sta r0+1
    lda #129
    sta r1
    lda #0
    sta r1+1
    rts
close:
    php
    lda want
    jsr SYS_CLOSE
    plp
    rts

; ---------------------------------------------------------------------------
.segment "RODATA"

back: .byte 4, 2, 3, 5, 6, 3, 2, 4
chars: .byte ".PNBRQK"
nb:   .byte 0, <-10, <-32, <-33, <-50, <-90, 0
st:   .byte 0, 16, 0, 8, 12, 8, 8, 20
en:   .byte 0, 20, 8, 12, 16, 16, 16, 24
dt:   .byte $DF, $E1, $EE, $F2, $0E, $12, $1F, $21
      .byte $EF, $F1, $0F, $11
      .byte $F0, $10, $FF, $01
      .byte $F0, $E0, $EF, $F1
      .byte $10, $20, $11, $0F

msgs:
msg_hdr:   .byte 10             ; the first line is a newline and then the footer
msg_foot:  .byte "  a b c d e f g h", 10, 0
msg_check: .byte "check!", 10, 0
msg_mate:  .byte "checkmate!", 10, 0
msg_stale: .byte "stalemate!", 10, 0
msg_wp:    .byte "white (e2e4/a/s/l/q)> ", 0
msg_bp:    .byte "black (e7e5/a/s/l/q)> ", 0
msg_syn:   .byte "err: use e2e4, a, s, l, q", 10, 0
msg_ill:   .byte "err: illegal move", 10, 0
msg_saved: .byte "saved /tmp/chess.sav", 10, 0
msg_loaded: .byte "loaded /tmp/chess.sav", 10, 0
msg_io:    .byte "err: /tmp i/o", 10, 0
msg_path:  .byte "/tmp/chess.sav", 0
m_hdr = msg_hdr - msgs
m_foot = msg_foot - msgs
m_check = msg_check - msgs
m_mate = msg_mate - msgs
m_stale = msg_stale - msgs
m_wp = msg_wp - msgs
m_bp = msg_bp - msgs
m_syn = msg_syn - msgs
m_ill = msg_ill - msgs
m_saved = msg_saved - msgs
m_loaded = msg_loaded - msgs
m_io = msg_io - msgs
m_path = msg_path - msgs

.segment "BSS"
board:  .res 128
bturn:  .res 1
in_buf: .res 16
cand:   .res 28
