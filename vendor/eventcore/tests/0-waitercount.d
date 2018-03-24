/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import core.stdc.signal;
import core.time : Duration, msecs;
import core.thread : Thread;


void test(Duration timeout)
{
	while (true) {
		auto reason = eventDriver.core.processEvents(timeout);
		final switch (reason) with (ExitReason) {
			case exited: assert(false, "Manual exit without call to exit()!?");
			case timeout: assert(false, "Event loop timed out, although no waiters exist!?");
			case idle: break;
			case outOfWaiters: return;
		}
	}
}

void main()
{
	assert(eventDriver.core.waiterCount == 0, "Initial waiter count not 0!");
	test(100.msecs);
	assert(eventDriver.core.waiterCount == 0, "Waiter count after outOfWaiters not 0!");
	test(Duration.max);
	assert(eventDriver.core.waiterCount == 0);
}
