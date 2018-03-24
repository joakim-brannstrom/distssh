/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import eventcore.socket;
import std.socket : InternetAddress;
import core.time : Duration, msecs;

ubyte[256] s_rbuf;
bool s_done;

void main()
{
	version (OSX) {
		import std.stdio;
		writeln("This doesn't work on macOS. Skipping this test until it is determined that this special case should stay supported.");
		return;
	} else {
	
	static ubyte[] pack1 = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];

	auto baddr 	= new InternetAddress(0x7F000001, 40002);
	auto server = listenStream(baddr);
	StreamSocket client;
	StreamSocket incoming;

	server.waitForConnections!((incoming_, addr) {
		incoming = incoming_; // work around ref counting issue
		incoming.read!((status, bts) {
			assert(status == IOStatus.ok);
			assert(bts == 0);

			incoming.read!((status, bts) {
			import std.stdio; try writefln("status %s", status); catch (Exception e) assert(false, e.msg);
				assert(status == IOStatus.ok);
				assert(bts == pack1.length);
				assert(s_rbuf[0 .. bts] == pack1);

				destroy(incoming);
				destroy(server);
				destroy(client);
				s_done = true;
			})(s_rbuf, IOMode.immediate);
		})(s_rbuf[0 .. 0], IOMode.once);
	});

	connectStream!((sock, status) {
		assert(status == ConnectStatus.connected);
		client = sock;

		auto tm = eventDriver.timers.create();
		eventDriver.timers.set(tm, 100.msecs, 0.msecs);
		eventDriver.timers.wait(tm, (tm) {
			client.write!((wstatus, bytes) {
				assert(wstatus == IOStatus.ok);
				assert(bytes == 10);
			})(pack1, IOMode.all);
		});
	})(baddr);

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;

	}
}
