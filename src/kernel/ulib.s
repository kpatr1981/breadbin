; Breadbin user library, kept in the kernel: strings, numbers, output,
; errors. Programs reach it through the jump table (SYS_PRINT and the
; others in breadbin.inc; src/lib/lib.s gives them their old names), so
; every program no longer carries a copy.
;
; These are not system calls: the table jumps straight here, and the code
; runs as part of the program (preemptible, interrupts on), calling the real
; system calls like any program would. So it may use only the program's
; zero page: $30-$3F, which is saved per process. Kernel scratch (tmp0 ...)
; is off limits here.
.include "k.inc"
.export ul_print, ul_eprint, ul_fprint, ul_putc, ul_eputc, ul_fputc
.export ul_newline, ul_print_dec, ul_print_dec_w, ul_print_hex, ul_dec_str
.export ul_parse_dec, ul_strlen, ul_strcmp, ul_argn, ul_perr, ul_errstr
.export ul_open_or_die, ul_basename

lp1  = $30
lp2  = $32
lp3  = $34
lt0  = $36
lt1  = $37
lt2  = $38
lt3  = $39
lchar = $37             ; fputc: the byte (r0 points here while it is written)
pv   = $37              ; parse_dec: the value (2 bytes)
ldec = $3a              ; dec_str: up to 5 digits and a NUL ($3a-$3f)

.segment "CODE"
; open_or_die: A/X = path, Y = flags -> A = fd; on error prints and exits 1
ul_open_or_die:
        sta lp3
        stx lp3+1
        sta r0
        stx r0+1
        tya
        jsr SYS_OPEN
        bcc @r
        ldx lp3
        ldy lp3+1
        jsr ul_perr
        lda #1
        jmp SYS_EXIT
@r:     rts

; basename: A/X = path -> A/X = part after the last '/'
ul_basename:
        sta lp1
        stx lp1+1
        ldy #0
        sty lt0
@l:     lda (lp1),y
        beq @d
        iny
        cmp #'/'
        bne @l
        sty lt0
        jmp @l
@d:     lda lp1
        clc
        adc lt0
        ldx lp1+1
        bcc @r
        inx
@r:     rts

; strlen: A/X = string -> Y = A = length (max 255)
ul_strlen:
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
ul_fprint:
        sty lt0
        sta r0
        stx r0+1
        jsr ul_strlen
        sta r1
        lda #0
        sta r1+1
        lda lt0
        jmp SYS_WRITE
ul_print:
        ldy #1
        jmp ul_fprint
ul_eprint:
        ldy #2
        jmp ul_fprint

; fputc: A = char, Y = fd
ul_fputc:
        sta lchar
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
ul_putc:
        ldy #1
        jmp ul_fputc
ul_eputc:
        ldy #2
        jmp ul_fputc
ul_newline:
        lda #10
        jmp ul_putc

; dec_str: A/X -> ldec, returns A/X = pointer to the first digit, Y = length
ul_dec_str:
        sta lp1
        stx lp1+1
        ldy #5
        lda #0
        sta ldec+5
@dg:    lda #0
        ldx #16
@dv:    asl lp1
        rol lp1+1
        rol a
        cmp #10
        bcc @n
        sbc #10
        inc lp1
@n:     dex
        bne @dv
        ora #'0'
        dey
        sta ldec,y
        lda lp1
        ora lp1+1
        bne @dg
        sty lt1
        lda #5
        sec
        sbc lt1
        tay
        lda lt1
        clc
        adc #<ldec
        ldx #>ldec
        rts

; print_dec: A/X unsigned to stdout
ul_print_dec:
        jsr ul_dec_str
        jmp ul_print

; print_dec_w: A/X unsigned, right aligned in Y columns
ul_print_dec_w:
        sty lt2
        jsr ul_dec_str
        sta lp2
        stx lp2+1
        sty lt3
@pad:   lda lt3
        cmp lt2
        bcs @p
        lda #' '
        jsr ul_putc
        inc lt3
        jmp @pad
@p:     lda lp2
        ldx lp2+1
        jmp ul_print

; print_hex: A as two hex digits
ul_print_hex:
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
        jmp ul_putc

; parse_dec: A/X = string -> A/X = value; carry set if not a number
ul_parse_dec:
        sta lp1
        stx lp1+1
        lda #0
        sta pv
        sta pv+1
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
        ; pv = pv*10 + digit
        lda pv
        ldx pv+1
        asl pv
        rol pv+1
        asl pv
        rol pv+1            ; *4
        clc
        adc pv
        sta pv
        txa
        adc pv+1
        sta pv+1            ; *5
        asl pv
        rol pv+1            ; *10
        lda pv
        clc
        adc lt0
        sta pv
        bcc @n
        inc pv+1
@n:     iny
        bne @l
@ok:    lda pv
        ldx pv+1
        clc
        rts
@bad:   sec
        rts

; strcmp: (lp1) vs (lp2) -> Z set if equal
ul_strcmp:
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
ul_argn:
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
ul_perr:
        sta lt3
        stx lp3
        sty lp3+1
        lda #0
        jsr ul_argn
        jsr ul_eprint
        lda #<s_colon
        ldx #>s_colon
        jsr ul_eprint
        lda lp3
        ora lp3+1
        beq @m
        lda lp3
        ldx lp3+1
        jsr ul_eprint
        lda #<s_colon
        ldx #>s_colon
        jsr ul_eprint
@m:     lda lt3
        jsr ul_errstr
        jsr ul_eprint
        lda #10
        jmp ul_eputc

; errstr: A = errno -> A/X = message
ul_errstr:
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
        .byte EBUSY
        .word e_busy
        .byte EEXIST
        .word e_exist
        .byte ENODEV
        .word e_nodev
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
e_busy:   .byte "device busy", 0
e_nodev:  .byte "no such device or no disk", 0
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
