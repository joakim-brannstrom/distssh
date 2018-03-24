/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import eventcore.internal.utils : print;
import core.thread : Thread;
import core.time : Duration, msecs;
import std.file : exists, remove, rename, rmdirRecurse, mkdir;
import std.format : format;
import std.functional : toDelegate;
import std.path : baseName, buildPath, dirName;
import std.stdio : File, writefln;
import std.array : replace;

bool s_done;
int s_cnt = 0;

enum testDir = "watcher_test";

WatcherID watcher;
FileChange[] pendingChanges;


void main()
{
	if (exists(testDir))
		rmdirRecurse(testDir);

	mkdir(testDir);
	mkdir(testDir~"/dira");

	// test non-recursive watcher
	watcher = eventDriver.watchers.watchDirectory(testDir, false, toDelegate(&testCallback));
	assert(watcher != WatcherID.invalid);
	Thread.sleep(400.msecs); // some watcher implementations need time to initialize
	testFile(     "file1.dat");
	testFile(     "file2.dat");
	testFile(     "dira/file1.dat", false);
	testCreateDir("dirb");
	testFile(     "dirb/file1.dat", false);
	testRemoveDir("dirb");
	eventDriver.watchers.releaseRef(watcher);
	testFile(     "file1.dat", false);
	testRemoveDir("dira", false);
	testCreateDir("dira", false);

	// test recursive watcher
	watcher = eventDriver.watchers.watchDirectory(testDir, true, toDelegate(&testCallback));
	assert(watcher != WatcherID.invalid);
	Thread.sleep(400.msecs); // some watcher implementations need time to initialize
	testFile(     "file1.dat");
	testFile(     "file2.dat");
	testFile(     "dira/file1.dat");
	testCreateDir("dirb");
	testFile(     "dirb/file1.dat");
	testRename(   "dirb", "dirc");
	testFile(     "dirc/file2.dat");
	eventDriver.watchers.releaseRef(watcher);
	testFile(     "file1.dat", false);
	testFile(     "dira/file1.dat", false);
	testFile(     "dirc/file1.dat", false);
	testRemoveDir("dirc", false);
	testRemoveDir("dira", false);

	rmdirRecurse(testDir);

	// make sure that no watchers are registered anymore
	auto er = eventDriver.core.processEvents(10.msecs);
	assert(er == ExitReason.outOfWaiters);
}

void testCallback(WatcherID w, in ref FileChange ch)
@safe nothrow {
	assert(w == watcher, "Wrong watcher generated a change");
	pendingChanges ~= ch;
}

void expectChange(FileChange ch, bool expect_change)
{
	import std.datetime : Clock, UTC;

	auto starttime = Clock.currTime(UTC());
	again: while (!pendingChanges.length) {
		auto er = eventDriver.core.processEvents(10.msecs);
		switch (er) {
			default: assert(false, format("Unexpected event loop exit code: %s", er));
			case ExitReason.idle: break;
			case ExitReason.timeout:
				assert(!pendingChanges.length);
				break;
			case ExitReason.outOfWaiters:
				assert(!expect_change, "No watcher left, but expected change.");
				return;
		}
		if (!pendingChanges.length && Clock.currTime(UTC()) - starttime >= 2000.msecs) {
			assert(!expect_change, format("Got no change, expected %s.", ch));
			return;
		}
	}
	assert(expect_change, "Got change although none was expected.");

	auto pch = pendingChanges[0];

	// adjust for Windows behavior
	pch.directory = pch.directory.replace("\\", "/");
	pch.name = pch.name.replace("\\", "/");
	pendingChanges = pendingChanges[1 .. $];
	if (pch.kind == FileChangeKind.modified && (pch.name == "dira" || pch.name == "dirb"))
		goto again;

	// test all field excep the isDir one, which does not work on all systems
	assert(pch.kind == ch.kind && pch.baseDirectory == ch.baseDirectory &&
		pch.directory == ch.directory && pch.name == ch.name,
		format("Unexpected change: %s vs %s", pch, ch));
}

void testFile(string name, bool expect_change = true)
{
print("test %s CREATE %s", name, expect_change);
	auto fil = File(buildPath(testDir, name), "wt");
	expectChange(fchange(FileChangeKind.added, name, false), expect_change);

print("test %s MODIFY %s", name, expect_change);
	fil.write("test");
	fil.close();
	expectChange(fchange(FileChangeKind.modified, name, false), expect_change);

print("test %s DELETE %s", name, expect_change);
	remove(buildPath(testDir, name));
	expectChange(fchange(FileChangeKind.removed, name, false), expect_change);
}

void testCreateDir(string name, bool expect_change = true)
{
print("test %s CREATEDIR %s", name, expect_change);
	mkdir(buildPath(testDir, name));
	expectChange(fchange(FileChangeKind.added, name, true), expect_change);
}

void testRemoveDir(string name, bool expect_change = true)
{
print("test %s DELETEDIR %s", name, expect_change);
	rmdirRecurse(buildPath(testDir, name));
	expectChange(fchange(FileChangeKind.removed, name, true), expect_change);
}

void testRename(string from, string to, bool expect_change = true)
{
print("test %s RENAME %s %s", from, to, expect_change);
	rename(buildPath(testDir, from), buildPath(testDir, to));
	expectChange(fchange(FileChangeKind.removed, from, true), expect_change);
	expectChange(fchange(FileChangeKind.added, to, true), expect_change);
}

FileChange fchange(FileChangeKind kind, string name, bool is_dir)
{
	auto dn = dirName(name);
	if (dn == ".") dn = "";
	return FileChange(kind, testDir, dn, baseName(name), is_dir);
}
