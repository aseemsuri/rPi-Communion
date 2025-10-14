(
// ---- AUDIO / SERVER OPTIONS ----


s.options.sampleRate = 48000;
s.options.numOutputBusChannels = 2;


s.waitForBoot({
    // ---- LOAD SAMPLES ----
    ~trumpetPath = "/home/pi/sc/Trumpet.wav";
    ~kickPath = "/home/pi/sc/Kick.wav";
    ~moneyPlantPath = "/home/pi/sc/moneyPlant.wav";

    ~buffers = ();
    ~buffers[\trumpet] = Buffer.readChannel(s, ~trumpetPath, channels: [0]);
    ~buffers[\kick] = Buffer.readChannel(s, ~kickPath, channels: [0]);
    ~buffers[\moneyPlant] = Buffer.readChannel(s, ~moneyPlantPath, channels: [0]);

    s.sync;
    
    // ---- PLAYER SYNTH ----
    SynthDef(\playerGate, { |bufnum, amp=0.3, rate=1, gate=1, out=0, atk=0.005, rel=0.25, loop=0|
        var rateScale = BufRateScale.kr(bufnum) * rate;
        var src = PlayBuf.ar(1, bufnum, rateScale, startPos: 0, loop: loop);
        var eg = EnvGen.kr(Env.asr(atk, 1.0, rel), gate, doneAction: 2);
        Out.ar(out, (src * eg * amp) ! 2);
    }).add;
    
    // ---- TOUCH HANDLER FACTORY ----
    ~makeTouchHandler = { |touchKey, bufKey, bufferObj, oscPath|
        var onThresh = 1.0;           // Threshold to trigger
        //Raise it to require more pressure before triggering (less sensitive). 
	//Lower it to trigger on light touch (more sensitive). 
	//Try values like 2.0–5.0.

	var offThresh = 0.8;          // Threshold to release
        //How far the value needs to drop to register a release. 
	//Lower values = faster release detection.

	var deltaMin = 2.0;           // Min change to trigger (avoid noise)
	//The minimum change needed to count as a "real" touch vs. noise. 
	//Lower = more sensitive to subtle touches, but more false triggers.
       
	 var emaAlpha = 0.6;           // EMA smoothing factor
        
        var ema = 0.0;
        var lastEma = 0.0;
        var pressed = false;
        var synth = nil;
        
        var ampMap = { |v|
            v.linlin(onThresh, 100.0, 0.1, 1.0).clip(0, 1)
        };
        
        OSCdef(touchKey, { |msg|
            var raw, risingEdge, fallingEdge;
            
            // Extract OSC value safely
            raw = (msg.size > 1 and: { msg[1].isNumber })
                .if({ msg[1].asFloat }, { 0.0 });
            
            // EMA smoothing
            lastEma = ema;
            ema = (emaAlpha * raw) + ((1 - emaAlpha) * lastEma);
            
            // Edge detection
            risingEdge = (ema > onThresh) and: ((ema - lastEma) > deltaMin);
            fallingEdge = (ema < offThresh);
            
            // ---- RISING EDGE: Start playback ----
            if (risingEdge and: pressed.not) {
                pressed = true;
                
                if (synth.notNil) { synth.free };
                
                synth = Synth(\playerGate, [
                    \bufnum, bufferObj.bufnum,
                    \amp, 1.0, //+ampMap.(ema),
                    \atk, 0.005,
                    \rel, 0.25,
                    \loop, 0
                ]);
                
                synth.onFree({ synth = nil });
                
                (">>> " ++ touchKey ++ " TRIGGER: ema=%, amp=%"
                    .format(
                        ema.round(0.001),
                        ampMap.(ema).round(0.01)
                    )).postln;
            };
            
            // ---- WHILE HELD: Update amplitude ----
            //if (pressed and: synth.notNil) {
            //    synth.set(\amp, ampMap.(ema));
            //};
            
            // ---- FALLING EDGE: Release playback ----
            if (pressed and: fallingEdge) {
                pressed = false;
                
                if (synth.notNil) {
                    synth.set(\gate, 0);
                };
                
                ("<<< " ++ touchKey ++ " RELEASE: ema=%"
                    .format(ema.round(0.001))).postln;
            };
        }, oscPath, recvPort: NetAddr.langPort);
    };
    
    // ---- REGISTER TOUCH HANDLERS ----
    // Format: touchKey, bufKey, buffer object, OSC path
    ~makeTouchHandler.(
        \touch10, \kick, ~buffers[\kick], "/touch10"
    );
    
    ~makeTouchHandler.(
        \touch11, \moneyPlant, ~buffers[\moneyPlant], "/touch11"
    );
    
    "✓ Ready! Listening on /touch10 (kick) and /touch11 (moneyPlant)".postln;
    "  Touch sensitivity can be tuned in ~makeTouchHandler".postln;
});
)
