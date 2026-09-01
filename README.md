# rigexpert-swift

**RigXSwift** — a native macOS application and Swift package for RigExpert antenna
analyzers.

> Not affiliated with, endorsed by, or supported by Rig Expert Ukraine Ltd. "RigExpert"
> and "AntScope" are their names, used here only to say which hardware this works with.

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

    ./make_app.sh                       # builds build/RigXSwift.app
    ./test.sh                           # 88 tests

The command line client needs no UI and is the quickest way to check a connection:

    swift build
    .build/debug/rigx-probe demo                    # against a simulated analyzer
    .build/debug/rigx-probe ports
    .build/debug/rigx-probe identify /dev/cu.usbserial-3130 --baud 115200
    .build/debug/rigx-probe sweep /dev/cu.usbserial-3130 1 30 200 --out antenna.s1p
    .build/debug/rigx-probe calibrate /dev/cu.usbserial-3130 0.1 30 501 --out cal.json
    .build/debug/rigx-probe cable Examples/rg174-1.01m-shorted.s1p --length 1.01

`make_app.sh` builds the bundle around the executable SwiftPM produces; there is no
`.xcodeproj`. Xcode still opens `Package.swift` directly. When `xcode-select` points at
the Command Line Tools the script borrows Xcode's toolchain through `DEVELOPER_DIR`, so
it needs no `sudo`.

## Structure

| module | contents |
|---|---|
| `RigXCore` | `Frequency`, `Impedance`, `Reflection`, `Sweep`, `DeviceProfile`, `Calibration`, cable and sweep analysis |
| `RigXIO` | Touchstone `.s1p` |
| `RigXTransport` | the AA protocol, `AnalyzerSession`, `SerialChannel`, and a simulated analyzer |
| `RigXSwiftApp` | the SwiftUI app |
| `rigx-probe` | command line client |

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
`Arduino/RigXBridge` carries those bytes to the Mac. Stack the shield on an Arduino
UNO R3, upload, and the analyzer appears as an ordinary serial port. The Mac side of the
bridge runs at 115200, which is why `--baud 115200` appears in the examples above.

Other Arduino boards are not covered: the analyzer's UART lands on D4 and D7, and whether
a board can receive on those pins depends on its core rather than on its speed.

## Known limitations

- Italian and English only, switchable from the globe in the toolbar
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
under `Tests/RigXIOTests/Fixtures` are that project's own files, used here only to
exercise the parser — they are not usable calibration standards, all three read close to
an open.

Reading that source also turned up bugs worth knowing about if you use the original:
parallel reactance is wrong on the calibration-corrected path, the Touchstone parser
rejects the specification's own lowercase `kHz`, and an unguarded Windows registry write
leaves a stray file inside the macOS app bundle.
