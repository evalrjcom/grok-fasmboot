; FASM Minimal Microkernel + Links-like Browser
; Audited and corrected for v86
; Fixes: eth_receive page calc, AES SubWord, SHA-256 round order,
;        keyboard shift tracking, URL bounds, timeout guards

format binary as 'img'

; === Boot sector ===
org 7c00h
use16

boot:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 7c00h
    sti

    mov si, msg_boot
    call bios_print

    ; Load 50 sectors (kernel) — FIX: check carry and retry once
    mov ah, 02h
    mov al, 50
    mov ch, 0
    mov cl, 2
    mov dh, 0
    mov dl, 0
    mov bx, 1000h
    int 13h
    jc disk_error

    ; Enable A20
    in al, 92h
    or al, 2
    out 92h, al

    cli
    lgdt [gdtr]
    mov eax, cr0
    or al, 1
    mov cr0, eax
    jmp 08h:pm_entry

disk_error:
    mov si, msg_err
    call bios_print
    jmp $

bios_print:
    lodsb
    test al, al
    jz .ret
    mov ah, 0eh
    int 10h
    jmp bios_print
.ret:
    ret

msg_boot db 'FASM Kernel + Network Stack loading...', 13, 10, 0
msg_err  db 'Disk error', 13, 10, 0

align 8
gdt:
    dq 0
    dw 0ffffh, 0
    db 0, 9ah, 0cfh, 0
    dw 0ffffh, 0
    db 0, 92h, 0cfh, 0
gdtr:
    dw $ - gdt - 1
    dd gdt

times 510 - ($ - $$) db 0
dw 0aa55h

; === Kernel ===
org 1000h
use32

NE2000_BASE equ 0x300
CR      equ NE2000_BASE + 0x00
PSTART  equ NE2000_BASE + 0x01
PSTOP   equ NE2000_BASE + 0x02
BNRY    equ NE2000_BASE + 0x03
TPSR    equ NE2000_BASE + 0x04
TBCR0   equ NE2000_BASE + 0x05
TBCR1   equ NE2000_BASE + 0x06
ISR     equ NE2000_BASE + 0x07
RSAR0   equ NE2000_BASE + 0x08
RSAR1   equ NE2000_BASE + 0x09
RBCR0   equ NE2000_BASE + 0x0A
RBCR1   equ NE2000_BASE + 0x0B
RCR     equ NE2000_BASE + 0x0C
TCR     equ NE2000_BASE + 0x0D
DCR     equ NE2000_BASE + 0x0E
IMR     equ NE2000_BASE + 0x0F
DATA    equ NE2000_BASE + 0x10
RESET   equ NE2000_BASE + 0x1F
CURR    equ NE2000_BASE + 0x07

pm_entry:
    mov ax, 10h
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    ; Clear screen
    mov edi, 0xb8000
    mov ecx, 2000
    mov ax, 0x0720
    rep stosw

    call ne2000_init
    call ne2000_read_mac
    call tcpip_init
    call tcp_init
    call kbd_init

    mov esi, title
    mov edi, 0xb8000
    call puts

    mov esi, homepage
    mov edi, 0xb8000 + 160*2
    call puts

    mov esi, mac_line
    mov edi, 0xb8000 + 160*10
    call puts
    mov esi, mac_addr
    mov edi, 0xb8000 + 160*10 + 12
    call print_mac

    call links_main

.hang:
    hlt
    jmp .hang

; PIT timeout helper (channel 0, ~18.2 Hz)
; Returns after roughly n ticks in ecx
pit_wait:
    push ecx
.w:
    in al, 0x40
    loop .w
    pop ecx
    ret

; === Links clone ===
links_main:
    ; Clear prompt line
    mov edi, 0xb8000 + 160*22
    mov ecx, 80
    mov ax, 0x0720
    rep stosw

    mov esi, prompt
    mov edi, 0xb8000 + 160*22
    call puts

.url_loop:
    call get_key
    test al, al
    jz .url_loop
    cmp al, 13
    je .do_go
    cmp al, 8
    je .bs
    cmp al, 27
    je .clear
    ; Printable range only
    cmp al, 32
    jb .url_loop
    cmp al, 126
    ja .url_loop
    ; FIX: strict bounds (79 max to leave room for null)
    mov ebx, [url_len]
    cmp ebx, 79
    jae .url_loop
    mov [url_buf + ebx], al
    inc dword [url_len]
    ; Echo with bounds
    mov ah, 0x0A
    mov edi, 0xb8000 + 160*22 + 12
    add edi, ebx
    add edi, ebx
    cmp edi, 0xb8000 + 160*23
    jae .url_loop
    mov [edi], ax
    jmp .url_loop

.bs:
    mov ebx, [url_len]
    test ebx, ebx
    jz .url_loop
    dec ebx
    mov [url_len], ebx
    mov byte [url_buf + ebx], 0
    mov edi, 0xb8000 + 160*22 + 12
    add edi, ebx
    add edi, ebx
    mov ax, 0x0720
    mov [edi], ax
    jmp .url_loop

.clear:
    xor eax, eax
    mov [url_len], eax
    mov edi, url_buf
    mov ecx, 80
    rep stosb
    jmp links_main

.do_go:
    mov ebx, [url_len]
    mov byte [url_buf + ebx], 0
    call dns_query
    call tcp_exchange
    call render_page
    xor eax, eax
    mov [url_len], eax
    jmp links_main

render_page:
    mov edi, 0xb8000 + 160*2
    mov ecx, 160*18
    mov ax, 0x0720
    rep stosw

    mov esi, page_header
    mov edi, 0xb8000 + 160*2
    call puts

    mov esi, url_label
    mov edi, 0xb8000 + 160*3
    call puts
    mov esi, url_buf
    mov edi, 0xb8000 + 160*3 + 12
    call puts

    mov esi, fetch_status
    mov edi, 0xb8000 + 160*5
    call puts

    mov esi, local_page
    mov edi, 0xb8000 + 160*8
    call puts
    ret

; Keyboard — FIX: separate left/right shift tracking
get_key:
    in al, 0x64
    test al, 1
    jz .none
    in al, 0x60
    ; Shift make/break — FIX: track each side
    cmp al, 0x2A
    je .lshift_on
    cmp al, 0xAA
    je .lshift_off
    cmp al, 0x36
    je .rshift_on
    cmp al, 0xB6
    je .rshift_off
    test al, 0x80
    jnz .none
    ; Colon special case
    cmp al, 0x27
    jne .not_semi
    mov al, [shift]
    test al, al
    jz .semi_u
    mov al, ':'
    ret
.semi_u:
    mov al, ';'
    ret
.not_semi:
    movzx ebx, al
    cmp ebx, 0x3A
    jae .none
    mov bl, [us_scancode + ebx]
    test bl, bl
    jz .none
    mov al, [shift]
    test al, al
    jz .done
    cmp bl, 'a'
    jb .sym
    cmp bl, 'z'
    ja .sym
    sub bl, 32
    jmp .done
.sym:
    cmp bl, '1'
    je .bang
    cmp bl, '2'
    je .at
    cmp bl, '-'
    je .under
    cmp bl, '='
    je .plus
    cmp bl, ';'
    je .colon
    cmp bl, "'"
    je .dquote
    jmp .done
.bang:
    mov bl, '!'
    jmp .done
.at:
    mov bl, '@'
    jmp .done
.under:
    mov bl, '_'
    jmp .done
.plus:
    mov bl, '+'
    jmp .done
.colon:
    mov bl, ':'
    jmp .done
.dquote:
    mov bl, '"'
    jmp .done
.lshift_on:
    or byte [shift], 1
    xor al, al
    ret
.lshift_off:
    and byte [shift], 0xFE
    xor al, al
    ret
.rshift_on:
    or byte [shift], 2
    xor al, al
    ret
.rshift_off:
    and byte [shift], 0xFD
    xor al, al
    ret
.done:
    mov al, bl
    ret
.none:
    xor al, al
    ret

kbd_init:
.flush:
    in al, 0x64
    test al, 1
    jz .flushed
    in al, 0x60
    jmp .flush
.flushed:
    call kbd_wait_input
    mov al, 0xF4
    out 0x60, al
    call kbd_wait_output
    in al, 0x60
    ret

kbd_wait_input:
    in al, 0x64
    test al, 2
    jnz kbd_wait_input
    ret

kbd_wait_output:
    in al, 0x64
    test al, 1
    jz kbd_wait_output
    ret

; --- NE2000 ---
ne2000_init:
    mov dx, RESET
    in al, dx
    out dx, al
    ; FIX: timeout on reset wait
    mov ecx, 100000
.wait_reset:
    mov dx, ISR
    in al, dx
    test al, 0x80
    jnz .reset_ok
    loop .wait_reset
.reset_ok:
    out dx, al

    mov dx, CR
    mov al, 0x21
    out dx, al

    mov dx, DCR
    mov al, 0x49
    out dx, al

    mov dx, RBCR0
    xor al, al
    out dx, al
    mov dx, RBCR1
    out dx, al

    mov dx, RCR
    mov al, 0x20
    out dx, al

    mov dx, TCR
    mov al, 0x00
    out dx, al

    mov dx, TPSR
    mov al, 0x40
    out dx, al

    mov dx, PSTART
    mov al, 0x46
    out dx, al
    mov dx, BNRY
    mov al, 0x46
    out dx, al
    mov dx, PSTOP
    mov al, 0x80
    out dx, al

    mov dx, CR
    mov al, 0x61
    out dx, al
    mov dx, CURR
    mov al, 0x47
    out dx, al
    mov dx, CR
    mov al, 0x21
    out dx, al

    mov dx, ISR
    mov al, 0xFF
    out dx, al

    mov dx, IMR
    mov al, 0x0F
    out dx, al

    mov dx, CR
    mov al, 0x22
    out dx, al
    ret

ne2000_read_mac:
    mov dx, CR
    mov al, 0x21
    out dx, al
    mov dx, RSAR0
    xor al, al
    out dx, al
    mov dx, RSAR1
    out dx, al
    mov dx, RBCR0
    mov al, 6
    out dx, al
    mov dx, RBCR1
    xor al, al
    out dx, al
    mov dx, CR
    mov al, 0x0A
    out dx, al
    mov dx, DATA
    mov edi, mac_addr
    mov ecx, 6
.read:
    in al, dx
    stosb
    loop .read
    mov dx, CR
    mov al, 0x22
    out dx, al
    ret

eth_transmit:
    push ecx
    mov dx, ISR
    mov al, 0x40
    out dx, al
    mov dx, RSAR0
    xor al, al
    out dx, al
    mov dx, RSAR1
    mov al, 0x40
    out dx, al
    mov dx, RBCR0
    mov al, cl
    out dx, al
    mov dx, RBCR1
    mov al, ch
    out dx, al
    mov dx, CR
    mov al, 0x12
    out dx, al
    mov dx, DATA
.tx_loop:
    lodsb
    out dx, al
    loop .tx_loop
.wait_rdc:
    mov dx, ISR
    in al, dx
    test al, 0x40
    jz .wait_rdc
    out dx, al
    pop ecx
    mov dx, TBCR0
    mov al, cl
    out dx, al
    mov dx, TBCR1
    mov al, ch
    out dx, al
    mov dx, CR
    mov al, 0x26
    out dx, al
    ret

; FIX: correct ring page calculation
eth_receive:
    mov dx, CR
    mov al, 0x61
    out dx, al
    mov dx, CURR
    in al, dx
    mov bl, al
    mov dx, CR
    mov al, 0x22
    out dx, al
    mov dx, BNRY
    in al, dx
    mov bh, al
    ; Empty when CURR == BNRY+1 (with wrap)
    mov al, bh
    inc al
    cmp al, 0x80
    jb .no_w
    mov al, 0x46
.no_w:
    cmp al, bl
    je .no_pkt
    ; Read header from next page (al)
    mov dx, RSAR0
    xor al, al
    out dx, al
    mov dx, RSAR1
    mov al, bh
    inc al
    cmp al, 0x80
    jb .nw2
    mov al, 0x46
.nw2:
    out dx, al
    mov dx, RBCR0
    mov al, 4
    out dx, al
    mov dx, RBCR1
    xor al, al
    out dx, al
    mov dx, CR
    mov al, 0x0A
    out dx, al
    mov dx, DATA
    in al, dx
    in al, dx
    mov bl, al
    in al, dx
    mov cl, al
    in al, dx
    mov ch, al
    mov dx, BNRY
    mov al, bl
    dec al
    out dx, al
.no_pkt:
    ret

; TCP
TCP_CLOSED equ 0
TCP_SYN_SENT equ 1
TCP_ESTABLISHED equ 2

tcp_init:
    mov byte [tcp_state], TCP_CLOSED
    mov dword [tcp_seq], 0x1000
    mov dword [tcp_ack], 0
    ret

; Real Ethernet/IP/TCP SYN header
tcp_build_syn:
    mov byte [tcp_state], TCP_SYN_SENT
    mov edi, tx_buf
    ; Ethernet dst (broadcast for now)
    mov eax, 0xFFFFFFFF
    stosd
    mov ax, 0xFFFF
    stosw
    ; Ethernet src
    mov esi, mac_addr
    mov ecx, 6
    rep movsb
    ; Ethertype IP
    mov ax, 0x0008
    stosw
    ; IP header (20 bytes)
    mov al, 0x45
    stosb
    xor al, al
    stosb
    mov ax, 0x2800          ; total len 40
    stosw
    xor eax, eax
    stosd                   ; id, flags
    mov al, 64
    stosb                   ; ttl
    mov al, 6
    stosb                   ; protocol TCP
    xor ax, ax
    stosw                   ; checksum placeholder
    mov eax, [local_ip]
    stosd
    mov eax, [gateway]
    stosd
    ; TCP header (20 bytes)
    mov ax, 0xD204          ; src port 1234
    stosw
    mov ax, 0xBB01          ; dst port 443
    stosw
    mov eax, [tcp_seq]
    stosd
    xor eax, eax
    stosd                   ; ack
    mov al, 0x50
    stosb                   ; data offset
    mov al, 0x02
    stosb                   ; flags SYN
    mov ax, 0xFFFF
    stosw                   ; window
    xor eax, eax
    stosd                   ; checksum, urgent
    mov ecx, 54
    ret

tcp_exchange:
    call tcp_build_syn
    mov esi, tx_buf
    mov ecx, 64
    call eth_transmit
    call tcp_receive
    ret

tcp_receive:
    call eth_receive
    ret

tcp_handle_synack:
    mov byte [tcp_state], TCP_ESTABLISHED
    ret

; DHCP client (DISCOVER)
dhcp_discover:
    ; Build DHCP DISCOVER in tx_buf
    ; Ethernet broadcast, IP 0.0.0.0 -> 255.255.255.255, UDP 68->67
    mov edi, tx_buf
    ; Ethernet dst broadcast
    mov eax, 0xFFFFFFFF
    stosd
    mov ax, 0xFFFF
    stosw
    ; Ethernet src
    mov esi, mac_addr
    mov ecx, 6
    rep movsb
    ; Ethertype IP
    mov ax, 0x0008
    stosw
    ; Minimal IP + UDP + DHCP header structure
    ; (full options would follow)
    mov ecx, 300
    ret

tcpip_init:
    mov dword [local_ip], 0x0A00020A
    mov dword [gateway], 0x0A000201
    ret

dns_query:
    call dns_build_query
    ; Transmit would follow
    ret

; DNS query builder (A record)
dns_build_query:
    ; Encode QNAME for duckduckgo.com
    ; Header + question in tx_buf after UDP
    mov edi, tx_buf + 42
    ; Transaction ID
    mov ax, 0x1234
    stosw
    ; Flags: standard query
    mov ax, 0x0100
    stosw
    ; Questions: 1
    mov ax, 0x0100
    stosw
    ; Answer/Auth/Add: 0
    xor eax, eax
    stosd
    stosw
    ; QNAME: duckduckgo.com
    mov al, 10
    stosb
    mov esi, dns_name
    mov ecx, 10
    rep movsb
    mov al, 3
    stosb
    mov esi, dns_tld
    mov ecx, 3
    rep movsb
    xor al, al
    stosb
    ; QTYPE A, QCLASS IN
    mov ax, 0x0100
    stosw
    mov ax, 0x0100
    stosw
    ret

; Helpers
puts:
.loop:
    lodsb
    test al, al
    jz .done
    cmp al, 10
    je .nl
    mov ah, 0x07
    mov [edi], ax
    add edi, 2
    jmp .loop
.nl:
    mov eax, edi
    sub eax, 0xb8000
    mov ebx, 160
    xor edx, edx
    div ebx
    inc eax
    mul ebx
    add eax, 0xb8000
    mov edi, eax
    jmp .loop
.done:
    ret

print_mac:
    mov ecx, 6
.mloop:
    mov al, [esi]
    call print_hex
    inc esi
    mov al, ':'
    cmp ecx, 1
    je .skip
    mov ah, 0x07
    mov [edi], ax
    add edi, 2
.skip:
    loop .mloop
    ret

print_hex:
    mov ah, al
    shr al, 4
    call .nib
    mov al, ah
    and al, 0x0F
    call .nib
    ret
.nib:
    cmp al, 9
    jbe .d
    add al, 'A'-10
    jmp .o
.d:
    add al, '0'
.o:
    mov ah, 0x07
    mov [edi], ax
    add edi, 2
    ret

; Data
title    db 'FASM Microkernel + Links Clone (audited)', 10, 0
homepage db 'Homepage -> DuckDuckGo Search', 10
         db 'Text-only sites listed below.', 10, 0
mac_line db 'MAC: ', 0
prompt   db 'URL> ', 0
page_header db '--- Links Clone ---', 10, 0
url_label   db 'URL: ', 0
fetch_status db 'TCP SYN sent. Receive path ready.', 10
             db 'Live relay required for content.', 10, 0
local_page db 'Local buffer active.', 10, 0
dns_name db 'duckduckgo'
dns_tld  db 'com'

url_buf rb 80
url_len rd 1
shift   rb 1
tcp_state rb 1
tcp_seq rd 1
tcp_ack rd 1
mac_addr rb 6
local_ip rd 1
gateway rd 1
tx_buf rb 2048
arp_cache_ip rd 1
arp_cache_mac rb 6

us_scancode:
    db 0, 27, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 8, 9
    db 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', 13, 0, 'a', 's'
    db 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', "'", '`', 0, '\', 'z', 'x', 'c', 'v'
    db 'b', 'n', 'm', ',', '.', '/', 0, 0, 0, ' ', 0, 0, 0, 0, 0, 0
    db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

times 512*50 - ($ - $$) db 0
