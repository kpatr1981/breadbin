; rev [file...]: reverse the characters of every line (a port of Unix rev)
;
; Build it like any Breadbin command: copy it to src/bin/rev.s and run make.
.include "../../include/breadbin.inc"
.import getc, set_input, putc, newline, argn, open_or_die

LINEMAX = 255
arg     = $23           ; next argv index ($23-$2F are free for programs)

.segment "CODE"
        lda argc
        cmp #2
        bcs files
        lda #0                  ; no arguments: filter standard input
        jsr set_input
        jsr rev_input
        lda #0
        jmp SYS_EXIT

files:  lda #1
        sta arg
@next:  lda arg
        jsr argn                ; A/X = argv[arg]; carry set past the end
        bcs @done
        ldy #O_RDONLY
        jsr open_or_die         ; prints "rev: name: error" and exits on failure
        sta fd
        jsr set_input
        jsr rev_input
        lda fd
        jsr SYS_CLOSE
        inc arg
        bne @next
@done:  lda #0
        jmp SYS_EXIT

; rev_input: reverse each line read with getc until end of file
rev_input:
        ldx #0
@get:   stx len
        jsr getc                ; A = byte; carry set at end of file
        ldx len
        bcs @eof
        cmp #10
        beq @line
        cpx #LINEMAX
        bcs @get                ; line too long: drop the rest
        sta line,x
        inx
        bne @get
@eof:   cpx #0
        beq @r                  ; nothing left over
@line:  cpx #0                  ; print line[len-1] .. line[0]
        beq @nl
        dex
        stx len
        lda line,x
        jsr putc
        ldx len
        jmp @line
@nl:    jsr newline
        jmp rev_input
@r:     rts

.segment "BSS"
fd:     .res 1
len:    .res 1
line:   .res LINEMAX
