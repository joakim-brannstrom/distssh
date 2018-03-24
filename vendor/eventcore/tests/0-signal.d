/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import std.stdio : writefln;
import core.stdc.signal;
import core.sys.posix.signal : SIGUSR1;
import core.time : Duration, msecs;

bool s_done;

void main()
{
	version (OSX) writefln("Signals are not yet supported on macOS. Skipping test.");
	else {

	auto id = eventDriver.signals.listen(SIGUSR1, (id, status, sig) {
		assert(!s_done);
		assert(status == SignalStatus.ok);
		assert(sig == () @trusted { return SIGUSR1; } ());
		eventDriver.signals.releaseRef(id);
		s_done = true;
	});

	auto tm = eventDriver.timers.create();
	eventDriver.timers.set(tm, 500.msecs, 0.msecs);
	eventDriver.timers.wait(tm, (tm) {
		() @trusted { raise(SIGUSR1); } ();
	});

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;

	}
}
