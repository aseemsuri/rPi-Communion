"""
RELICT — DMX watchdog
Paste into an EXECUTE DAT with "Frame Start" enabled.

Lives outside the lighting Script CHOP on purpose: if that op stalls, a
watchdog inside it stalls with it. onFrameStart runs off the frame clock, not
the CHOP cook chain, so it keeps going when the chain doesn't.

WHAT IT CAN AND CANNOT SEE
  Detectable — the chain freezing. BREATH is always moving, so light0_r is
  always changing. If it sits at exactly the same value for STALL_S, something
  upstream has stopped and re-arming the DMX CHOP kicks it.

  NOT detectable — the interface dropping silently. TD has no status to read
  for that: the CHOP values keep updating perfectly while nothing reaches the
  fixtures. The only answer there is a blind periodic re-arm, which is why
  PERIODIC_S exists. It is OFF by default because it costs a visible blip.
"""

LIGHTS_OP  = 'RELICT_lights'   # the Script CHOP producing light0_r ...
DMX_OP     = 'dmxout1'         # the DMX Out CHOP to re-arm
WATCH_CHAN = 'light0_r'

STALL_S    = 3.0     # frozen output for this long -> re-arm
COOLDOWN_S = 15.0    # never re-arm more often than this
PERIODIC_S = 0.0     # 0 = off. N = blind re-arm every N seconds regardless
VERBOSE    = True

_last_val   = None
_last_move  = 0.0
_last_arm   = -999.0
_pending    = 0      # frames left before restoring active


def _rearm(now, why):
    """Drop the DMX CHOP's active flag; _restore puts it back next frame.
    Two frames rather than one — setting it off and on in the same frame
    often does not reach the device at all."""
    global _last_arm, _pending
    try:
        d = op(DMX_OP)
        if d is None:
            return
        d.par.active = 0
        _pending = 2
        _last_arm = now
        if VERBOSE:
            print(f"RELICT_dmx_watchdog: re-armed {DMX_OP} ({why})")
    except Exception as e:
        if VERBOSE:
            print(f"RELICT_dmx_watchdog: could not re-arm — {e}")


def onFrameStart(frame):
    global _last_val, _last_move, _pending

    now = absTime.seconds

    # finish a re-arm started on an earlier frame
    if _pending > 0:
        _pending -= 1
        if _pending == 0:
            try:
                op(DMX_OP).par.active = 1
            except Exception:
                pass
        return

    try:
        v = float(op(LIGHTS_OP)[WATCH_CHAN])
    except Exception:
        return          # op or channel missing — nothing to judge yet

    if _last_val is None or v != _last_val:
        _last_val = v
        _last_move = now
        return

    # value has not moved since _last_move
    if (now - _last_move) > STALL_S and (now - _last_arm) > COOLDOWN_S:
        _rearm(now, f"{WATCH_CHAN} frozen {now - _last_move:.1f}s")
        _last_move = now
        return

    if PERIODIC_S > 0 and (now - _last_arm) > PERIODIC_S:
        _rearm(now, "periodic")
