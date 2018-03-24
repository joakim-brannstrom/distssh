/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import std.stdio : File, writefln;
import std.file : exists, mkdir, remove, rmdirRecurse;
import core.time : Duration, msecs;

bool s_done;
int s_cnt = 0;

enum testDir = "watcher_test";
enum testFilename = "test.dat";

void main()
{
	if (exists(testDir))
		rmdirRecurse(testDir);
	mkdir(testDir);
	scope (exit) rmdirRecurse(testDir);

	auto id = eventDriver.watchers.watchDirectory(testDir, false, (id, ref change) {
		switch (s_cnt++) {
			default:
				import std.conv : to;
				assert(false, "Unexpected change: "~change.to!string);
			case 0:
				assert(change.kind == FileChangeKind.added);
				assert(change.baseDirectory == testDir);
				assert(change.directory == "");
				assert(change.name == testFilename);
				break;
			case 1:
				assert(change.kind == FileChangeKind.modified);
				assert(change.baseDirectory == testDir);
				assert(change.directory == "");
				assert(change.name == testFilename);
				break;
			case 2:
				assert(change.kind == FileChangeKind.removed);
				assert(change.baseDirectory == testDir);
				assert(change.directory == "");
				assert(change.name == testFilename);
				eventDriver.watchers.releaseRef(id);
				s_done = true;
				break;
		}
	});

	auto fil = File(testDir~"/"~testFilename, "wt");

	auto tm = eventDriver.timers.create();
	eventDriver.timers.set(tm, 1500.msecs, 0.msecs);
	eventDriver.timers.wait(tm, (tm) {
		scope (failure) assert(false);
		fil.write("test");
		fil.close();
		eventDriver.timers.set(tm, 1500.msecs, 0.msecs);
		eventDriver.timers.wait(tm, (tm) {
			scope (failure) assert(false);
			remove(testDir~"/"~testFilename);
		});
	});

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;
}
