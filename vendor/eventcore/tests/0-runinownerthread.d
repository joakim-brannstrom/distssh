/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import core.thread;
import std.stdint;

intptr_t s_id; // thread-local

void main()
{
	auto ed = cast(shared)eventDriver;

	auto thr = new Thread({ threadFunc(ed); });
	thr.start();

	// keep the event loop running for one second
	auto tm = eventDriver.timers.create();
	eventDriver.timers.set(tm, 1.seconds, 0.seconds);

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);

	assert(s_id == 42);
}

void threadFunc(shared(NativeEventDriver) drv)
{
	drv.core.runInOwnerThread((id) {
		s_id = id;
	}, 42);
}
