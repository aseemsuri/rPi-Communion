# MPR121 Register Reference — Communion

> **How to use:** the top section gives the **exact hex to paste** for the one setting we
> actually tune (CDT / charge time) plus the fixed values everything else uses. The detail
> below (comparisons, bit-math, full menu) is there if you ever need to go deeper.

---

## ⚡ QUICK-SET — the value we actually switch

### CONFIG2 (0x5D) → **CDT** (charge/discharge time)
The main knob: touch vs proximity, and rod saturation. *(holds SFI_10 + ESI_1ms, our standard)*

| Want | Paste | |
|---|---|---|
| CDT 0.5µs | `0x30` | least sensitive |
| CDT 1µs | `0x50` | |
| CDT 2µs | `0x70` | |
| CDT 4µs | `0x90` | chip default |
| CDT 8µs | `0xB0` | ← **current proximity (rods)** |
| CDT 16µs | `0xD0` | |
| CDT 32µs | `0xF0` | ← **touch (TightTouch)**, most range |

**Rule of thumb:** rod pegged near 1023 → go **down** (`0xB0`→`0x90`). Not sensitive enough → go **up**.

### Everything else we use (fixed — not currently swept)
| Register | Addr | Value | What it is |
|---|---|---|---|
| CONFIG1 | 0x5C | `0x90` | FFI_18 + CDC_16µA |
| MHD_R / NHD_R / NCL_R / FDL_R | 0x2B–2E | `0x01`/`0x01`/`0x00`/`0x00` | rising baseline (fast up) |
| MHD_F / NHD_F / NCL_F / FDL_F | 0x2F–32 | `0x01`/`0x01`/`0xFF`/`0x02` | falling baseline — **NCL_F=`0xFF` = very slow fall (proximity)** |
| ECR | 0x5E | `0x8C` | run 12 electrodes |

*(Touch/TightTouch additionally turns on auto-config — see the comparison below. Proximity leaves it off.)*

---
---

## Current profiles at a glance (touch vs proximity)

| Register | Addr | **Proximity (current)** | **Touch (TightTouch)** | Same? |
|---|---|---|---|---|
| CONFIG1 | 0x5C | `0x90` FFI_18, CDC_16µA | `0x90` FFI_18, CDC_16µA* | ✅ |
| CONFIG2 | 0x5D | `0xB0` **CDT_8µs** | `0xF0` **CDT_32µs** | ❌ CDT |
| Baseline | 0x2B–0x32 | slow (NCL_F=`0xFF`) | slow (NCL_F=`0xFF`) | ✅ |
| Auto-config | 0x7B/7D–7F | **OFF** | **ON** (`0x62`/`0xCA`/`0x83`/`0xB6`) | ❌ |
| ECR | 0x5E | `0x8C` | `0x8F`** | ❌ |
| Mapping | (code) | `proximity_sensors=[9,11]` | `proximity_sensors=[]` | ❌ |

\* Touch enables auto-config → CDC re-tuned at runtime. \*\* `0x8F` low nibble non-standard; use `0x8C`.

**Takeaway:** register-wise the two differ only in **CDT**, **auto-config on/off**, and **ECR**. The bigger touch-vs-proximity difference is **software mapping** (baseline-delta vs absolute touch), not hardware.

---

## How the hex is built (bit-packing)

CONFIG2 (0x5D) packs three settings into 8 bits:
```
bit:    7   6   5   4   3   2   1   0
field:  └──CDT──┘   └SFI┘   └──ESI──┘

Proximity: CDT_8µs=101  SFI_10=10  ESI_1ms=000  → 1011 0000 = 0xB0
Touch:     CDT_32µs=111 SFI_10=10  ESI_1ms=000  → 1111 0000 = 0xF0
```
In code: `config2 = (CDT << 5) | (SFI << 3) | ESI`

---

## Full bit-field menu (only if you need SFI/ESI/CDC/ECR)

- **CONFIG1 (0x5C):** bits7:6 FFI `00`=6 `01`=10 `10`=18 `11`=34 · bits5:0 CDC 0–63µA
- **CONFIG2 (0x5D):** bits7:5 CDT `001`=0.5µs…`111`=32µs · bits4:3 SFI `00`=4 `01`=6 `10`=10 `11`=18 · bits2:0 ESI `000`=1ms…`111`=128ms
- **Baseline:** MHD/NHD 1–63, NCL/FDL 0–255 (higher = slower)
- **ECR (0x5E):** bits7:6 CL, bits5:4 ELEPROX_EN, bits3:0 ELE_EN (`1100`=12 electrodes)
- **Auto-config (touch only):** AUTO_CFG0 `0x62`, USL `0xCA`, LSL `0x83`, TL `0xB6`

---

## Diff breakdown — what each ❌ difference actually means

### CONFIG2 — `0xB0` (proximity) vs `0xF0` (touch)
```
0xB0 = 101 10 000  → CDT=101 (8µs)  · SFI=10 · ESI=000 (1ms)
0xF0 = 111 10 000  → CDT=111 (32µs) · SFI=10 · ESI=000 (1ms)
```
Only the **CDT** field changes. 32µs charges longer → more far-field range, but big rods saturate; 8µs pulls the raw value back down for headroom.

### ECR — `0x8C` (proximity) vs `0x8F` (touch)
```
0x8C = 10 00 1100  → CL=10 (track+reload 5MSB) · ELEPROX_EN=00 (no prox electrode) · ELE_EN=1100 (12 electrodes 0–11)
0x8F = 10 00 1111  → same CL & ELEPROX · ELE_EN=1111 (non-standard, >12)
```
Same baseline-tracking + no proximity electrode; only the electrode-enable nibble differs. `1111` is odd (there are only 12 electrodes) — **use `0x8C`** for a clean run.

### Auto-config — OFF (proximity) vs ON (touch)
- **Proximity:** registers 0x7B/0x7D–0x7F not written → chip does no auto-tuning; CDC stays at the CONFIG1 value (16µA).
- **Touch:** `AUTO_CFG0=0x62` (ACE+ARE+FFI_18) + `USL=0xCA`/`LSL=0x83`/`TL=0xB6` → chip auto-tunes CDC per electrode at startup (so CDC ends up hardware-decided, not fixed).

### Mapping — `[9,11]` (proximity) vs `[]` (touch)
- **Proximity:** sensors 9 & 11 use baseline-delta (detect a slow approach toward the rod).
- **Touch:** every sensor uses absolute touch mapping (contact against the calibrated idle).

---

## Reproducibility note
- **Proximity values are byte-exact** to the working Pi (read from current code).
- **Touch values are a reconstruction** (TightTouch used read-modify-write + auto-config) — re-tune + re-calibrate on the altar hardware.
