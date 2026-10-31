; tee [-a] file...: copy stdin to stdout and into the files (-a appends)
.include "../../include/breadbin.inc"
.import argn, open_or_die
MAXF = 4
idx   = $23
n     = $24
flags = $25
p     = $26             ; 2
xs    = $28
fd    = $29
len   = $2a             ; 2
.segment "CODE"
        lda #(O_WRONLY | O_CREAT | O_TRUNC)
        sta flags
        lda #0
        sta n
        lda #1
        sta idx
        jsr argn
        bcs copy
        sta p
        stx p+1
        ldy #0
        lda (p),y
        cmp #'-'
        bne @files
        iny
        lda (p),y
        cmp #'a'
        bne @files
        lda #(O_WRONLY | O_CREAT | O_APPEND)
        sta flags
        inc idx
@files: lda idx
        jsr argn
        bcs copy
        ldy flags
        jsr open_or_die
        ldx n
        sta fds,x
        inc n
        inc idx
        cpx #MAXF-1
        bcc @files

copy:   lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #0
        sta r1
        lda #1
        sta r1+1
        lda #0
        jsr SYS_READ
        bcs done
        lda r1
        sta len
        lda r1+1
        sta len+1
        ora len
        beq done
        lda #1
        jsr out
        ldx #0
@f:     cpx n
        beq copy
        stx xs
        lda fds,x
        jsr out
        ldx xs
        inx
        jmp @f
done:   ldx #0
@c:     cpx n
        beq @x
        stx xs
        lda fds,x
        jsr SYS_CLOSE
        ldx xs
        inx
        jmp @c
@x:     lda #0
        jmp SYS_EXIT

; out: A = fd; write the len bytes in buf
out:    sta fd
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda len
        sta r1
        lda len+1
        sta r1+1
        lda fd
        jmp SYS_WRITE

.segment "BSS"
fds:    .res MAXF
buf:    .res 256
