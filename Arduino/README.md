# Arduino bridge

The AA-30.ZERO has no USB of its own: it needs 5 V, ground and a 3.3 V UART at 38400 baud.
`RigXBridge` carries those bytes to the Mac, which then sees an ordinary serial port.

## Use

Stack the shield on an **Arduino UNO R3**, upload the sketch, connect the board.

    arduino-cli compile --fqbn arduino:avr:uno -u -p /dev/cu.usbserial-XXXX Arduino/RigXBridge

The Mac side runs at **115200** — the bridge converts to the analyzer's 38400, which is
why `rigx-probe` needs `--baud 115200` behind it.

## Compatibility

Tested on an UNO R3 (ATmega328P). Other boards need their own wiring and are not covered
here: the analyzer's UART lands on D4 and D7, and whether a given board can receive on
those pins depends on its core.

RigExpert's own `AA-30_ZERO_serial_repeater` also works on an UNO R3 and is a good
fallback; this sketch adds buffering and a faster host link.
