; Breadbin swapping (docs/design-swap.md): when the pool runs out, processes
; that aren't running go to the REU, and come back to the same pages when
; the scheduler picks them.
;
; Most of it lives in the RAM under the KERNAL ROM (segments HICODE and
; HIBSS, copied there at boot): only in_core and alloc_pages are resident.
; They switch the ROM out (MAP_RAM) with interrupts off around each call.
; The code up there may call resident code that doesn't need the ROM
; (page_alloc, page_free), and reaches the REU through the I/O area.
.include "k.inc"
.import pa_n, pg_used

SWPAGES = 128           ; the upper half of bank sw_bank
POOL_FIRST = $08        ; as in mem.s

REU_CMD    = $df01
REU_C64LO  = $df02
REU_C64HI  = $df03
REU_LO     = $df04
REU_HI     = $df05
REU_BANK   = $df06
REU_LENLO  = $df07
REU_LENHI  = $df08
REU_CTRL   = $df0a
CMD_STASH  = $90        ; C64 -> REU, now
CMD_FETCH  = $91        ; REU -> C64, now

.segment "BSS"
sw_on:   .res 1         ; 1: swapping is on (an REU with /tmp on it)
sw_bank: .res 1         ; the REU bank whose upper half is the swap area

.segment "CODE"
; in_core: X = a ready slot, interrupts off -> carry clear if its pages are
; in the pool (brought back from the REU if need be), carry set if they
; can't come back yet. Keeps X and Y.
in_core:
        lda p_flags,x
        bmi @out
        clc
        rts
@out:   lda #MAP_RAM
        sta $01
        jsr sw_in
        lda #MAP_KERNAL     ; (lda/sta keep the carry)
        sta $01
        rts

; alloc_pages: Y = pages -> A = first page, carry clear; or carry set,
; A = ENOMEM. Like page_alloc, but a full pool moves processes that aren't
; the caller to the REU until the pages fit.
alloc_pages:
        jsr page_alloc
        bcc @r
        lda sw_on
        beq @no
        php
        sei
        lda #MAP_RAM
        sta $01
        jsr sw_room
        ldx #MAP_KERNAL
        stx $01
        bcs @f
        plp
        clc
        rts
@f:     plp
@no:    lda #ENOMEM
        sec
@r:     rts

; ---------------------------------------------------------------------
.segment "HIBSS"
sw_map:  .res SWPAGES   ; 0: that page of the swap area is free
sw_pg:   .res MAXPROC   ; where each process that is out starts in the area
sw_t:    .res 1         ; sw_in: the process coming back
sw_x:    .res 1
sw_y:    .res 1
sw_n:    .res 1
sw_run:  .res 1
sw_start: .res 1
sw_p:    .res 1         ; a page being looked at
sw_e:    .res 1         ; one past a process's last page
sw_best: .res 1

.segment "HICODE"
; sw_room: pa_n pages are wanted. Move out the biggest process that isn't
; running until page_alloc finds them -> A = first page, carry clear; or
; carry set.
sw_room:
@l:     jsr pick_victim
        bcs @r
        jsr sw_out
        bcs @r
        ldy pa_n
        jsr page_alloc
        bcs @l
@r:     rts

; pick_victim -> X = the biggest process in the pool that isn't the
; current one, carry clear; carry set if there is none
pick_victim:
        lda #0
        sta sw_n
        lda #$ff
        sta sw_best
        ldx #MAXPROC-1
@l:     cpx cur
        beq @n
        jsr in_pool
        bcs @n
        lda p_mlen,x
        cmp sw_n
        bcc @n
        beq @n
        sta sw_n
        stx sw_best
@n:     dex
        bpl @l
        ldx sw_best
        cpx #$ff            ; carry set if none
        rts

; in_pool: X = slot -> carry clear if it's a live process (not free, not a
; zombie) whose pages are in the pool. Keeps X and Y.
in_pool:
        lda p_state,x
        beq @no
        cmp #PS_ZOMBIE
        beq @no
        lda p_flags,x
        bmi @no
        lda p_mlen,x
        beq @no
        clc
        rts
@no:    sec
        rts

; sw_out: X = slot (in the pool, not running) -> its pages go to the swap
; area and back to the pool's free list; carry set if the area is full.
; Keeps X.
sw_out:
        stx sw_x
        lda p_mlen,x
        sta sw_n
        ldy #0              ; first fit: a run of sw_n free pages
        sty sw_run
@f:     cpy #SWPAGES
        bcs @full
        lda sw_map,y
        beq @fr
        lda #0
        sta sw_run
        iny
        bne @f
@fr:    lda sw_run
        bne @c
        sty sw_start
@c:     inc sw_run
        iny
        lda sw_run
        cmp sw_n
        bne @f
        ldy sw_start
        lda #1
@m:     sta sw_map,y
        iny
        dec sw_run
        bne @m
        ldx sw_x
        lda sw_start
        sta sw_pg,x
        ldy #CMD_STASH
        jsr sw_dma
        ldx sw_x
        lda p_flags,x
        ora #PF_OUT
        sta p_flags,x
        lda p_mpage,x
        ldy p_mlen,x
        jsr page_free
        ldx sw_x
        clc
        rts
@full:  ldx sw_x
        sec
        rts

; sw_in: X = slot (out) -> its pages are back where they were, carry clear;
; carry set if one of them is held by something that can't move.
; Keeps X and Y.
sw_in:
        stx sw_t
        sty sw_y
        lda p_mpage,x
        sta sw_p
        clc
        adc p_mlen,x
        sta sw_e
@pg:    lda sw_p            ; every page it needs must be free:
        cmp sw_e            ; move out whoever holds one
        bcs @take
        sec
        sbc #POOL_FIRST
        tay
        lda pg_used,y
        beq @nx
        jsr owner
        bcs @fail
        jsr sw_out
        bcs @fail
@nx:    inc sw_p
        jmp @pg
@take:  ldx sw_t
        lda free_pages
        sec
        sbc p_mlen,x
        sta free_pages
        lda p_mlen,x
        sta sw_n
        lda p_mpage,x
        sec
        sbc #POOL_FIRST
        tay
        lda #1
@tk:    sta pg_used,y
        iny
        dec sw_n
        bne @tk
        ldy #CMD_FETCH
        jsr sw_dma
        ldx sw_t            ; free its place in the swap area
        lda p_mlen,x
        sta sw_n
        ldy sw_pg,x
        lda #0
@fm:    sta sw_map,y
        iny
        dec sw_n
        bne @fm
        lda p_flags,x
        and #<~PF_OUT
        sta p_flags,x
        ldy sw_y
        clc
        rts
@fail:  ldx sw_t
        ldy sw_y
        sec
        rts

; owner: sw_p = a page in use -> X = the process in the pool that holds
; it, carry clear; carry set if none does (a pipe, a program being loaded)
owner:
        ldx #MAXPROC-1
@l:     jsr in_pool
        bcs @n
        lda sw_p
        cmp p_mpage,x
        bcc @n
        lda p_mpage,x
        clc
        adc p_mlen,x
        sta sw_run
        lda sw_p
        cmp sw_run
        bcc @f
@n:     dex
        bpl @l
        sec
        rts
@f:     clc
        rts

; sw_dma: X = slot, Y = REU command: move its pages between the pool and
; its place in the swap area
sw_dma:
        lda #0
        sta REU_C64LO
        sta REU_LO
        sta REU_LENLO
        sta REU_CTRL
        lda p_mpage,x
        sta REU_C64HI
        lda sw_pg,x
        ora #$80
        sta REU_HI
        lda sw_bank
        sta REU_BANK
        lda p_mlen,x
        sta REU_LENHI
        sty REU_CMD
        rts
