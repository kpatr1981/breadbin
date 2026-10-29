; c64os memory: 256-byte page allocator for the user pool
.include "k.inc"

POOL_FIRST = $08
POOL_END   = >KSTART                ; first page owned by the kernel
NPOOL      = POOL_END - POOL_FIRST


.segment "BSS"
pg_used:     .res NPOOL
free_pages:  .res 1
total_pages: .res 1
pa_n:        .res 1
pa_run:      .res 1
pa_start:    .res 1

.segment "CODE"
mem_init:
        ldx #NPOOL-1
        lda #0
@l:     sta pg_used,x
        dex
        bpl @l
        lda #NPOOL
        sta free_pages
        sta total_pages
        rts

; page_alloc: Y = number of pages -> A = first page (carry clear),
; or carry set (A = ENOMEM). First fit.
page_alloc:
        sty pa_n
        cpy #0
        beq @fail
        ldx #0
        stx pa_run
@l:     cpx #NPOOL
        bcs @fail
        lda pg_used,x
        beq @free
        lda #0
        sta pa_run
        inx
        bne @l
@free:  lda pa_run
        bne @cont
        stx pa_start
@cont:  inc pa_run
        inx
        lda pa_run
        cmp pa_n
        bne @l
        ; mark pa_start .. pa_start+n-1
        ldx pa_start
        ldy pa_n
        lda #1
@m:     sta pg_used,x
        inx
        dey
        bne @m
        lda free_pages
        sec
        sbc pa_n
        sta free_pages
        lda pa_start
        clc
        adc #POOL_FIRST
        clc
        rts
@fail:  lda #ENOMEM
        sec
        rts

; page_free: A = first page, Y = count
page_free:
        cpy #0
        beq @r
        sec
        sbc #POOL_FIRST
        tax
        tya
        clc
        adc free_pages
        sta free_pages
        lda #0
@l:     sta pg_used,x
        inx
        dey
        bne @l
@r:     rts

; meminfo(r0 = buf): free pages, total pages, reu banks, procs used, max procs
sys_meminfo:
        ldy #0
        lda free_pages
        sta (r0),y
        iny
        lda total_pages
        sta (r0),y
        iny
        lda reu_banks
        sta (r0),y
        ldx #MAXPROC-1
        lda #0
        sta tmp0
@c:     lda p_state,x
        beq @n
        inc tmp0
@n:     dex
        bpl @c
        iny
        lda tmp0
        sta (r0),y
        iny
        lda #MAXPROC
        sta (r0),y
        clc
        rts
