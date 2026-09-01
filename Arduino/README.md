# Arduino bridges

The AA-30.ZERO speaks 3.3 V UART at 38400 baud and has no USB of its own, so something
has to carry its bytes to the Mac. Whatever does — an Arduino, a plain USB-UART adapter,
or a network bridge — the Mac side is unchanged: a `/dev/cu.*` port that `SerialChannel`
opens at 38400.

## AntScopeBridge

For the UNO R4 WiFi or Minima. Uses the free hardware UART and buffers both directions.
See the comments at the top of the sketch for wiring.

RigExpert's own `AA-30_ZERO_serial_repeater` also works on a plain UNO R3 and needs no
wires, at the cost of bit-banging the UART. It is the right thing to try first if that is
the hardware you have.
