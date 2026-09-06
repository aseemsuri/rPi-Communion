"""
RELICT — installation lighting
Script CHOP.  Outputs light0_r/g/b/a .. light3_r/g/b/a, 0-255.

  BREATH   slow sine per fixture, phase-offset so the room rotates
  FLICKER  proximity destabilises the nearest fixture; contact stills it
  ALTAR    a plant touched -> room warms, slows, diagonals pair up

IN, from an OSC In CHOP named OSC_OP:
    /prox  <p1..p8>   per-column proximity 0-100   -> prox1..prox8
    /gates <g1..g8>   per-column contact 0/1       -> gates1..gates8
    /altar <0|1>      any plant touched            -> altar

State lives in module globals, NOT scriptOp.store(). Writing storage on the
op you are currently cooking is a change to that op during its own cook, and
TD reports it as   relict_lights (/project1/relict_lights).
Same reason this never calls scriptOp.chans().

Tune by editing the numbers below — the DAT reloads on save.
"""

import math
import random

OSC_OP = 'oscin1'

BASE_RGB   = (255, 60, 0)            # sodium orange
ALTAR_RGB  = (255, 120, 15)           # where it warms to
AMBER      = 0                        # 4th channel on RGBA fixtures

LEVEL      = 0.55                     # overall trim
BREATH_HZ  = 0.07                     # ~14s cycle
BREATH_AMP = 0.40
PHASE      = (0.0, 0.25, 0.5, 0.75)   # normal: four-way rotation
ALTAR_PHASE= (0.0, 0.5,  0.0, 0.5)    # altar:  diagonals paired, pairs opposed
ALTAR_HZ   = 0.035                    # breath slows to about half
ALTAR_UP   = 2.0                      # s to warm
ALTAR_DOWN = 5.0                      # s to cool

FLICK_ON   = 2.0                      # proximity where flicker starts
FLICK_FULL = 30.0                     # ... and where it is maximal
SETTLE_TAU = 0.25                     # s for a touched fixture to go still

# ─── flicker styles ───────────────────────────────────────────────────────
# rate  jumps/sec at full proximity      depth  >1 = nearly every jump full swing
# tau   s for a jump to settle           a / b  the two colours it wanders between
STYLES = {
    'arc':     dict(rate=30, tau=0.07, depth=3.0, a=(255, 85, 20), b=(235,150, 45)),
    'stutter': dict(rate=12, tau=0.02, depth=3.0, a=(255, 60,  0), b=(255,190,110)),
    'wander':  dict(rate=3,  tau=0.90, depth=1.0, a=(255,105, 30), b=(240,160, 70)),
    'cold':    dict(rate=20, tau=0.05, depth=2.0, a=(200,150, 60), b=(150,180,120)),
}
STYLE = 'arc'      # any key above, or 'mixed' — a random one per outbreak

# ─── how many may flicker at once ─────────────────────────────────────────
# Four fixtures all agitating reads as noise. Cap it, and when more want to
# flicker than are allowed, rotate the privilege instead of picking favourites.
FLICK_MAX   = 2
ROTATE_MODE = 'circle'   # circle: window slides by one    alt:  groups swap
                         # random: new subset each turn    strongest: no rotation
ROTATE_S    = 1.5        # seconds a fixture holds its turn

COL_TO_LIGHT = [0, 1, 2, 3, 2, 0, 1, 3]   # column 1-8 -> fixture 0-3

# ─── module state ─────────────────────────────────────────────────────────
_t     = None
_phase = 0.0
_flick = [0.0] * 4
_warm  = 0.0
_grant = []            # fixtures currently allowed to flicker
_rot_t = 0.0           # when the turn last changed
_ptr   = 0             # rotation pointer
_fstyle= ['arc'] * 4   # style in force per fixture


def onCook(scriptOp):
    global _t, _phase, _flick, _warm, _grant, _rot_t, _ptr, _fstyle

    now = absTime.seconds
    dt  = 1.0 / 60.0 if _t is None else now - _t
    if dt <= 0 or dt > 0.5:
        dt = 1.0 / 60.0
    _t = now

    def slew(cur, tgt, tau):
        return tgt if tau <= 0 else cur + (tgt - cur) * (1.0 - math.exp(-dt / tau))

    def lerp(a, b, t):
        return a + (b - a) * t

    src = op(OSC_OP)

    def ch_in(name):
        try:
            return float(src[name])
        except Exception:
            return 0.0

    # per-fixture activation, and whether anything on it is being touched
    lit  = [0.0] * 4
    held = [False] * 4
    if src is not None:
        span = max(1.0, FLICK_FULL - FLICK_ON)
        for c, f in enumerate(COL_TO_LIGHT):
            a = (ch_in(f'prox{c+1}') - FLICK_ON) / span
            lit[f] = max(lit[f], max(0.0, min(1.0, a)))
            if ch_in(f'gates{c+1}') >= 0.5:
                held[f] = True

    # altar: one value drives colour, rate and phase together
    _warm = slew(_warm, 1.0 if ch_in('altar') >= 0.5 else 0.0,
                 ALTAR_UP if ch_in('altar') >= 0.5 else ALTAR_DOWN)
    base = tuple(lerp(BASE_RGB[c], ALTAR_RGB[c], _warm) for c in range(3))
    _phase = (_phase + lerp(BREATH_HZ, ALTAR_HZ, _warm) * dt) % 1.0

    # who WANTS to flicker — a hand on the column disqualifies it
    want = [i for i in range(4) if lit[i] > 0.0 and not held[i]]

    if len(want) <= FLICK_MAX:
        _grant = want                       # everyone who wants it gets it
    elif now - _rot_t >= ROTATE_S or not [g for g in _grant if g in want]:
        _rot_t = now                        # demand exceeds the cap — take turns
        if ROTATE_MODE == 'random':
            _grant = random.sample(want, FLICK_MAX)
        elif ROTATE_MODE == 'strongest':
            _grant = sorted(want, key=lambda i: -lit[i])[:FLICK_MAX]
        else:
            step  = FLICK_MAX if ROTATE_MODE == 'alt' else 1
            _ptr  = (_ptr + step) % len(want)
            _grant = [want[(_ptr + k) % len(want)] for k in range(FLICK_MAX)]
        for i in _grant:                    # a new turn picks a fresh character
            _fstyle[i] = random.choice(list(STYLES)) if STYLE == 'mixed' else STYLE

    # irregular by design — a chance per frame, not an LFO.
    # A hand on the column starts no new jumps and settles the current one.
    for i in range(4):
        st = STYLES.get(_fstyle[i], STYLES['arc'])
        if held[i]:
            _flick[i] = slew(_flick[i], 0.0, SETTLE_TAU)
            continue
        if i in _grant and random.random() < lit[i] * st['rate'] * dt:
            _flick[i] = random.uniform(-1.0, 1.0) * st['depth']
        _flick[i] = slew(_flick[i], 0.0, st['tau'])

    # keep what appendChan returns; never read scriptOp.chans()
    scriptOp.clear()
    out = [scriptOp.appendChan(f'light{i}_{c}') for i in range(4) for c in 'rgba']

    for i in range(4):
        off    = lerp(PHASE[i], ALTAR_PHASE[i], _warm)
        b      = math.sin((_phase + off) * 2.0 * math.pi) * 0.5 + 0.5
        level  = max(0.0, LEVEL * (1.0 + (b - 0.5) * 2.0 * BREATH_AMP))

        f   = _flick[i]
        st  = STYLES.get(_fstyle[i], STYLES['arc'])
        col = base if f == 0.0 else tuple(
            lerp(base[c], (st['a'] if f < 0 else st['b'])[c], min(1.0, abs(f)))
            for c in range(3))

        for k, v in enumerate((col[0], col[1], col[2], AMBER)):
            out[i * 4 + k][0] = max(0.0, min(255.0, v * level))
