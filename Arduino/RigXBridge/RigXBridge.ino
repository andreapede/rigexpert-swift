// RigX bridge — Arduino UNO R3 (ATmega328P)
//
// Pipes bytes between the Mac and a RigExpert AA-30.ZERO. Stack the shield, upload,
// and the analyzer appears on the Mac as an ordinary serial port.
//
// Improves on RigExpert's own AA-30_ZERO_serial_repeater in two ways: it buffers both
// directions, so a stall on one side cannot drop bytes on the other, and it runs the
// USB side at 115200 rather than 38400, giving three times the headroom the analyzer
// can fill.
//
// WIRING
//   None. The analyzer's UART2 is on D4 (its transmit) and D7 (its receive), which the
//   shield connects when it is stacked. Power and ground come through the stack too.
//
// NOTE ON LOGIC LEVELS
//   The UNO R3 has 5 V I/O; the AA-30.ZERO is a 3.3 V board (STM32F070 + LM1117-3.3).
//   It works because the STM32's pins are 5 V tolerant and the shield has series
//   resistors, but it is out of specification. A 3.3 V host would be the correct match.

#include <SoftwareSerial.h>

static const unsigned long ANALYZER_BAUD = 38400;
static const unsigned long HOST_BAUD = 115200;

SoftwareSerial ZERO(4, 7);   // RX = analyzer Tx2, TX = analyzer Rx2

// A 500-point sweep is roughly 12 KB of text arriving over about three seconds. These
// buffers only have to cover a momentary stall, not the whole sweep: the host side drains
// three times faster than the analyzer fills. An ATmega328P has 2 KB of RAM in total, so
// 256 bytes each leaves room for the SoftwareSerial and HardwareSerial buffers too.
static const size_t BUFFER_SIZE = 256;

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

static Ring toHost;      // analyzer -> Mac
static Ring toAnalyzer;  // Mac -> analyzer

// Counts bytes lost to a full buffer. Never expected to move; if it does, the bridge is
// the bottleneck and not the analyzer.
static uint32_t overflows = 0;

void setup() {
  Serial.begin(HOST_BAUD);
  ZERO.begin(ANALYZER_BAUD);
  pinMode(LED_BUILTIN, OUTPUT);
}

void loop() {
  bool active = false;

  // Drain both sources first, so neither can be starved by a slow sink.
  while (ZERO.available()) {
    if (!toHost.push((uint8_t)ZERO.read())) overflows++;
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
  for (int i = 0; i < 64 && !toHost.empty(); i++) {
    Serial.write((uint8_t)toHost.pop());
  }
  for (int i = 0; i < 16 && !toAnalyzer.empty(); i++) {
    ZERO.write((uint8_t)toAnalyzer.pop());
  }

  digitalWrite(LED_BUILTIN, active ? HIGH : LOW);
}
