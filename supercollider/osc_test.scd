(
// Boot the audio server (not strictly necessary just to print)
s.waitForBoot({
    // Listen for OSC messages with address /touch1
    OSCdef(\touch11Printer, { |msg, time, addr, recvPort|
        // msg[0] is the address string "/touch1"
        // msg[1] should be your float
        ("Received value: " ++ msg).postln;
    }, '/touch10', recvPort: NetAddr.langPort);

//    OSCdef(\touch10Printer, { |msg, time, addr, recvPort|
//	("Received value: " ++ msg).postln;
//    }, '/touch10', recvPort: NetAddr.landPort);

    "Ready: listening on port %".format(NetAddr.langPort).postln;
});
)
