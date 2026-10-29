; basic: a small integer BASIC for Breadbin
;
;   basic            interactive (lines with numbers are stored)
;   basic file.bas   load and run a program, then exit
;
; Statements: print (?) input let if/then goto gosub return for/to/step
; next end rem list run new load save bye. Variables a-z are 16-bit
; signed integers. Operators: + - * / % = <> < > <= >= and parentheses.
; Functions: rnd(n) abs(n). I/O goes through stdin/stdout, so basic
; works in pipes: `cat prog.bas | basic`.
.include "../../include/breadbin.inc"
.import getc, set_input, argn, print, eprint, putc, newline, print_dec
.import open_or_die, perr

tp   = $23              ; text pointer
cl   = $25              ; current line record (0 = immediate)
v0   = $27              ; expression result
v1   = $29
mp   = $2b
mq   = $2d

PROGSZ = 8192
NGOSUB = 16
NFOR   = 8
FORSZ  = 9

.segment "BSS"
ibuf:   .res 128
prog:   .res PROGSZ
ptop:   .res 2
vars:   .res 52
gstk:   .res NGOSUB*4
gsp:    .res 1
fstk:   .res NFOR*FORSZ
fsp:    .res 1
errsp:  .res 1
running: .res 1
tty:    .res 1
neg:    .res 1
num:    .res 2
cnt:    .res 2
rseed:  .res 2
depth:  .res 1
iofd:   .res 1
sgn:    .res 1
reldp:  .res 1
lnum:   .res 2
ilen:   .res 1
kwi:    .res 1

.segment "CODE"
start:
        lda #$a5
        sta rseed
        lda #$1f
        sta rseed+1
        jsr do_new
        lda #0
        jsr SYS_ISATTY
        lda #0
        rol a
        eor #1
        sta tty             ; 1 = interactive
        lda argc
        cmp #2
        bcc @repl
        ; basic file: load, run, exit
        lda #1
        jsr argn
        jsr load_path
        jsr do_run_go
        lda #0
        jmp SYS_EXIT
@repl:  lda tty
        beq repl
        lda #<s_banner
        ldx #>s_banner
        jsr print

repl:   tsx
        stx errsp
        lda #0
        sta running
        sta cl
        sta cl+1
        lda #0
        jsr set_input
@l:     lda tty
        beq @np
        lda #<s_prompt
        ldx #>s_prompt
        jsr print
@np:    jsr readline
        bcc @have
        lda #0
        jmp SYS_EXIT
@have:  jsr enter_or_exec
        jmp @l

; readline: getc -> ibuf (lowercased outside quotes); carry set at EOF
readline:
        ldx #0
        stx ilen
@c:     jsr getc
        bcs @eof
        cmp #10
        beq @end
        cmp #13
        beq @c
        ldx ilen
        cpx #127
        bcs @c
        sta ibuf,x
        inc ilen
        jmp @c
@eof:   lda ilen
        bne @end
        sec
        rts
@end:   ldx ilen
        lda #0
        sta ibuf,x
        ; lowercase outside strings
        ldx #0
        ldy #0              ; y = in string
@lc:    lda ibuf,x
        beq @done
        cmp #'"'
        bne @nq
        tya
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
        sta ibuf,x
@nx:    inx
        bne @lc
@done:  clc
        rts

; a line starting with a number is stored, anything else is run now
enter_or_exec:
        lda #<ibuf
        sta tp
        lda #>ibuf
        sta tp+1
        jsr skipsp
        jsr peek
        beq @r
        jsr isdigit
        bcs @exec
        jsr parse_num
        lda v0
        sta lnum
        lda v0+1
        sta lnum+1
        jsr peek
        cmp #' '
        bne @ns
        jsr adv
@ns:    jmp store_line
@exec:  lda #0
        sta cl
        sta cl+1
        lda #1
        sta running
        jsr exec
        lda #0
        sta running
@r:     rts

; ---------------------------------------------------------------------
; program storage: records of num(2) len(1) text... 0, sorted by num

; find_line: lnum -> mp = first record with num >= lnum; Z set if equal
find_line:
        lda #<prog
        sta mp
        lda #>prog
        sta mp+1
@l:     lda mp
        cmp ptop
        lda mp+1
        sbc ptop+1
        bcs @end
        ldy #1
        lda (mp),y
        cmp lnum+1
        bne @c
        dey
        lda (mp),y
        cmp lnum
@c:     bcs @ge
        ldy #2
        lda (mp),y
        clc
        adc mp
        sta mp
        bcc @l
        inc mp+1
        jmp @l
@ge:    ldy #0
        lda (mp),y
        cmp lnum
        bne @ne
        iny
        lda (mp),y
        cmp lnum+1
        rts
@ne:    rts
@end:   lda #1              ; not equal
        rts

store_line:
        jsr find_line
        bne @ins
        ; delete the existing record
        ldy #2
        lda (mp),y
        sta cnt
        jsr del_bytes
@ins:   jsr peek
        beq @r              ; empty text: delete only
        ; length = 3 + strlen(tp) + 1
        ldy #0
@sl:    lda (tp),y
        beq @se
        iny
        bne @sl
@se:    tya
        clc
        adc #4
        sta cnt
        ; room?
        lda ptop
        clc
        adc cnt
        sta v1
        lda ptop+1
        adc #0
        sta v1+1
        cmp #>(prog+PROGSZ)
        bcc @room
        jmp err_mem
@room:  jsr ins_bytes
        ldy #0
        lda lnum
        sta (mp),y
        iny
        lda lnum+1
        sta (mp),y
        iny
        lda cnt
        sta (mp),y
        ; copy text
        lda mp
        clc
        adc #3
        sta mq
        lda mp+1
        adc #0
        sta mq+1
        ldy #0
@ct:    lda (tp),y
        sta (mq),y
        beq @r
        iny
        bne @ct
@r:     rts

; del_bytes: remove cnt bytes at mp
del_bytes:
        lda mp
        clc
        adc cnt
        sta mq
        lda mp+1
        adc #0
        sta mq+1
        ldy #0
@l:     lda mq
        cmp ptop
        lda mq+1
        sbc ptop+1
        bcs @d
        lda (mq),y
        sta (mp),y
        inc mp
        bne @a
        inc mp+1
@a:     inc mq
        bne @l
        inc mq+1
        jmp @l
@d:     lda ptop
        sec
        sbc cnt
        sta ptop
        bcs @r
        dec ptop+1
@r:     ; restore mp to the deletion point
        lda mq
        sec
        sbc cnt
        sta mp
        lda mq+1
        sbc #0
        sta mp+1
        lda ptop
        sta mp
        lda ptop+1
        sta mp+1
        jmp find_line

; ins_bytes: open cnt bytes at mp (moves mp..ptop up)
ins_bytes:
        ; mq = ptop - 1, v1 = ptop - 1 + cnt; copy down to mp
        lda ptop
        sec
        sbc #1
        sta mq
        lda ptop+1
        sbc #0
        sta mq+1
        lda mq
        clc
        adc cnt
        sta v1
        lda mq+1
        adc #0
        sta v1+1
        ldy #0
@l:     lda mq
        cmp mp
        lda mq+1
        sbc mp+1
        bcc @d
        lda (mq),y
        sta (v1),y
        lda mq
        bne @a
        dec mq+1
@a:     dec mq
        lda v1
        bne @b
        dec v1+1
@b:     dec v1
        jmp @l
@d:     lda ptop
        clc
        adc cnt
        sta ptop
        bcc @r
        inc ptop+1
@r:     rts

; ---------------------------------------------------------------------
; execution
; exec: run statements from tp until the program stops
exec:
@stmt:  jsr skipsp
        jsr peek
        bne @nz
        jmp @eol
@nz:    cmp #':'
        bne @do
        jsr adv
        jmp @stmt
@do:    jsr statement
        lda running
        bne @stmt
        rts
@eol:   lda cl+1
        bne @next
        rts                 ; immediate line done
@next:  ldy #2
        lda (cl),y
        clc
        adc cl
        sta cl
        bcc @c
        inc cl+1
@c:     lda cl
        cmp ptop
        lda cl+1
        sbc ptop+1
        bcc @go
        lda #0
        sta running
        rts
@go:    jsr set_tp_cl
        jmp @stmt

set_tp_cl:
        lda cl
        clc
        adc #3
        sta tp
        lda cl+1
        adc #0
        sta tp+1
        rts

statement:
        ; keyword?
        ldx #0
@k:     lda kwtab,x
        beq @nokw
        stx kwi
        ldy #0
@m:     lda kwtab,x
        beq @hit
        cmp (tp),y
        bne @skip
        inx
        iny
        bne @m
@skip:  ldx kwi
@s2:    lda kwtab,x
        beq @s3
        inx
        bne @s2
@s3:    inx
        inx
        inx
        jmp @k
@hit:   ; advance tp by y, jump to handler at kwtab+x+1
        tya
        clc
        adc tp
        sta tp
        bcc @h
        inc tp+1
@h:     lda kwtab+2,x
        pha
        lda kwtab+1,x
        pha
        rts
@nokw:  ; implicit let
        jmp do_let

; ---- statements (entered with tp after the keyword; jumped to by rts) ----
do_rem: jsr peek
        beq @r
        jsr adv
        jmp do_rem
@r:     rts

do_print:
        lda #0
        sta sgn             ; 1 = suppress newline
@l:     jsr skipsp
        jsr peek
        beq @end
        cmp #':'
        beq @end
        cmp #'"'
        bne @ne
        jsr adv
@str:   jsr peek
        beq @end
        jsr adv
        cmp #'"'
        beq @sep
        jsr putc
        jmp @str
@ne:    jsr expr
        jsr print_int
@sep:   lda #0
        sta sgn
        jsr skipsp
        jsr peek
        cmp #';'
        beq @semi
        cmp #','
        bne @l
        jsr adv
        lda #' '
        jsr putc
        inc sgn
        jmp @l
@semi:  jsr adv
        inc sgn
        jmp @l
@end:   lda sgn
        bne @r
        jmp newline
@r:     rts

do_input:
        jsr skipsp
        jsr peek
        cmp #'"'
        bne @var
        jsr adv
@p:     jsr peek
        beq @var
        jsr adv
        cmp #'"'
        beq @pe
        jsr putc
        jmp @p
@pe:    jsr skipsp
        jsr peek
        cmp #';'
        bne @var
        jsr adv
@var:   jsr skipsp
        jsr getvar
        stx num
        lda #'?'
        jsr putc
        lda #' '
        jsr putc
        ; read a line from the console
        lda tp
        pha
        lda tp+1
        pha
        jsr read_tty_line
        lda #<ibuf2
        sta tp
        lda #>ibuf2
        sta tp+1
        jsr expr_safe
        ldx num
        lda v0
        sta vars,x
        lda v0+1
        sta vars+1,x
        pla
        sta tp+1
        pla
        sta tp
        rts

; read_tty_line: one line from fd 0 into ibuf2 (direct read: cooked console)
read_tty_line:
        lda #<ibuf2
        sta r0
        lda #>ibuf2
        sta r0+1
        lda #63
        sta r1
        lda #0
        sta r1+1
        lda #0
        jsr SYS_READ
        ldx r1
        lda #0
        sta ibuf2,x
        rts

; expr_safe: like expr, but junk input evaluates to 0
expr_safe:
        jsr skipsp
        jsr peek
        cmp #'-'
        beq @e
        jsr isdigit
        bcc @e
        lda #0
        sta v0
        sta v0+1
        rts
@e:     jmp expr

do_let: jsr skipsp
        jsr getvar
        txa
        pha
        jsr skipsp
        jsr peek
        cmp #'='
        beq @eq
        jmp err_syntax
@eq:    jsr adv
        jsr expr
        pla
        tax
        lda v0
        sta vars,x
        lda v0+1
        sta vars+1,x
        rts

do_goto:
        jsr expr
goto_v0:
        lda v0
        sta lnum
        lda v0+1
        sta lnum+1
        jsr find_line
        beq @f
        jmp err_line
@f:     lda mp
        sta cl
        lda mp+1
        sta cl+1
        lda #1
        sta running
        jmp set_tp_cl

do_gosub:
        jsr expr
        ldx gsp
        cpx #NGOSUB*4
        bcc @ok
        jmp err_nest
@ok:    lda cl
        sta gstk,x
        lda cl+1
        sta gstk+1,x
        lda tp
        sta gstk+2,x
        lda tp+1
        sta gstk+3,x
        inx
        inx
        inx
        inx
        stx gsp
        jmp goto_v0

do_return:
        ldx gsp
        bne @ok
        jmp err_ret
@ok:    dex
        dex
        dex
        dex
        stx gsp
        lda gstk,x
        sta cl
        lda gstk+1,x
        sta cl+1
        lda gstk+2,x
        sta tp
        lda gstk+3,x
        sta tp+1
        rts

do_if:  jsr expr
        lda v0
        ora v0+1
        bne @true
        ; false: skip the rest of the line
@sk:    jsr peek
        beq @r
        jsr adv
        jmp @sk
@r:     rts
@true:  jsr skipsp
        ldy #0
@t:     lda s_then,y
        beq @then
        cmp (tp),y
        bne @nothen
        iny
        bne @t
@then:  tya
        clc
        adc tp
        sta tp
        bcc @nothen
        inc tp+1
@nothen:
        jsr skipsp
        jsr peek
        jsr isdigit
        bcs @stmt
        jmp do_goto
@stmt:  jmp statement

do_for: jsr skipsp
        jsr getvar
        stx num
        jsr skipsp
        jsr peek
        cmp #'='
        beq @eq
        jmp err_syntax
@eq:    jsr adv
        jsr expr
        ldx num
        lda v0
        sta vars,x
        lda v0+1
        sta vars+1,x
        jsr skipsp
        ldy #0
@to:    lda s_to,y
        beq @isto
        cmp (tp),y
        beq @tn
        jmp err_syntax
@tn:    iny
        bne @to
@isto:  jsr adv
        jsr adv
        jsr expr
        lda v0
        pha
        lda v0+1
        pha
        lda #1
        sta v0
        lda #0
        sta v0+1
        jsr skipsp
        ldy #0
@st:    lda s_step,y
        beq @isst
        cmp (tp),y
        bne @nost
        iny
        bne @st
@isst:  tya
        clc
        adc tp
        sta tp
        bcc @se
        inc tp+1
@se:    jsr expr
@nost:  ldx fsp
        cpx #NFOR*FORSZ
        bcc @ok
        jmp err_nest
@ok:    lda num
        sta fstk,x
        pla
        sta fstk+2,x        ; limit hi
        pla
        sta fstk+1,x        ; limit lo
        lda v0
        sta fstk+3,x
        lda v0+1
        sta fstk+4,x
        lda cl
        sta fstk+5,x
        lda cl+1
        sta fstk+6,x
        lda tp
        sta fstk+7,x
        lda tp+1
        sta fstk+8,x
        txa
        clc
        adc #FORSZ
        sta fsp
        rts

do_next:
        jsr skipsp
        ldx fsp
        bne @ok
        jmp err_next
@ok:    txa
        sec
        sbc #FORSZ
        tax
        ; var += step
        ldy fstk,x
        lda vars,y
        clc
        adc fstk+3,x
        sta vars,y
        sta v0
        lda vars+1,y
        adc fstk+4,x
        sta vars+1,y
        sta v0+1
        ; compare with limit, direction by sign of step
        lda v0
        sec
        sbc fstk+1,x
        sta v1
        lda v0+1
        sbc fstk+2,x
        bvc @nv
        eor #$80
@nv:    sta v1+1            ; sign: var - limit
        lda fstk+4,x
        bmi @down
        lda v1+1
        bmi @loop           ; var < limit
        ora v1
        beq @loop           ; var == limit
        jmp @done
@down:  lda v1+1
        bpl @loop           ; var >= limit
        jmp @done
@loop:  lda fstk+5,x
        sta cl
        lda fstk+6,x
        sta cl+1
        lda fstk+7,x
        sta tp
        lda fstk+8,x
        sta tp+1
        rts
@done:  stx fsp
        ; skip an optional variable name after next
        jsr peek
        cmp #'a'
        bcc @r
        cmp #'z'+1
        bcs @r
        jsr adv
@r:     rts

do_end: lda #0
        sta running
        rts

do_new: lda #<prog
        sta ptop
        lda #>prog
        sta ptop+1
        lda #0
        sta gsp
        sta fsp
        rts

do_run: jsr do_run_go
        lda #0
        sta running
        ; leave tp on a NUL so exec ends
        lda #<zero
        sta tp
        lda #>zero
        sta tp+1
        lda #0
        sta cl
        sta cl+1
        rts

; do_run_go: clear variables and run the stored program
do_run_go:
        ldx #51
        lda #0
@z:     sta vars,x
        dex
        bpl @z
        sta gsp
        sta fsp
        lda ptop
        cmp #<prog
        bne @go
        lda ptop+1
        cmp #>prog
        bne @go
        rts
@go:    lda #<prog
        sta cl
        lda #>prog
        sta cl+1
        lda #1
        sta running
        jsr set_tp_cl
        jmp exec

do_list:
        lda #1
        sta iofd
list_fd:
        lda #<prog
        sta mp
        lda #>prog
        sta mp+1
@l:     lda mp
        cmp ptop
        lda mp+1
        sbc ptop+1
        bcs @d
        ldy #0
        lda (mp),y
        sta v0
        iny
        lda (mp),y
        sta v0+1
        jsr out_int
        lda #' '
        jsr out_ch
        ldy #3
@t:     lda (mp),y
        beq @nl
        jsr out_ch
        iny
        bne @t
@nl:    lda #10
        jsr out_ch
        ldy #2
        lda (mp),y
        clc
        adc mp
        sta mp
        bcc @l
        inc mp+1
        jmp @l
@d:     rts

do_bye: lda #0
        jmp SYS_EXIT

; load "path"
do_load:
        jsr get_str
        jsr load_path
        lda #<zero
        sta tp
        lda #>zero
        sta tp+1
        rts

; save "path"
do_save:
        jsr get_str
        sta r0
        stx r0+1
        lda #(O_WRONLY | O_CREAT | O_TRUNC)
        jsr SYS_OPEN
        bcc @ok
        jmp err_io
@ok:    sta iofd
        jsr list_fd
        lda iofd
        jsr SYS_CLOSE
        lda #<zero
        sta tp
        lda #>zero
        sta tp+1
        rts

; load_path: A/X = path. NEW, then enter every line of the file.
load_path:
        ldy #O_RDONLY
        jsr open_or_die
        pha
        jsr do_new
        pla
        jsr set_input
@l:     jsr readline
        bcs @d
        lda #<ibuf
        sta tp
        lda #>ibuf
        sta tp+1
        jsr skipsp
        jsr peek
        beq @l
        jsr isdigit
        bcs @l              ; ignore non-numbered lines in files
        jsr parse_num
        lda v0
        sta lnum
        lda v0+1
        sta lnum+1
        jsr peek
        cmp #' '
        bne @ns
        jsr adv
@ns:    jsr store_line
        jmp @l
@d:     lda #0
        jmp set_input

; get_str: "string" at tp -> A/X = pointer to NUL-terminated copy (sbuf)
get_str:
        jsr skipsp
        jsr peek
        cmp #'"'
        beq @q
        jmp err_syntax
@q:     jsr adv
        ldx #0
@c:     jsr peek
        beq @e
        jsr adv
        cmp #'"'
        beq @e
        sta sbuf,x
        inx
        cpx #63
        bcc @c
@e:     lda #0
        sta sbuf,x
        lda #<sbuf
        ldx #>sbuf
        rts

; ---------------------------------------------------------------------
; expressions -> v0
expr:   lda #0
        sta depth
expr_r: inc depth
        lda depth
        cmp #12
        bcc @ok
        jmp err_complex
@ok:    jsr sum
        jsr skipsp
        jsr peek
        cmp #'='
        beq @eq
        cmp #'<'
        beq @lt
        cmp #'>'
        beq @gt
        dec depth
        rts
@eq:    jsr adv
        lda #1              ; =
        jmp @rel
@lt:    jsr adv
        jsr peek
        cmp #'>'
        bne @lt2
        jsr adv
        lda #2              ; <>
        jmp @rel
@lt2:   cmp #'='
        bne @lt3
        jsr adv
        lda #4              ; <=
        jmp @rel
@lt3:   lda #3              ; <
        jmp @rel
@gt:    jsr adv
        jsr peek
        cmp #'='
        bne @gt2
        jsr adv
        lda #6              ; >=
        jmp @rel
@gt2:   lda #5              ; >
@rel:   pha
        lda v0
        pha
        lda v0+1
        pha
        jsr sum
        pla
        sta v1+1
        pla
        sta v1
        pla
        sta reldp
        ; d = v1 - v0 (signed): left - right
        lda v1
        sec
        sbc v0
        sta mq
        lda v1+1
        sbc v0+1
        bvc @nv
        eor #$80
@nv:    sta mq+1            ; N = left < right
        ldx #0              ; result flags
        lda mq
        ora mq+1
        beq @isEq
        lda mq+1
        bmi @isLt
        lda #4              ; gt
        bne @cmp
@isEq:  lda #1
        bne @cmp
@isLt:  lda #2
@cmp:   ; A: 1 eq, 2 lt, 4 gt. Table of accepted results per operator
        ldx reldp
        and relmask,x
        beq @f
        lda #1
@f:     sta v0
        lda #0
        sta v0+1
        dec depth
        rts

sum:    jsr term
@l:     jsr skipsp
        jsr peek
        cmp #'+'
        beq @add
        cmp #'-'
        beq @sub
        rts
@add:   jsr adv
        jsr push_v0
        jsr term
        jsr pop_v1
        lda v1
        clc
        adc v0
        sta v0
        lda v1+1
        adc v0+1
        sta v0+1
        jmp @l
@sub:   jsr adv
        jsr push_v0
        jsr term
        jsr pop_v1
        lda v1
        sec
        sbc v0
        sta v0
        lda v1+1
        sbc v0+1
        sta v0+1
        jmp @l

term:   jsr unary
@l:     jsr skipsp
        jsr peek
        cmp #'*'
        beq @mul
        cmp #'/'
        beq @div
        cmp #'%'
        beq @mod
        rts
@mul:   jsr adv
        jsr push_v0
        jsr unary
        jsr pop_v1
        jsr mul16
        jmp @l
@div:   jsr adv
        jsr push_v0
        jsr unary
        jsr pop_v1
        jsr div16
        jmp @l
@mod:   jsr adv
        jsr push_v0
        jsr unary
        jsr pop_v1
        jsr div16
        lda mq
        sta v0
        lda mq+1
        sta v0+1
        jmp @l

; push_v0 / pop_v1 use a small software stack (keeps the 6502 stack shallow)
push_v0:
        ldx vsp
        cpx #32
        bcc @ok
        jmp err_complex
@ok:    lda v0
        sta vstk,x
        lda v0+1
        sta vstk+1,x
        inx
        inx
        stx vsp
        rts
pop_v1: ldx vsp
        dex
        dex
        stx vsp
        lda vstk,x
        sta v1
        lda vstk+1,x
        sta v1+1
        rts

unary:  jsr skipsp
        jsr peek
        cmp #'-'
        bne @p
        jsr adv
        jsr unary
        jmp negate
@p:     jmp primary

negate: lda #0
        sec
        sbc v0
        sta v0
        lda #0
        sbc v0+1
        sta v0+1
        rts

primary:
        jsr peek
        cmp #'('
        bne @n
        jsr adv
        jsr expr_r
        jsr skipsp
        jsr peek
        cmp #')'
        beq @cp
        jmp err_syntax
@cp:    jmp adv
@n:     jsr isdigit
        bcs @v
        jmp parse_num
@v:     ; functions
        ldy #0
@f1:    lda s_rnd,y
        beq @rnd
        cmp (tp),y
        bne @nf1
        iny
        bne @f1
@nf1:   ldy #0
@f2:    lda s_abs,y
        beq @abs
        cmp (tp),y
        bne @var
        iny
        bne @f2
@rnd:   jsr skip_y
        jsr primary
        jsr random
        lda mq
        sta v0
        lda mq+1
        sta v0+1
        rts
@abs:   jsr skip_y
        jsr primary
        lda v0+1
        bpl @r
        jmp negate
@r:     rts
@var:   jsr peek
        cmp #'a'
        bcc @bad
        cmp #'z'+1
        bcs @bad
        jsr getvar
        lda vars,x
        sta v0
        lda vars+1,x
        sta v0+1
        rts
@bad:   jmp err_syntax

skip_y: tya
        clc
        adc tp
        sta tp
        bcc @r
        inc tp+1
@r:     rts

; random: mq = random mod v0 (v0 > 0), 16-bit xorshift
random: lda rseed+1
        lsr a
        lda rseed
        ror a
        eor rseed+1
        sta rseed+1
        ror a
        eor rseed
        sta rseed
        eor rseed+1
        sta rseed+1
        lda v0
        ora v0+1
        beq @z
        lda rseed
        sta v1
        lda rseed+1
        and #$7f
        sta v1+1
        jmp div16
@z:     lda #0
        sta mq
        sta mq+1
        rts

; getvar: tp at a letter -> X = offset into vars, tp advanced
getvar: jsr peek
        cmp #'a'
        bcc @bad
        cmp #'z'+1
        bcs @bad
        sec
        sbc #'a'
        asl a
        tax
        jmp adv
@bad:   jmp err_syntax

; parse_num: decimal at tp -> v0
parse_num:
        lda #0
        sta v0
        sta v0+1
@l:     jsr peek
        jsr isdigit
        bcs @d
        jsr adv
        sec
        sbc #'0'
        pha
        ; v0 *= 10
        lda v0
        sta v1
        lda v0+1
        sta v1+1
        asl v0
        rol v0+1
        asl v0
        rol v0+1
        lda v0
        clc
        adc v1
        sta v0
        lda v0+1
        adc v1+1
        sta v0+1
        asl v0
        rol v0+1
        pla
        clc
        adc v0
        sta v0
        bcc @l
        inc v0+1
        jmp @l
@d:     rts

; mul16: v0 = v1 * v0 (low 16 bits)
mul16:  lda v0
        sta mq
        lda v0+1
        sta mq+1
        lda #0
        sta v0
        sta v0+1
        ldx #16
@l:     lsr mq+1
        ror mq
        bcc @n
        lda v0
        clc
        adc v1
        sta v0
        lda v0+1
        adc v1+1
        sta v0+1
@n:     asl v1
        rol v1+1
        dex
        bne @l
        rts

; div16: v0 = v1 / v0 (signed, truncating), mq = remainder (sign of v1)
div16:  lda v0
        ora v0+1
        bne @ok
        jmp err_div
@ok:    lda v1+1
        eor v0+1
        sta sgn             ; bit 7: result sign
        lda v1+1
        sta neg             ; bit 7: remainder sign
        bpl @a
        lda #0
        sec
        sbc v1
        sta v1
        lda #0
        sbc v1+1
        sta v1+1
@a:     lda v0+1
        bpl @b
        jsr negate
@b:     ; unsigned v1 / v0: quotient in v1, remainder in mq
        lda #0
        sta mq
        sta mq+1
        ldx #16
@l:     asl v1
        rol v1+1
        rol mq
        rol mq+1
        lda mq
        sec
        sbc v0
        tay
        lda mq+1
        sbc v0+1
        bcc @n
        sta mq+1
        sty mq
        inc v1
@n:     dex
        bne @l
        lda v1
        sta v0
        lda v1+1
        sta v0+1
        lda sgn
        bpl @c
        jsr negate
@c:     lda neg
        bpl @r
        lda #0
        sec
        sbc mq
        sta mq
        lda #0
        sbc mq+1
        sta mq+1
@r:     rts

; ---------------------------------------------------------------------
; output helpers
print_int:
        lda #1
        sta iofd
out_int:
        lda v0+1
        bpl @p
        lda #'-'
        jsr out_ch
        jsr negate
@p:     lda v0
        ldx v0+1
        ; print_dec writes to stdout; for SAVE we format into dbuf ourselves
        jsr fmt_dec
        ldy #0
@l:     lda dbuf,y
        beq @r
        jsr out_ch
        iny
        bne @l
@r:     rts

; fmt_dec: A/X unsigned -> dbuf (NUL-terminated)
fmt_dec:
        sta mq
        stx mq+1
        ldy #0
@d:     lda #0
        ldx #16
@v:     asl mq
        rol mq+1
        rol a
        cmp #10
        bcc @n
        sbc #10
        inc mq
@n:     dex
        bne @v
        ora #'0'
        pha
        iny
        lda mq
        ora mq+1
        bne @d
        ldx #0
@p:     pla
        sta dbuf,x
        inx
        dey
        bne @p
        lda #0
        sta dbuf,x
        rts

; out_ch: write A to iofd (preserves Y)
out_ch: sty och_y
        ldy iofd
        .import fputc
        jsr fputc
        ldy och_y
        rts

; ---------------------------------------------------------------------
; text helpers
peek:   ldy #0
        lda (tp),y
        rts
adv:    inc tp
        bne @r
        inc tp+1
@r:     rts
skipsp: jsr peek
        cmp #' '
        bne @r
        jsr adv
        jmp skipsp
@r:     rts
; isdigit: A -> carry clear if '0'-'9'
isdigit:
        cmp #'0'
        bcc @no
        cmp #'9'+1
        bcs @no
        clc
        rts
@no:    sec
        rts

; ---------------------------------------------------------------------
; errors: print message (with line number when running), back to the prompt
err_syntax: lda #<e_syntax
        ldx #>e_syntax
        jmp error
err_line:   lda #<e_line
        ldx #>e_line
        jmp error
err_nest:   lda #<e_nest
        ldx #>e_nest
        jmp error
err_ret:    lda #<e_ret
        ldx #>e_ret
        jmp error
err_next:   lda #<e_next
        ldx #>e_next
        jmp error
err_div:    lda #<e_div
        ldx #>e_div
        jmp error
err_mem:    lda #<e_mem
        ldx #>e_mem
        jmp error
err_io:     lda #<e_io
        ldx #>e_io
        jmp error
err_complex: lda #<e_complex
        ldx #>e_complex
error:  pha
        txa
        pha
        lda #<e_q
        ldx #>e_q
        jsr eprint
        pla
        tax
        pla
        jsr eprint
        lda cl+1
        beq @nl
        lda #<e_in
        ldx #>e_in
        jsr eprint
        ldy #0
        lda (cl),y
        sta v0
        iny
        lda (cl),y
        sta v0+1
        lda #2
        sta iofd
        jsr out_int
@nl:    lda #2
        sta iofd
        lda #10
        jsr out_ch
        lda #0
        sta vsp
        sta running
        sta depth
        lda argc
        cmp #2
        bcc @repl
        lda #1
        jmp SYS_EXIT
@repl:  ldx errsp
        txs
        jmp repl

.segment "RODATA"
; keyword table: name, 0, handler-1 (low, high)
.macro KW name, handler
        .byte name, 0
        .word handler-1
.endmacro
kwtab:
        KW "print", do_print
        KW "?", do_print
        KW "input", do_input
        KW "let", do_let
        KW "if", do_if
        KW "goto", do_goto
        KW "gosub", do_gosub
        KW "return", do_return
        KW "for", do_for
        KW "next", do_next
        KW "end", do_end
        KW "rem", do_rem
        KW "list", do_list
        KW "run", do_run
        KW "new", do_new
        KW "load", do_load
        KW "save", do_save
        KW "bye", do_bye
        .byte 0
; accepted compare results (1 eq, 2 lt, 4 gt) for = <> < <= > >=
relmask: .byte 0, 1, 6, 2, 3, 4, 5
s_then:  .byte "then", 0
s_to:    .byte "to", 0
s_step:  .byte "step", 0
s_rnd:   .byte "rnd", 0
s_abs:   .byte "abs", 0
s_banner: .byte "breadbin basic 0.1", 10, 0
s_prompt: .byte "> ", 0
zero:    .byte 0
e_q:     .byte "?", 0
e_in:    .byte " in ", 0
e_syntax: .byte "syntax error", 0
e_line:  .byte "undefined line", 0
e_nest:  .byte "too many nested gosubs/fors", 0
e_ret:   .byte "return without gosub", 0
e_next:  .byte "next without for", 0
e_div:   .byte "division by zero", 0
e_mem:   .byte "out of memory", 0
e_io:    .byte "cannot write file", 0
e_complex: .byte "expression too complex", 0

.segment "BSS"
ibuf2:  .res 64
sbuf:   .res 64
dbuf:   .res 8
vstk:   .res 32
vsp:    .res 1
och_y:  .res 1
