/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
	debugVersions "EventCoreLogDNS"
+/
module test;

import eventcore.core;
import std.stdio : writefln;
import core.time : Duration;

bool s_done;

void main()
{
	eventDriver.dns.lookupHost("example.org", (id, status, scope addrs) {
		assert(status == DNSStatus.ok);
		assert(addrs.length >= 1);
		foreach (a; addrs) {
			try writefln("addr %s (%s)", a.toAddrString(), a.toPortString());
			catch (Exception e) assert(false, e.msg);
		}
		s_done = true;
	});

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;
}
