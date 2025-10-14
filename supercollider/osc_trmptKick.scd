(
// ---- AUDIO / SERVER OPTIONS ----
s.options.sampleRate = 48000;
s.options.numOutputBusChannels = 2;

s.waitForBoot({

    // ---- LOAD SAMPLES ----
    ~trumpetPath = "/home/pi/sc/Trumpet.wav";
    ~kickPath = "/home/pi/sc/Kick.wav";
    ~bufReady = false;
    ~bufTrumpet = nil;
    ~bufKick = nil;

    Buffer.readChannel(s, ~trumpetPath, channels: [0], action: { |buf|
        if (buf.numFrames > 0) {
            ~bufTrumpet = buf;
            ("Loaded Trumpet: " ++ ~trumpetPath).postln;
        } { "ERROR: Trumpet buffer empty".warn; }
    });

    Buffer.readChannel(s, ~kickPath, channels: [0], action: { |buf|
        if (buf.numFrames > 0) {
            ~bufKick = buf;
            ("Loaded Kick: " ++ ~kickPath).postln;
        } { "ERROR: Kick buffer empty".warn; }
    });

    s.sync;
    ~bufReady = true;

    // ---- PLAYER SYNTH ----
    SynthDef(\playerGate, { |bufnum, amp=0.3, rate=1, gate=1, out=0, atk=0.005, rel=0.25, loop=0|
        var rateScale = BufRateScale.kr(bufnum) * rate;
        var src = PlayBuf.ar(1, bufnum, rateScale, startPos: 0, loop: loop);
        var eg  = EnvGen.kr(Env.asr(atk, 1.0, rel), gate, doneAction: 2);
        Out.ar(out, (src * eg * amp) ! 2);
    }).add;

    // ---- TOUCH SETTINGS ----
    ~makeTouchHandler = { |key, buf, touchPath|
        var onThresh = 3.0;
        var offThresh = 0.0;
        var deltaMin = 0.6;
        var emaAlpha = 0.2;

        var ema = 0.0;
        var lastEma = 0.0;
        var pressed = false;
        var synth = nil;

        var ampMap = { |v| v.linlin(onThresh, 1.0, 0.12, 1.0).clip(0, 1) };

        OSCdef(key, { |msg|
            var raw, risingBig, falling;

            if (~bufReady.not or: { buf.isNil }) {
                "Buffer not ready; ignoring.".postln;
                ^nil;
            };

            raw = (msg.size > 1 and: { msg[1].isNumber }) 
                .if({ msg[1].asFloat }, { 0.0 });

            // EMA smoothing
            lastEma = ema;
            ema = (emaAlpha * raw) + ((1 - emaAlpha) * lastEma);

            risingBig = (ema > onThresh) and: ((ema - lastEma) > deltaMin);
            falling = (ema < offThresh);

            // Rising edge
            if (risingBig and: (pressed.not)) {
                pressed = true;
                if (synth.notNil) { synth.free };
                synth = Synth(\playerGate, [
                    \bufnum, buf.bufnum,
                    \amp, ampMap.(ema),
                    \atk, 0.005,
                    \rel, 0.25,
                    \loop, 0
                ]);
                synth.onFree({ synth = nil });
                ("% TRIGGER: ema: %, amp: %"
                    .format(key, ema.round(0.001), ampMap.(ema).round(0.01))).postln;

            } {
                // While held
                if (pressed and: (synth.notNil)) {
                    synth.set(\amp, ampMap.(ema));
                };
            };

            // Falling edge
            if (pressed and: falling) {
                pressed = false;
                if (synth.notNil) {
                    synth.set(\gate, 0);
                };
                ("% RELEASE: ema: %"
                    .format(key, ema.round(0.001))).postln;
            };

        }, touchPath, recvPort: NetAddr.langPort);
    };

    // ---- REGISTER TOUCHES ----
    OSCdef(\touch10).free;
    OSCdef(\touch11).free;

    ~makeTouchHandler.(
        \touch10, ~bufKick, "/touch10"
    );
    ~makeTouchHandler.(
        \touch11, ~bufTrumpet, "/touch11"
    );

    "Ready! Listening on /touch9 and /touch11".postln;

});
)
