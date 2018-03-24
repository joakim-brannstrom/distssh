/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import eventcore.socket;
import std.socket : parseAddress;
import core.time : Duration, msecs;

ubyte[256] s_rbuf;
bool s_done;

void main()
{
	// (hopefully) non-existant host, so that the connection times out
	auto baddr = parseAddress("192.0.2.1", 1);

	auto sock = eventDriver.sockets.connectStream(baddr, null, (sock, status) {
		assert(false, "Connection callback should not have been called.");
	});
	assert(sock != StreamSocketFD.invalid, "Expected connection to be in progress.");
	assert(eventDriver.sockets.getConnectionState(sock) == ConnectionState.connecting);

	auto tm = eventDriver.timers.create();
	eventDriver.timers.set(tm, 100.msecs, 0.msecs);
	eventDriver.timers.wait(tm, (tm) {
		assert(eventDriver.sockets.getConnectionState(sock) == ConnectionState.connecting);
		eventDriver.sockets.cancelConnectStream(sock);
		s_done = true;
	});

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;
}
