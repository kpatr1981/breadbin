; htop: cpu, memory and process usage, redrawn in place
;
;   r  redraw now (and restart the counters)      q  quit
;
; The kernel keeps no CPU time per process, so htop measures it. It
; sleeps one jiffy and reads the clock when it wakes:
;  - on time: nothing else wanted the CPU (the scheduler would have run
;    it first), so the jiffy was idle, and the process table isn't read;
;  - late: another process held the CPU for the jiffies that passed. htop
;    looks for a ready process (state r) and gives it all of them; with
;    several ready ones they go round robin, like the scheduler's slices.
;    If none is ready any more, they count as idle.
; Idle time is shown as pid 0.
;
; Every counter is 8 bits. The tick counter is their sum, so none can
; overflow: when it reaches 128 (about 2 s) htop redraws, works out each
; share with an 8-bit divide (count*100/ticks) and starts again.
;
; Memory is shown like free: the bar is the pages in use, the numbers are
; used/total KB (pages / 4). With an REU or GeoRAM, a third line shows how
; full the /tmp RAM disk on it is (SYS_FSINFO; the swap area that shares
; the expansion has no usage the kernel reports). The tasks line also has
; the free/total pages and the time since boot.
.include "../../include/breadbin.inc"
.import print, eprint, dec_str

NSLOT  = 16             ; procinfo slots (the kernel uses the first 12)
BARW   = 16             ; bar width
REFRESH = 128           ; ticks per round
MAXEL   = 32            ; at most this many ticks for one wake-up (a long
                        ; disk wait): the 8-bit counters can't overflow
ROW_I  = 6              ; the idle row; processes follow it
ROW_S  = 24             ; status line
OBUFSZ = 40             ; output buffer: one SYS_WRITE when full (about a line)

KBNDX  = $c6            ; KERNAL: keys in the keyboard buffer (only read)

slot = $23
row  = $24
q    = $25              ; string pointer
lo   = $27              ; dividend / product
hi   = $28
dv   = $29              ; divisor
n    = $2a
w    = $2b
total = $2c             ; the busiest variables: zero page is 1 byte
idle = $2d              ; shorter per use than the rest of memory
el   = $2e              ; jiffies that passed during the last sleep
olen = $2f              ; bytes in obuf

.segment "CODE"
start:
        lda #0              ; full screen: the console only. isatty gives
        jsr SYS_ISATTY      ; X = the terminal (0 the console, 1 the serial
        bcs @con            ; line, where cursor keys and colours differ)
        txa
        beq @con
        lda #<s_cons
        ldx #>s_cons
        jsr eprint
        lda #1
        jmp SYS_EXIT
@con:   jsr SYS_GETPID
        sta mypid
        lda #$ff
        sta last
        lda #1
        jsr SYS_CONMODE     ; one key per read, no echo
        lda #<s_cls
        ldx #>s_cls
        jsr print
        jsr draw            ; also clears the counters

main:   jsr SYS_TIME        ; (the low byte is enough for a difference)
        sta tlast
        lda #1
        ldx #0
        jsr SYS_SLEEP       ; one jiffy
        jsr SYS_TIME
        sec
        sbc tlast           ; jiffies that passed: 1 = woke on time
        cmp #MAXEL+1
        bcc @el
        lda #MAXEL
@el:    sta el
        jsr sample
        lda total
        cmp #REFRESH
        bcc @key
        jsr draw
@key:   lda KBNDX           ; a key waiting? (else SYS_READ would block)
        beq main
        jsr getkey
        ora #$20            ; either case
        cmp #'q'
        beq quit
        cmp #'r'
        bne main
        jsr draw
        jmp main

quit:   lda #0
        jsr SYS_CONMODE
        lda #<s_cls
        ldx #>s_cls
        jsr print
        lda #0
        jmp SYS_EXIT

getkey: lda #<key
        sta r0
        lda #>key
        sta r0+1
        lda #1
        sta r1
        lda #0
        sta r1+1
        jsr SYS_READ        ; fd 0
        bcs @eof
        lda r1
        beq @eof
        lda key
        rts
@eof:   lda #'q'
        rts

; ---------------------------------------------------------------------
; sample: count the `el` jiffies that passed. On time (el <= 1): idle,
; without reading the process table. Late: to the next ready process after
; `last`, or to idle if none is ready now. Only the slots seen at the last
; redraw are looked at (spid).
sample: lda total
        clc
        adc el
        sta total
        lda el
        cmp #2
        bcs @scan
        inc idle            ; on time: an idle jiffy
        rts
@scan:  ldx last
        lda #NSLOT
        sta n
@nx:    inx
        cpx #NSLOT
        bcc @c
        ldx #0
@c:     lda spid,x
        beq @sk             ; empty at the last redraw
        cmp mypid
        beq @sk             ; not ourselves
        stx slot
        jsr pinfo
        ldx slot
        bcs @sk             ; gone
        lda buf
        cmp spid,x
        bne @sk             ; slot reused by a new process
        lda buf+2
        cmp #1              ; ready: running or waiting for the CPU
        bne @sk
        lda cnt,x
        clc
        adc el
        sta cnt,x
        stx last
        rts
@sk:    dec n
        bne @nx
        lda idle            ; nobody ready any more: idle
        clc
        adc el
        sta idle
        rts

pinfo:  lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda slot
        jmp SYS_PROCINFO

; ---------------------------------------------------------------------
; draw: the whole screen, then clear the counters for the next round
draw:   lda #<mi
        sta r0
        lda #>mi
        sta r0+1
        jsr SYS_MEMINFO

        ; cpu [bar] nnn%
        lda #0
        jsr out_goto
        lda #<s_cpu
        ldx #>s_cpu
        jsr out_str
        lda total
        sec
        sbc idle
        ldx total
        jsr pct
        jsr bar_pct
        jsr out_eol

        ; mem [bar] nnn% used/totalk: like free (KB = pages / 4)
        lda #1
        jsr out_goto
        lda #<s_mem
        ldx #>s_mem
        jsr out_str
        lda mi+1
        sec
        sbc mi
        sta used
        ldx mi+1
        jsr pct
        jsr bar_pct
        lda #' '
        jsr out_ch
        lda used
        lsr a
        lsr a               ; pages / 4 = KB
        ldx #3
        jsr out_dec
        lda #'/'
        jsr out_ch
        lda mi+1
        lsr a
        lsr a
        ldx #0
        jsr out_dec
        lda #'k'
        jsr out_ch
        jsr out_eol

        ; reu / geo [bar] nnn% used/totalk: the /tmp RAM disk
        lda #2
        jsr out_goto
        jsr ram_line
        jsr out_eol

        ; reu / geo nnnk: the expansion size, as free (banks * 64 KB)
        lda #3
        jsr out_goto
        jsr exp_line
        jsr out_eol

        ; tasks n/max  pg free/total  up h:mm
        lda #4
        jsr out_goto
        lda #<s_tasks
        ldx #>s_tasks
        jsr out_str
        lda mi+3
        ldx #0
        jsr out_dec
        lda #'/'
        jsr out_ch
        lda mi+4
        ldx #0
        jsr out_dec
        lda #<s_pgs
        ldx #>s_pgs
        jsr out_str
        lda mi              ; free pages
        ldx #0
        jsr out_dec
        lda #'/'
        jsr out_ch
        lda mi+1
        ldx #0
        jsr out_dec
        lda #<s_up
        ldx #>s_up
        jsr out_str
        jsr uptime
        jsr out_eol

        lda #5
        jsr out_goto
        lda #<s_hdr
        ldx #>s_hdr
        jsr rbar

        ; pid 0: idle
        lda #ROW_I
        sta row
        jsr out_goto
        lda #0
        ldx #5
        jsr out_dec
        lda idle            ; its cpu% right-aligned in the cpu% column
        ldx total
        jsr pct
        ldx #18
        jsr out_dec
        lda #<s_idle
        ldx #>s_idle
        jsr out_str
        jsr out_eol
        inc row

        ; one row per process, as ps
        lda #0
        sta slot
@p:     jsr pinfo
        ldx slot
        bcc @have
        lda #0
        sta spid,x
        sta cnt,x
        jmp @np
@have:  lda buf             ; its ticks, if it is the process counted
        cmp spid,x
        beq @same
        lda #0
        beq @cnt
@same:  lda cnt,x
@cnt:   pha
        lda #0
        sta cnt,x
        lda buf
        sta spid,x          ; count this one from now on
        pla
        ldx total
        jsr pct
        sta cpu
        lda row
        jsr out_goto
        lda buf             ; pid
        ldx #5
        jsr out_dec
        lda buf+1           ; ppid
        ldx #5
        jsr out_dec
        lda #' '
        jsr out_ch
        jsr out_ch
        ldx buf+2           ; state
        cpx #5
        bcc @st
        ldx #0
@st:    lda states,x
        jsr out_ch
        lda buf+4           ; pages
        ldx #5
        jsr out_dec
        lda cpu
        ldx #5
        jsr out_dec
        lda #' '
        jsr out_ch
        ldy #5              ; name
@nl:    lda buf,y
        beq @ne
        jsr out_ch
        iny
        cpy #16
        bne @nl
@ne:    jsr out_eol
        inc row
@np:    inc slot
        lda slot
        cmp #NSLOT
        beq @clr
        jmp @p

@clr:   lda row             ; clear what an exited process left
        cmp #ROW_S
        bcs @stat
        jsr out_goto
        jsr out_eol
        inc row
        bne @clr

@stat:  lda #ROW_S
        jsr out_goto
        lda #<s_stat
        ldx #>s_stat
        jsr rbar
        jsr flush
        lda #0
        sta total
        sta idle
        rts

; exp_line: with an REU or GeoRAM, "reu"/"geo" and its size in KB
; (banks * 64), as free does. Nothing without.
exp_line:
        lda mi+2
        bne @x
        rts                 ; no expansion: nothing
@x:     ldx #<s_reu
        ldy #>s_reu
        lda mi+5
        cmp #2
        bne @l
        ldx #<s_geo
        ldy #>s_geo
@l:     txa
        pha
        tya
        tax
        pla
        jsr out_str
        lda #0
        sta rb
        lda mi+2
        ldy #6
@m:     asl a               ; banks * 64
        rol rb
        dey
        bne @m
        ldx rb
        ldy #0
        jsr out_dec16
        lda #'k'
        jmp out_ch

; ram_line: with an REU or GeoRAM (meminfo type), "reu"/"geo" and how full
; the /tmp RAM disk on it is: bar, percent, used/total KB. Nothing without.
ram_line:
        lda mi+5
        bne @x
        rts                 ; no expansion: nothing
@x:     lda #<(s_tmp+1)     ; "tmp" (s_tmp is "/tmp")
        ldx #>(s_tmp+1)
        jsr out_str
        lda #' '
        jsr out_ch
        lda #<s_tmp         ; fsinfo("/tmp"): free, total blocks
        sta r0
        lda #>s_tmp
        sta r0+1
        lda #<fsb
        sta r1
        lda #>fsb
        sta r1+1
        jsr SYS_FSINFO
        bcc @f
        rts                 ; no /tmp RAM disk: just the name
@f:     lda fsb+2           ; ub = used = total - free, tb = total
        sec
        sbc fsb
        sta ub
        lda fsb+3
        sbc fsb+1
        sta ub+1
        lda fsb+2
        sta tb
        lda fsb+3
        sta tb+1
        ldx #3              ; uk, tk = the same in KB (blocks / 4)
@k:     lda ub,x
        sta uk,x
        dex
        bpl @k
        ldx #2
@q:     lsr uk+1
        ror uk
        lsr tk+1
        ror tk
        dex
        bne @q
@s:     lda tb+1            ; the same shift on both until total fits 8 bits
        beq @p
        lsr tb+1
        ror tb
        lsr ub+1
        ror ub
        jmp @s
@p:     lda ub
        ldx tb
        jsr pct
        jsr bar_pct
        lda uk
        ldx uk+1
        ldy #5
        jsr out_dec16
        lda #'/'
        jsr out_ch
        lda tk
        ldx tk+1
        ldy #0
        jsr out_dec16
        lda #'k'
        jmp out_ch

; uptime: the time since boot as h:mm (SYS_TIME: jiffies, 24 bits;
; divided by 60 three times; under 78 hours, so the hours fit 8 bits)
uptime: jsr SYS_TIME
        sta t
        stx t+1
        sty t+2
        jsr div60           ; jiffies -> seconds
        jsr div60           ; -> minutes
        jsr div60           ; remainder: minutes; t = hours
        sta mins
        lda t
        ldx #0
        jsr out_dec
        lda mins
; two: ":" and A as two digits
two:    pha
        lda #':'
        jsr out_ch
        pla
        cmp #10
        bcs @t
        pha
        lda #'0'
        jsr out_ch
        pla
@t:     ldx #0
        jmp out_dec

; div60: t (24 bits) /= 60 -> A = the remainder
div60:  lda #0
        ldx #24
@l:     asl t
        rol t+1
        rol t+2
        rol a
        cmp #60
        bcc @n
        sbc #60
        inc t
@n:     dex
        bne @l
        rts

; ---------------------------------------------------------------------
; pct: A = count, X = of how many -> A = count*100/X, rounded (0 if X = 0)
pct:    cpx #0
        bne @go
        lda #0
        rts
@go:    stx dv
        ldx #100
        ; fall through

; muldiv: A * X / dv, rounded. The quotient must fit 8 bits.
muldiv: jsr mul8
        lda dv              ; + dv/2, to round
        lsr a
        clc
        adc lo
        sta lo
        bcc div8
        inc hi
        ; fall through

; div8: hi:lo / dv -> A = quotient, hi = remainder. Needs hi < dv (the
; quotient fits 8 bits): 8 shift-subtracts.
div8:   ldx #8
        lda hi
@l:     asl lo
        rol a
        bcs @s              ; a 9-bit remainder is bigger than dv
        cmp dv
        bcc @n
@s:     sbc dv              ; carry is set on both paths here
        inc lo              ; quotient bit
@n:     dex
        bne @l
        sta hi
        lda lo
        rts

; mul8: A * X -> hi:lo (shift and add)
mul8:   sta lo
        stx m
        lda #0
        ldx #8
        lsr lo
@l:     bcc @n
        clc
        adc m
@n:     ror a
        ror lo
        dex
        bne @l
        sta hi
        rts

; bar_pct: A = percent -> "[" + reverse cells + dots + "] nnn%" (BARW cells)
bar_pct:
        sta pv
        ldx #100            ; cells = percent * BARW / 100, rounded
        stx dv
        ldx #BARW
        jsr muldiv
        sta n
        lda #'['
        jsr out_ch
        lda #'R'
        jsr out_esc
        ldy n               ; 3. two plain loops: reverse spaces, then dots
        beq @e
@f:     lda #' '
        jsr out_ch
        dey
        bne @f
@e:     lda #'r'
        jsr out_esc
        lda #BARW
        sec
        sbc n
        tay
        beq @x
@d:     lda #'.'
        jsr out_ch
        dey
        bne @d
@x:     lda #']'
        jsr out_ch
        lda pv
        ldx #4
        jsr out_dec
        lda #'%'
        jmp out_ch

; ---------------------------------------------------------------------
; output, buffered: one SYS_WRITE per OBUFSZ bytes
; out_ch: A = byte (X and Y kept)
out_ch: stx ox
        ldx olen
        sta obuf,x
        inx
        stx olen
        cpx #OBUFSZ
        bcc @r
        sty oy
        jsr flush
        ldy oy
@r:     ldx ox
        rts

flush:  lda olen
        beq @r
        sta r1
        lda #0
        sta r1+1
        sta olen
        lda #<obuf
        sta r0
        lda #>obuf
        sta r0+1
        lda #1
        jsr SYS_WRITE
@r:     rts

; out_str: A/X = string
out_str:
        sta q
        stx q+1
        ldy #0
@l:     lda (q),y
        beq @r
        jsr out_ch
        iny
        bne @l
@r:     rts

; out_dec16: A/X = 16-bit number, Y = width (right aligned)
out_dec16:
        sty w
        jmp od
; out_dec: A = number, X = width (right aligned)
out_dec:
        stx w
        ldx #0
od:     jsr dec_str         ; A/X = digits, Y = their count
        sta q
        stx q+1
        sty n
@p:     lda n
        cmp w
        bcs @d
        lda #' '
        jsr out_ch
        dec w
        bne @p
@d:     ldy #0
@l:     lda (q),y
        beq @r
        jsr out_ch
        iny
        bne @l
@r:     rts

; out_goto: A = row, column 0
out_goto:
        pha
        lda #'='
        jsr out_esc
        pla
        clc
        adc #32
        jsr out_ch
        lda #32
        jmp out_ch

out_eol:
        lda #'K'
        ; fall through

; out_esc: ESC, then A
out_esc:
        pha
        lda #ESC
        jsr out_ch
        pla
        jmp out_ch

; rbar: A/X = string -> in reverse, padded to 39 columns (4. padding by a
; loop, not stored)
rbar:   pha
        lda #'R'
        jsr out_esc
        pla
        jsr out_str         ; leaves Y = its length
        sty n
        lda #39
        sec
        sbc n
        tay
        beq @e
@p:     lda #' '
        jsr out_ch
        dey
        bne @p
@e:     lda #'r'
        jmp out_esc

.segment "RODATA"
s_cls:   .byte 12, 0
s_cons:  .byte "htop: needs the console", 10, 0
s_cpu:   .byte "cpu ", 0
s_mem:   .byte "mem ", 0
s_tasks: .byte "tasks ", 0
s_pgs:   .byte "  pg ", 0
s_up:    .byte "  up ", 0
s_reu:   .byte "reu ", 0
s_geo:   .byte "geo ", 0
s_tmp:   .byte "/tmp", 0
s_hdr:   .byte "  pid ppid st  mem cpu% name", 0   ; rbar: reverse, padded
s_idle:  .byte " idle", 0
s_stat:  .byte " r refresh  q quit", 0
states:  .byte "?rszT"

.segment "BSS"
buf:    .res 17         ; procinfo
mi:     .res 6          ; meminfo
spid:   .res NSLOT      ; pid counted in each slot (0 = none)
cnt:    .res NSLOT      ; its ticks
last:   .res 1          ; slot that got the last busy tick
mypid:  .res 1
used:   .res 1
cpu:    .res 1
pv:     .res 1
m:      .res 1          ; mul8's multiplier
tlast:  .res 1          ; the clock (low byte) before the sleep
fsb:    .res 8          ; fsinfo: free, total blocks, inodes, device
ub:     .res 2          ; used blocks (scaled)
tb:     .res 2          ; total blocks (scaled)      ub, tb, uk, tk: in this
uk:     .res 2          ; used KB                    order (copied as 4 bytes)
tk:     .res 2          ; total KB
t:      .res 3          ; uptime: jiffies, then minutes, hours
mins:   .res 1
rb:     .res 1          ; exp_line: size high byte
key:    .res 1
ox:     .res 1
oy:     .res 1
obuf:   .res OBUFSZ