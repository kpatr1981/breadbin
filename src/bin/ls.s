; ls [-l] [-a] [path...]: list directory contents
.include "../../include/c64os.inc"
.import argn, perr, print, putc, newline, print_dec_w, strlen
.importzp lp1
idx   = $23
fd    = $24
longf = $25
allf  = $26
col   = $27
tty   = $28
npath = $29
cur   = $2a             ; 2 bytes: current argument
COLW  = 13
.segment "CODE"
        lda #0
        sta longf
        sta allf
        sta npath
        lda #1
        jsr SYS_ISATTY
        lda #0
        rol a               ; carry set = not a terminal -> one per line
        sta tty
        ; options
        lda #1
        sta idx
@opt:   lda idx
        jsr argn
        bcs @opts_done
        sta lp1
        stx lp1+1
        ldy #0
        lda (lp1),y
        cmp #'-'
        bne @nopt
@oc:    iny
        lda (lp1),y
        beq @nopt
        cmp #'l'
        bne @oa
        sta longf
        jmp @oc
@oa:    cmp #'a'
        bne @oc
        sta allf
        jmp @oc
@nopt:  inc idx
        jmp @opt
@opts_done:
        lda #1
        sta idx
@arg:   lda idx
        jsr argn
        bcs @argend
        sta cur
        stx cur+1
        sta lp1
        stx lp1+1
        ldy #0
        lda (lp1),y
        cmp #'-'
        beq @skip
        inc npath
        jsr list
@skip:  inc idx
        jmp @arg
@argend:
        lda npath
        bne @done
        lda #<dot
        sta cur
        lda #>dot
        sta cur+1
        jsr list
@done:  rts

; list the path in `cur`
list:   lda cur
        sta r0
        lda cur+1
        sta r0+1
        lda #<st
        sta r1
        lda #>st
        sta r1+1
        jsr SYS_STAT
        bcc @ok
        ldx cur
        ldy cur+1
        jmp perr
@ok:    lda st
        cmp #T_DIR
        beq @dir
        ; a single file: show it like an entry
        lda cur
        ldx cur+1
        jsr show_path
        jmp endline
@dir:   lda cur
        sta r0
        lda cur+1
        sta r0+1
        lda #O_RDONLY
        jsr SYS_OPEN
        bcc @op
        ldx cur
        ldy cur+1
        jmp perr
@op:    sta fd
        lda #0
        sta col
@rd:    lda #<ent
        sta r0
        lda #>ent
        sta r0+1
        lda #16
        sta r1
        lda #0
        sta r1+1
        lda fd
        jsr SYS_READ
        bcs @close
        lda r1
        cmp #16
        bne @close
        lda ent
        beq @rd
        lda allf
        bne @show
        lda ent+1
        cmp #'.'
        beq @rd
@show:  jsr entry
        jmp @rd
@close: lda fd
        jsr SYS_CLOSE
        jmp endline

endline:
        lda col
        beq @r
        lda #0
        sta col
        jmp newline
@r:     rts

; entry: show ent+1 (name) inside directory `cur`
entry:  lda longf
        bne @long
        lda #<(ent+1)
        ldx #>(ent+1)
        jmp show_name
@long:  ; build cur/name for stat
        ldy #0
@c:     lda (cur),y
        beq @ce
        sta pbuf,y
        iny
        bne @c
@ce:    lda pbuf-1,y
        cmp #'/'
        beq @ns
        lda #'/'
        sta pbuf,y
        iny
@ns:    ldx #0
@n:     lda ent+1,x
        sta pbuf,y
        beq @nd
        iny
        inx
        bne @n
@nd:    lda #<pbuf
        sta r0
        lda #>pbuf
        sta r0+1
        lda #<st
        sta r1
        lda #>st
        sta r1+1
        jsr SYS_STAT
        lda #<(ent+1)
        ldx #>(ent+1)
        jmp show_long

; show_path: A/X = path (a non-directory argument)
show_path:
        ldy longf
        bne show_long
; show_name: A/X = name; columns on a terminal, one per line otherwise
show_name:
        sta lp1
        stx lp1+1
        lda tty
        bne @one
        lda col
        beq @first
        cmp #3
        bcc @pad
        jsr newline
        lda #0
        sta col
        jmp @first
@pad:   ; pad previous name to COLW
@p:     lda pad
        beq @first
        lda #' '
        jsr putc
        dec pad
        jmp @p
@first: lda lp1
        ldx lp1+1
        jsr strlen
        sta pad
        lda #COLW
        sec
        sbc pad
        bcs @w
        lda #1
@w:     sta pad
        lda lp1
        ldx lp1+1
        jsr print
        inc col
        rts
@one:   lda lp1
        ldx lp1+1
        jsr print
        jmp newline

; show_long: A/X = name, st = stat
show_long:
        pha
        txa
        pha
        ldx st
        lda types,x
        jsr putc
        lda st+2
        ldx st+3
        ldy #7
        jsr print_dec_w
        lda #' '
        jsr putc
        pla
        tax
        pla
        jsr print
        jmp newline

.segment "RODATA"
dot:   .byte ".", 0
types: .byte "?-dc"
.segment "BSS"
st:    .res 8
ent:   .res 16
pbuf:  .res 80
pad:   .res 1
