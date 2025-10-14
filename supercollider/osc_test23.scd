// Simple test: just listen for /touch11
(
OSCdef(\testTouch, { |msg|
    ("RECEIVED: " ++ msg).postln;
}, "/touch11");

"Listening on /touch11 - try touching!".postln;
)
