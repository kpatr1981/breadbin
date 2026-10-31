; hang: hang with interrupts off; CIA 2 timer A raises an NMI ~66 ms later
; (the same vector as the RESTORE key), which must kill this process
.segment "CODE"
        lda #$ff
        sta $dd04
        sta $dd05
        lda #$81            ; timer A may raise an NMI
        sta $dd0d
        lda #$19            ; one-shot, force load, start
        sta $dd0e
        sei
hang:   jmp hang
