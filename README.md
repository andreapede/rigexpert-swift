# rigexpert-swift

A native macOS application and Swift package for RigExpert antenna analyzers.

Not a port of AntScope2. No source is shared with it — the AA serial protocol, the
analyzer capability table and the OSL calibration algebra were read out of its
MIT-licensed source and reimplemented. The result is 5,000 lines of Swift against
72,000 of Qt C++, and an app bundle of **950 KB** against the official build's 85 MB.

Everything below was measured with a real AA-30.ZERO against physical references.

## What it does

- Connects over a serial port and sweeps
- Plots SWR, resistance and reactance, and a hand-drawn Smith chart, with a hover cursor
- Applies an open/short/load calibration captured from the command line
- Measures a coaxial cable's length, velocity factor and loss from the sweep alone
- Detects when the reactance crossings belong to the feedline rather than the antenna,
  and measures the feedline instead of misreporting it as a resonance
- Counts the samples the analyzer failed to measure, rather than hiding them
- Exports Touchstone `.s1p`

## Does it work

Verified against known references, not asserted:

| measurement | reference | result |
|---|---|---|
| 50 Ω load, uncalibrated | 50 Ω | R 47.4–48.2 Ω, SWR 1.04–1.06 |
| 50 Ω load, calibrated | 50 Ω | R 49.2–50.0 Ω, SWR 1.00–1.02 |
| RG-58 length, 2.97 m by tape | 2.970 m | **2.962 m** (velocity factor 0.662 vs 0.66 nominal) |
| RG-174 velocity factor | 0.66 solid PE | 0.66, allowing 2 cm for connectors |
| RG-174 loss, 1–30 MHz | ≈0.1 dB/m datasheet | 0.126 dB/m |
| Feedline length, 1.66 m of cable | 1.66 m + connectors | 1.747 m (8.7 cm over three connector interfaces) |
| Dipole resonance, 2.04 m tip to tip | 143/L = 70.1 MHz | **70.33 MHz**, 0.33% |

System repeatability, from two sweeps taken without touching anything: **±120 kHz** on a
67 MHz resonance, about **1%** on |Γ|.

## Getting started

    ./make_app.sh                       # builds build/AntScope.app
    ./test.sh                           # 88 tests

The command line client needs no UI and is the quickest way to check a connection:

    swift build
    .build/debug/antscope-probe demo                    # against a simulated analyzer
    .build/debug/antscope-probe ports
    .build/debug/antscope-probe identify /dev/cu.usbserial-3130 --baud 115200
    .build/debug/antscope-probe sweep /dev/cu.usbserial-3130 1 30 200 --out antenna.s1p
    .build/debug/antscope-probe calibrate /dev/cu.usbserial-3130 0.1 30 501 --out cal.json
    .build/debug/antscope-probe cable Examples/rg174-1.01m-shorted.s1p --length 1.01

`make_app.sh` builds the bundle around the executable SwiftPM produces; there is no
`.xcodeproj`. Xcode still opens `Package.swift` directly. When `xcode-select` points at
the Command Line Tools the script borrows Xcode's toolchain through `DEVELOPER_DIR`, so
it needs no `sudo`.

## Structure

| module | contents |
|---|---|
| `AntScopeCore` | `Frequency`, `Impedance`, `Reflection`, `Sweep`, `DeviceProfile`, `Calibration`, cable and sweep analysis |
| `AntScopeIO` | Touchstone `.s1p` |
| `AntScopeTransport` | the AA protocol, `AnalyzerSession`, `SerialChannel`, and a simulated analyzer |
| `AntScopeApp` | the SwiftUI app |
| `antscope-probe` | command line client |

`Reflection` is the hub: SWR, return loss, ρ, phase and the Smith coordinate are all
functions of Γ, so they derive from one type rather than being recomputed in six places.

Frequencies are a type, never a bare `Double`. The original passes numbers whose unit
depends on the layer — megahertz on the wire, kilohertz in the device table, whatever the
header says in a Touchstone file — and that is a whole class of bug that simply cannot
occur here.

`ByteChannel` is a protocol, which is why the entire session can be tested with no
hardware attached: `SimulatedAnalyzerChannel` answers the real command vocabulary from
memory, in chunks that deliberately fall in the middle of lines. A network bridge would be
another implementation and nothing above it would change.

## Hardware

The AA-30.ZERO has no USB of its own: it needs 5 V, ground and a 3.3 V UART at 38400 baud.
`Arduino/AntScopeBridge` carries those bytes to the Mac. See its header comment for wiring.

One trap is worth repeating here. **On an Arduino UNO R4 this does not work with the shield
simply stacked.** The Renesas core supports SoftwareSerial reception only on pins 6, 11 and
12, and the analyzer's output lands on D4. Transmission works, reception silently receives
nothing, and the symptom is indistinguishable from a dead analyzer — the ZERO's Rx and Tx
LEDs both blink while the bridge reads zero bytes. An UNO R3 has pin-change interrupts on
every pin and works unmodified. On an R4, run two wires to D0/D1 and use the hardware UART.

Also: on the UNO R4 WiFi the USB-C port is bridged by the ESP32-S3 rather than being native
CDC, so the baud rate on the Mac side is real and must match the sketch.

## Known limitations

- The user interface is in Italian; the code and its comments are in English
- The app loads a calibration but cannot capture one — that flow is on the command line
- The Smith chart shows the cursor but cannot set it; use the SWR or R/X view
- No TDR yet
- The app's views have no tests. Everything below them does

## Author

Andrea Pede, **IZ0TWS**.

## Provenance

The RigExpert AA protocol, the analyzer capability table and the OSL correction were
derived by reading [AntScope2](https://github.com/rigexpert/AntScope2), which is
MIT-licensed; its copyright notice is retained in `LICENSE`. The three `.s1p` fixtures
under `Tests/AntScopeIOTests/Fixtures` are that project's own files, used here only to
exercise the parser — they are not usable calibration standards, all three read close to
an open.

Reading that source also turned up bugs worth knowing about if you use the original:
parallel reactance is wrong on the calibration-corrected path, the Touchstone parser
rejects the specification's own lowercase `kHz`, and an unguarded Windows registry write
leaves a stray file inside the macOS app bundle.
