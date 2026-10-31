; sh: the Breadbin shell
;
;   cmd args...            run /bin/cmd (or a path containing '/')
;   a | b | c              pipelines
;   < file  > file  >> file
;   cmd &                  background job
;   a ; b                  sequence
;   a && b, a || b         run b only if a succeeded / failed; $? = exit status
;   2> file, 2>&1         redirect stderr
;   "quoted words", # comments
; Built-ins: cd, exit, kill (also /bin/kill), jobs, fg, bg. `sh file` runs a
; script. CTRL-Z stops the foreground job; fg/bg [pid] continue it.
; Words with * or ? are expanded against the directory they name.
; On the console, cursor up/down recall the last 8 lines.
.include "../../include/breadbin.inc"
.import print, eprint, putc, newline, print_dec, perr, argn, strlen, exit, parse_dec, dec_str
.importzp lp1, lp2

MAXTOK  = 32
MAXARG  = 16
LINEMAX = 127

zp1 = $23
zp2 = $25
tptr = $27

T_WORD  = 0
ST_MARK = 1             ; $? in a word, until expand_status replaces it
HIST    = 8             ; lines of history (a power of two)
HLEN    = 64            ; longer lines are not kept

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
pinfo:   .res 17
lastjob: .res 1         ; job that fg/bg act on by default
status:  .res 1         ; $?: exit status of the last command
lastpid: .res 1         ; the last stage of the running pipeline (0: any)
sep:     .res 1         ; the operator before the next command: ; a(&&) o(||)
errf_lo: .res 1         ; 2> file
errf_hi: .res 1
errdup:  .res 1         ; 2>&1
efd:     .res 1
tsave:   .res 1
xsave:   .res 1
tlen:    .res 1
tty:     .res 1         ; interactive on the console: edit lines in raw mode
hn:      .res 1         ; history: lines stored
hhead:   .res 1         ; the slot the next line goes to
hsel:    .res 1         ; 0: a new line, k: the k-th most recent one
kbuf:    .res 1
hbuf:    .res HIST*HLEN
job:     .res 1         ; job of the pipeline being started (its first pid)
fgjob:   .res 1
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
        sta lastjob
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

main:   lda #0
        sta tty
        lda interactive
        beq loop
        lda #0
        jsr SYS_ISATTY
        bcs loop
        inc tty
loop:   lda interactive
        beq @noprompt
        jsr reap
        jsr prompt
@noprompt:
        jsr getline
        bcc @have
        lda #0
        jmp exit
@have:  jsr tokenize
        bcs loop
        jsr run_line
        jmp loop

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
        lda tty
        beq @buf
        jmp readline
@buf:   lda #0
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

; readline: a line from the console, edited in raw mode: DEL, cursor up and
; down walk the history, CTRL-D on an empty line is EOF (carry set)
readline:
        lda #1
        jsr SYS_CONMODE
        lda #0
        sta lnlen
        sta hsel
@key:   jsr rawkey
        cmp #K_RET
        beq @ret
        cmp #K_DEL
        beq @del
        cmp #K_UP
        beq @up
        cmp #K_DOWN
        beq @down
        cmp #4              ; CTRL-D
        beq @eof
        cmp #$20
        bcc @key
        cmp #$7f
        bcs @key
        ldx lnlen
        cpx #LINEMAX
        bcs @key
        sta line,x
        inc lnlen
        jsr putc
        jmp @key
@del:   lda lnlen
        beq @key
        dec lnlen
        lda #K_DEL
        jsr putc
        jmp @key
@up:    lda hsel
        cmp hn
        bcs @key
        inc hsel
        jsr recall
        jmp @key
@down:  lda hsel
        beq @key
        dec hsel
        jsr recall
        jmp @key
@eof:   lda lnlen
        bne @key
        lda #0
        jsr SYS_CONMODE
        sec
        rts
@ret:   jsr newline
        lda #0
        jsr SYS_CONMODE
        ldx lnlen
        lda #0
        sta line,x
        cpx #HLEN
        bcs @r
        txa
        beq @r
        jsr hist_add
@r:     clc
        rts

; rawkey -> A = next key (4 = CTRL-D on error or EOF)
rawkey: lda #<kbuf
        sta r0
        lda #>kbuf
        sta r0+1
        lda #1
        sta r1
        lda #0
        sta r1+1
        lda in_fd
        jsr SYS_READ
        bcs @e
        lda r1
        beq @e
        lda kbuf
        rts
@e:     lda #4
        rts

; recall: replace the line being edited with history entry hsel (0: empty)
recall:
@e:     lda lnlen
        beq @c
        dec lnlen
        lda #K_DEL
        jsr putc
        jmp @e
@c:     lda hsel
        beq @r
        lda hhead
        sec
        sbc hsel
        and #HIST-1
        jsr hslot
@l:     ldy lnlen
        lda (zp2),y
        beq @r
        sta line,y
        inc lnlen
        jsr putc
        jmp @l
@r:     rts

; hist_add: line (NUL-terminated, 1 to HLEN-1 characters) becomes the newest
hist_add:
        lda hhead
        jsr hslot
        ldy #0
@c:     lda line,y
        sta (zp2),y
        beq @d
        iny
        bne @c
@d:     lda hhead
        clc
        adc #1
        and #HIST-1
        sta hhead
        lda hn
        cmp #HIST
        bcs @r
        inc hn
@r:     rts

; hslot: A = history slot (0-7) -> zp2 = &hbuf[A * 64]
hslot:  pha
        lsr a
        lsr a
        sta zp2+1           ; slot / 4 pages
        pla
        and #3
        lsr a
        ror a
        ror a               ; (slot & 3) * 64
        clc
        adc #<hbuf
        sta zp2
        lda zp2+1
        adc #>hbuf
        sta zp2+1
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
        cmp #'2'            ; 2> file, 2>&1
        bne @t2
        lda line+1,y
        cmp #'>'
        bne @t1
        iny
        lda line+1,y
        cmp #'&'
        bne @e2
        lda line+2,y
        cmp #'1'
        bne @e2
        iny
        iny
        lda #'D'
        jmp @op
@e2:    lda #'E'
        jmp @op
@t1:    lda line,y
@t2:    cmp #'|'
        beq @dbl
        cmp #'&'
        beq @dbl
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
        bne @op
@dbl:   cmp line+1,y        ; && -> 'a', || -> 'o'
        bne @op
        iny
        cmp #'|'
        beq @or
        lda #'a'
        bne @op
@or:    lda #'o'
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
        cmp #'$'
        bne @lit
        lda line+1,y
        cmp #'?'
        beq @status
        lda #'$'
@lit:   sta tbuf,x
        inx
        iny
        jmp @wc
@status:                    ; $?: a marker, expanded when the command runs
        iny
        iny
        lda #ST_MARK
        sta tbuf,x
        inx
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
        lda #';'
        sta sep
@cmd:   lda cur_tok
        cmp ntok
        bcs @r
        ; find end of this command (; && || or end)
        tax
@f:     cpx ntok
        beq @fe
        lda ttype,x
        cmp #';'
        beq @fe
        cmp #'a'
        beq @fe
        cmp #'o'
        beq @fe
        inx
        jmp @f
@fe:    stx cmd_end
        ; a && b runs b only if a succeeded, a || b only if it failed
        lda sep
        cmp #';'
        beq @run
        ldx status
        cmp #'a'
        beq @and
        cpx #0              ; ||
        bne @run
        beq @skip
@and:   cpx #0
        bne @skip
@run:   jsr run_cmd
@skip:  lda #';'
        ldx cmd_end
        cpx ntok
        beq @s
        lda ttype,x
@s:     sta sep
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
        sta job
        sta lastpid
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
        sta errf_hi
        sta errdup
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
        jsr expand_status
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
        bne @od
        jmp syntax
@od:    cmp #'D'            ; 2>&1
        bne @op2
        inc errdup
        inx
        jmp @t
@op2:   pha
        inx
        cpx cmd_end
        beq @syn
        lda ttype,x
        bne @syn
        pla
        cmp #'<'
        bne @oe
        lda tlo,x
        sta inf_lo
        lda thi,x
        sta inf_hi
        inx
        jmp @t
@oe:    cmp #'E'            ; 2> file
        bne @out
        lda tlo,x
        sta errf_lo
        lda thi,x
        sta errf_hi
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
        lda #0
        sta status
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
@noout: lda #0              ; stderr: 2> file
        sta efd
        lda errf_hi
        beq @noerr
        lda errf_lo
        sta r0
        lda errf_hi
        sta r0+1
        lda #(O_WRONLY | O_CREAT | O_TRUNC)
        jsr SYS_OPEN
        bcc @eok
        ldx errf_lo
        ldy errf_hi
        jsr perr
        jsr close_pout
        jmp abort
@eok:   sta efd
@noerr: jsr make_path
        lda #<cmdpath
        sta r0
        lda #>cmdpath
        sta r0+1
        lda #<av
        sta r1
        lda #>av
        sta r1+1
        lda job             ; every stage joins the job of the first one
        sta r2
        ldy #SP_JOB
        lda errdup          ; 2>&1: stderr = this stage's stdout
        beq @ne1
        lda pout
        sta r2+1
        ldy #(SP_JOB | SP_ERR)
@ne1:   lda efd
        beq @ne2
        sta r2+1
        ldy #(SP_JOB | SP_ERR)
@ne2:   lda bg
        beq @fg
        tya
        ora #SP_BG
        tay
@fg:    lda pin
        ldx pout
        jsr SYS_SPAWN
        bcc @spok
        ldx av
        ldy av+1
        jsr perr
        lda #127            ; $?: command not found (or not runnable)
        sta status
        jmp @cl
@spok:  sta lastpid
        ldx job
        bne @inj
        sta job
@inj:   ldx npids
        sta pids,x
        inc npids
@cl:    lda efd
        beq @cl2
        jsr SYS_CLOSE
@cl2:   jsr close_pin
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
        lda #0
        sta status
        lda #'['
        jsr putc
        lda job
        sta lastjob
        ldx #0
        jsr print_dec
        lda #']'
        jsr putc
        jmp newline
@wl:    lda job
        jsr fgwait
@r:     rts

; fgwait: wait for every process of foreground job A; carry set if the
; job stopped instead
fgwait: sta fgjob
@w:     lda fgjob
        ldx #(W_UNTRACED | W_JOB)
        jsr SYS_WAIT
        bcs @ok             ; ECHILD: all of the job's processes are gone
        cpx #WSTOPPED
        beq @stop
        ldy lastpid         ; $? is the last stage's exit code
        beq @st
        cmp lastpid
        bne @w
@st:    stx status
        jmp @w
@stop:  lda #128+SIGTSTP
        sta status
        lda #0
        sta lastpid
        lda fgjob
        sta lastjob
        jsr newline
        lda #'['
        jsr putc
        lda lastjob
        ldx #0
        jsr print_dec
        lda #<s_stopped
        ldx #>s_stopped
        jsr print
        jsr newline
        sec
        rts
@ok:    clc
        rts

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
        cpy g_d
        beq @dz
        jmp @lit            ; a directory name too long for g_dir: as is
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

; expand_status: if the word at zp1 has $? in it, copy it into the glob
; buffer with the exit status of the last command there; zp1 = the copy
expand_status:
        ldy #0
@f:     lda (zp1),y
        beq @r
        cmp #ST_MARK
        beq @go
        iny
        bne @f
@r:     rts
@go:    lda gpos+1
        bne @r
        lda gpos
        cmp #256-64
        bcs @r
        lda zp1
        sta zp2
        lda zp1+1
        sta zp2+1
        lda #<gbuf
        clc
        adc gpos
        sta zp1
        lda #>gbuf
        adc #0
        sta zp1+1
        lda #0
        sta tsave           ; index into the word
        sta xsave           ; index into the copy
@c:     ldy tsave
        inc tsave
        lda (zp2),y
        cmp #ST_MARK
        beq @st
        ldy xsave
        inc xsave
        sta (zp1),y
        cmp #0
        bne @c
        lda xsave
        clc
        adc gpos
        sta gpos
        rts
@st:    lda status
        ldx #0
        jsr dec_str         ; A/X = digits, Y = length
        sta tptr
        stx tptr+1
        sty tlen
        ldx #0
@d:     txa
        tay
        lda (tptr),y
        ldy xsave
        inc xsave
        sta (zp1),y
        inx
        cpx tlen
        bne @d
        jmp @c

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
@w:     lda #1
        sta status
        lda #0
        sta bg
        lda #1
        sta last
        lda job             ; wait for the stages already started
        beq @r
        jsr fgwait
@r:     rts

syntax: lda #2
        sta status
        lda prev_in
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
        lda #1
        sta status
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
        lda #<s_fg
        sta lp2
        lda #>s_fg
        sta lp2+1
        jsr strcmp_
        bne @nofg
        jmp bi_fg
@nofg:
        lda #<s_bg
        sta lp2
        lda #>s_bg
        sta lp2+1
        jsr strcmp_
        bne @nobg
        jmp bi_bg
@nobg:
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
        lda #1
        sta status
@n:     inc bk_i
        jmp @l
@done:  sec
        rts

; fg [job]: bring a stopped or background job to the foreground
bi_fg:  jsr job_arg
        bcs @r
        ldx #1
        jsr SYS_FG
        bcs job_err
        lda bk_p
        jsr fgwait
@r:     sec
        rts

; bg [job]: let a stopped job go on running in the background
bi_bg:  jsr job_arg
        bcs @r
        ldx #0
        jsr SYS_FG
        bcs job_err
        lda #'['
        jsr putc
        lda bk_p
        ldx #0
        jsr print_dec
        lda #<s_run
        ldx #>s_run
        jsr print
        jsr newline
@r:     sec
        rts

; job_err: A = errno from fg/bg; a pid that isn't running is "no such job"
job_err:
        ldx #1
        stx status
        cmp #ESRCH
        beq job_none
        ldx av
        ldy av+1
        jsr perr
        sec
        rts

; job_arg: A = bk_p = pid from av[1], or lastjob; carry set (after a
; message) if there is none
job_arg:
        lda nargs
        cmp #2
        bcc @last
        lda av+2
        ldx av+3
        jsr parse_dec
        bcs @none
        bcc @ok
@last:  lda lastjob
        beq @none
@ok:    sta bk_p
        clc
        rts
@none:
job_none:
        lda #<s_nojob
        ldx #>s_nojob
        jsr eprint
        sec
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
        ldy pinfo+2
        cpy #4              ; stopped
        bne @st
        lda #<s_stopped
        ldx #>s_stopped
@st:    jsr print
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
s_stopped: .byte "] stopped  ", 0
s_fg:      .byte "fg", 0
s_bg:      .byte "bg", 0
s_nojob:   .byte "no such job", 10, 0
s_root:    .byte "/", 0
