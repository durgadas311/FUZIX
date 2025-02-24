;
;	Modified version of the general VDP driver code. We can't use the
;	generic code because we run in banked memory and our CPU speed is
;	much higher so we need a lot of I/O delays
;
;	The TMS9918A looks like a simple  I/O device but internally it's
;	actually attached to the CPU by various buffers and runs at a lower
;	pace than the CPU. A write is effectively queued with a depth of
;	one. Reads are more complicated. The I/O ports set an address which
;	is read at some point later and put into a buffer. We thus have to
;	not only wait but wait in the right part of the cycle.
;
;	The read/write buffer is shared
;
;	Vertical blank we can do much better but right now we don't do
;	anything like scroll or write on vblank. We should do to sort the
;	scroll flickering.
;
;	Timing rules
;	Text RAM access worst case ~26 clocks
;	

        .module vdp

	; video driver
	.globl _scroll_up
	.globl _scroll_down
	.globl _plot_char
	.globl _clear_lines
	.globl _clear_across
	.globl _cursor_on
	.globl _cursor_off
	.globl _cursor_disable
	.globl _set_console

	; graphics API
	.globl _vdp_rop
	.globl _vdp_wop

	.globl cursorpos

	.globl _int_disabled

	.globl _vdpport
	.globl _inputtty
	.globl _outputtty
	.globl _ef9345_present

	.globl _vtattr_notify

	.globl _vtattr_cap
	.globl _vidmode

	.globl _vt_twidth

	.globl _scrolld_s1
	.globl _scrollu_w
	.globl _scrollu_mov
	.globl _scrolld_base
	.globl _scrolld_mov

;
;	EF9345 driver interface for 80 column modes
;
	.globl ef_scroll_up
	.globl ef_scroll_down
	.globl ef_plot_char
	.globl ef_clear_lines
	.globl ef_clear_across
	.globl ef_cursor_on
	.globl ef_cursor_off
	.globl ef_cursor_disable
	.globl ef_set_console

;
;	Core support
;
	.globl map_process_always
	.globl map_kernel_restore
	.area _CODE1
;
;	Register write value E to register A. This is a pure VDP register
;	access so we shouldn't need a delay (check if we need a small one
;	just because we are hitting it at nearly 8MHz)
;
vdpout:	    ld bc, (_vdpport)
	    out (c), e			; Write the data
	    out (c), d			; and then the register | 0x80
	    ret

;
;	FIXME: need to IRQ protect the pairs of writes
;


videopos:	; turn E=Y D=X into HL = addr
	        ; pass B = 0x40 if writing
	        ; preserves C
	    ld a, (_outputtty)
	    dec a
	    add a			; 1K per screen
	    add a
	    add b
	    ld b,a
	    ld a, e			; 0-24 Y
	    add a, a
	    add a, a
	    add a, a			; x 8
	    ld l, a
	    ld h, #0
	    ld a, (_vidmode)
	    or a
	    jr nz, pos32
	    push hl
	    add hl, hl			; x 16
	    add hl, hl			; x 32
	    ld a, d
	    pop de
	    add hl, de			; x 40
	    ld e, a
	    ld d, b			; 0 for read 0x40 for write
	    add hl, de			; + X
	    ret
pos32:
	    add hl,hl
	    add hl,hl
            ld e,d
	    ld d,b
	    add hl,de
	    ret
;
;	Eww.. wonder if VT should provide a hint that its the 'next char'
;
_plot_char:
	    pop af
	    pop hl
	    pop de			; D = x E = y
	    pop bc
	    push bc
	    push de
	    push hl
	    push af
	    ld a,(_ef9345_present)
	    or a
	    jp nz, ef_plot_char
	    ld a,(_int_disabled)
	    push af
	    di
plotit:
	    ld b, #0x40			; writing
	    call videopos
	    ld a, c
plotit2:
	    ld bc, (_vdpport)
	    out (c), l			; address
	    out (c), h			; address | 0x40
	    dec c
	    out (c), a			; character
	    ; We need 24 clocks for this to complete - which is fine as
	    ; we won't be back that fast
popret:
	    pop af
	    or a
	    ret nz
	    ei
	    ret

;
;	We can keep the buffer in banked code as we only use it here
;

scrollbuf:
	    .ds		40

;
;	We don't yet use attributes, we should support inverse video but
;	there isn't anything else we can do in text mode
;
_scroll_down:
	    ld a,(_ef9345_present)
	    or a
	    jp nz, ef_scroll_down
	    ld a,(_int_disabled)
	    push af
	    di
	    ld a, (_outputtty)
	    dec a
	    add a			; 1K per screen
	    add a
	    ld h,a
	    ld l,#0
	    ld b, #23
	    ld de, (_scrolld_base) ; start of bottom line
	    add hl,de
	    ex de,hl
upline:
	    push bc
	    ld bc, (_vdpport)	; vdpport + 1 always holds the width (40)
	    ld hl, #scrollbuf
	    out (c), e		; our position
	    out (c), d
	    dec c		; 4 clocks
	    ; Wait for the TMS9918A to be ready - FIXME we can trim this a tiny
	    ; bit because there are a few machine cycles from the out data
	    ; hitting the TMS9918A to the ini decoding and reading
	    bit 0,0(ix)		; 20 clocks
down_0:
	    ; Our data is not available for 24 clocks from the setup or
	    ; previous ini. 
	    ini			; 16 clocks
	    jp nz, down_0	; 10 clocks
	    inc c
	    ld hl, (_scrolld_s1); go down one line and into write mode
	    ld b, l		; get the number of chars as it's in l
	    add hl, de		; relative to our position
	    out (c), l
	    out (c), h
	    ld hl, #scrollbuf
	    dec c
down_1:
	    outi		; video ptr is to the line below so keep going
	    jp nz,down_1	; total 26 clocks per loop
	    pop bc		; recover line counter
	    ld hl, (_scrolld_mov)
	    add hl, de		; up 40 bytes
	    ex de, hl		; and back into DE
	    djnz upline
	    jp popret

_scroll_up:
	    ld a,(_ef9345_present)
	    or a
	    jp nz, ef_scroll_up
	    ld a,(_int_disabled)
	    push af
	    di
	    ld a, (_outputtty)
	    dec a
	    add a			; 1K per screen
	    add a
	    ld h,a
	    ld l,#0
	    ld b, #23
	    ld de, (_scrollu_w)		; start of second line (base = width)
	    add hl,de
	    ex de,hl
downline:   push bc
	    ld bc, (_vdpport)
	    ld hl, #scrollbuf
	    out (c), e
	    out (c), d
	    dec c
	    bit 0,0(ix)		; 20 clocks
up_0:
	    ini
	    jp nz, up_0
	    inc c
	    ld hl, (_scrollu_mov); up w bytes in the low 12 bits, add 0x40
				; for write ( we will carry one into the top
				; nybble)
	    add hl, de
	    out (c), l
	    out (c), h
	    dec c
	    ld hl, #scrollbuf
	    ld a,(_scrollu_w)	; get width
	    ld b, a
up_1:
	    outi
	    jp nz,up_1
	    pop bc
	    ld hl, (_scrollu_w)	; get width
	    add hl, de
	    ex de, hl
	    djnz downline
	    jp popret

_clear_lines:
	    pop bc
	    pop hl
	    pop de	; E = line, D = count
	    push de
	    push hl
	    push bc
	    ld a,(_ef9345_present)
	    or a
	    jp nz, ef_clear_lines
	    ld a,(_int_disabled)
	    push af
	    di
	    ld c, d
	    ld d, #0
	    ld b, #0x40
	    call videopos
	    ld e, c
	    ld bc, (_vdpport)
	    out (c), l
	    out (c), h
	    dec c
l2:	    ld a, (_vt_twidth)
	    ld b,a
            ld a, #' '
l1:	    out (c), a		; Inner loop clears a line, outer counts
				; need 26 clocks between writes. DJNZ is 13,
				; out is 11
	    nop
            djnz l1
	    dec e
	    jr nz, l2
	    jp popret

_clear_across:
	    pop af
	    pop hl
	    pop de	; DE = coords
	    pop bc	; C = count
	    push bc
	    push de
	    push hl
	    push af
	    ld a,(_ef9345_present)
	    or a
	    jp nz, ef_clear_across
	    ld a,(_int_disabled)
	    push af
	    di
	    ld b,#0x40
	    call videopos
	    ld a, c
	    ld bc, (_vdpport)
	    out (c), l
	    out (c), h
	    ld b, a
            ld a, #' '
	    dec c
l3:	    out (c),a
	    nop
            djnz l3
	    jp popret

;
;	Turn on the cursor if this is the displayed console
;
_cursor_on:
	    pop bc
	    pop hl
	    pop de
	    push de
	    push hl
	    push bc
	    ld a,(_outputtty)
	    ld c,a
	    ld a,(_inputtty)
	    cp c
	    ret nz
	    ld a,(_ef9345_present)
	    or a
	    jp nz, ef_cursor_on
	    ld a,(_int_disabled)
	    push af
	    di
	    ld (cursorpos), de
	    ld b, #0x00			; reading
	    call videopos
	    ld a, c
	    ld bc, (_vdpport)
	    out (c), l			; address
	    out (c), h			; address
	    dec c
	    bit 0,0(ix)			; wait for byte to be ready
	    in a, (c)			; character
	    ld (cursorpeek), a		; save it away
	    set 6, h			; make it a write command
	    xor #0x80			; invert the video
	    jp plotit2

_cursor_off:
	    ld a,(_outputtty)
	    ld c,a
	    ld a,(_inputtty)
	    cp c
	    ret nz
	    ld a,(_ef9345_present)
	    or a
	    jp nz, ef_cursor_off
	    ld a,(_int_disabled)
	    push af
	    di
	    ld de, (cursorpos)
	    ld a, (cursorpeek)
	    ld c,a
	    jp plotit

; TODO: we may want to hook this for the ef9345
_vtattr_notify:
_cursor_disable:
	    ret

_set_console:
	    ld a,(_ef9345_present)
	    or a
	    jp nz, ef_set_console
	    ld a,(_inputtty)
	    ld bc, (_vdpport)
	    dec a
	    out (c), a
	    ld a,#0x82
	    out (c),a
	    ret

;
;	Read write low level helpers (fastcall). Need IRQ off
;
;	These are designed to run with the user space mapped so we
;	directly burst rectangles to and from the VDP. We check for
;	writes into the 3C00-3FFF area reserved for the font cache. It's
;	perhaps a silly check on an unprotected Z80 but when we get to Z280
;	it might matter rather more!
;
_vdp_rop:
	    push ix
	    push hl
	    pop ix
	    ld l, 2(ix)	; VDP offset
	    ld a, 3(ix)
	    cp #0x3C
	    ld h, a
	    jr nc, bounds	; Offset exceeds boundary
	    ld e, 6(ix)		; Stride
	    ld d, #0
	    ld bc, (_vdpport)
	    out (c), l
	    out (c), h		; Set starting pointer
	    exx
	    ld l, (ix)		; User pointer
	    ld h, 1(ix)
	    ld d, 5(ix)		; cols
	    ld e, 4(ix)		; lines
	    ld bc,(_vdpport);
	    inc c		; data port
	    call map_process_always
ropl:
	    ld b,d
ropc:
	    ini
	    nop
	    djnz ropc
	    ; Stride ?
	    exx
	    add hl, de		; stride
	    ld a, #0x3B		; we don't care about a read overruning 3C
	    cp h		; just 3F
	    jr c, bounds
	    out (c), l		; next line
	    out (c), h
	    exx
	    dec e
	    jr nz, ropl
	    pop ix
	    ld hl, #0
	    jp map_kernel_restore
bounds:
	    pop ix
	    ld hl, #-1
            jp map_kernel_restore

_vdp_wop:
	    push ix
	    push hl
	    pop ix
	    ld l, 2(ix)		; VDP offset
	    ld a, 3(ix)
	    or #0x40		; Write operation
	    cp #0x7C
	    ld h, a
	    jr nc, bounds	; Offset exceeds boundary
	    ld bc, (_vdpport)
	    ld b, 5(ix)		; cols
	    ld e, 6(ix)		; Stride
	    ld d, #0
	    out (c),l
	    out (c),h		; Set starting pointer
	    exx
	    ld l,(ix)		; User pointer
	    ld h,1(ix)
	    ld d,5(ix)		; cols
	    ld e,4(ix)		; lines
	    ld bc,(_vdpport)	;
	    inc c		; data port
	    call map_process_always
wopl:
	    ld b,d
wopc:
	    outi
	    nop
	    djnz wopc
	    ; Stride ?
	    exx
	    add hl,de		; stride
	    ld a,#0x7C
	    cp h
	    jr nc, boundclear
	    jr c, bounds	; going over boundary
	    ; We could cross the boundary during the line
	    ld a, l
	    add b
	    jr c, bounds
boundclear:
	    out (c), l		; next line
	    out (c), h
	    exx
	    dec e
	    jr nz, ropl
	    pop ix
	    ld hl,#0
	    jp map_kernel_restore


;
;	This must be in data or common not code
;
	    .area _DATA
cursorpos:  .dw 0
cursorpeek: .db 0

_scrolld_base:
	    .dw		0x03C0		; Start of bottom line
_scrolld_mov:
	    .dw		0xFFD8		; -40
_scrolld_s1:
	    .dw		0x4028		; 4000 turns on write 40 chars
_scrollu_w:
	    .dw		0x0028		; width
_scrollu_mov:
	    .dw		0x3FD8		; up 40 bytes in low 12, add 0x4000
					; carry 11->12
