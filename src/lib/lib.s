; c64os user library: strings, numbers, output, errors
.include "../../include/c64os.inc"

lp1  = $30
lp2  = $32
lp3  = $34
lt0  = $36
lt1  = $37
lt2  = $38
lt3  = $39
lval = $3a              ; 2 bytes
.exportzp lp1, lp2, lp3, lval

.export print, eprint, fprint, putc, eputc, newline, print_dec, print_dec_w
.export strlen, parse_dec, strcmp, argn, perr, errstr, exit, write_buf
.export fputc, print_hex

.segment "BSS"
lchar:  .res 1
ldec:   .res 7

.segment "CODE"
exit:   jmp SYS_EXIT

; strlen: A/X = string -> Y = A = length (max 255)
strlen:
        sta lp1
        stx lp1+1
        ldy #0
@l:     lda (lp1),y
        beq @d
        iny
        bne @l
        dey
@d:     tya
        rts

; fprint: A/X = string, Y = fd
fprint:
        sty lt0
        sta r0
        stx r0+1
        jsr strlen
        sta r1
        lda #0
        sta r1+1
        lda lt0
        jmp SYS_WRITE
print:  ldy #1
        jmp fprint
eprint: ldy #2
        jmp fprint

; write_buf: A = fd, r0/r1 set
write_buf:
        jmp SYS_WRITE

; fputc: A = char, Y = fd
fputc:  sta lchar
        sty lt0
        lda #<lchar
        sta r0
        lda #>lchar
        sta r0+1
        lda #1
        sta r1
        lda #0
        sta r1+1
        lda lt0
        jmp SYS_WRITE
putc:   ldy #1
        jmp fputc
eputc:  ldy #2
        jmp fputc
newline:
        lda #10
        jmp putc

; dec_str: A/X -> ldec, returns A/X pointer to first digit, Y = length
dec_str:
        sta lval
        stx lval+1
        ldy #6
        lda #0
        sta ldec+6
@dg:    lda #0
        ldx #16
@dv:    asl lval
        rol lval+1
        rol a
        cmp #10
        bcc @n
        sbc #10
        inc lval
@n:     dex
        bne @dv
        ora #'0'
        dey
        sta ldec,y
        lda lval
        ora lval+1
        bne @dg
        sty lt1
        lda #6
        sec
        sbc lt1
        tay
        lda lt1
        clc
        adc #<ldec
        ldx #>ldec
        bcc @r
        inx
@r:     rts

; print_dec: A/X unsigned to stdout
print_dec:
        jsr dec_str
        jmp print

; print_dec_w: A/X unsigned, right aligned in Y columns
print_dec_w:
        sty lt2
        jsr dec_str
        sta lp2
        stx lp2+1
        sty lt3
@pad:   lda lt3
        cmp lt2
        bcs @p
        lda #' '
        jsr putc
        inc lt3
        jmp @pad
@p:     lda lp2
        ldx lp2+1
        jmp print

; print_hex: A as two hex digits
print_hex:
        pha
        lsr a
        lsr a
        lsr a
        lsr a
        jsr @nib
        pla
        and #$0f
@nib:   cmp #10
        bcc @d
        adc #'a'-'0'-11
@d:     adc #'0'
        jmp putc

; parse_dec: A/X = string -> A/X = value; carry set if not a number
parse_dec:
        sta lp1
        stx lp1+1
        lda #0
        sta lval
        sta lval+1
        tay
        lda (lp1),y
        beq @bad
@l:     lda (lp1),y
        beq @ok
        sec
        sbc #'0'
        cmp #10
        bcs @bad
        sta lt0
        ; lval = lval*10 + digit
        lda lval
        ldx lval+1
        asl lval
        rol lval+1
        asl lval
        rol lval+1          ; *4
        clc
        adc lval
        sta lval
        txa
        adc lval+1
        sta lval+1          ; *5
        asl lval
        rol lval+1          ; *10
        lda lval
        clc
        adc lt0
        sta lval
        bcc @n
        inc lval+1
@n:     iny
        bne @l
@ok:    lda lval
        ldx lval+1
        clc
        rts
@bad:   sec
        rts

; strcmp: (lp1) vs (lp2) -> Z set if equal
strcmp:
        ldy #0
@l:     lda (lp1),y
        cmp (lp2),y
        bne @r
        cmp #0
        beq @r
        iny
        bne @l
@r:     rts

; argn: A = index -> A/X = argv[index]; carry set if index >= argc
argn:
        cmp argc
        bcs @r
        asl a
        tay
        lda (argv),y
        pha
        iny
        lda (argv),y
        tax
        pla
        clc
@r:     rts

; perr: A = errno, X/Y = extra string or 0/0.
; prints "argv0: [extra: ]message" to stderr
perr:
        sta lt3
        stx lp3
        sty lp3+1
        lda #0
        jsr argn
        jsr eprint
        lda #<s_colon
        ldx #>s_colon
        jsr eprint
        lda lp3
        ora lp3+1
        beq @m
        lda lp3
        ldx lp3+1
        jsr eprint
        lda #<s_colon
        ldx #>s_colon
        jsr eprint
@m:     lda lt3
        jsr errstr
        jsr eprint
        lda #10
        jmp eputc

; errstr: A = errno -> A/X = message
errstr:
        ldx #0
@l:     ldy errtab,x
        beq @unk
        cmp errtab,x
        beq @f
        inx
        inx
        inx
        bne @l
@f:     lda errtab+2,x
        pha
        lda errtab+1,x
        tay
        pla
        tax
        tya
        rts
@unk:   lda #<e_unk
        ldx #>e_unk
        rts

.segment "RODATA"
s_colon: .byte ": ", 0
errtab:
        .byte EPERM
        .word e_perm
        .byte ENOENT
        .word e_noent
        .byte ESRCH
        .word e_srch
        .byte EIO
        .word e_io
        .byte E2BIG
        .word e_2big
        .byte ENOEXEC
        .word e_noexec
        .byte EBADF
        .word e_badf
        .byte ECHILD
        .word e_child
        .byte EAGAIN
        .word e_again
        .byte ENOMEM
        .word e_nomem
        .byte EEXIST
        .word e_exist
        .byte EXDEV
        .word e_xdev
        .byte ENOTDIR
        .word e_notdir
        .byte EISDIR
        .word e_isdir
        .byte EINVAL
        .word e_inval
        .byte EMFILE
        .word e_mfile
        .byte EFBIG
        .word e_fbig
        .byte ENOSPC
        .word e_nospc
        .byte EPIPE
        .word e_pipe
        .byte ENAMETOOLONG
        .word e_long
        .byte ENOTEMPTY
        .word e_notempty
        .byte 0
e_perm:   .byte "operation not permitted", 0
e_noent:  .byte "no such file or directory", 0
e_srch:   .byte "no such process", 0
e_io:     .byte "i/o error", 0
e_2big:   .byte "argument list too long", 0
e_noexec: .byte "exec format error", 0
e_badf:   .byte "bad file descriptor", 0
e_child:  .byte "no child processes", 0
e_again:  .byte "too many processes", 0
e_nomem:  .byte "out of memory", 0
e_exist:  .byte "file exists", 0
e_xdev:   .byte "cross-device link", 0
e_notdir: .byte "not a directory", 0
e_isdir:  .byte "is a directory", 0
e_inval:  .byte "invalid argument", 0
e_mfile:  .byte "too many open files", 0
e_fbig:   .byte "file too large", 0
e_nospc:  .byte "no space left on device", 0
e_pipe:   .byte "broken pipe", 0
e_long:   .byte "file name too long", 0
e_notempty: .byte "directory not empty", 0
e_unk:    .byte "error", 0
