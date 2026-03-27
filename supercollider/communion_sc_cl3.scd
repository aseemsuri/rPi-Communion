// Auto-start JACK if not running
// "pgrep jackd".unixCmd({ |res, pid|
//     if (res != 0) {
//         "jackd -d alsa -d hw:CARD=AB13X -r 48000 -p 512 &".unixCmd;
//         2.wait;
//     };
// });

(
// ========== TUNING PARAMETERS ==========
// Per-instrument settings: indices 0-11 (touch0 through touch11)
~totalVol = 0.25;  // Master volume (0.0-1.0); also set via /masterVol OSC from Python

~touchOnThresh = [
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.0, 1.0, 3.0, 1.0, 3.0
];

~touchOffThresh = [
    0.5, 0.5, 0.5, 0.5, 0.5, 0.5,
    0.5, 0.5, 0.5, 0.5, 0.5, 0.5
];

~touchDeltaMin = [
    0.6, 0.6, 0.6, 0.6, 0.6, 0.6,
    0.6, 0.6, 0.6, 3.0, 0.6, 3.0  // Lowered touch9 from 2.0 to 0.8
];

~samplePaths = [
    "/home/pi/communion-project/supercollider/samples/moneyPlant.wav",
    "/home/pi/communion-project/supercollider/samples/moneyPlant.wav",
    "/home/pi/communion-project/supercollider/samples/moneyPlant.wav",
    "/home/pi/communion-project/supercollider/samples/moneyPlant.wav",
    "/home/pi/communion-project/supercollider/samples/kick.wav",          // touch4 = flowerPlant (muted/unused)
    "/home/pi/communion-project/supercollider/samples/moneyPlant.wav",
    "/home/pi/communion-project/supercollider/samples/moneyPlant.wav",
    "/home/pi/communion-project/supercollider/samples/moneyPlant.wav",
    "/home/pi/communion-project/supercollider/samples/moneyPlant.wav",
    "/home/pi/communion-project/supercollider/samples/moneyPlant.wav",
    "/home/pi/communion-project/supercollider/samples/trumpet.wav",       // touch10 = trumpetPlant
    "/home/pi/communion-project/supercollider/samples/strings.wav",      // touch11 = stringsPlant
];

~baseNote = 24;
~emaAlpha = 0.8;  // Higher = more responsive (less smoothing)

~moneyPlantNotes  = [0, 2, 4, 7, 9, 12];
~trumpetNotes     = [0, 2, 4,5, 7, 9,11, 12];
~flowerPlantNotes = [-7, -5, 0, 5, 7];

// ========== END TUNING ==========

s.options.sampleRate = 48000;
s.options.numOutputBusChannels = 2;
s.options.numInputBusChannels = 0;  // No input needed
s.options.device = "hw:1";  // USB Audio card 1
s.options.blockSize = 256;        // Lower = more responsive (default is 64)
s.options.hardwareBufferSize = 256;  // Match JACK buffer

// Force JACK to use the correct device via inDevice/outDevice
s.options.inDevice = "hw:1";
s.options.outDevice = "hw:1";

//s.options.device = "system";


s.waitForBoot({

    // ===== OSC Debug =======
    //Print all incoming OSC messages
    // OSCFunc({ |msg, time, addr, recvPort|
    //     ("OSC received: " ++ msg).postln;
    // }, nil);  // nil means listen to all OSC paths



    // ---- REVERB BUS ----
    ~reverbBus = Bus.audio(s, 1);

    // ---- LOAD SAMPLES ----
    ~buffers = ();
    ~samplePaths.do({ |path, i|
        ~buffers[i] = Buffer.readChannel(s, path, channels: [0]);
    });
    
    s.sync;
    
    // ========== SYNTH DEFINITIONS ==========
    
    // Basic sampler synth (used for plants 0-10)
    SynthDef(\basicSampler, { |bufnum, amp=0.3, rate=1, gate=1, out=0, atk=0.005, rel=0.25|
        var rateScale = BufRateScale.kr(bufnum) * rate;
        var src = PlayBuf.ar(1, bufnum, rateScale, startPos: 0, loop: 0);
        var eg = EnvGen.kr(Env.asr(atk, 1.0, rel), gate, doneAction: 2);
        Out.ar(out, (src * eg * amp) ! 2);
    }).add;
    
    // Money Plant synth with pentatonic pitching
    SynthDef(\moneyPlant, { |bufnum, amp=0.9, rate=1, gate=1, out=0, atk=0.001, rel=0.015, vibrato=0|
        var rateScale = BufRateScale.kr(bufnum) * rate;
        var vibLfo = SinOsc.kr(5, 0, vibrato * 0.05);  // 5Hz vibrato, max 5% rate variation
        var vibratingRate = rateScale * (1.0 + vibLfo);
        var src = PlayBuf.ar(1, bufnum, vibratingRate, gate, startPos: 0, loop: 0);
        var eg = EnvGen.kr(Env.asr(atk, 1.0, rel), gate, doneAction: 2);
        Out.ar(out, (src * eg * amp) ! 2);
    }).add;

    // Flower Plant synth - kick with pitch shifting, no vibrato
    SynthDef(\flowerPlant, { |bufnum, amp=0.9, rate=1, gate=1, out=0, atk=0.001, rel=0.015|
        var rateScale = BufRateScale.kr(bufnum) * rate;
        var src = PlayBuf.ar(1, bufnum, rateScale, startPos: 0, loop: 0);
        var eg = EnvGen.kr(Env.asr(atk, 1.0, rel), gate, doneAction: 2);
        Out.ar(out, (src * eg * amp) ! 2);
    }).add;

    // Trumpet Plant synth - major scale with vibrato
    SynthDef(\trumpetPlant, { |bufnum, amp=1.1, rate=1, gate=1, out=0, reverbBus=0, reverbSend=0, atk=0.06, dec=0.1, sus=0.2, rel=0.06, vibrato=0|
        var rateScale = BufRateScale.kr(bufnum) * rate;
        var vibLfo = SinOsc.kr(5, 0, vibrato * 0.05);
        var vibratingRate = rateScale * (1.0 + vibLfo);
        var src = PlayBuf.ar(1, bufnum, vibratingRate, gate, startPos: 0, loop: 0);
        var eg = EnvGen.kr(Env.adsr(atk, dec, sus, rel), gate, doneAction: 2);
        var sig = src * eg * amp;
        var compressed = Compander.ar(sig, sig, thresh: 0.1, slopeBelow: 1, slopeAbove: 0.1, clampTime: 0.01, relaxTime: 0.1);
        Out.ar(out, compressed ! 2);
        Out.ar(reverbBus, sig * reverbSend);
    }).add;

    // Warmer synth - simple sine wave at 440Hz
    SynthDef(\warmer, { |out=0, amp=0.05|
        var sig = SinOsc.ar(440, 0, amp);
        Out.ar(out, sig ! 2);
    }).add;

    // Shared reverb — reads from reverbBus, runs at tail of node tree
    SynthDef(\reverbTail, { |reverbBus=0, out=0, room=20, revtime=5, damp=0.5, amp=1|
        var in = In.ar(reverbBus, 1);
        var verb = GVerb.ar(in, room, revtime, damp);
        Out.ar(out, verb * amp);
    }).add;

    // Strings Plant synth - for chord building (root, third, fifth, octave)
    SynthDef(\stringsPlant, { |bufnum, amp=0.1, rate=1, gate=1, out=0, reverbBus=0, reverbSend=0, atk=0.1, dec=1.5, sus=0.5, rel=0.1|
        var rateScale = BufRateScale.kr(bufnum) * rate;
        var src = PlayBuf.ar(1, bufnum, rateScale, startPos: 0, loop: 0);
        var eg = EnvGen.kr(Env.adsr(atk, dec, sus, rel), gate, doneAction: 2);
        var sig = src * eg * amp;
        Out.ar(out, sig ! 2);
        Out.ar(reverbBus, sig * reverbSend);
    }).add;

    SynthDef(\masterVol, { |out=0, vol=1|
        var sig = In.ar(out, 2);
        ReplaceOut.ar(out, sig * vol);
    }).add;

    s.sync;

    // ========== TOUCH HANDLER FACTORIES ==========
    
    // Basic handler for plants 0-10
    ~makeBasicHandler = { |touchKey, bufIndex, bufferObj, oscPath, index|
        var onThresh = ~touchOnThresh[index];
        var offThresh = ~touchOffThresh[index];
        var deltaMin = ~touchDeltaMin[index];
       //var emaAlpha = 0.2;

        var ema = 0.0;
        var lastEma = 0.0;
        var pressed = false;
        var synth = nil;
        var ampMap = { |v|
            v.linlin(onThresh, 100.0, 0.1, 1.0).clip(0, 1)
        };

        OSCdef(touchKey, { |msg|
            var raw, risingEdge, fallingEdge;

            raw = (msg.size > 1 and: { msg[1].isNumber })
                .if({ msg[1].asFloat }, { 0.0 });

            lastEma = ema;
            // Initialize EMA with first non-zero value to avoid startup lag
            if (ema == 0.0 and: { raw > 0.1 }) {
                ema = raw;
            } {
                ema = (~emaAlpha * raw) + ((1 - ~emaAlpha) * lastEma);
            };
            
            risingEdge = (ema > onThresh) and: ((ema - lastEma) > deltaMin);
            fallingEdge = (ema < offThresh);

            if (risingEdge and: pressed.not) {
                pressed = true;

                if (synth.notNil) { synth.free };
                
                synth = Synth(\basicSampler, [
                    \bufnum, bufferObj.bufnum,
                    \amp, ampMap.(ema),
                    \rate, 1.0,
                    \atk, 0.005,
                    \rel, 0.25
                ]);

                synth.onFree({ synth = nil });

                    // (">>> " ++ touchKey ++ " TRIGGER: ema=%, amp=%"
                    //     .format(
                    //         ema.round(0.001),
                    //         ampMap.(ema).round(0.01)
                    //     )).postln;
               // };
            };
            
            if (pressed and: synth.notNil and: { synth.isPlaying }) {
                synth.set(\amp, ampMap.(ema));  // Update vibrato in real-time
            };
            
            if (pressed and: fallingEdge) {
                pressed = false;
                
                if (synth.notNil) {
                    synth.set(\gate, 0);
                };
                
                // ("<<< " ++ touchKey ++ " RELEASE").postln;
            };
        }, oscPath, recvPort: NetAddr.langPort);
    };
    
    // Money Plant handler (touch9) with pentatonic pitching
    ~makeMoneyPlantHandler = { |touchKey, bufIndex, bufferObj, oscPath, index|
        var onThresh = ~touchOnThresh[index];
        var offThresh = ~touchOffThresh[index];
        var deltaMin = ~touchDeltaMin[index];

        var ema = 0.0;
        var lastEma = 0.0;
        var pressed = false;
        var synth = nil;
        var currentNote = 36;
        var ampMap = { |v|
            0.9  // Fixed amplitude (not touch-sensitive)
        };

        var vibratoMap = { |v|
            v.linlin(onThresh, 100.0, 0.0, 1.0).clip(0, 1)  // 0-1 vibrato amount
        };

        OSCdef(touchKey, { |msg|

            var raw, risingEdge, fallingEdge, rate, potentialRisingEdge;
            raw = (msg.size > 1 and: { msg[1].isNumber })
                .if({ msg[1].asFloat }, { 0.0 });

            lastEma = ema;

            // Check for rising edge using raw value (before smoothing)
            potentialRisingEdge = (raw > onThresh) and: ((raw - ema) > deltaMin) and: pressed.not;

            // If rising edge detected, jump EMA to raw value for instant response
            if (potentialRisingEdge) {
                ema = raw;
            } {
                ema = (~emaAlpha * raw) + ((1 - ~emaAlpha) * ema);
            };

            risingEdge = potentialRisingEdge;
            fallingEdge = (ema < offThresh);

            if (risingEdge and: pressed.not) {
                pressed = true;
                currentNote = ~baseNote + ~moneyPlantNotes.choose;
                rate = (currentNote - ~baseNote).midiratio;

                if (synth.notNil) { synth.free };

                synth = Synth(\moneyPlant, [
                    \bufnum, bufferObj.bufnum,
                    \amp, 0.9,
                    \rate, rate,
                    \vibrato, vibratoMap.(ema),
                    \atk, 0.001,
                    \rel, 0.015
                ]);

                synth.onFree({ synth = nil });

                (">>> " ++ touchKey ++ " TRIGGER: note=%, rate=%, amp=%"
                    .format(
                        currentNote,
                        rate.round(0.001),
                        ampMap.(ema).round(0.01)
                    )).postln;
            };

            if (pressed and: synth.notNil and: { synth.isPlaying }) {
                synth.set(\vibrato, vibratoMap.(ema));
            };

            if (pressed and: fallingEdge) {
                pressed = false;
                ema = 0.0;  // Reset EMA so next touch starts fresh

                synth.set(\gate, 0);

                ("<<< " ++ touchKey ++ " RELEASE").postln;
            };
        }, oscPath, recvPort: NetAddr.langPort);
    };

    // Flower Plant handler (touch10) - kick with fa/sol pitching, no vibrato
    ~makeFlowerPlantHandler = { |touchKey, bufIndex, bufferObj, oscPath, index|
        var onThresh = ~touchOnThresh[index];
        var offThresh = ~touchOffThresh[index];
        var deltaMin = ~touchDeltaMin[index];

        var ema = 0.0;
        var lastEma = 0.0;
        var pressed = false;
        var synth = nil;
        var currentNote = 36;
        var ampMap = { |v|
            0.9  // Fixed amplitude (not touch-sensitive)
        };

        OSCdef(touchKey, { |msg|

            var raw, risingEdge, fallingEdge, rate, potentialRisingEdge;
            raw = (msg.size > 1 and: { msg[1].isNumber })
                .if({ msg[1].asFloat }, { 0.0 });

            lastEma = ema;

            // Check for rising edge using raw value (before smoothing)
            potentialRisingEdge = (raw > onThresh) and: ((raw - ema) > deltaMin) and: pressed.not;

            // If rising edge detected, jump EMA to raw value for instant response
            if (potentialRisingEdge) {
                ema = raw;
            } {
                ema = (~emaAlpha * raw) + ((1 - ~emaAlpha) * ema);
            };

            risingEdge = potentialRisingEdge;
            fallingEdge = (ema < offThresh);

            if (risingEdge and: pressed.not) {
                pressed = true;
                currentNote = ~baseNote + ~flowerPlantNotes.choose;
                rate = (currentNote - ~baseNote).midiratio;

                if (synth.notNil) { synth.free };

                synth = Synth(\flowerPlant, [
                    \bufnum, bufferObj.bufnum,
                    \amp, 0.9,
                    \rate, rate,
                    \atk, 0.001,
                    \rel, 0.015
                ]);

                synth.onFree({ synth = nil });

                (">>> " ++ touchKey ++ " TRIGGER: note=%, rate=%"
                    .format(
                        currentNote,
                        rate.round(0.001)
                    )).postln;
            };

            if (pressed and: fallingEdge) {
                pressed = false;
                ema = 0.0;  // Reset EMA so next touch starts fresh

                synth.set(\gate, 0);

                ("<<< " ++ touchKey ++ " RELEASE").postln;
            };
        }, oscPath, recvPort: NetAddr.langPort);
    };

    // Trumpet Plant handler (touch10) - major scale with pressure-based vibrato
    ~makeTrumpetHandler = { |touchKey, bufIndex, bufferObj, oscPath, index|
        var onThresh = ~touchOnThresh[index];
        var offThresh = ~touchOffThresh[index];
        var deltaMin = ~touchDeltaMin[index];

        var ema = 0.0;
        var lastEma = 0.0;
        var pressed = false;
        var synth = nil;
        var currentNote = 36;

        var vibratoMap = { |v|
            v.linlin(onThresh, 100.0, 0.0, 1.0).clip(0, 1)
        };

        OSCdef(touchKey, { |msg|
            var raw, risingEdge, fallingEdge, rate, potentialRisingEdge;
            raw = (msg.size > 1 and: { msg[1].isNumber })
                .if({ msg[1].asFloat }, { 0.0 });

            lastEma = ema;

            potentialRisingEdge = (raw > onThresh) and: ((raw - ema) > deltaMin) and: pressed.not;

            if (potentialRisingEdge) {
                ema = raw;
            } {
                ema = (~emaAlpha * raw) + ((1 - ~emaAlpha) * ema);
            };

            risingEdge = potentialRisingEdge;
            fallingEdge = (ema < offThresh);

            if (risingEdge and: pressed.not) {
                pressed = true;
                currentNote = (~baseNote - 12) + (~trumpetNotes.choose);
                rate = (currentNote - ~baseNote).midiratio;

                if (synth.notNil) { synth.free };

                synth = Synth(\trumpetPlant, [
                    \bufnum, bufferObj.bufnum,
                    \amp, 8.0,
                    \rate, rate,
                    \vibrato, vibratoMap.(ema),
                    \reverbBus, ~reverbBus,
                    \reverbSend, 0,
                    \atk, 0.7,
                    \dec, 0.3,
                    \sus, 0.1,
                    \rel, 0.01
                ]);

                synth.onFree({ synth = nil });

                (">>> " ++ touchKey ++ " TRIGGER: note=%, rate=%"
                    .format(currentNote, rate.round(0.001))).postln;
            };

            if (pressed and: synth.notNil and: { synth.isPlaying }) {
                synth.set(\vibrato, vibratoMap.(ema));
            };

            if (pressed and: fallingEdge) {
                pressed = false;
                ema = 0.0;

                synth.set(\gate, 0);

                ("<<< " ++ touchKey ++ " RELEASE").postln;
            };
        }, oscPath, recvPort: NetAddr.langPort);
    };

    // Strings Plant handler (touch11) - chord building based on pressure
    ~makeStringsPlantHandler = { |touchKey, bufIndex, bufferObj, oscPath, index|
        var onThresh = ~touchOnThresh[index];
        var offThresh = ~touchOffThresh[index];

        var stringsAtk  = 0.1;
        var stringsDec  = 1.5;  // time to decay from peak to sustain level
        var stringsSus  = 0.5;  // holds at 50% while held
        var stringsRel  = 0.5;
        var stringsAmp  = 0.1;

        var ema = 0.0;
        var rootSynth = nil;
        var thirdSynth = nil;
        var fifthSynth = nil;
        var octaveSynth = nil;
        var rootPlaying = false;
        var thirdPlaying = false;
        var fifthPlaying = false;
        var octavePlaying = false;

        // Thresholds for adding notes
        var rootThresh = 1.0;     // Root plays immediately on touch
        var thirdThresh = 15.0;   // Third added at 25%
        var fifthThresh = 40.0;   // Fifth added at 50%
        var octaveThresh = 60.0;  // Octave added at 75%

        OSCdef(touchKey, { |msg|
            var raw;
            raw = (msg.size > 1 and: { msg[1].isNumber })
                .if({ msg[1].asFloat }, { 0.0 });

            ema = (~emaAlpha * raw) + ((1 - ~emaAlpha) * ema);



            // Add root note when touch starts
            if ((ema > rootThresh) and: rootPlaying.not) {
                rootPlaying = true;
                // Free old synth if it exists
                if (rootSynth.notNil) { rootSynth.free };
                rootSynth = Synth(\stringsPlant, [
                    \bufnum, bufferObj.bufnum,
                    \amp, stringsAmp,
                    \rate, 1.0 * 0.5,  // Root note, octave down
                    \reverbBus, ~reverbBus, \reverbSend, 0,
                    \atk, stringsAtk, \dec, stringsDec, \sus, stringsSus, \rel, stringsRel
                ]);
                rootSynth.onFree({ rootSynth = nil; rootPlaying = false });
                (">>> " ++ touchKey ++ " ROOT added (ema=%)".format(ema.round(0.1))).postln;
            };

            // Add third when pressure increases
            if ((ema > thirdThresh) and: thirdPlaying.not and: rootPlaying) {
                thirdPlaying = true;
                // Free old synth if it exists
                if (thirdSynth.notNil) { thirdSynth.free };
                thirdSynth = Synth(\stringsPlant, [
                    \bufnum, bufferObj.bufnum,
                    \amp, stringsAmp-0.02,
                    \rate, 4.midiratio,  // Major third (4 semitones)
                    \reverbBus, ~reverbBus, \reverbSend, 0,
                    \atk, stringsAtk, \dec, stringsDec, \sus, stringsSus, \rel, stringsRel
                ]);
                thirdSynth.onFree({ thirdSynth = nil; thirdPlaying = false });
                (">>> " ++ touchKey ++ " THIRD added (ema=%)".format(ema.round(0.1))).postln;
            };

            // Add fifth when pressure increases more
            if ((ema > fifthThresh) and: fifthPlaying.not and: thirdPlaying) {
                fifthPlaying = true;
                // Free old synth if it exists
                if (fifthSynth.notNil) { fifthSynth.free };
                fifthSynth = Synth(\stringsPlant, [
                    \bufnum, bufferObj.bufnum,
                    \amp, stringsAmp-0.05,
                    \rate, 7.midiratio,  // Perfect fifth (7 semitones)
                    \reverbBus, ~reverbBus, \reverbSend, 0,
                    \atk, stringsAtk, \dec, stringsDec, \sus, stringsSus, \rel, stringsRel
                ]);
                fifthSynth.onFree({ fifthSynth = nil; fifthPlaying = false });
                (">>> " ++ touchKey ++ " FIFTH added (ema=%)".format(ema.round(0.1))).postln;
            };

            // Add octave at maximum pressure
            if ((ema > octaveThresh) and: octavePlaying.not and: fifthPlaying) {
                octavePlaying = true;
                // Free old synth if it exists
                if (octaveSynth.notNil) { octaveSynth.free };
                octaveSynth = Synth(\stringsPlant, [
                    \bufnum, bufferObj.bufnum,
                    \amp, stringsAmp-0.05,
                    \rate, 12.midiratio,  // Octave (12 semitones)
                    \reverbBus, ~reverbBus, \reverbSend, 0,
                    \atk, stringsAtk, \dec, stringsDec, \sus, stringsSus, \rel, stringsRel
                ]);
                octaveSynth.onFree({ octaveSynth = nil; octavePlaying = false });
                (">>> " ++ touchKey ++ " OCTAVE added (ema=%)".format(ema.round(0.1))).postln;
            };

            // Release all notes when hand lifts
            if (ema < offThresh) {
                if (rootPlaying) {
                    if (rootSynth.notNil) { rootSynth.free };
                    rootPlaying = false;
                };
                if (thirdPlaying) {
                    if (thirdSynth.notNil) { thirdSynth.free };
                    thirdPlaying = false;
                };
                if (fifthPlaying) {
                    if (fifthSynth.notNil) { fifthSynth.free };
                    fifthPlaying = false;
                };
                if (octavePlaying) {
                    if (octaveSynth.notNil) { octaveSynth.free };
                    octavePlaying = false;
                };
                ema = 0.0;
//                ("<<< " ++ touchKey ++ " ALL RELEASED").postln;
            };
        }, oscPath, recvPort: NetAddr.langPort);
    };

    // ---- REGISTER TOUCH HANDLERS ----
    12.do({ |i|
        var touchKey = ("touch" ++ i).asSymbol;
        var oscPath = "/touch" ++ i;

        if (i == 9) {
            // Touch9 = Money Plant with pentatonic
            ~makeMoneyPlantHandler.(
                touchKey, i, ~buffers[i], oscPath, i
            );
        } {
            if (i == 10) {
                // Touch10 = Trumpet Plant with major scale + vibrato
                ~makeTrumpetHandler.(
                    touchKey, i, ~buffers[i], oscPath, i
                );
            } {
                if (i == 11) {
                    // Touch11 = Strings Plant with chord building
                    ~makeStringsPlantHandler.(
                        touchKey, i, ~buffers[i], oscPath, i
                    );
                } {
                    // All others = Basic sampler
                    ~makeBasicHandler.(
                        touchKey, i, ~buffers[i], oscPath, i
                    );
                };
            };
        };
    });

    // Wait for server to fully stabilize before creating warmer synth
    s.sync;

    // Explicitly recreate default group in case server reconnected
    s.initTree;
    s.sync;

    // Start the warmer synth
    // ~warmerSynth = Synth(\warmer, [\amp, 0.01]);

    // Start shared reverb at tail of node tree (processes after all instruments)
    // ~reverbSynth = Synth(\reverbTail, [\reverbBus, ~reverbBus, \room, 20, \revtime, 5, \damp, 0.5], addAction: \addToTail);

    // Master volume — sits after reverb at very end of chain
    ~masterVolSynth = Synth(\masterVol, [\out, 0, \vol, ~totalVol], addAction: \addToTail);

    // OSC listener so Python can set master volume at runtime
    OSCdef(\masterVolHandler, { |msg|
        var vol = msg[1].clip(0.0, 1.0);
        ~totalVol = vol;
        ~masterVolSynth.set(\vol, vol);
        ("masterVol set to: " ++ vol).postln;
    }, '/masterVol');

    "✓ Ready! Listening on /touch0 through /touch11".postln;
});
)
