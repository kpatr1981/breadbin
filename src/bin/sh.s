; sh: the c64os shell
;
;   cmd args...            run /bin/cmd (or a path containing '/')
;   a | b | c              pipelines
;   < file  > file  >> file
;   cmd &                  background job
;   a ; b                  sequence
;   "quoted words", # comments
; Built-ins: cd, exit, kill (also /bin/kill), jobs. `sh file` runs a script.
; Words with * or ? are expanded against the directory they name.
.include "../../include/c64os.inc"
.import print, eprint, putc, newline, print_dec, perr, argn, strlen, exit, parse_dec
.importzp lp1, lp2

MAXTOK  = 32
MAXARG  = 16
LINEMAX = 127

zp1 = $23
zp2 = $25

T_WORD  = 0

.segment "BSS"
in_fd:   .res 1
interactive: .res 1
ipos:    .res 1
ilen:    .res 1
ibuf:    .res 256
line:    .res LINEMAX+1
lnlen:   .res 1
tbuf:    .res 256
tlo:     .res MAXTOK
thi:     .res MAXTOK
ttype:   .res MAXTOK
ntok:    .res 1
av:      .res 2*(MAXARG+1)
nargs:   .res 1
cmdpath: .res 64
pids:    .res 8
npids:   .res 1
cmd_end: .res 1
cur_tok: .res 1
st_start: .res 1
first:   .res 1
last:    .res 1
bg:      .res 1
prev_in: .res 1
pin:     .res 1
pout:    .res 1
pr:      .res 1
inf_lo:  .res 1
inf_hi:  .res 1
outf_lo: .res 1
outf_hi: .res 1
outapp:  .res 1
cwd:     .res 64
tmpb:    .res 1
qch:     .res 1
bk_sig:  .res 1
bk_i:    .res 1
bk_p:    .res 2
pinfo:   .res 16
g_tok:   .res 1
g_word:  .res 2
g_d:     .res 1
g_dir:   .res 48
g_fd:    .res 1
g_n:     .res 1
g_ent:   .res 16
g_p:     .res 1
g_s:     .res 1
g_star:  .res 1
g_ss:    .res 1
gpos:    .res 2
gbuf:    .res 256
tpos:    .res 1

.segment "CODE"
start:
        lda #0
        sta in_fd
        sta ipos
        sta ilen
        lda #1
        sta interactive
        lda argc
        cmp #2
        bcc main
        lda #1
        jsr argn
        sta r0
        stx r0+1
        lda #O_RDONLY
        jsr SYS_OPEN
        bcc @ok
        sta tmpb
        lda #1
        jsr argn
        pha
        txa
        tay
        pla
        tax
        lda tmpb
        jsr perr
        lda #1
        jmp exit
@ok:    sta in_fd
        lda #0
        sta interactive

main:   lda interactive
        beq @noprompt
        jsr reap
        jsr prompt
@noprompt:
        jsr getline
        bcc @have
        lda #0
        jmp exit
@have:  jsr tokenize
        bcs main
        jsr run_line
        jmp main

; ---- prompt and job reaping ----
prompt:
        lda #<cwd
        sta r0
        lda #>cwd
        sta r0+1
        lda #64
        jsr SYS_GETCWD
        lda #<cwd
        ldx #>cwd
        jsr print
        lda #<s_prompt
        ldx #>s_prompt
        jmp print

reap:   lda #$ff
        ldx #W_NOHANG
        jsr SYS_WAIT
        bcs @r
        cmp #0
        beq @r
        pha
        lda #'['
        jsr putc
        pla
        ldx #0
        jsr print_dec
        lda #<s_done
        ldx #>s_done
        jsr print
        jmp reap
@r:     rts

; ---- input ----
; getline: next line from in_fd into `line` (NUL-terminated, no newline)
; carry set on EOF with nothing read
getline:
        lda #0
        sta lnlen
@loop:  lda ipos
        cmp ilen
        bne @ch
        lda #<ibuf
        sta r0
        lda #>ibuf
        sta r0+1
        lda #255
        sta r1
        lda #0
        sta r1+1
        lda in_fd
        jsr SYS_READ
        lda #0
        sta ipos
        bcs @eof
        lda r1
        sta ilen
        bne @ch
@eof:   lda #0
        sta ilen
        lda lnlen
        bne @end
        sec
        rts
@ch:    ldx ipos
        inc ipos
        lda ibuf,x
        cmp #10
        beq @end
        ldx lnlen
        cpx #LINEMAX
        bcs @loop
        sta line,x
        inc lnlen
        jmp @loop
@end:   ldx lnlen
        lda #0
        sta line,x
        clc
        rts

; ---- tokenizer ----
; tokenize `line` into tbuf/tlo/thi/ttype; carry set on error/empty
tokenize:
        lda #0
        sta ntok
        sta tpos
        ldy #0
@skip:  lda line,y
        cmp #' '
        beq @sp
        cmp #9
        bne @nsp
@sp:    iny
        bne @skip
@nsp:   cmp #0
        beq @jdone
        cmp #'#'
        bne @ntc
@jdone: jmp @done
@ntc:   ldx ntok
        cpx #MAXTOK
        bcc @tok
        jmp @toomany
@tok:
        cmp #'|'
        beq @op
        cmp #'&'
        beq @op
        cmp #';'
        beq @op
        cmp #'<'
        beq @op
        cmp #'>'
        bne @word
        lda line+1,y
        cmp #'>'
        bne @gt
        lda #'A'
        iny
        jmp @op
@gt:    lda #'>'
@op:    sta ttype,x
        inc ntok
        iny
        jmp @skip
@word:  lda #T_WORD
        sta ttype,x
        lda tpos
        clc
        adc #<tbuf
        sta tlo,x
        lda #>tbuf
        adc #0
        sta thi,x
        inc ntok
        ldx tpos
@wc:    lda line,y
        beq @we
        cmp #' '
        beq @we
        cmp #9
        beq @we
        cmp #'|'
        beq @we
        cmp #'&'
        beq @we
        cmp #';'
        beq @we
        cmp #'<'
        beq @we
        cmp #'>'
        beq @we
        cmp #'"'
        beq @quote
        cmp #$27            ; single quote
        beq @quote
        sta tbuf,x
        inx
        iny
        jmp @wc
@quote: sta qch
        iny
@ql:    lda line,y
        beq @we
        iny
        cmp qch
        beq @wc
        sta tbuf,x
        inx
        jmp @ql
@we:    lda #0
        sta tbuf,x
        inx
        stx tpos
        jmp @skip
@done:  lda ntok
        beq @empty
        clc
        rts
@empty: sec
        rts
@toomany:
        lda #<s_toolong
        ldx #>s_toolong
        jsr eprint
        sec
        rts

; ---- execution ----
run_line:
        lda #0
        sta gpos
        sta gpos+1
        sta cur_tok
@cmd:   lda cur_tok
        cmp ntok
        bcs @r
        ; find end of this command (';' or end)
        tax
@f:     cpx ntok
        beq @fe
        lda ttype,x
        cmp #';'
        beq @fe
        inx
        jmp @f
@fe:    stx cmd_end
        jsr run_cmd
        ldx cmd_end
        inx
        stx cur_tok
        jmp @cmd
@r:     rts

; run_cmd: tokens cur_tok .. cmd_end-1
run_cmd:
        lda cur_tok
        cmp cmd_end
        bne @ne
        rts
@ne:    lda #0
        sta bg
        sta npids
        sta prev_in
        ldx cmd_end
        dex
        lda ttype,x
        cmp #'&'
        bne @nbg
        stx cmd_end
        inc bg
        cpx cur_tok
        bne @nbg
        jmp syntax
@nbg:   lda #1
        sta first
        lda cur_tok
        sta st_start

stage:  lda #0
        sta nargs
        sta inf_hi
        sta outf_hi
        sta outapp
        ldx st_start
@t:     cpx cmd_end
        bne @t1
@jtend: jmp @tend
@t1:    lda ttype,x
        cmp #'|'
        beq @jtend
        cmp #T_WORD
        bne @op
        ldy nargs
        cpy #MAXARG
        bcc @aok
        jmp syntax
@aok:   lda tlo,x
        sta zp1
        lda thi,x
        sta zp1+1
        stx g_tok
        jsr is_glob
        bcs @lit
        jsr glob
        ldx g_tok
        inx
        jmp @t
@lit:   jsr add_arg
        ldx g_tok
        inx
        jmp @t
@op:    cmp #'&'
        bne @op2
        jmp syntax
@op2:   pha
        inx
        cpx cmd_end
        beq @syn
        lda ttype,x
        bne @syn
        pla
        cmp #'<'
        bne @out
        lda tlo,x
        sta inf_lo
        lda thi,x
        sta inf_hi
        inx
        jmp @t
@out:   ldy #0
        cmp #'A'
        bne @o2
        iny
@o2:    sty outapp
        lda tlo,x
        sta outf_lo
        lda thi,x
        sta outf_hi
        inx
        jmp @t
@syn:   pla
        jmp syntax
@tend:  stx tmpb
        lda #0
        sta last
        cpx cmd_end
        bne @nl
        inc last
@nl:    lda nargs
        bne @hasargs
        jmp syntax
@hasargs:
        asl a
        tay
        lda #0
        sta av,y
        sta av+1,y
        ; built-ins for a single simple command
        lda first
        and last
        beq @ext
        jsr builtin
        bcc @ext
        rts
@ext:   ; stdin
        lda prev_in
        sta pin
        lda inf_hi
        beq @noin
        lda inf_lo
        sta r0
        lda inf_hi
        sta r0+1
        lda #O_RDONLY
        jsr SYS_OPEN
        bcc @inok
        ldx inf_lo
        ldy inf_hi
        jsr perr
        jmp abort
@inok:  pha
        jsr close_pin
        pla
        sta pin
@noin:  ; stdout
        lda #0
        sta pr
        lda #1
        sta pout
        lda last
        bne @nopipe
        jsr SYS_PIPE
        bcc @pok
        ldx #0
        ldy #0
        jsr perr
        jmp abort
@pok:   sta pr
        stx pout
@nopipe:
        lda outf_hi
        beq @noout
        lda outf_lo
        sta r0
        lda outf_hi
        sta r0+1
        lda #(O_WRONLY | O_CREAT | O_TRUNC)
        ldx outapp
        beq @tr
        lda #(O_WRONLY | O_CREAT | O_APPEND)
@tr:    jsr SYS_OPEN
        bcc @ook
        ldx outf_lo
        ldy outf_hi
        jsr perr
        jsr close_pout
        jmp abort
@ook:   pha
        jsr close_pout
        pla
        sta pout
@noout: jsr make_path
        lda #<cmdpath
        sta r0
        lda #>cmdpath
        sta r0+1
        lda #<av
        sta r1
        lda #>av
        sta r1+1
        ldy #0
        lda bg
        beq @fg
        ldy #SP_BG
@fg:    lda pin
        ldx pout
        jsr SYS_SPAWN
        bcc @spok
        ldx av
        ldy av+1
        jsr perr
        jmp @cl
@spok:  ldx npids
        sta pids,x
        inc npids
@cl:    jsr close_pin
        jsr close_pout
        lda pr
        sta prev_in
        lda last
        bne @wait
        lda #0
        sta first
        ldx tmpb
        inx
        stx st_start
        jmp stage
@wait:  lda npids
        beq @r
        lda bg
        beq @wl
        lda #'['
        jsr putc
        ldx npids
        lda pids-1,x
        ldx #0
        jsr print_dec
        lda #']'
        jsr putc
        jmp newline
@wl:    ldx #0
@w:     stx tmpb
        lda pids,x
        ldx #0
        jsr SYS_WAIT
        ldx tmpb
        inx
        cpx npids
        bne @w
@r:     rts

; add_arg: av[nargs++] = zp1 (silently ignored when full)
add_arg:
        lda nargs
        cmp #MAXARG
        bcs @r
        asl a
        tay
        lda zp1
        sta av,y
        lda zp1+1
        sta av+1,y
        inc nargs
@r:     rts

; is_glob: carry clear if the word at zp1 contains * or ?
is_glob:
        ldy #0
@l:     lda (zp1),y
        beq @no
        cmp #'*'
        beq @y
        cmp #'?'
        beq @y
        iny
        bne @l
@no:    sec
        rts
@y:     clc
        rts

; glob: expand the pattern word at zp1 into av (literal if nothing matches)
glob:   lda zp1
        sta g_word
        lda zp1+1
        sta g_word+1
        ; d = index after the last '/'
        ldy #0
        sty g_d
@s:     lda (zp1),y
        beq @se
        iny
        cmp #'/'
        bne @s
        sty g_d
        jmp @s
@se:    ; directory to read
        ldy g_d
        bne @dir
        lda #'.'
        sta g_dir
        lda #0
        sta g_dir+1
        jmp @open
@dir:   ldy #0
@dc:    cpy g_d
        beq @dz
        lda (zp1),y
        sta g_dir,y
        iny
        cpy #47
        bcc @dc
@dz:    cpy #1
        beq @root
        dey                 ; drop the trailing '/'
@root:  lda #0
        sta g_dir,y
@open:  lda #<g_dir
        sta r0
        lda #>g_dir
        sta r0+1
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @lit
        sta g_fd
        lda #0
        sta g_n
@rd:    lda #<g_ent
        sta r0
        lda #>g_ent
        sta r0+1
        lda #16
        sta r1
        lda #0
        sta r1+1
        lda g_fd
        jsr SYS_READ
        bcs @done
        lda r1
        cmp #16
        bne @done
        lda g_ent
        beq @rd
        ; hidden names only match a pattern that starts with '.'
        lda g_ent+1
        cmp #'.'
        bne @m
        lda g_word
        clc
        adc g_d
        sta zp2
        lda g_word+1
        adc #0
        sta zp2+1
        ldy #0
        lda (zp2),y
        cmp #'.'
        bne @rd
@m:     jsr match
        bcs @rd
        jsr g_store
        bcs @done
        inc g_n
        jmp @rd
@done:  lda g_fd
        jsr SYS_CLOSE
        lda g_n
        bne @r
@lit:   lda g_word
        sta zp1
        lda g_word+1
        sta zp1+1
        jmp add_arg
@r:     rts

; g_store: append word[0..d) + name to the glob buffer and add it to av
g_store:
        lda gpos+1
        bne @full
        lda gpos
        cmp #256-64
        bcs @full
        lda #<gbuf
        clc
        adc gpos
        sta zp1
        lda #>gbuf
        adc gpos+1
        sta zp1+1
        lda g_word
        sta zp2
        lda g_word+1
        sta zp2+1
        ldy #0
@p:     cpy g_d
        beq @pd
        lda (zp2),y
        sta (zp1),y
        iny
        bne @p
@pd:    ldx #0
@n:     lda g_ent+1,x
        sta (zp1),y
        beq @e
        iny
        inx
        cpx #15
        bcc @n
        lda #0
        sta (zp1),y
@e:     iny
        tya
        clc
        adc gpos
        sta gpos
        bcc @a
        inc gpos+1
@a:     jsr add_arg
        clc
        rts
@full:  sec
        rts

; match: pattern (word + d) against the name g_ent+1 -> carry clear if it matches
match:  lda #0
        sta g_p
        sta g_s
        lda #$ff
        sta g_star
        lda g_word
        clc
        adc g_d
        sta zp2
        lda g_word+1
        adc #0
        sta zp2+1
@loop:  ldx g_s
        lda g_ent+1,x
        beq @tail
        ldy g_p
        lda (zp2),y
        cmp #'?'
        beq @adv
        cmp g_ent+1,x
        beq @adv
        cmp #'*'
        bne @back
        sty g_star
        inc g_p
        stx g_ss
        jmp @loop
@adv:   inc g_p
        inc g_s
        jmp @loop
@back:  lda g_star
        cmp #$ff
        beq @no
        tay
        iny
        sty g_p
        inc g_ss
        lda g_ss
        sta g_s
        jmp @loop
@tail:  ldy g_p
@t:     lda (zp2),y
        cmp #'*'
        bne @end
        iny
        bne @t
@end:   cmp #0
        bne @no
        clc
        rts
@no:    sec
        rts

close_pin:
        lda pin
        beq @r
        jsr SYS_CLOSE
        lda #0
        sta pin
@r:     rts

close_pout:
        lda pout
        cmp #1
        beq @r
        jsr SYS_CLOSE
        lda #1
        sta pout
@r:     rts

; abort a pipeline after an error: close what is open, wait for started stages
abort:  jsr close_pin
        jsr close_pout
        lda pr
        beq @w
        jsr SYS_CLOSE
@w:     lda #0
        sta bg
        lda #1
        sta last
        ldx #0
        cpx npids
        beq @r
@l:     stx tmpb
        lda pids,x
        ldx #0
        jsr SYS_WAIT
        ldx tmpb
        inx
        cpx npids
        bne @l
@r:     rts

syntax: lda prev_in
        beq @n
        jsr SYS_CLOSE
@n:     lda #<s_syntax
        ldx #>s_syntax
        jmp eprint

; make_path: av[0] -> cmdpath ("/bin/" + name unless it contains '/')
make_path:
        lda av
        sta zp1
        lda av+1
        sta zp1+1
        ldy #0
@s:     lda (zp1),y
        beq @nos
        cmp #'/'
        beq @lit
        iny
        bne @s
@nos:   ldx #4
@p:     lda s_bin,x
        sta cmdpath,x
        dex
        bpl @p
        ldx #5
        jmp @cp
@lit:   ldx #0
@cp:    ldy #0
@c:     lda (zp1),y
        sta cmdpath,x
        beq @r
        inx
        iny
        cpx #63
        bcc @c
        lda #0
        sta cmdpath,x
@r:     rts

; builtin: carry set if av[0] was a built-in (and it ran)
builtin:
        lda av
        sta lp1
        lda av+1
        sta lp1+1
        lda #<s_cd
        sta lp2
        lda #>s_cd
        sta lp2+1
        jsr strcmp_
        bne @nocd
        lda nargs
        cmp #2
        bcs @arg
        lda #<s_root
        sta r0
        lda #>s_root
        sta r0+1
        jmp @cd
@arg:   lda av+2
        sta r0
        lda av+3
        sta r0+1
@cd:    jsr SYS_CHDIR
        bcc @done
        ldx r0
        ldy r0+1
        jsr perr
@done:  sec
        rts
@nocd:  lda #<s_kill
        sta lp2
        lda #>s_kill
        sta lp2+1
        jsr strcmp_
        bne @nokill
        jmp bi_kill
@nokill:
        lda #<s_jobs
        sta lp2
        lda #>s_jobs
        sta lp2+1
        jsr strcmp_
        bne @nojobs
        jmp bi_jobs
@nojobs:
        lda #<s_exit
        sta lp2
        lda #>s_exit
        sta lp2+1
        jsr strcmp_
        bne @no
        lda #0
        jmp exit
@no:    clc
        rts

; kill [-signal] pid... as a built-in, so a full process table can be
; cleared (the shell needs no new process to send a signal)
bi_kill:
        lda #SIGTERM
        sta bk_sig
        lda #1
        sta bk_i
        lda nargs
        cmp #2
        bcc @done
        lda av+2
        sta zp1
        lda av+3
        sta zp1+1
        ldy #0
        lda (zp1),y
        cmp #'-'
        bne @l
        lda zp1
        clc
        adc #1
        ldx zp1+1
        bcc @p
        inx
@p:     jsr parse_dec
        bcs @done
        sta bk_sig
        inc bk_i
@l:     lda bk_i
        cmp nargs
        bcs @done
        asl a
        tay
        lda av,y
        ldx av+1,y
        sta bk_p
        stx bk_p+1
        jsr parse_dec
        bcs @bad
        ldx bk_sig
        jsr SYS_KILL
        bcc @n
@bad:   ldx bk_p
        ldy bk_p+1
        jsr perr
@n:     inc bk_i
        jmp @l
@done:  sec
        rts

; jobs: background children of this shell (from the process table)
bi_jobs:
        jsr SYS_GETPID
        sta bk_sig          ; my pid
        lda #0
        sta bk_i
@l:     lda #<pinfo
        sta r0
        lda #>pinfo
        sta r0+1
        lda bk_i
        jsr SYS_PROCINFO
        bcs @n
        lda pinfo+1
        cmp bk_sig
        bne @n
        lda pinfo+2
        cmp #3              ; zombie: finished, reaped at the next prompt
        beq @n
        lda #'['
        jsr putc
        lda pinfo
        ldx #0
        jsr print_dec
        lda #<s_run
        ldx #>s_run
        jsr print
        lda #<(pinfo+5)
        ldx #>(pinfo+5)
        jsr print
        jsr newline
@n:     inc bk_i
        lda bk_i
        cmp #16
        bne @l
        sec
        rts

strcmp_:
        ldy #0
@l:     lda (lp1),y
        cmp (lp2),y
        bne @r
        cmp #0
        beq @r
        iny
        bne @l
@r:     rts

.segment "RODATA"
s_prompt:  .byte " $ ", 0
s_done:    .byte "] done", 10, 0
s_syntax:  .byte "sh: syntax error", 10, 0
s_toolong: .byte "sh: line too long", 10, 0
s_bin:     .byte "/bin/"
s_cd:      .byte "cd", 0
s_exit:    .byte "exit", 0
s_kill:    .byte "kill", 0
s_jobs:    .byte "jobs", 0
s_run:     .byte "] running  ", 0
s_root:    .byte "/", 0
