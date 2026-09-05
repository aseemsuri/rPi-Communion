"""
RELICT — installation lighting
Script CHOP callbacks.  Outputs light0_r/g/b/a .. light3_r/g/b/a, 0-255.

Four wash fixtures in the room corners, floor-mounted, angled up at the
opposite wall.

Two layers only:

  BREATH   a slow sine per fixture, phase-offset so the room rotates.
           Runs whether anything is connected or not.

  FLICKER  a column going active destabilises the nearest fixture, like a
           sodium lamp with a failing arc. The HUE wanders; the luminance
           does not — that's what a dying lamp actually does, and it avoids
           the photosensitivity risk that brightness flicker carries.

INPUT — from Max, into an OSC In CHOP named by OSC_OP:
        /prox <p1> <p2> ... <p8>      per-column proximity, 0-100
    TD names a multi-argument address by index, so these arrive as
    prox1 .. prox8.
"""

from typing import Any
import math
import random

# ─── COLOUR ───────────────────────────────────────────────────────────────
BASE_RGB   = (255, 120, 15)     # sodium orange. lower green = less yellow
AMBER      = 0                  # 4th channel on RGBA fixtures; 0 = unused

# ─── BREATH ───────────────────────────────────────────────────────────────
BREATH_HZ    = 0.07             # ~14s cycle
BREATH_AMP   = 0.40             # depth
BREATH_PHASE = (0.0, 0.25, 0.5, 0.75)

# ─── FLICKER ──────────────────────────────────────────────────────────────
# The two targets bracket BASE_RGB in luminance (~128 / 148 / 163) so the
# fixture doesn't appear to pulse as it wanders between them.
FLICK_A    = (255,  85,  20)    # hotter, redder
FLICK_B    = (235, 150,  45)    # paler, dirtier
FLICK_RATE  = 30.0              # jumps/sec at full proximity
FLICK_TAU   = 0.12              # s — how fast each jump settles
FLICK_DEPTH = 2.0               # 0..1 how far a jump travels toward a target
FLICK_ON    = 2.0              # proximity below this does nothing
FLICK_FULL  = 80.0              # ... and this counts as full

# Which fixture each column destabilises. Columns 1-8 -> lights 0-3.
# Edit to match the room.
COL_TO_LIGHT = [0, 1, 2, 3, 0, 1, 2, 3]

BASE_LEVEL = 0.55               # overall trim

# Every constant above is also readable from CTRL_OP as a channel, lowercase
# and without the underscore:  flickrate, flicktau, flickdepth, flickon,
# flickfull, breathamp, breathhz, master, enbreath, enflick.
# Anything absent from that CHOP falls back to the value above.

# Op names this script reads. Neither has to exist — missing ops fall back.
OSC_OP  = 'oscin1'   # OSC In CHOP receiving /prox
CTRL_OP = 'ctrl'     # optional Constant CHOP for live tuning


def onSetupParameters(scriptOp: scriptCHOP):
	"""Deliberately empty — writing a par value here dirties the op mid-cook
	and TD raises a dependency error. Tuning comes from CTRL_OP instead."""
	return


def onPulse(par: Any):
	return


def onGetCookLevel(scriptOp: scriptCHOP) -> CookLevel:
	return CookLevel.ALWAYS


def onCook(scriptOp: scriptCHOP):

	# ─── TIME ─────────────────────────────────────────────────
	now  = absTime.seconds
	prev = scriptOp.fetch('last_t', now)
	dt   = now - prev
	if dt <= 0 or dt > 0.5:      # first frame, or a hitch — don't jump
		dt = 1.0 / 60.0
	scriptOp.store('last_t', now)

	# ─── HELPERS ──────────────────────────────────────────────
	def find_source(probe):
		"""Locate the CHOP carrying `probe`. Tries OSC_OP by name, then scans
		sibling CHOPs — so the OSC In CHOP can be called anything."""
		try:
			o = op(OSC_OP)
			if o is not None and o[probe] is not None:
				return o
		except Exception:
			pass
		try:
			for o in scriptOp.parent().findChildren(type=CHOP):
				try:
					if o is not scriptOp and o[probe] is not None:
						return o
				except Exception:
					continue
		except Exception:
			pass
		return None

	def chan(source, names, fallback=0.0):
		"""First channel that exists, tolerating a missing op or channel."""
		if source is None:
			return fallback
		if isinstance(names, str):
			names = [names]
		for nm in names:
			try:
				v = source[nm]
				if v is not None:
					return float(v)
			except Exception:
				continue
		return fallback

	def slew(cur, tgt, tau):
		"""Frame-rate independent approach. tau = seconds to ~63% of the way."""
		if tau <= 0.0:
			return tgt
		return cur + (tgt - cur) * (1.0 - math.exp(-dt / tau))

	def lerp(a, b, t):
		return a + (b - a) * t

	# ─── TUNING (optional Constant CHOP; falls back to constants) ──
	try:
		ctrl = op(CTRL_OP)
	except Exception:
		ctrl = None
	master     = chan(ctrl, 'master',    1.0) * BASE_LEVEL
	breath_amp = chan(ctrl, 'breathamp', BREATH_AMP)
	breath_hz  = chan(ctrl, 'breathhz',  BREATH_HZ)
	flick_rate  = chan(ctrl, 'flickrate',  FLICK_RATE)
	flick_tau   = chan(ctrl, 'flicktau',   FLICK_TAU)
	flick_depth = chan(ctrl, 'flickdepth', FLICK_DEPTH)
	flick_on    = chan(ctrl, 'flickon',    FLICK_ON)
	flick_full  = chan(ctrl, 'flickfull',  FLICK_FULL)
	en_breath  = chan(ctrl, 'enbreath',  1.0) > 0.5
	en_flick   = chan(ctrl, 'enflick',   1.0) > 0.5

	# ─── INPUT: per-column proximity -> per-fixture activation ──
	src = find_source('prox1')

	# Say once, in the textport, what we resolved to — silence here is the
	# usual reason nothing responds.
	found = src.name if src is not None else 'NONE'
	if scriptOp.fetch('src_note', '') != found:
		scriptOp.store('src_note', found)
		if src is None:
			print("RELICT_lights: no CHOP with a 'prox1' channel found. "
			      "Check the OSC In CHOP is receiving /prox from Max.")
		else:
			print("RELICT_lights: reading prox1-8 from '%s' (%d chans: %s)"
			      % (found, len(src.chans()),
			         ', '.join(c.name for c in src.chans()[:12])))

	pcol = [chan(src, [f'prox{i+1}'], 0.0) for i in range(8)]
	lit  = [0.0, 0.0, 0.0, 0.0]
	for ci, li in enumerate(COL_TO_LIGHT):
		if 0 <= li < 4:
			a = (pcol[ci] - flick_on) / max(1.0, (flick_full - flick_on))
			lit[li] = max(lit[li], max(0.0, min(1.0, a)))   # strongest wins

	# ─── STATE ────────────────────────────────────────────────
	phase = scriptOp.fetch('phase', 0.0)
	flick = scriptOp.fetch('flick', [0.0] * 4)   # -1..1 per fixture, decaying

	# ─── BREATH ───────────────────────────────────────────────
	phase = (phase + breath_hz * dt) % 1.0

	# ─── FLICKER ──────────────────────────────────────────────
	# Irregular by design: a Poisson-ish chance per frame rather than an LFO.
	# A periodic wobble reads as an effect; random intervals read as a fault.
	for i in range(4):
		# Activation drives HOW OFTEN, not how far. A struggling lamp flickers
		# less frequently when it settles, not more gently — and full-depth
		# jumps are what make it read from across the room.
		if en_flick and lit[i] > 0.0 and random.random() < lit[i] * flick_rate * dt:
			flick[i] = random.uniform(-1.0, 1.0) * flick_depth
		flick[i] = slew(flick[i], 0.0, flick_tau)

	def fixture_colour(i):
		"""Base pushed toward one flicker target or the other. Sign picks
		which, magnitude picks how far."""
		f = flick[i]
		if f == 0.0:
			return BASE_RGB
		tgt = FLICK_A if f < 0 else FLICK_B
		k = min(1.0, abs(f))
		return tuple(lerp(BASE_RGB[c], tgt[c], k) for c in range(3))

	# ─── OUTPUT ───────────────────────────────────────────────
	scriptOp.clear()
	chans = {}
	for i in range(4):
		for c in 'rgba':
			chans[f'light{i}_{c}'] = scriptOp.appendChan(f'light{i}_{c}')

	def setLight(index, r, g, b, a=0.0):
		chans[f'light{index}_r'][0] = max(0.0, min(255.0, r))
		chans[f'light{index}_g'][0] = max(0.0, min(255.0, g))
		chans[f'light{index}_b'][0] = max(0.0, min(255.0, b))
		chans[f'light{index}_a'][0] = max(0.0, min(255.0, a))

	for i in range(4):
		if en_breath:
			b = math.sin((phase + BREATH_PHASE[i]) * 2.0 * math.pi) * 0.5 + 0.5
			breath = 1.0 + (b - 0.5) * 2.0 * breath_amp
		else:
			breath = 1.0

		level = max(0.0, master * breath)
		col   = fixture_colour(i)
		setLight(i, col[0] * level, col[1] * level, col[2] * level, AMBER * level)

	# ─── PERSIST ──────────────────────────────────────────────
	scriptOp.store('phase', phase)
	scriptOp.store('flick', flick)
	return
