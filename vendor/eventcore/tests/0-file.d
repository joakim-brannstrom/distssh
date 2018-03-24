/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
	debugVersions "EventCoreLogFiles"
+/
module test;

import eventcore.core;
import eventcore.socket;
import std.file : remove;
import std.socket : InternetAddress;
import core.time : Duration, msecs;

bool s_done;

void main()
{
	auto f = eventDriver.files.open("test.txt", FileOpenMode.createTrunc);
	assert(eventDriver.files.getSize(f) == 0);
	auto data = cast(const(ubyte)[])"Hello, World!";

	eventDriver.files.write(f, 0, data[0 .. 7], IOMode.all, (f, status, nbytes) {
		assert(status == IOStatus.ok);
		assert(nbytes == 7);
		assert(eventDriver.files.getSize(f) == 7);
		eventDriver.files.write(f, 5, data[5 .. $], IOMode.all, (f, status, nbytes) {
			assert(status == IOStatus.ok);
			assert(nbytes == data.length - 5);
			assert(eventDriver.files.getSize(f) == data.length);
			auto dst = new ubyte[data.length];
			eventDriver.files.read(f, 0, dst[0 .. 7], IOMode.all, (f, status, nbytes) {
				assert(status == IOStatus.ok);
				assert(nbytes == 7);
				assert(dst[0 .. 7] == data[0 .. 7]);
				eventDriver.files.read(f, 5, dst[5 .. $], IOMode.all, (f, status, nbytes) {
					assert(status == IOStatus.ok);
					assert(nbytes == data.length - 5);
					assert(dst == data);
					eventDriver.files.close(f);
					() @trusted {
						scope (failure) assert(false);
						remove("test.txt");
					} ();
					eventDriver.files.releaseRef(f);
					s_done = true;
				});
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
