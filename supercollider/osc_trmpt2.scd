(
// ---- AUDIO / SERVER OPTIONS ----
//s.options.device = "hw:3,0";
s.options.sampleRate = 48000;
s.options.numOutputBusChannels = 2;

s.waitForBoot({

    // ---- LOAD SAMPLE ----
    ~samplePath = "/home/pi/sc/Trumpet.wav";
    ~bufReady = false;

    b = Buffer.readChannel(s, ~samplePath, channels: [0], action: { |buf|
        if (buf.numFrames > 0) {
            ~bufReady = true;
            ("Loaded sample: " ++ ~samplePath ++ " frames:" ++ buf.numFrames).postln;
        } {
            ("ERROR: buffer has 0 frames: " ++ ~samplePath).warn;
        };
    });
    s.sync;

    // ---- SUSTAINABLE PLAYER (gate-controlled) ----
    SynthDef(\playerGate, { |bufnum, amp=0.3, rate=1, gate=1, out=0, atk=0.005, rel=0.25, loop=0|
        var rateScale = BufRateScale.kr(bufnum) * rate;
        var src = PlayBuf.ar(1, bufnum, rateScale, startPos: 0, loop: loop);
        var eg  = EnvGen.kr(Env.asr(atk, 1.0, rel), gate, doneAction: 2);
        Out.ar(out, (src * eg * amp) ! 2);
    }).add;

    // ---- EDGE / STATE ----
    ~onThresh  = 0.9;
    ~offThresh = 0.05;
    ~deltaMin  = 0.6;   // minimum upward jump
    ~emaAlpha  = 0.4;    // smoothing (lower = smoother)

    ~ema      = 0.0;
    ~lastEma  = 0.0;
    ~pressed  = false;
    ~synth    = nil;

    // map value to volume
    ~ampMap = { |v| v.linlin(~onThresh, 1.0, 0.12, 1.0).clip(0, 1) };

    // Remove any previous handler with same key (hot-reload friendly)
    OSCdef(\touch11).free;

    // ---- LISTENER: /touch1 with one float arg ----
    OSCdef(\touch11, { |msg, time, addr, recvPort|
        var raw, risingBig, falling;

        // guard until buffer is ready
        if (~bufReady.not) {
            "Buffer not ready yet; ignoring message.".postln;
            ^nil;
        };

        // parse safely
        if (msg.size > 1 and: { msg[1].isNumber }) {
            raw = msg[1].asFloat;
        } {
            raw = 0.0;
        };

        // EMA smoothing
        ~lastEma = ~ema;
        ~ema     = (~emaAlpha * raw) + ((1 - ~emaAlpha) * ~lastEma);

        risingBig = (~ema > ~onThresh) and: ((~ema - ~lastEma) > ~deltaMin);
        falling   = (~ema < ~offThresh);

        // Rising edge: start once
        if (risingBig and: (~pressed.not)) {
            ~pressed = true;

            // safety: free any prior
            if (~synth.notNil) { ~synth.free; };

            ~synth = Synth(\playerGate, [
                \bufnum, b.bufnum,
                \amp, ~ampMap.(~ema),
                \atk, 0.005,
                \rel, 0.25,
                \loop, 0
            ]);
            ~synth.onFree({ ~synth = nil; });
            ("TRIGGER  ema:%  amp:%".format(~ema, ~ampMap.(~ema))).postln;

        } {
            // While held: update volume continuously
            if (~pressed and: (~synth.notNil)) {
                ~synth.set(\amp, ~ampMap.(~ema));
            };
        };

        // Falling edge: release (fade out)
        if (~pressed and: falling) {
            ~pressed = false;
            if (~synth.notNil) {
                ~synth.set(\gate, 0);
            };
            ("RELEASE  ema:%".format(~ema)).postln;
        };
    }, '/touch11', recvPort: NetAddr.langPort);

    "Ready: /touch11 on %, sample '%', gate-controlled"
        .format(NetAddr.langPort, ~samplePath).postln;
});
)
