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

~touchOnThresh = [
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.0, 1.0, 3.0, 1.0, 1.0
];

~touchOffThresh = [
    0.5, 0.5, 0.5, 0.5, 0.5, 0.5,
    0.5, 0.5, 0.5, 0.5, 0.5, 0.5
];

~touchDeltaMin = [
    0.6, 0.6, 0.6, 0.6, 0.6, 0.6,
    0.6, 0.6, 0.6, 3.0, 0.6, 0.6  // Lowered touch9 from 2.0 to 0.8
];

~samplePaths = [
    "/home/pi/sc/moneyPlant.wav",
    "/home/pi/sc/moneyPlant.wav",
    "/home/pi/sc/moneyPlant.wav",
    "/home/pi/sc/moneyPlant.wav",
    "/home/pi/sc/moneyPlant.wav",
    "/home/pi/sc/moneyPlant.wav",
    "/home/pi/sc/moneyPlant.wav",
    "/home/pi/sc/moneyPlant.wav",
    "/home/pi/sc/moneyPlant.wav",
    "/home/pi/sc/moneyPlant.wav",
    "/home/pi/sc/moneyPlant.wav",
    "/home/pi/sc/moneyPlant.wav"
];

~baseNote = 24;
~emaAlpha = 0.8;  // Higher = more responsive (less smoothing)

// ========== END TUNING ==========

s.options.sampleRate = 48000;
s.options.numOutputBusChannels = 2;
s.options.numInputBusChannels = 0;  // No input needed
s.options.device = "hw:3";  // USB Audio card 3
s.options.blockSize = 128;        // Lower = more responsive (default is 64)
s.options.hardwareBufferSize = 128;  // Match JACK buffer

// Force JACK to use the correct device via inDevice/outDevice
s.options.inDevice = "hw:3";
s.options.outDevice = "hw:3";

//s.options.device = "system";


s.waitForBoot({

    // ===== OSC Debug =======
    //Print all incoming OSC messages
    // OSCFunc({ |msg, time, addr, recvPort|
    //     ("OSC received: " ++ msg).postln;
    // }, nil);  // nil means listen to all OSC paths
    
    
    
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
    ~majorPentatonic = [0, 2, 4, 7, 9, 12];
    
    ~getRandomPentatonicNote = { |v|
        var interval = ~majorPentatonic.choose;
        v + interval;
    };
    
    SynthDef(\moneyPlant, { |bufnum, amp=0.9, rate=1, gate=1, out=0, atk=0.001, rel=0.015, vibrato=0|
        var rateScale = BufRateScale.kr(bufnum) * rate;
        var vibLfo = SinOsc.kr(5, 0, vibrato * 0.05);  // 5Hz vibrato, max 5% rate variation
        var vibratingRate = rateScale * (1.0 + vibLfo);
        var src = PlayBuf.ar(1, bufnum, vibratingRate, gate, startPos: 0, loop: 0);
        var eg = EnvGen.kr(Env.asr(atk, 1.0, rel), gate, doneAction: 2);
        Out.ar(out, (src * eg * amp) ! 2);
    }).add;

    // Warmer synth - simple sine wave at 440Hz
    SynthDef(\warmer, { |out=0, amp=0.05|
        var sig = SinOsc.ar(440, 0, amp);
        Out.ar(out, sig ! 2);
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
        //var lastTriggerTime = 0;
        //var debounceTime = 0.01;  // 300ms minimum between triggers

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
                // Check debounce timer to prevent double-triggering
          //      if ((Main.elapsedTime - lastTriggerTime) > debounceTime) {
                pressed = true;
            //        lastTriggerTime = Main.elapsedTime;

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
        //var emaAlpha = 0.2;

        var ema = 0.0;
        var lastEma = 0.0;
        var pressed = false;
        var synth = nil;
        var currentNote = 36;
        //var lastTriggerTime = 0;
        //var debounceTime = 0.01;  // 300ms minimum between triggers

        var ampMap = { |v|
            0.9  // Fixed amplitude (not touch-sensitive)
        };

        var vibratoMap = { |v|
            v.linlin(onThresh, 100.0, 0.0, 1.0).clip(0, 1)  // 0-1 vibrato amount
        };

        OSCdef(touchKey, { |msg|

            var raw, risingEdge, fallingEdge, rate, potentialRisingEdge;
            // (msg).postln;
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
                currentNote = ~getRandomPentatonicNote.(~baseNote);
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

                // Release the synth (but don't free it)
                synth.set(\gate, 0);

                ("<<< " ++ touchKey ++ " RELEASE").postln;
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
            // All others = Basic sampler
            ~makeBasicHandler.(
                touchKey, i, ~buffers[i], oscPath, i
            );
        };
    });

    // Start the warmer synth
    ~warmerSynth = Synth(\warmer, [\amp, 0.001]);

    "✓ Ready! Listening on /touch0 through /touch11".postln;
});
)
