; grep [-v] [-c] pattern [file]: print lines containing pattern
.include "../../include/breadbin.inc"
.import argn, open_or_die, getc, set_input, eprint, print_dec, newline
.importzp lp1
pat  = $23              ; 2: pattern pointer
len  = $25              ; line length
inv  = $26
idx  = $27
cnt  = $28              ; 2
cflag = $2a
found = $2b
.segment "CODE"
        lda #0
        sta inv
        sta cflag
        sta cnt
        sta cnt+1
        lda #1
        sta idx
@o:     lda idx
        jsr argn
        bcc @oarg
        jmp @usage
@oarg:
        sta lp1
        stx lp1+1
        ldy #0
        lda (lp1),y
        cmp #'-'
        bne @pat
        iny
        lda (lp1),y
        cmp #'v'
        bne @oc
        inc inv
@oc:    cmp #'c'
        bne @on
        inc cflag
@on:    inc idx
        jmp @o
@pat:   lda lp1
        sta pat
        lda lp1+1
        sta pat+1
        inc idx
        lda idx
        jsr argn
        bcs @stdin
        ldy #O_RDONLY
        jsr open_or_die
        jmp @go
@stdin: lda #0
@go:    jsr set_input
@line:  lda #0
        sta len
@ch:    jsr getc
        bcs @eof
        cmp #10
        beq @eol
        ldx len
        cpx #250
        bcs @ch
        sta buf,x
        inc len
        jmp @ch
@eof:   lda len
        beq @end
        jsr match
        jmp @end
@eol:   jsr match
        jmp @line
@end:   lda cflag
        beq @x
        lda cnt
        ldx cnt+1
        jsr print_dec
        jsr newline
@x:     lda cnt
        ora cnt+1
        beq @no
        lda #0
        jmp SYS_EXIT
@no:    lda #1
        jmp SYS_EXIT
@usage: lda #<usage
        ldx #>usage
        jsr eprint
        lda #2
        jmp SYS_EXIT

; match: buf[0..len) contains pattern? print it (respecting -v)
match:  lda #0
        sta found
        ldx #0
@start: ldy #0
@cmp:   lda (pat),y
        beq @yes
        stx tmp
        txa
        sty tmp2
        clc
        adc tmp2
        cmp len
        bcs @no
        tax
        lda buf,x
        ldx tmp
        cmp (pat),y
        bne @next
        iny
        bne @cmp
@next:  inx
        cpx len
        bcc @start
        beq @start
        jmp @no
@yes:   inc found
@no:    lda found
        eor inv
        beq @r
        inc cnt
        bne @pc
        inc cnt+1
@pc:    lda cflag
        bne @r
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        ldx len
        lda #10
        sta buf,x
        inx
        stx r1
        lda #0
        sta r1+1
        lda #1
        jmp SYS_WRITE
@r:     rts
.segment "RODATA"
usage: .byte "usage: grep [-v] [-c] pattern [file]", 10, 0
.segment "BSS"
buf:  .res 256
tmp:  .res 1
tmp2: .res 1
