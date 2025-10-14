(
// ======== TUNING PARAMETERS ===========
//Per-instrument settings: indices 0-11 (touch0 to touch11)

~touchOnThresh = [
	3.0, 3.0, 3.0, 3.0, 3.0, 3.0, 
	3.0, 3.0, 3.0, 3.0, 3.0, 3.0
];

~touchOffThresh = [
	0.5, 0.5, 0.5, 0.5, 0.5, 0.5,
	0.5, 0.5, 0.5, 0.5, 0.5, 0.5
];

~touchDeltaMin = [
	0.6, 0.6, 0.6, 0.6, 0.6, 0.6,
	0.6, 0.6, 0.6, 0.6, 0.6, 0.6
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

~baseNote = 36;

// ============ END TUNING ============
	
s.options.sampleRate = 48000;
s.options.numOutputBusChannels = 2;
s.options.device = "Audio";

s.waitForBoot({
	//----LOAD SAMPLES----
	~buffers = ();
	~samplePaths.do({ | path i |
		~buffers[i] = Buffer.readChannel(s, path, channels: [0]);	
	});

	s.sync;

	//====== SYNTH DEFINITIONS ==== 
	
	// Basic Sampler Synth (stand-in)
	SynthDef(\basicSampler, {|bufnum, amp=0.3, rate=1, gate=1, out=0, atk=0.005, rel=0.25|
		var rateScale = BufRateScale.kr(bufnum)*rate;
		var src = PlayBuf.ar(1, bufnum, rateScale, startPos: 0, loop: 0);
		var eg = EnvGen.kr(Env.asr(atk, 1.0, rel), gate, doneAction: 2);
		Out.ar(out, (src*eg*amp) !2 ); 
	}).add;

	//Money Plant Synth with pentatonic pitching
	~majorPentatonic = [0, 2, 4, 7, 9, 12, 14, 16, 19, 21, 24];

	~getRandomPentatonicNote = { |v|
		var interval = ~majorPentatonic.choose;
		v + interval;
	};

	SynthDef(\moneyPlant, {|bufnum, amp=0.9, rate=1, gate=1, out=0, atk=0.01, rel=0.25|
		var rateScale = BufRateScale.kr(bufnum )* rate;
		var src = PlayBuf.ar(1, bufnum, rateScale, startPos: 0, loop: 0);
		var eg = EnvGen.kr(Env.asr(atk, 1.0, rel), gate, doneAction: 2);
		Out.ar(out, (src*eg*amp) !2);
	}).add;


	// ====== TOUCH HANDLERS =======
	
	//Basic handler for plants 0-10, stand-in
	~makeBasicHandler = { |touchKey, bufIndex, bufferObj, oscPath, index|
		var onThresh = ~touchOnThresh[index];
		var offThres = ~touchOffThresh[index];
		var deltaMin = ~touchDeltaMin[index];
		var emaAlpha = 0.2;
		
		var ema = 0.0;
		var lastEma = 0.0;
		var pressed = false;
		var synth = nil;

		var ampMap = {|v|
			v.linlin(onThresh, 100.0, 0.1, 1.0).clip(0,1)
		};

		OSCdef(touchKey, {|msg|
			var raw, risingEdge, fallingEdge;

			raw = (msg.size > 1 and: {msg[1].isNumber})
				.if({msg[i].asFloat}, {0.0});

			lastEma = ema;
			ema = (emaAlpha*raw) + ((1-emaAlpha)*lastEma);

			risingEdge = (ema > onThresh) and: ((ema-lastEma)>deltaMin);
			fallingEdge = (ema<offThres);

			if (risingEdge and: pressed.not){
				pressed = true;

				if (synth.notNil){synth.free};

				synth = Synth(\basicSampler, [
					\bufnum, bufferObj.bufnum,
					\amp, ampMap.(ema),
					\rate, 1.0,
					\atk, 0.005,
					\rel, 0.25
				]);

				synth.onFree({synth = nil});

				(">>> " ++ touchKey ++ " TRIGGER: ema=%, amp=%"
					.format(
						ema.round(0.001),
						ampMap.(ema).round(0.01)
					)
				).postln;
			};


			if (pressed and: synth.notNil) {
				synth.set(\amp, ampMap.(ema));
			};

			if (pressed and: fallingEdge){
				pressed = false;

				if (synth.notNil) {
					synth.set(\gate, 0);
				};

				("<<< " ++ touchKey ++ " RELEASE").postln;

			};

		}, oscPath, recvPort: NetAddr.langPort);

	};


	// Money Plant Handler (touch 9) with pentatonic pitching
	~makeMoneyPlantHandler = { |touchKey, bufIndex, bufferObj, oscPath, index|
		var onThresh = ~touchOnThresh[index];
		var offThresh = ~touchOffThresh[index];
		var deltaMin = ~touchDeltaMin[index];
		var emaAlpha = 0.2;
		var rate = 1.0;

		var ema = 0.0;
		var lastEma = 0.0;
		var pressed = false;
		var synth = nil;
		var currentNote = 36;

		var ampMap = {|v|
			0.9             //fixed amp
		};

		var vibratoMap = {|v|
			v.linlin(onThresh, 100.0, 0.0, 1.0).clip(0,1) //vibratoAmount

		};

		OSCdef(touchKey, {|msg|
			var raw, risingEdge, fallingEdge;

			raw = (msg.size>1 and: {msg[1].isNumber})
				.if({msg[1].asFloat}, {0.0});

			lastEma = ema;
			ema = (emaAlpha*raw) + ((1-emaAlpha)*lastEma);

			risingEdge = (ema>onThresh) and: ((ema-lastEma)>deltaMin);
			fallingEdge = (ema<offThresh);

			if (risingEdge and: pressed.not) {
				pressed = true;
				currentNote = ~getRandomPentatonicNote.(~baseNote);
				rate = (currentNote - ~baseNote).midiratio;

				if (synth.notNil) {synth.free};

				synth = Synth(\moneyPlant, [
					\bufnum, bufferObj.bufnum,
					\amp, ampMap.(ema),
					\rate, rate,
					\vibrato, vibratoMap.(ema),
					\atk, 0.01,
					\rel, 0.25
				]);

				synth.onFree({synth = nil});

				(">>> " ++ touchKey ++ " TRIGGER: note=%, rate=%, amp=%"
					.format(
						currentNote,
						rate,round(0.001),
						ampMap.(ema).round(0.01)
					)
				).postln;

			};

			if (pressed and: synth.notNil){
				synth.set(\vibrato, vibratoMap.(ema));
				synth.set(\amp, ampMap.(ema));
			};

			if (pressed and: fallingEdge){
				pressed = false;

				if (synth.notNil){
					synth.set(\gate, 0);
				};

				("<<< " ++ touchKey ++ " RELEASE").postln;
			};

		}, oscPath, recvPort: NetAddr.langPort);

	};

	// ======== REGISTER TOUCH HANDLERS ======

	12.do({
		var touchKey = ("touch" ++ i).asSymbol;
		var oscPath = "/touch" ++ i;

		
		if (i==9) {
			//touch9 - moneyPlant with pentatonic
			~makeMoneyPlantHandler.(touchKey, i, ~buffers[i], oscPath, i);

		} {
			//all others - basicSampler
			~makeBasicHandler.(touchKey, i, ~buffers[i], oscPath, i);
		};
	});

	"Ready! Listening on /touch0 through /touch11".postln;

});
)
