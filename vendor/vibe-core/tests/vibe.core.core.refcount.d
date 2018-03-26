/+ dub.sdl:
	name "tests"
	description "Invalid ref count after runTask"
	dependency "vibe-core" path="../"
+/
module test;
import vibe.core.core;
import std.stdio;

struct RC {
	int* rc;
	this(int* rc) { this.rc = rc; }
	this(this) {
		if (rc) {
			(*rc)++;
			writefln("addref %s", *rc);
		}
	}
	~this() {
		if (rc) {
			(*rc)--;
			writefln("release %s", *rc);
		}
	}
}

void main()
{
	int rc = 1;
	bool done = false;

	{
		auto s = RC(&rc);
		assert(rc == 1);
		runTask((RC st) {
			assert(rc == 2);
			st = RC.init;
			assert(rc == 1);
			exitEventLoop();
			done = true;
		}, s);
		assert(rc == 2);
	}

	assert(rc == 1);

	runEventLoop();

	assert(rc == 0);
	assert(done);
}
