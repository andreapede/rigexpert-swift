// AntScope bridge — Arduino UNO R4 WiFi / Minima
//
// Pipes bytes between the Mac (USB-C, native CDC) and a RigExpert AA-30.ZERO.
//
// Improves on RigExpert's AA-30_ZERO_serial_repeater in three ways:
//   * uses the free hardware UART (Serial1) instead of bit-banged SoftwareSerial
//   * buffers both directions, so a stall on one side cannot drop bytes on the other
//   * the USB side is native CDC, so it never throttles the analyzer at 38400
//
// WIRING
//
//   HARDWARE_UART (default, recommended)
//     Do not rely on the stacked pins for data. Run two wires:
//       shield pin 4 (analyzer Tx2)  ->  board D0 / RX1
//       shield pin 7 (analyzer Rx2)  ->  board D1 / TX1
//     Leave D4 and D7 unconfigured on the board so nothing contends for them.
//     GND and 5V come through the stack, or wire them too if not stacking.
//
//   SOFTWARE_UART (no wires, plain stacked shield)
//     Set USE_HARDWARE_UART to 0. Bit-bangs on D4/D7 like the original sketch, but
//     on a 48 MHz core rather than a 16 MHz one.
//
// NOTE ON LOGIC LEVELS
//   The UNO R4 keeps 5 V I/O for shield compatibility; the AA-30.ZERO is a 3.3 V
//   board (STM32F070 + LM1117-3.3). It works because the STM32 pins are 5 V tolerant
//   and the shield has series resistors, but it is out of spec. If you are wiring
//   anyway, a level shifter on the board's TX line costs a euro and removes the doubt.

// 2 = ONE wire, shield D4 -> board D0. Reception on hardware Serial1, transmission on
//     SoftwareSerial D7 — which does work, since only the core's RX side is broken.
//     The least wiring that can work on an R4 with UART2 strapped.
// 1 = two wires, shield D4 -> D0 and shield D7 -> D1. Hardware UART both ways.
// 0 = plain stacked shield, no wires. Works on an UNO R3, not on an R4.
//
// WHY NOT ON AN R4: the Renesas core only supports SoftwareSerial RX on a few pins —
// 6, 11 and 12 on the WiFi, 12 and 13 on the Minima — and the list in the library's own
// example comments is wrong (ArduinoCore-renesas issue #291). D4, where the analyzer's
// Tx2 lands, is not one of them. Transmission works, reception silently receives
// nothing, and the symptom is indistinguishable from a dead analyzer: the ZERO's Rx and
// Tx LEDs both blink while the bridge reports zero bytes.
//
// WHY D0/D1 ARE THE SAFE PINS TO WIRE TO: the schematic's 0-ohm links for the analyzer's
// UART1 (R55/R56) are not fitted, so the shield drives neither D0 nor D1 — they are
// floating on its side. The pins that would work for SoftwareSerial RX (6, 11, 12) carry
// the shield's GPIO lines, and tying an analyzer output to a board output could damage
// both.
// Defaults to whatever the board can actually do; override before compiling to force it.
#ifndef USE_HARDWARE_UART
  #if defined(__AVR_ATmega328P__)
    #define USE_HARDWARE_UART 0   // AVR receives on any pin: stack the shield and go
  #else
    #define USE_HARDWARE_UART 2   // everything else needs the wire to D0
  #endif
#endif

static const unsigned long ANALYZER_BAUD = 38400;

#if USE_HARDWARE_UART == 1
  #define ZERO_IN  Serial1
  #define ZERO_OUT Serial1
#elif USE_HARDWARE_UART == 2
  #include <SoftwareSerial.h>
  // RX pin 12 is never connected: the core only accepts 6, 11 or 12 as an RX pin and
  // this instance is used for transmission only.
  SoftwareSerial softOut(12, 7);
  #define ZERO_IN  Serial1
  #define ZERO_OUT softOut
#else
  #include <SoftwareSerial.h>
  SoftwareSerial softPort(4, 7);   // RX, TX
  #define ZERO_IN  softPort
  #define ZERO_OUT softPort
#endif

// A 500-point sweep is roughly 12 KB of text arriving over about three seconds. These
// buffers only have to cover a momentary stall, not the whole sweep: the Mac side runs
// at 115200 and drains three times faster than the analyzer's 38400 fills.
//
// An ATmega328P has 2 KB of RAM in total, so a pair of kilobyte buffers does not fit —
// 256 bytes each leaves room for the SoftwareSerial and HardwareSerial buffers too.
#if defined(__AVR__)
static const size_t BUFFER_SIZE = 256;
#else
static const size_t BUFFER_SIZE = 1024;
#endif

struct Ring {
  uint8_t data[BUFFER_SIZE];
  size_t head = 0;
  size_t tail = 0;

  bool empty() const { return head == tail; }
  bool full() const { return (head + 1) % BUFFER_SIZE == tail; }

  bool push(uint8_t byte) {
    if (full()) return false;
    data[head] = byte;
    head = (head + 1) % BUFFER_SIZE;
    return true;
  }

  int pop() {
    if (empty()) return -1;
    uint8_t byte = data[tail];
    tail = (tail + 1) % BUFFER_SIZE;
    return byte;
  }
};

static Ring toMac;      // analyzer -> Mac
static Ring toAnalyzer; // Mac -> analyzer

// Counts bytes lost to a full buffer. Never expected to move; if it does, the link
// is the bottleneck and not the analyzer.
static uint32_t overflows = 0;

void setup() {
  // On the R4 WiFi the USB-C port is bridged by the ESP32-S3 rather than being native
  // CDC, so this baud rate is real and the host must match it. Open the Mac side at
  // 115200, not at the analyzer's 38400.
  Serial.begin(115200);
  ZERO_IN.begin(ANALYZER_BAUD);
#if USE_HARDWARE_UART == 2
  ZERO_OUT.begin(ANALYZER_BAUD);
#endif
  pinMode(LED_BUILTIN, OUTPUT);
}

void loop() {
  bool active = false;

  // Drain both sources first, so neither can be starved by a slow sink.
  while (ZERO_IN.available()) {
    if (!toMac.push((uint8_t)ZERO_IN.read())) overflows++;
    active = true;
  }
  while (Serial.available()) {
    if (!toAnalyzer.push((uint8_t)Serial.read())) overflows++;
    active = true;
  }

  // Then forward a bounded batch to each sink.
  //
  // Do NOT gate this on availableForWrite(): Print declares it with a default of 0 and
  // SoftwareSerial never overrides it, so gating on it silently forwards nothing at all.
  // Bounding the batch instead keeps one direction from starving the other while
  // guaranteeing forward progress every iteration.
  for (int i = 0; i < 64 && !toMac.empty(); i++) {
    Serial.write((uint8_t)toMac.pop());
  }
  for (int i = 0; i < 16 && !toAnalyzer.empty(); i++) {
    ZERO_OUT.write((uint8_t)toAnalyzer.pop());
  }

  digitalWrite(LED_BUILTIN, active ? HIGH : LOW);
}
