// fieldMap.js — Communion column field -> position
// ---------------------------------------------------------------------------
// in :  touch1..touch8   proximity, 0..100   (float)
//       gate1..gate8     contact, 0/1        (stored; unused so far)
//       altar <6 floats>    — all six plants at once, from [pak] -> [prepend altar]
//       altar1..altar6      — or one at a time
//       touches <8 floats>  — all proximities at once
//       gates   <8 ints>    — all gates at once
// out:  0 = x   1 = y   2 = activity (0..1, how busy the room is)
//       3 = gate events, as tagged lists — route them in Max:
//             altar  <0|1>              1 while any plant is touched
//             tap    <col> <vel> <ms>   short press, fires on RELEASE
//             hold   <col> 1 <vel>      crossed the hold threshold, still down
//             hold   <col> 0            released after a hold
//             holdcc <col> <0-127>      ramps while held, 0 on release
//             rnd    <col> <0-127>      one random value, at hold start
//             accrete <col> <n> <note>  an extra voice joined a sustained hold
//             field  <x> <y> <act> <holds>   every tick, for the TD lighting
//             prox   <p1..p8>                every tick, per-column proximity
//
//       proximity controls:  proxon <0|1>      master enable
//                            proxrange <0..1>  1 = ~3ft, 0 = ~0.5ft
//       4 = MIDI, ready for noteout / ctlout:
//             note <pitch> <vel> <chan>       -> [noteout]
//             cc   <val> <ctrl> <chan>        -> [ctlout]   (ctlout's own order)
//
//       CHANNEL = COLUMN.  Column 1-8 -> MIDI channel 1-8. Within a channel the
//       NOTE says which event it was, so chain selection / note mapping picks
//       the synth:   tap 36   hold 48   prox 60   (all settable)
//
// Two ways of turning the field into a point, switchable live:
//    mode 0   CENTROID — magnitude-weighted mean. Continuous and smooth, but
//             every wobble in a reading moves it, and with a crowd the weights
//             even out and it collapses to the middle.
//    mode 1   MEDIAN   — ignores magnitude, uses only WHICH columns are active.
//             Steppy rather than continuous, but immune to magnitude noise.
//             (default)
// ---------------------------------------------------------------------------
autowatch = 1;
inlets  = 1;
outlets = 5;   // 3 = gate events   4 = MIDI

var N = 8;

// Column positions in a -1..1 square.  1-4 are the corners as you described;
// 5-8 are the interior columns and these are PLACEHOLDERS — measure the real
// room and set them with:   setpos <1-8> <x> <y>
var POS = [
    [-1.00,  1.00],   // 1  corner
    [ 1.00,  1.00],   // 2  corner
    [ 1.00, -1.00],   // 3  corner
    [-1.00, -1.00],   // 4  corner
    [-0.45,  0.35],   // 5  interior  <- set me
    [ 0.40,  0.50],   // 6  interior  <- set me
    [ 0.35, -0.40],   // 7  interior  <- set me
    [-0.40, -0.30]    // 8  interior  <- set me
];

var prox = [], gate = [];
for (var i = 0; i < N; i++) { prox[i] = 0.0; gate[i] = 0; }

// ---- tunable parameters ---------------------------------------------------
var pMode  = 1;      // 0 = centroid, 1 = median
var pDead  = 8.0;    // activation threshold. In MEDIAN mode this is the only
                     // thing deciding membership, so it matters a lot more
                     // than it did for the centroid — too low and distant
                     // bodies drag everything toward the middle.
var pExp   = 2.0;    // CENTROID only: >1 pulls toward the strongest column
var pEase  = 0.04;   // 0..1 per frame; ~1.5s to settle
var pMinSum= 0.02;   // CENTROID only: below this total weight, don't move
var pRate  = 20;     // ms between outputs
var pMaxSpeed = 0.25;// units/sec ceiling; room is 2 units wide, so ~8s across
var pRestX = 0.0, pRestY = 0.0;   // where it drifts when the room is empty
var pTapMax   = 300;  // ms — released under this is a TAP, over it is a HOLD
var pHoldRamp = 800; // ms for holdcc to travel 0..127 while held

// ---- MIDI mapping --------------------------------------------------------
// Channel carries the column; note carries the event type. So every column
// gets its own MIDI channel and its own instrument rack, and inside that rack
// note ranges select which chain a tap / hold / proximity reaches.
var pChBase   = 1;     // column 1 -> this channel, column 2 -> +1, and so on
var pNoteTap  = 60;
var pNoteHold = 48;
var pNoteProx = 60;
var pCCProx   = 20;    // proximity value, on the column's own channel
var pCCHold   = 21;    // hold ramp,       on the column's own channel

// Velocity source. Proximity at the instant of contact is nearly always high —
// you're touching the thing. Approach SPEED is the expressive one: how fast the
// hand closed the last 200ms. Someone who slams and someone who eases in get
// different velocities from the same contact.
var pVelMode   = 1;    // 0 = proximity at contact, 1 = approach speed
var pVelFrames = 10;   // history depth in frames (10 * 20ms = 200ms)
var pVelRange  = 25.0; // approach delta that counts as a full-force arrival
var pVelGamma  = 0.5;  // curve. 1 = linear, <1 lifts soft approaches,
                       // 0.5 = sqrt, 0.35 = strongly compressed
var pVelFloor  = 30.0; // softest possible result, so a gentle touch still speaks
// Release note: letting go is an event too. Velocity comes from how long it
// was held, so a long hold ends with weight and a brief one barely registers.
var pRelease   = 1;
var pNoteRel   = 72;
var pRelMin    = 300;   // ms — shorter holds get no release note
var pRelFull   = 4000;  // ms held that maps to velocity 127

// Retrigger: while held, pulse a separate note at a rate set by proximity.
// Leaning in makes it faster.
var pRetrig      = 0;   // off by default now — see ACCRETE below
var pNoteRetrig  = 60;
var pRetrigSlow  = 500; // ms between pulses at proximity 0
var pRetrigFast  = 80;  // ms between pulses at proximity 100
var retrigAt = [];
for (var i = 0; i < N; i++) retrigAt[i] = 0;

// Accrete: instead of pulsing, a held column gathers voices. Extra notes join
// the sustain at set intervals and stay until release, so holding builds a
// chord rather than repeating a figure.
var pAccrete  = 0;
var ACC_NOTES = [65, 67, 72];             // join in this order; must NOT
                                          // collide with tap/hold/prox/rel/retrig
var ACC_TIMES = [1500, 3500, 6000];       // ms held when each one arrives
var accN = [];
for (var i = 0; i < N; i++) accN[i] = 0;  // how many have joined, per column

// ---- ALTAR ---------------------------------------------------------------
// csna1 sends /touchN only — no gates — so the gate is derived here.
// 1 while any plant is touched, 0 when none are. Two thresholds rather than
// one so it can't chatter at the edge; the columns get that hysteresis from
// the MPR121 itself, this doesn't.
var NA = 6;                       // altar electrodes, in the order you route them
var altarV = [];                  // named altarV so the message handler can be altar()
for (var i = 0; i < NA; i++) altarV[i] = 0.0;

var pAltOn   = 1.0;      // touch value that turns the gate ON
var pAltOff  = 0.5;      // ... and below this it goes OFF
var altState = 0;

var pHist = [], hIdx = 0;
for (var i = 0; i < N; i++) { pHist[i] = []; for (var k = 0; k < 64; k++) pHist[i][k] = 0; }
var pTapLen = 200;     // ms — a tap is detected on release, so it needs a length
// Proximity note gate. The working thresholds are DERIVED from proxrange, so
// don't set pProxOn/pProxOff directly — move the slider or the endpoints.
//
// Shrinking the range means RAISING the thresholds: the proximity value climbs
// as a body gets closer, so a higher bar means they have to be nearer to cross
// it. proxrange 1 = the far setting (~3ft), 0 = the near one (~0.5ft).
var pProxOnFar   = 12.0, pProxOffFar  =  6.0;   // proxrange 1.0
var pProxOnNear  = 100.0, pProxOffNear = 90.0;   // proxrange 0.0
var pProxRange   = 1.0;                          // the slider, 0..1
var pProxOn = pProxOnFar;      // derived each tick — see applyProxRange()
var pProxOff= pProxOffFar;

var pProxEnable = 1;   // master on/off for the whole proximity layer

// Proximity notes sit UNDER the contact/hold notes on the same channel, so
// they get their own velocity range rather than the full 1-127. Velocity is
// fixed at the moment the note triggers — CC 20 is what moves while it
// sustains, so this sets the floor the swell starts from.
var pProxVelMin = 5;
var pProxVelMax = 55;

var onTap = [], onHold = [], onProx = [], lastCC = [];
var pend  = [];        // pending note-offs: [frame, pitch, chan]

var gPrev = [], gOnFrame = [], gHeld = [], gVel = [], gCC = [];
for (var i = 0; i < N; i++) { gPrev[i]=0; gOnFrame[i]=0; gHeld[i]=0; gVel[i]=0; gCC[i]=-1; }
for (var i = 0; i < N; i++) { onTap[i]=-1; onHold[i]=-1; onProx[i]=-1; lastCC[i]=-1; }
var frames = 0;

var curX = 0.0, curY = 0.0;   // what we actually output (smoothed)
var tgtX = 0.0, tgtY = 0.0;   // instantaneous target
var act  = 0.0;

// ---- input ----------------------------------------------------------------
function anything() {
    var m = messagename, v = (arguments.length ? arguments[0] : 0), idx;
    if (m.indexOf("touch") === 0) {
        idx = parseInt(m.substring(5), 10) - 1;
        if (idx >= 0 && idx < N) prox[idx] = v;
    } else if (m.indexOf("gate") === 0) {
        idx = parseInt(m.substring(4), 10) - 1;
        if (idx >= 0 && idx < N) gate[idx] = v;
    } else if (m.indexOf("altar") === 0) {
        idx = parseInt(m.substring(5), 10) - 1;
        if (idx >= 0 && idx < NA) altarV[idx] = v;
    }
}

function touches() {
    for (var i = 0; i < N && i < arguments.length; i++) prox[i] = arguments[i];
}

// Six values at once:  [pak 0. 0. 0. 0. 0. 0.] -> [prepend altar] -> here.
function altar() {
    for (var i = 0; i < NA && i < arguments.length; i++) altarV[i] = arguments[i];
}
function altars() { altar.apply(this, arguments); }   // alias

function gates() {
    for (var i = 0; i < N && i < arguments.length; i++) gate[i] = arguments[i];
}

// ---- the field ------------------------------------------------------------
function median(a) {
    a.sort(function(p, q) { return p - q; });
    var n = a.length, h = Math.floor(n / 2);
    return (n % 2) ? a[h] : (a[h-1] + a[h]) / 2.0;
}

// MODE 0 — magnitude-weighted mean.
function computeCentroid() {
    var sw = 0.0, sx = 0.0, sy = 0.0;
    for (var i = 0; i < N; i++) {
        var p = prox[i];
        if (p <= pDead) continue;
        var w = Math.pow((p - pDead) / (100.0 - pDead), pExp);
        sw += w;
        sx += w * POS[i][0];
        sy += w * POS[i][1];
    }
    if (sw > pMinSum) { tgtX = sx / sw; tgtY = sy / sw; }
    else              { tgtX = pRestX;  tgtY = pRestY;  }
}

// MODE 1 — componentwise median of the ACTIVE columns' positions.
// Magnitude is discarded entirely: a column at 9 counts the same as one at 100.
function computeMedian() {
    var xs = [], ys = [];
    for (var i = 0; i < N; i++) {
        if (prox[i] > pDead) { xs.push(POS[i][0]); ys.push(POS[i][1]); }
    }
    if (xs.length === 0) { tgtX = pRestX; tgtY = pRestY; return; }
    tgtX = median(xs);
    tgtY = median(ys);
}

function compute() {
    var raw = 0.0;
    for (var i = 0; i < N; i++) raw += prox[i];
    act = raw / (N * 100.0);
    if (pMode === 0) computeCentroid(); else computeMedian();
}

// ---- MIDI ----------------------------------------------------------------
function chanFor(i) { return pChBase + i; }

function pushHist() {
    for (var i = 0; i < N; i++) pHist[i][hIdx] = prox[i];
    hIdx = (hIdx + 1) % pVelFrames;      // now points at the oldest sample
}

function computeVel(i) {
    if (pVelMode === 0) return prox[i];
    var d = prox[i] - pHist[i][hIdx];        // rise over the history window
    if (d < 0) d = 0;
    var n = Math.min(1.0, d / pVelRange);    // 0..1 against a full-force arrival
    var c = Math.pow(n, pVelGamma);          // compress: lift the quiet end
    return pVelFloor + c * (100.0 - pVelFloor);
}

function vel127(p) { var v = Math.round(p * 1.27); return Math.max(1, Math.min(127, v)); }

function noteOn(pitch, vel, chan)  { outlet(4, "note", pitch, vel, chan); }
function noteOff(pitch, chan)      { outlet(4, "note", pitch, 0, chan); }
function sendCC(ctrl, val, chan)   { outlet(4, "cc", ctrl, val, chan); }  // ctlout order

// Proximity notes: on above pProxOn, off below pProxOff. The gap between the
// two is what stops someone hovering at the edge from machine-gunning notes.
// CC tracks the value continuously, deduped so it only sends on change.
// Interpolate the working thresholds from the slider. Linear between the two
// endpoints, so the slider reads as distance even though the underlying
// falloff isn't linear — calibrate by moving the endpoints, not the curve.
function applyProxRange() {
    var r = Math.max(0.0, Math.min(1.0, pProxRange));
    pProxOn  = pProxOnNear  + (pProxOnFar  - pProxOnNear)  * r;
    pProxOff = pProxOffNear + (pProxOffFar - pProxOffNear) * r;
}

function processProx() {
    // Disabled: lift anything still sounding, then do nothing. Without this
    // a note held at the moment you switch off would hang forever.
    if (!pProxEnable) {
        for (var i = 0; i < N; i++) {
            if (onProx[i] >= 0) { noteOff(onProx[i], chanFor(i)); onProx[i] = -1; }
            if (lastCC[i] !== 0) { lastCC[i] = 0; sendCC(pCCProx, 0, chanFor(i)); }
        }
        return;
    }
    applyProxRange();
    for (var i = 0; i < N; i++) {
        var p = prox[i];

        if (onProx[i] < 0 && p >= pProxOn) {
            onProx[i] = pNoteProx;
            var pv = pProxVelMin +
                     (Math.min(100.0, p) / 100.0) * (pProxVelMax - pProxVelMin);
            noteOn(pNoteProx, Math.max(1, Math.min(127, Math.round(pv))), chanFor(i));
        } else if (onProx[i] >= 0 && p < pProxOff) {
            noteOff(onProx[i], chanFor(i));
            onProx[i] = -1;
        }

        var c = Math.max(0, Math.min(127, Math.round(p * 1.27)));
        if (c !== lastCC[i]) { lastCC[i] = c; sendCC(pCCProx, c, chanFor(i)); }
    }
}

// Taps are struck, not held, so their note-off is scheduled rather than
// following the gate.
function schedOff(pitch, chan, ms) {
    pend.push([frames + Math.round(ms / pRate), pitch, chan]);
}

function processPending() {
    for (var k = pend.length - 1; k >= 0; k--) {
        if (frames >= pend[k][0]) {
            noteOff(pend[k][1], pend[k][2]);
            pend.splice(k, 1);
        }
    }
}

function panic() {
    for (var i = 0; i < N; i++) {
        if (onTap[i]  >= 0) { noteOff(onTap[i],  chanFor(i)); onTap[i]  = -1; }
        if (onHold[i] >= 0) { noteOff(onHold[i], chanFor(i)); onHold[i] = -1; }
        if (onProx[i] >= 0) { noteOff(onProx[i], chanFor(i)); onProx[i] = -1; }
        for (var a = 0; a < accN[i]; a++) noteOff(ACC_NOTES[a], chanFor(i));
        accN[i] = 0;
    }
    for (var k = 0; k < pend.length; k++) noteOff(pend[k][1], pend[k][2]);
    pend = [];
    post("fieldMap: panic — all notes off\n");
}

// Edge-detect the gates on the tick rather than in anything(), so every
// duration is measured on the same clock. Resolution is pRate (20ms), which
// is far finer than the tap/hold distinction needs.
function processGates() {
    for (var i = 0; i < N; i++) {
        var g = gate[i] ? 1 : 0;
        var ms = (frames - gOnFrame[i]) * pRate;

        if (g && !gPrev[i]) {                       // pressed — fire NOW, on attack
            gOnFrame[i] = frames;
            gVel[i] = computeVel(i);
            gHeld[i] = 0;
            gCC[i] = -1;
            outlet(3, "touch", i+1, 1, Math.round(gVel[i]));
            onTap[i] = pNoteTap;
            noteOn(pNoteTap, vel127(gVel[i]), chanFor(i));

        } else if (!g && gPrev[i]) {                // released
            if (onTap[i] >= 0) { noteOff(onTap[i], chanFor(i)); onTap[i] = -1; }
            for (var a = 0; a < accN[i]; a++) noteOff(ACC_NOTES[a], chanFor(i));
            accN[i] = 0;
            outlet(3, "touch", i+1, 0);
            if (pRelease && ms >= pRelMin) {
                var rv = Math.max(1, Math.min(127, Math.round((ms / pRelFull) * 127)));
                noteOn(pNoteRel, rv, chanFor(i));
                schedOff(pNoteRel, chanFor(i), pTapLen);
                outlet(3, "release", i+1, rv, ms);
            }
            if (ms < pTapMax) {
                outlet(3, "tap", i+1, Math.round(gVel[i]), ms);   // informational
            } else {
                outlet(3, "hold", i+1, 0);
                if (onHold[i] >= 0) { noteOff(onHold[i], chanFor(i)); onHold[i] = -1; }
            }
            if (gCC[i] >= 0) { outlet(3, "holdcc", i+1, 0); sendCC(pCCHold, 0, chanFor(i)); }
            gHeld[i] = 0; gCC[i] = -1;

        } else if (g) {                             // still down
            if (!gHeld[i] && ms >= pTapMax) {       // just became a hold
                gHeld[i] = 1;
                outlet(3, "hold", i+1, 1, Math.round(gVel[i]));
                outlet(3, "rnd", i+1, Math.floor(Math.random() * 128));
                onHold[i] = pNoteHold;
                noteOn(pNoteHold, vel127(gVel[i]), chanFor(i));
                retrigAt[i] = frames;
                accN[i] = 0;
            }
            if (gHeld[i] && pAccrete && accN[i] < ACC_NOTES.length &&
                ms >= ACC_TIMES[accN[i]]) {
                noteOn(ACC_NOTES[accN[i]], vel127(gVel[i]), chanFor(i));
                outlet(3, "accrete", i+1, accN[i] + 1, ACC_NOTES[accN[i]]);
                accN[i]++;
            }
            if (gHeld[i] && pRetrig && frames >= retrigAt[i]) {
                var iv = pRetrigSlow +
                         (pRetrigFast - pRetrigSlow) * (Math.min(100, prox[i]) / 100.0);
                retrigAt[i] = frames + Math.max(1, Math.round(iv / pRate));
                noteOn(pNoteRetrig, vel127(prox[i]), chanFor(i));
                schedOff(pNoteRetrig, chanFor(i), Math.min(pTapLen, iv * 0.8));
                outlet(3, "retrig", i+1, Math.round(iv));
            }
            if (gHeld[i]) {
                var c = Math.round(Math.min(1.0, ms / pHoldRamp) * 127);
                if (c !== gCC[i]) {
                    gCC[i] = c;
                    outlet(3, "holdcc", i+1, c);
                    sendCC(pCCHold, c, chanFor(i));
                }
            }
        }
        gPrev[i] = g;
    }
}

function processAltar() {
    var hot = 0.0;
    for (var i = 0; i < NA; i++) if (altarV[i] > hot) hot = altarV[i];

    if (!altState && hot >= pAltOn)      { altState = 1; outlet(3, "altar", 1); }
    else if (altState && hot <  pAltOff) { altState = 0; outlet(3, "altar", 0); }
}

function tick() {
    frames++;
    pushHist();
    processGates();
    processProx();
    processPending();
    processAltar();
    compute();
    var nx = curX + (tgtX - curX) * pEase;
    var ny = curY + (tgtY - curY) * pEase;
    // Speed clamp: never travel faster than a body could walk, so a change in
    // which columns are active reads as movement rather than a jump.
    var dx = nx - curX, dy = ny - curY;
    var d  = Math.sqrt(dx*dx + dy*dy);
    var lim = pMaxSpeed * (pRate / 1000.0);
    if (d > lim && d > 0) { nx = curX + dx * (lim/d); ny = curY + dy * (lim/d); }
    curX = nx; curY = ny;
    // One bundle for TouchDesigner's lighting:  /field <x> <y> <activity> <holds>
    // holds = how many columns are currently past the hold threshold.
    var nHeld = 0;
    for (var q = 0; q < N; q++) if (gHeld[q]) nHeld++;
    outlet(3, "field", curX, curY, act, nHeld);

    // Per-column proximity for TD's per-light response. Sent as one message so
    // TD lands them as prox1..prox8 in argument order.
    outlet(3, "prox", prox[0], prox[1], prox[2], prox[3],
                      prox[4], prox[5], prox[6], prox[7]);

    outlet(2, act);
    outlet(1, curY);
    outlet(0, curX);
}

// ---- messages -------------------------------------------------------------
function mode(v)     { pMode = (v ? 1 : 0);
                       post("fieldMap: " + (pMode ? "MEDIAN" : "CENTROID") + "\n"); }
function setpos(i, x, y) {
    i = i - 1;
    if (i >= 0 && i < N) { POS[i][0] = x; POS[i][1] = y; }
}
function setrest(x, y) { pRestX = x; pRestY = y; }
function setdead(v)  { pDead   = v; }
function setexp(v)   { pExp    = v; }
function setease(v)  { pEase   = Math.max(0.001, Math.min(1.0, v)); }
function setminsum(v){ pMinSum = v; }
function setrate(v)  { pRate   = Math.max(5, v); task.interval = pRate; }
function setmaxspeed(v){ pMaxSpeed = v; }
function settapmax(v)  { pTapMax   = Math.max(pRate, v); }
function setholdramp(v){ pHoldRamp = Math.max(50, v); }
function setnotes(t, h, p) { pNoteTap = t; pNoteHold = h; pNoteProx = p; }
function setchbase(v)  { panic(); pChBase = v; }   // column 1's channel
function setccs(pr, ho){ pCCProx = pr; pCCHold = ho; }
function setvel(mode)  { pVelMode = (mode ? 1 : 0); }
function setvelcurve(range, gamma, floor) {
    if (range) pVelRange = Math.max(1.0, range);
    if (gamma) pVelGamma = Math.max(0.05, Math.min(4.0, gamma));
    if (floor !== undefined && floor !== null) pVelFloor = Math.max(0, Math.min(99, floor));
}
function setvelframes(v) { pVelFrames = Math.max(2, Math.min(64, v)); hIdx = 0; }
function setrelease(on, note, minms, fullms) {
    pRelease = (on ? 1 : 0);
    if (note)   pNoteRel = note;
    if (minms)  pRelMin  = minms;
    if (fullms) pRelFull = fullms;
}
function setaccrete(on)  { pAccrete = (on ? 1 : 0); }
function setaccnotes()  { ACC_NOTES = []; for (var i = 0; i < arguments.length; i++) ACC_NOTES.push(arguments[i]); }
function setacctimes()  { ACC_TIMES = []; for (var i = 0; i < arguments.length; i++) ACC_TIMES.push(arguments[i]); }
function setretrig(on, note, slowms, fastms) {
    pRetrig = (on ? 1 : 0);
    if (note)   pNoteRetrig = note;
    if (slowms) pRetrigSlow = slowms;
    if (fastms) pRetrigFast = fastms;
}
function settaplen(v)  { pTapLen = Math.max(pRate, v); }
// The slider. 1 = full range (far endpoint), 0 = tightest (near endpoint).
function proxrange(v) { pProxRange = Math.max(0.0, Math.min(1.0, v)); applyProxRange(); }

// Master on/off for proximity notes and CC.
function proxon(v) {
    var was = pProxEnable;
    pProxEnable = (v ? 1 : 0);
    if (was && !pProxEnable) processProx();   // runs the disable branch, lifts notes
    post("fieldMap: proximity " + (pProxEnable ? "ON" : "OFF") + "\n");
}

// Move the endpoints the slider interpolates between.
//   setproxends <onFar> <offFar> <onNear> <offNear>
function setproxends(onFar, offFar, onNear, offNear) {
    if (onFar)   pProxOnFar   = onFar;
    if (offFar)  pProxOffFar  = Math.min(offFar,  onFar  ? onFar  * 0.9 : pProxOnFar  * 0.9);
    if (onNear)  pProxOnNear  = onNear;
    if (offNear) pProxOffNear = Math.min(offNear, onNear ? onNear * 0.9 : pProxOnNear * 0.9);
    applyProxRange();
}
function setaltar(on, off) {
    pAltOn  = on;
    pAltOff = Math.min(off, on * 0.9);   // proportional, so it survives small values
}
function setproxvel(lo, hi) {
    pProxVelMin = Math.max(1, Math.min(127, lo));
    pProxVelMax = Math.max(pProxVelMin, Math.min(127, hi));
}

function reset() {
    for (var i = 0; i < N; i++) {
        prox[i] = 0.0; gate[i] = 0;
        gPrev[i] = 0; gHeld[i] = 0; gCC[i] = -1;
    }
    curX = curY = tgtX = tgtY = 0.0;
    panic();
}

function dump() {
    post("mode " + (pMode ? "MEDIAN" : "CENTROID") +
         "  dead " + pDead + "  ease " + pEase + "  maxspeed " + pMaxSpeed + "\n");
    for (var i = 0; i < N; i++)
        post("col " + (i+1) + "  pos " + POS[i][0] + "," + POS[i][1] +
             "   prox " + prox[i] + "   gate " + gate[i] +
             (prox[i] > pDead ? "   ACTIVE" : "") + "\n");
    var arow = "";
    for (var j = 0; j < NA; j++) arow += " " + altarV[j];
    post("altar[" + arow + " ]  on>" + pAltOn + " off<" + pAltOff +
         "   gate " + altState + "\n");
    post("prox " + (pProxEnable ? "ON" : "OFF") + "  range " + pProxRange +
         "  ->  on>" + pProxOn.toFixed(1) + " off<" + pProxOff.toFixed(1) + "\n");
    post("x " + curX + "  y " + curY + "  activity " + act + "\n");
}

function bang() { tick(); }

var task = new Task(tick, this);
task.interval = pRate;
task.repeat();
