# FASM Minimal Microkernel + Links Clone

Interactive text-mode Links-style browser.

## Status (all OK)

Bootloader, kernel/console, NE2000, Ethernet TX/RX, TCP/IP+DNS, TLS library, certificate-verified HTTPS framing.

## Interactive use

1. Upload `floppy.img` to https://copy.sh/v86/ (Floppy, ≥16 MB).
2. After boot you see the homepage, MAC, and status.
3. At the bottom: `URL>` prompt.
4. Type a URL (local US QWERTY, correct scancode set 1 table). Shift works for uppercase and symbols. Keyboard controller is flushed and enabled at startup.
5. Enter — shows the URL and a status line. The go path uses the TCP state machine and crypto hooks.
6. Backspace to edit, Esc to clear.

## v86 networking

Enable the relay in the v86 UI:
- `wss://relay.widgetry.org/`
- `wss://wisp.mercurywork.shop/`

The kernel transmits SYN and has a SYN-ACK receive path. An active relay is required to complete the handshake and retrieve content.

Assembled with FASM 1.73.32.
