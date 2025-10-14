(
// ---------- CONFIG ----------
s.options.numOutputBusChannels = 2;           // stereo
s.options.sampleRate = 48000;                 // match your card if needed
s.options.device = "hw:2,0";               // uncomment/set if you need a specific device name

// ---------- BOOT ----------
s.waitForBoot({
    // Define a simple synth we can trigger
    SynthDef(\ping, { |freq=440, amp=0.1, pan=0|
        var env = Env.perc(0.001, 0.3, amp).ar(doneAction:2);
        var sig = SinOsc.ar(freq) * env;
        Out.ar(0, Pan2.ar(sig, pan));
    }).add;

    // Map touch IDs to pitches (just an example)
    ~touchToFreq = { |id| [220, 247, 262, 294, 330, 349, 392, 440, 494, 523, 587, 659].wrapAt(id) };

    // Listen for /touch messages: /touch <id:int> <value:int-or-float>
    // Example: id = electrode index, value = 1 for touched, 0 for released
    OSCdef(\touchHandler, { |msg, time, addr, recvPort|
        var id    = msg[1].asInteger;
        var val   = msg[2].asFloat;
        if (val > 0) {
            var f = ~touchToFreq.(id);
            Synth(\ping, [\freq, f, \amp, 0.12, \pan, (id%8-4)/4]); // pan by id a bit
        };
    }, '/touch1', recvPort: NetAddr.langPort); // NetAddr.langPort == 57120 by default

    "SuperCollider started; waiting for /touch1 on port %".format(NetAddr.langPort).postln;
});
)

// Optional: force a reboot of the server if needed
// s.reboot;
