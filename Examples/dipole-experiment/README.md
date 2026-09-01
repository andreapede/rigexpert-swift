# A telescopic dipole, measured six times

Six sweeps of the same 2.04 m telescopic V-dipole, taken in this order on 1 September
2026 with an AA-30.ZERO over 1–170 MHz, 501 points, uncalibrated (the calibration on hand
covered 0.1–30 MHz, and holding a correction beyond its range adds nothing). The feedline
is RG-174.

They are here because the repeatability figure quoted in the top-level README comes from
them, and a number like that should be checkable.

| file | what changed | lowest SWR |
|---|---|---|
| `1-feedline-1.66m` | the starting point | 67.517 MHz |
| `2-feedline-1.66m-repeat` | nothing at all | 67.399 MHz |
| `3-feedline-0.65m` | the long feedline swapped for a short one | 66.631 MHz |
| `4-feedline-1.66m-restored` | the long feedline put back | 66.694 MHz |
| `5-arms-realigned` | arms re-extended and straightened | 66.727 MHz |
| `6-moved-clear-of-obstacles` | the whole antenna moved across the room | 70.333 MHz |

## What they show

**Repeatability.** Files 1 and 2 differ by 119 kHz with nothing touched between them, and
by about 1% in |Γ| across the band. That is the noise floor of the whole chain, and it is
the error bar on every other number here.

**The feedline is not the antenna.** Files 3 and 4 bracket a feedline swap. The resonance
moved by 890 kHz when the cable was changed — but did not move back when it was restored,
which rules the cable out: the shift happened when the antenna was handled, and stayed.
File 5 confirms it, since realigning the arms did not undo it either. The common-mode
choke is doing its job.

**The room dominates.** File 6 moved the antenna away from the bench and the resonance
rose 3.6 MHz, thirty times the repeatability. A dipole 2.04 m long resonates at 143/L ≈
70.1 MHz in free space; measured clear of obstacles it reads 70.33. The 67 MHz of files
1–5 was the antenna plus the table, the laptop and the wall.

**A better SWR is not a better antenna.** In the loaded position the match reads 1.07; in
the open one it degrades to 1.74. A dipole in free space presents about 73 Ω, which
against 50 Ω cannot do better than 1.46 — nearby objects pull the resistance down toward
50 Ω, and part of what they add is loss rather than radiation.

Each file also carries six evenly spaced reactance crossings that belong to the feedline
rather than the antenna; `rigx-probe cable` reads the line's length out of their spacing.
