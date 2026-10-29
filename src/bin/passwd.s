; passwd [user]: change a password (root may change anyone's)
.include "../../include/c64os.inc"
.import print, eprint, newline, putc, argn, perr, fprint, fputc, print_dec
.import pw_open, pw_next, pw_hash, pw_name, pw_hashs, pw_uid, pw_home, pw_find_uid
.importzp lp1
fd  = $23
.segment "CODE"
start:  jsr SYS_GETUID
        sta me
        ; target user
        lda #1
        jsr argn
        bcs @self
        sta lp1
        stx lp1+1
        ldy #0
@cp:    lda (lp1),y
        sta who,y
        beq @named
        iny
        cpy #15
        bcc @cp
@named: lda me
        beq @go
        lda #<s_perm
        ldx #>s_perm
        jsr eprint
        lda #1
        jmp SYS_EXIT
@self:  lda me
        jsr pw_find_uid
        bcs @nouser
        ldy #0
@cs:    lda pw_name,y
        sta who,y
        beq @go
        iny
        bne @cs
@nouser:
        lda #<s_nouser
        ldx #>s_nouser
        jsr eprint
        lda #1
        jmp SYS_EXIT
@go:    lda #<s_new
        ldx #>s_new
        jsr print
        jsr read_secret
        lda #<pw1
        ldx #>pw1
        jsr copy_line
        lda #<s_again
        ldx #>s_again
        jsr print
        jsr read_secret
        ldy #0
@cmp:   lda line,y
        cmp pw1,y
        bne @diff
        cmp #0
        beq @same
        iny
        bne @cmp
@diff:  lda #<s_mismatch
        ldx #>s_mismatch
        jsr eprint
        lda #1
        jmp SYS_EXIT
@same:  ; new hash (empty password = no password)
        lda #0
        sta newh
        lda line
        beq @rw
        lda #<line
        ldx #>line
        jsr pw_hash
        sta lp1
        stx lp1+1
        ldy #4
@hc:    lda (lp1),y
        sta newh,y
        dey
        bpl @hc
@rw:    ; rewrite /etc/passwd via /etc/passwd.new
        lda #<p_new
        sta r0
        lda #>p_new
        sta r0+1
        lda #(O_WRONLY | O_CREAT | O_TRUNC)
        jsr SYS_OPEN
        bcc @o
        jmp @ioerr
@o:     sta fd
        jsr pw_open
        bcc @po
        jmp @ioerr
@po:
        lda #0
        sta found
@l:     jsr pw_next
        bcs @end
        ; same name?
        ldy #0
@m:     lda pw_name,y
        cmp who,y
        bne @wr
        cmp #0
        beq @hit
        iny
        bne @m
@hit:   inc found
        ldy #0
@nh:    lda newh,y
        sta pw_hashs,y
        beq @wr
        iny
        bne @nh
@wr:    lda #<pw_name
        ldx #>pw_name
        jsr out
        lda #':'
        jsr outc
        lda #<pw_hashs
        ldx #>pw_hashs
        jsr out
        lda #':'
        jsr outc
        lda pw_uid
        jsr outdec
        lda #':'
        jsr outc
        lda #<pw_home
        ldx #>pw_home
        jsr out
        lda #10
        jsr outc
        jmp @l
@end:   lda fd
        jsr SYS_CLOSE
        lda found
        bne @fnd
        jmp @nouser
@fnd:   lda #<p_new
        sta r0
        lda #>p_new
        sta r0+1
        lda #<p_pw
        sta r1
        lda #>p_pw
        sta r1+1
        jsr SYS_RENAME
        bcs @ioerr
        lda #<s_ok
        ldx #>s_ok
        jsr print
        lda #0
        jmp SYS_EXIT
@ioerr: ldx #<p_pw
        ldy #>p_pw
        jsr perr
        lda #1
        jmp SYS_EXIT
out:    ldy fd
        jmp fprint
outc:   ldy fd
        jmp fputc
outdec: ldx #'0'-1
        sec
@h:     inx
        sbc #100
        bcs @h
        adc #100
        cpx #'0'
        beq @t0
        pha
        txa
        jsr outc
        pla
        ldx #'0'-1
        sec
@t:     inx
        sbc #10
        bcs @t
        adc #10
        pha
        txa
        jsr outc
        pla
        jmp @u
@t0:    ldx #'0'-1
        sec
@t2:    inx
        sbc #10
        bcs @t2
        adc #10
        cpx #'0'
        beq @u
        pha
        txa
        jsr outc
        pla
@u:     ora #'0'
        jmp outc
copy_line:
        sta lp1
        stx lp1+1
        ldy #0
@c:     lda line,y
        sta (lp1),y
        beq @r
        iny
        bne @c
@r:     rts
read_secret:
        lda #1
        jsr SYS_CONMODE
        ldx #0
@l:     stx n
        lda #<key
        sta r0
        lda #>key
        sta r0+1
        lda #1
        sta r1
        lda #0
        sta r1+1
        lda #0
        jsr SYS_READ
        ldx n
        lda key
        cmp #K_RET
        beq @d
        cmp #$20
        bcc @l
        cpx #30
        bcs @l
        sta line,x
        inx
        jmp @l
@d:     lda #0
        sta line,x
        lda #0
        jsr SYS_CONMODE
        jmp newline
.segment "RODATA"
s_new:     .byte "new password: ", 0
s_again:   .byte "again: ", 0
s_mismatch: .byte "passwd: passwords differ", 10, 0
s_perm:    .byte "passwd: only root can change another user", 10, 0
s_nouser:  .byte "passwd: no such user", 10, 0
s_ok:      .byte "password changed", 10, 0
p_new:     .byte "/etc/passwd.new", 0
p_pw:      .byte "/etc/passwd", 0
.segment "BSS"
me:    .res 1
who:   .res 16
pw1:   .res 32
line:  .res 32
newh:  .res 6
key:   .res 1
n:     .res 1
found: .res 1
