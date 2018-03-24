/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import std.stdio : writefln;
import core.stdc.signal;
import core.time : Duration, msecs;
import core.thread : Thread;

bool s_done;
shared EventDriverEvents ss_evts;

// TODO: adjust to detect premature loop exit if only an event wait is active (no timer)

void test(bool notify_all)
{
	auto id = eventDriver.events.create();
	auto tm = eventDriver.timers.create();

	eventDriver.events.wait(id, (id) {
		assert(!s_done);

		eventDriver.events.wait(id, (id) {
			assert(!s_done);
			s_done = true;
			eventDriver.timers.cancelWait(tm);
		});
	});

	eventDriver.timers.set(tm, 500.msecs, 0.msecs);
	eventDriver.timers.wait(tm, (tm) {
		eventDriver.events.trigger(id, notify_all);
		eventDriver.timers.set(tm, 500.msecs, 0.msecs);
		eventDriver.timers.wait(tm, (tm) @trusted {
			scope (failure) assert(false);
			new Thread({
				ss_evts.trigger(id, notify_all);
			}).start();

			eventDriver.timers.set(tm, 500.msecs, 0.msecs);
			eventDriver.timers.wait(tm, (tm) @trusted {
				assert(false, "Test hung.");
			});
		});
	});

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;
}

void main()
{
	ss_evts = cast(shared)eventDriver.events;
	test(false);
	test(true);
}

void log(string s)
@safe nothrow {
	import std.stdio : writeln;
	scope (failure) assert(false);
	writeln(s);
}
