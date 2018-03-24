/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import std.datetime : Clock, SysTime, UTC;
import std.stdio : writefln;
import core.time : Duration, msecs;

SysTime s_startTime;
int s_cnt = 0;
bool s_done;

void main()
{
	s_startTime = Clock.currTime(UTC());

	bool timer1fired = false;

	// first timer: one-shot 200ms
	auto tm = eventDriver.timers.create();
	eventDriver.timers.wait(tm, (tm) nothrow @safe {
		try {
			writefln("First timer");
			auto dur = Clock.currTime(UTC()) - s_startTime;

			assert(dur >= 1200.msecs, (dur - 1200.msecs).toString());
			assert(dur < 1300.msecs, (dur - 1200.msecs).toString());

			timer1fired = true;
		} catch (Exception e) {
			assert(false, e.msg);
		}
	});
	eventDriver.timers.set(tm, 1200.msecs, 0.msecs);

	// second timer repeating 300ms, 5 times
	auto tm2 = eventDriver.timers.create();
	eventDriver.timers.set(tm2, 300.msecs, 300.msecs);
	void periodicCallback(TimerID timer) nothrow @safe {
		try {
			writefln("Second timer");

			auto dur = Clock.currTime(UTC()) - s_startTime;
			s_cnt++;
			assert(dur > 300.msecs * s_cnt, (dur - 300.msecs * s_cnt).toString());
			assert(dur < 300.msecs * s_cnt + 100.msecs, (dur - 300.msecs * s_cnt).toString());
			assert(s_cnt <= 5);

			if (s_cnt == 5) {
				s_done = true;
				eventDriver.timers.stop(timer);
				assert(timer1fired, "Timer 1 didn't fire within 300ms");
			} else eventDriver.timers.wait(tm2, &periodicCallback);
		} catch (Exception e) {
			assert(false, e.msg);
		}
	}

	eventDriver.timers.wait(tm2, &periodicCallback);


	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;
}
