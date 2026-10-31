; as: a two-pass 6502 assembler that runs on Breadbin
;
;   as prog.s prog        assemble prog.s into the executable `prog`
;
; Source syntax (case-insensitive):
;   label:  lda #<msg     ; comment
;   name = expr
;   .byte 1, "text", >addr      .word expr, ...      .res count
; Operands: #imm  #<expr  #>expr  zp/abs  ,x ,y  (zp,x)  (zp),y  (abs)
; Expressions: numbers ($hex %bin dec 'c'), labels, * (pc), + and -.
; System names are predefined: sys_exit .. sys_sync, r0 r1 r2,
; argv argc, o_rdonly o_wronly o_rdwr o_creat o_trunc o_append.
; Output is a relocatable CX file: run it like any other command.
.include "../../include/breadbin.inc"
.import getc, set_input, argn, print, eprint, print_dec, newline, perr
.import open_or_die, fputc

syp  = $23              ; symbol pointer
obp  = $25              ; output pointer
tq   = $27

NSYM   = 220
SYMSZ  = 18             ; name[15] value[2] flags
OBMAX  = 8192
RMAX   = 1024
F_DEF  = 1
F_REL  = 2
F_SEEN = 4
F_BUILTIN = 8

.segment "BSS"
pass:   .res 1
pc:     .res 2
lineno: .res 2
nrel:   .res 2
errs:   .res 1
lbuf:   .res 128
li:     .res 1
name:   .res 16
nlen:   .res 1
nsym:   .res 1
ev:     .res 2          ; expression value
erel:   .res 1          ; relocatable symbol count (signed)
efwd:   .res 1          ; used a symbol not yet defined in this pass
ehl:    .res 1          ; 0 none, 1 <, 2 >
tv:     .res 2
trel:   .res 1
esign:  .res 1
mnem:   .res 1
mode:   .res 1
opc:    .res 1
idx:    .res 1
srcp:   .res 2
outp:   .res 2
fd:     .res 1
hdr:    .res 9
symtab: .res NSYM*SYMSZ
obuf:   .res OBMAX
rbuf:   .res RMAX*2

.segment "CODE"
start:  lda argc
        cmp #3
        beq @ok
        lda #<s_usage
        ldx #>s_usage
        jsr eprint
        lda #1
        jmp SYS_EXIT
@ok:    lda #1
        jsr argn
        sta srcp
        stx srcp+1
        lda #2
        jsr argn
        sta outp
        stx outp+1
        jsr init_syms
        lda #1
        sta pass
        jsr run_pass
        lda errs
        bne @fail
        jsr clear_seen
        lda #2
        sta pass
        jsr run_pass
        lda errs
        beq @write
@fail:  lda #1
        jmp SYS_EXIT
@write: jsr write_out
        lda outp
        ldx outp+1
        jsr print
        lda #<s_colon
        ldx #>s_colon
        jsr print
        lda pc
        ldx pc+1
        jsr print_dec
        lda #<s_bytes
        ldx #>s_bytes
        jsr print
        lda nrel
        ldx nrel+1
        jsr print_dec
        lda #<s_rels
        ldx #>s_rels
        jsr print
        lda #0
        jmp SYS_EXIT

run_pass:
        lda srcp
        ldx srcp+1
        ldy #O_RDONLY
        jsr open_or_die
        sta fd
        jsr set_input
        lda #0
        sta pc
        sta pc+1
        sta lineno
        sta lineno+1
        sta nrel
        sta nrel+1
rp_loop:
        jsr readline
        bcs rp_done
        inc lineno
        bne rp_n
        inc lineno+1
rp_n:   tsx
        stx errsp_
        jsr do_line
line_done:
        jmp rp_loop
rp_done:
        lda fd
        jmp SYS_CLOSE

write_out:
        lda outp
        sta r0
        lda outp+1
        sta r0+1
        lda #(O_WRONLY | O_CREAT | O_TRUNC)
        jsr SYS_OPEN
        bcc @ok
        ldx outp
        ldy outp+1
        jsr perr
        lda #1
        jmp SYS_EXIT
@ok:    sta fd
        lda #'C'
        sta hdr
        lda #'X'
        sta hdr+1
        lda #1
        sta hdr+2
        lda pc
        sta hdr+3
        lda pc+1
        sta hdr+4
        lda #0
        sta hdr+5
        sta hdr+6
        lda nrel
        sta hdr+7
        lda nrel+1
        sta hdr+8
        lda #<hdr
        ldx #>hdr
        ldy #9
        jsr wr
        lda pc
        sta r1
        lda pc+1
        sta r1+1
        lda #<obuf
        sta r0
        lda #>obuf
        sta r0+1
        lda fd
        jsr SYS_WRITE
        lda nrel
        asl a
        sta r1
        lda nrel+1
        rol a
        sta r1+1
        lda #<rbuf
        sta r0
        lda #>rbuf
        sta r0+1
        lda fd
        jsr SYS_WRITE
        lda fd
        jmp SYS_CLOSE
wr:     sta r0
        stx r0+1
        sty r1
        lda #0
        sta r1+1
        lda fd
        jmp SYS_WRITE

; readline: getc -> lbuf, lowercased outside quotes; carry set at EOF
readline:
        ldx #0
@c:     stx li
        jsr getc
        ldx li
        bcs @eof
        cmp #10
        beq @end
        cpx #127
        bcs @c
        sta lbuf,x
        inx
        jmp @c
@eof:   cpx #0
        bne @end
        sec
        rts
@end:   lda #0
        sta lbuf,x
        ldx #0
        ldy #0
@lc:    lda lbuf,x
        beq @done
        cmp #'"'
        beq @q
        cmp #$27
        bne @nq
@q:     tya
        eor #1
        tay
        jmp @nx
@nq:    cpy #0
        bne @nx
        cmp #'A'
        bcc @nx
        cmp #'Z'+1
        bcs @nx
        ora #$20
        sta lbuf,x
@nx:    inx
        bne @lc
@done:  lda #0
        sta li
        clc
        rts

; ---------------------------------------------------------------------
do_line:
        jsr skipsp
        jsr peek
        beq @r
        cmp #';'
        beq @r
        cmp #'.'
        beq @dir
        jsr isidstart
        bcs @bad
        jsr getname
        jsr peek
        cmp #':'
        bne @nolab
        jsr adv
        lda pc
        ldx pc+1
        ldy #F_REL
        jsr define
        jsr skipsp
        jsr peek
        beq @r
        cmp #';'
        beq @r
        cmp #'.'
        beq @dir
        jsr getname
        jmp @ins
@nolab: jsr skipsp
        jsr peek
        cmp #'='
        bne @ins
        jsr adv
        jsr save_name
        jsr expr
        jsr restore_name
        lda erel
        beq @abs
        ldy #F_REL
        bne @def
@abs:   ldy #0
@def:   lda ev
        ldx ev+1
        jmp define
@ins:   jmp instruction
@dir:   jsr adv
        jsr getname
        jmp directive
@bad:   lda #<e_syntax
        ldx #>e_syntax
        jmp error
@r:     rts

save_name:
        ldx #15
@l:     lda name,x
        sta name2,x
        dex
        bpl @l
        rts
restore_name:
        ldx #15
@l:     lda name2,x
        sta name,x
        dex
        bpl @l
        rts

; ---- directives ----
directive:
        lda #<d_byte
        ldx #>d_byte
        jsr name_is
        beq d_bytes
        lda #<d_word
        ldx #>d_word
        jsr name_is
        beq d_words
        lda #<d_res
        ldx #>d_res
        jsr name_is
        bne @nres
        jmp d_ress
@nres:
        lda #<d_text
        ldx #>d_text
        jsr name_is
        beq d_bytes
        lda #<e_dir
        ldx #>e_dir
        jmp error

d_bytes:
@l:     jsr skipsp
        jsr peek
        cmp #'"'
        bne @e
        jsr adv
@s:     jsr peek
        beq @r
        jsr adv
        cmp #'"'
        beq @next
        jsr emit
        jmp @s
@e:     jsr expr
        lda erel
        beq @b
        lda ehl
        cmp #2
        bne @b
        jsr reloc_here
@b:     lda ev
        jsr emit
@next:  jsr skipsp
        jsr peek
        cmp #','
        bne @r
        jsr adv
        jmp @l
@r:     rts

d_words:
@l:     jsr expr
        lda erel
        beq @w
        lda pc
        clc
        adc #1
        tax
        lda pc+1
        adc #0
        jsr reloc_at
@w:     lda ev
        jsr emit
        lda ev+1
        jsr emit
        jsr skipsp
        jsr peek
        cmp #','
        bne @r
        jsr adv
        jmp @l
@r:     rts

d_ress: jsr expr
@l:     lda ev
        ora ev+1
        beq @r
        lda #0
        jsr emit
        lda ev
        bne @d
        dec ev+1
@d:     dec ev
        jmp @l
@r:     rts

; ---- instructions ----
instruction:
        lda nlen
        cmp #3
        bne @unk
        ldx #0
        ldy #0
@f:     lda mnames,y
        cmp name
        bne @nx
        lda mnames+1,y
        cmp name+1
        bne @nx
        lda mnames+2,y
        cmp name+2
        beq @found
@nx:    iny
        iny
        iny
        inx
        cpx #NMNEM
        bne @f
@unk:   lda #<e_ins
        ldx #>e_ins
        jmp error
@found: stx mnem
        ; tq = &optab[mnem*13]
        txa
        sta tq
        lda #0
        sta tq+1
        ldy #12
@m13:   txa                 ; tq += mnem, 12 more times
        clc
        adc tq
        sta tq
        bcc @mc
        inc tq+1
@mc:    dey
        bne @m13
        lda tq
        clc
        adc #<optab
        sta tq
        lda tq+1
        adc #>optab
        sta tq+1
        jsr skipsp
        jsr peek
        beq @noop
        cmp #';'
        beq @noop
        cmp #'a'
        bne @nacc
        ldy li
        lda lbuf+1,y
        beq @acc
        cmp #' '
        beq @acc
        cmp #';'
        bne @nacc
@acc:   jsr adv
        lda #1
        jmp emit_mode0
@noop:  lda #0
        jsr has_mode
        bcs @tacc
        lda #0
        jmp emit_mode0
@tacc:  lda #1              ; asl etc. with no operand = accumulator
        jmp emit_mode0
@nacc:  cmp #'#'
        bne @nimm
        jsr adv
        jsr expr
        lda #2
        jsr need_mode
        jsr emit_op
        lda erel
        beq @ib
        lda ehl
        cmp #2
        bne @ib
        jsr reloc_here
@ib:    lda ev
        jmp emit
@nimm:  cmp #'('
        bne @direct
        jsr adv
        jsr expr
        jsr skipsp
        jsr peek
        cmp #','
        bne @ind1
        jsr adv
        jsr expect_x
        jsr expect_rp
        lda #9
        jmp emit_zp
@ind1:  jsr expect_rp
        jsr skipsp
        jsr peek
        cmp #','
        bne @ind
        jsr adv
        jsr expect_y
        lda #10
        jmp emit_zp
@ind:   lda #11
        jmp emit_abs
@direct:
        jsr expr
        ; branch?
        lda #12
        jsr has_mode
        bcs @nobr
        jmp emit_branch
@nobr:  lda #0
        sta idx
        jsr skipsp
        jsr peek
        cmp #','
        bne @mode
        jsr adv
        jsr skipsp
        jsr peek
        jsr adv
        cmp #'x'
        beq @ix
        cmp #'y'
        beq @iy
        jmp bad_mode
@ix:    lda #1
        sta idx
        bne @mode
@iy:    lda #2
        sta idx
@mode:  ; zp form allowed?
        lda efwd
        ora erel
        ora ev+1
        bne @absf
        ldx idx
        lda zpmodes,x
        jsr has_mode
        bcs @absf
        ldx idx
        lda zpmodes,x
        jmp emit_zp
@absf:  ldx idx
        lda absmodes,x
        jsr has_mode
        bcs @tryzp
        ldx idx
        lda absmodes,x
        jmp emit_abs
@tryzp: ldx idx             ; e.g. "stx zp,y" written with a constant > 255
        lda zpmodes,x
        jsr has_mode
        bcs bad_mode
        ldx idx
        lda zpmodes,x
        jmp emit_zp

bad_mode:
        lda #<e_mode
        ldx #>e_mode
        jmp error

; has_mode: A = mode -> carry clear if the mnemonic has it (opc = opcode)
has_mode:
        tay
        lda (tq),y
        sta opc
        cmp #$ff
        bne @y
        sec
        rts
@y:     clc
        rts

need_mode:
        jsr has_mode
        bcs bad_mode
        rts

emit_op:
        lda opc
        jmp emit

emit_mode0:
        jsr need_mode
        jmp emit_op

emit_zp:
        jsr need_mode
        jsr emit_op
        lda ev
        jmp emit

emit_abs:
        jsr need_mode
        jsr emit_op
        lda erel
        beq @n
        jsr reloc_next      ; high byte is at pc+1 after the low byte
@n:     lda ev
        jsr emit
        lda ev+1
        jmp emit

emit_branch:
        lda #12
        jsr has_mode
        jsr emit_op
        ; offset = ev - (pc + 1)
        lda pc
        clc
        adc #1
        sta tv
        lda pc+1
        adc #0
        sta tv+1
        lda ev
        sec
        sbc tv
        sta tv
        lda ev+1
        sbc tv+1
        sta tv+1
        lda pass
        cmp #2
        bne @emit
        ; must fit in -128..127
        lda tv+1
        beq @pos
        cmp #$ff
        bne @far
        lda tv
        bmi @emit
        jmp @far
@pos:   lda tv
        bpl @emit
@far:   lda #<e_range
        ldx #>e_range
        jmp error
@emit:  lda tv
        jmp emit

expect_x:
        jsr skipsp
        jsr peek
        jsr adv
        cmp #'x'
        bne @b
        rts
@b:     jmp bad_mode
expect_y:
        jsr skipsp
        jsr peek
        jsr adv
        cmp #'y'
        bne @b
        rts
@b:     jmp bad_mode
expect_rp:
        jsr skipsp
        jsr peek
        jsr adv
        cmp #')'
        bne @b
        rts
@b:     jmp bad_mode

; ---- output ----
emit:   ldx pass
        cpx #2
        bne @inc
        pha
        lda pc+1
        cmp #>OBMAX
        bcc @ok
        pla
        lda #<e_big
        ldx #>e_big
        jmp error
@ok:    lda #<obuf
        clc
        adc pc
        sta obp
        lda #>obuf
        adc pc+1
        sta obp+1
        pla
        ldy #0
        sta (obp),y
@inc:   inc pc
        bne @r
        inc pc+1
@r:     rts

; reloc_here: the next emitted byte needs the load page added
reloc_here:
        ldx pc
        lda pc+1
        jmp reloc_at
; reloc_next: the byte after the next one (high byte of an address)
reloc_next:
        lda pc
        clc
        adc #1
        tax
        lda pc+1
        adc #0
; reloc_at: X/A = offset
reloc_at:
        ldy pass
        cpy #2
        bne @r
        pha
        lda nrel+1
        cmp #>RMAX
        bcc @ok
        pla
        lda #<e_big
        ldx #>e_big
        jmp error
@ok:    lda nrel
        asl a
        sta obp
        lda nrel+1
        rol a
        sta obp+1
        lda obp
        clc
        adc #<rbuf
        sta obp
        lda obp+1
        adc #>rbuf
        sta obp+1
        txa
        ldy #0
        sta (obp),y
        pla
        iny
        sta (obp),y
        inc nrel
        bne @r
        inc nrel+1
@r:     rts

; ---------------------------------------------------------------------
; expressions -> ev, erel, efwd, ehl
expr:   lda #0
        sta ev
        sta ev+1
        sta erel
        sta efwd
        sta ehl
        sta esign
        jsr skipsp
        jsr peek
        cmp #'<'
        bne @hi
        lda #1
        sta ehl
        jsr adv
        jmp @terms
@hi:    cmp #'>'
        bne @terms
        lda #2
        sta ehl
        jsr adv
@terms: jsr term
        lda esign
        bne @sub
        lda ev
        clc
        adc tv
        sta ev
        lda ev+1
        adc tv+1
        sta ev+1
        lda erel
        clc
        adc trel
        sta erel
        jmp @more
@sub:   lda ev
        sec
        sbc tv
        sta ev
        lda ev+1
        sbc tv+1
        sta ev+1
        lda erel
        sec
        sbc trel
        sta erel
@more:  jsr skipsp
        jsr peek
        cmp #'+'
        bne @m
        lda #0
        beq @op
@m:     cmp #'-'
        bne @end
        lda #1
@op:    sta esign
        jsr adv
        jmp @terms
@end:   lda ehl
        beq @chk
        cmp #1
        bne @hb
        lda #0
        sta ev+1
        sta erel            ; low byte of a page-aligned address is fixed
        rts
@hb:    lda ev+1
        sta ev
        lda #0
        sta ev+1
@chk:   lda erel
        beq @r
        cmp #1
        beq @r
        lda #<e_reloc
        ldx #>e_reloc
        jmp error
@r:     rts

term:   lda #0
        sta tv
        sta tv+1
        sta trel
        jsr skipsp
        jsr peek
        cmp #'$'
        beq @hex
        cmp #'%'
        beq @bin
        cmp #$27
        beq @chr
        cmp #'*'
        beq @pc
        jsr isdigit
        bcc @dec
        jsr isidstart
        bcs @nsym
        jmp @sym
@nsym:  lda #<e_syntax
        ldx #>e_syntax
        jmp error
@r0:    rts
@pc:    jsr adv
        lda pc
        sta tv
        lda pc+1
        sta tv+1
        lda #1
        sta trel
        rts
@chr:   jsr adv
        jsr peek
        sta tv
        jsr adv
        jsr peek
        cmp #$27
        bne @r0
        jmp adv
@hex:   jsr adv
@hl:    jsr peek
        jsr hexval
        bcs @r0
        ldx #4
@hs:    asl tv
        rol tv+1
        dex
        bne @hs
        ora tv
        sta tv
        jsr adv
        jmp @hl
@bin:   jsr adv
@bl:    jsr peek
        cmp #'0'
        beq @b0
        cmp #'1'
        bne @r
@b0:    lsr a               ; carry = bit
        rol tv
        rol tv+1
        jsr adv
        jmp @bl
@dec:   jsr peek
        jsr isdigit
        bcs @r
        sec
        sbc #'0'
        pha
        lda tv
        sta tq2
        lda tv+1
        sta tq2+1
        asl tv
        rol tv+1
        asl tv
        rol tv+1
        lda tv
        clc
        adc tq2
        sta tv
        lda tv+1
        adc tq2+1
        sta tv+1
        asl tv
        rol tv+1
        pla
        clc
        adc tv
        sta tv
        bcc @dn
        inc tv+1
@dn:    jsr adv
        jmp @dec
@r:     rts
@sym:   jsr save_name
        jsr getname
        jsr lookup
        bcs @undef
        ldy #15
        lda (syp),y
        sta tv
        iny
        lda (syp),y
        sta tv+1
        iny
        lda (syp),y
        tax
        and #F_REL
        beq @na
        lda #1
        sta trel
@na:    txa
        and #(F_SEEN | F_BUILTIN)
        bne @seen
        lda pass
        cmp #2
        beq @fw
        txa
        and #F_DEF
        bne @seen
@fw:    lda #1
        sta efwd
@seen:  jmp restore_name
@undef: lda #1
        sta efwd
        lda pass
        cmp #2
        bne @seen
        jsr restore_name
        lda #<e_undef
        ldx #>e_undef
        jmp error

; hexval: A = char -> A = 0-15, carry clear; carry set if not hex
hexval: cmp #'0'
        bcc @no
        cmp #'9'+1
        bcc @d
        cmp #'a'
        bcc @no
        cmp #'f'+1
        bcs @no
        sbc #'a'-11
        clc
        rts
@d:     sbc #'0'-1
        clc
        rts
@no:    sec
        rts

; ---------------------------------------------------------------------
; symbols
; getname: identifier at li -> name (NUL-padded), nlen
getname:
        ldx #0
@l:     jsr peek
        jsr isidchar
        bcs @e
        cpx #14
        bcs @skip
        sta name,x
        inx
@skip:  jsr adv
        jmp @l
@e:     stx nlen
        lda #0
@p:     cpx #16
        bcs @r
        sta name,x
        inx
        bne @p
@r:     rts

; lookup: name -> syp = entry, carry clear if found
lookup: lda #<symtab
        sta syp
        lda #>symtab
        sta syp+1
        ldx nsym
        beq @no
@l:     ldy #0
@c:     lda (syp),y
        cmp name,y
        bne @n
        iny
        cpy #15
        bne @c
        clc
        rts
@n:     lda syp
        clc
        adc #SYMSZ
        sta syp
        bcc @x
        inc syp+1
@x:     dex
        bne @l
@no:    sec
        rts

; define: name = A/X with flags Y (F_REL or 0)
define: sta tv
        stx tv+1
        sty trel
        jsr lookup
        bcc @have
        ; new symbol (pass 1)
        lda nsym
        cmp #NSYM
        bcc @room
        lda #<e_syms
        ldx #>e_syms
        jmp error
@room:  inc nsym
        ldy #0
@cp:    lda name,y
        sta (syp),y
        iny
        cpy #15
        bne @cp
        jmp @set
@have:  lda pass
        cmp #2
        beq @set
        lda #<e_dup
        ldx #>e_dup
        jmp error
@set:   ldy #15
        lda tv
        sta (syp),y
        iny
        lda tv+1
        sta (syp),y
        iny
        lda trel
        ora #F_DEF
        ldx pass
        cpx #2
        bne @f
        ora #F_SEEN
@f:     sta (syp),y
        rts

clear_seen:
        lda #<symtab
        sta syp
        lda #>symtab
        sta syp+1
        ldx nsym
        beq @r
@l:     ldy #17
        lda (syp),y
        and #<~F_SEEN
        sta (syp),y
        lda syp
        clc
        adc #SYMSZ
        sta syp
        bcc @n
        inc syp+1
@n:     dex
        bne @l
@r:     rts

; init_syms: predefined system names
init_syms:
        lda #0
        sta nsym
        lda #<builtins
        sta obp
        lda #>builtins
        sta obp+1
@l:     ldy #0
        lda (obp),y
        beq @r
        ldx #0
@c:     lda (obp),y
        sta name,x
        beq @e
        inx
        iny
        bne @c
@e:     lda #0
@p:     cpx #16
        bcs @v
        sta name,x
        inx
        bne @p
@v:     iny
        lda (obp),y
        sta tv
        iny
        lda (obp),y
        tax
        iny
        tya
        clc
        adc obp
        sta obp
        bcc @d
        inc obp+1
@d:     lda tv
        ldy #F_BUILTIN
        jsr define
        jmp @l
@r:     rts

; ---------------------------------------------------------------------
; text helpers
peek:   ldy li
        lda lbuf,y
        rts
adv:    inc li
        rts
skipsp: jsr peek
        cmp #' '
        beq @a
        cmp #9
        bne @r
@a:     jsr adv
        jmp skipsp
@r:     rts
isdigit:
        cmp #'0'
        bcc @no
        cmp #'9'+1
        bcs @no
        clc
        rts
@no:    sec
        rts
isidstart:
        cmp #'_'
        beq @y
        cmp #'a'
        bcc @no
        cmp #'z'+1
        bcs @no
@y:     clc
        rts
@no:    sec
        rts
isidchar:
        jsr isidstart
        bcc @r
        jmp isdigit
@r:     rts

; name_is: compare name with the string at A/X -> Z set if equal
name_is:
        sta obp
        stx obp+1
        ldy #0
@l:     lda (obp),y
        cmp name,y
        bne @r
        cmp #0
        beq @r
        iny
        bne @l
@r:     rts

; error: print "as: line N: message" (A/X) and skip the rest of the line
error:  pha
        txa
        pha
        inc errs
        lda #<s_as
        ldx #>s_as
        jsr eprint
        lda lineno
        ldx lineno+1
        jsr eprint_dec
        lda #<s_colon
        ldx #>s_colon
        jsr eprint
        pla
        tax
        pla
        jsr eprint
        lda #10
        ldy #2
        jsr fputc
        ; abandon this line: unwind to run_pass's loop
        ldx errsp_
        txs
        jmp line_done
eprint_dec:
        sta tq2
        stx tq2+1
        ldy #0
@d:     lda #0
        ldx #16
@v:     asl tq2
        rol tq2+1
        rol a
        cmp #10
        bcc @n
        sbc #10
        inc tq2
@n:     dex
        bne @v
        ora #'0'
        pha
        iny
        lda tq2
        ora tq2+1
        bne @d
@p:     pla
        sty tq2
        ldy #2
        jsr fputc
        ldy tq2
        dey
        bne @p
        rts

.segment "RODATA"
.include "as_ops.inc"
zpmodes:  .byte 3, 4, 5
absmodes: .byte 6, 7, 8
d_byte:  .byte "byte", 0
d_word:  .byte "word", 0
d_res:   .byte "res", 0
d_text:  .byte "text", 0
s_usage: .byte "usage: as source output", 10, 0
s_as:    .byte "as: line ", 0
s_colon: .byte ": ", 0
s_bytes: .byte " bytes, ", 0
s_rels:  .byte " relocations", 10, 0
e_syntax: .byte "syntax error", 0
e_ins:   .byte "unknown instruction", 0
e_dir:   .byte "unknown directive", 0
e_mode:  .byte "bad addressing mode", 0
e_range: .byte "branch out of range", 0
e_undef: .byte "undefined symbol", 0
e_dup:   .byte "duplicate symbol", 0
e_syms:  .byte "too many symbols", 0
e_big:   .byte "program too big", 0
e_reloc: .byte "bad relocatable expression", 0
.macro SYM n, v
        .byte n, 0
        .word v
.endmacro
builtins:
        SYM "sys_exit", SYS_EXIT
        SYM "sys_spawn", SYS_SPAWN
        SYM "sys_wait", SYS_WAIT
        SYM "sys_kill", SYS_KILL
        SYM "sys_getpid", SYS_GETPID
        SYM "sys_yield", SYS_YIELD
        SYM "sys_sleep", SYS_SLEEP
        SYM "sys_open", SYS_OPEN
        SYM "sys_close", SYS_CLOSE
        SYM "sys_read", SYS_READ
        SYM "sys_write", SYS_WRITE
        SYM "sys_pipe", SYS_PIPE
        SYM "sys_mkdir", SYS_MKDIR
        SYM "sys_rmdir", SYS_RMDIR
        SYM "sys_unlink", SYS_UNLINK
        SYM "sys_rename", SYS_RENAME
        SYM "sys_chdir", SYS_CHDIR
        SYM "sys_getcwd", SYS_GETCWD
        SYM "sys_stat", SYS_STAT
        SYM "sys_procinfo", SYS_PROCINFO
        SYM "sys_meminfo", SYS_MEMINFO
        SYM "sys_fsinfo", SYS_FSINFO
        SYM "sys_time", SYS_TIME
        SYM "sys_isatty", SYS_ISATTY
        SYM "sys_conmode", SYS_CONMODE
        SYM "sys_getuid", SYS_GETUID
        SYM "sys_setuid", SYS_SETUID
        SYM "sys_mount", SYS_MOUNT
        SYM "sys_umount", SYS_UMOUNT
        SYM "sys_mntinfo", SYS_MNTINFO
        SYM "sys_diskio", SYS_DISKIO
        SYM "sys_fg", SYS_FG
        SYM "sys_sync", SYS_SYNC
        SYM "r0", r0
        SYM "r1", r1
        SYM "r2", r2
        SYM "argv", argv
        SYM "argc", argc
        SYM "o_rdonly", O_RDONLY
        SYM "o_wronly", O_WRONLY
        SYM "o_rdwr", O_RDWR
        SYM "o_creat", O_CREAT
        SYM "o_trunc", O_TRUNC
        SYM "o_append", O_APPEND
        .byte 0

.segment "BSS"
name2:  .res 16
tq2:    .res 2
errsp_: .res 1
