(
// -------- AUDIO / SERVER OPTIONS --------
s.options.device = "hw:2,0";       // make sure this is your card (aplay -l)
s.options.sampleRate = 48000;
s.options.numOutputBusChannels = 2;

s.waitForBoot({
    // -------- LOAD SAMPLE (mono -> stereo) --------
    ~samplePath = "/home/pi/sc/Trumpet.wav";
    b = Buffer.readChannel(s, ~samplePath, channels: [0]);  // take left channel only
    s.sync;  // wait for buffer to be ready

    // -------- ONE-SHOT PLAYER --------
    // New Synth each time -> guaranteed retrigger & auto-free when done.
    SynthDef(\oneshot, { |bufnum, amp=0.5, rate=1, out=0|
        var sig = PlayBuf.ar(1, bufnum, rate, trig: 1, startPos: 0, doneAction: 2);
        sig = sig * amp;
        Out.ar(out, sig ! 2);  // duplicate to stereo
    }).add;

    // -------- EDGE DETECTION SETTINGS --------
    ~onThresh    = 10.45;   // must rise above this to count as a touch
    ~offThresh   = 10.30;   // must fall below this to re-arm
    ~deltaThresh = 0.08;   // must be a "big" positive jump (filters small noise)
    ~lastVal     = 0.0;
    ~armed       = true;   // ready to trigger

    // Map sensor value to amplitude (tweak to taste)
    ~ampMap = { |val|
        val.linlin(~onThresh, 1.0, 0.12, 1.0).clip(0.0, 1.0)
    };

    // -------- LISTENER: /touch1 with 1 float arg --------
    OSCdef(\touch1, { |msg, time, addr, recvPort|
        var val = (msg.size > 1 and: { msg[1].isNumber }).if({ msg[1].asFloat }, { 0.0 });
        var risingBig = (val - ~lastVal) > ~deltaThresh;

        // Optional: print every value (comment out if too chatty)
        // ("touch1: " ++ val).postln;

        // Arm/disarm logic with hysteresis + delta
        if (~armed and: { val > ~onThresh } and: { risingBig }) {
            // Trigger once
            Synth(\oneshot, [\bufnum, b, \amp, ~ampMap.(val)]);
            ("TRIGGER /touch1  val:%  amp:%".format(val, ~ampMap.(val))).postln;
            ~armed = false;
        } {
            // Re-arm when it cools off
            if (val < ~offThresh) { ~armed = true; };
        };

        ~lastVal = val;
    }, '/touch1', recvPort: NetAddr.langPort);

    "Ready: /touch1 on %, sample '%', armed=%"
        .format(NetAddr.langPort, ~samplePath, ~armed).postln;
});
)
