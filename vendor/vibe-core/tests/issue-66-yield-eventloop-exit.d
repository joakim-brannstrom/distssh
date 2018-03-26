/+ dub.sdl:
	name "tests"
	dependency "vibe-core" path=".."
+/
module tests;

import vibe.core.core;

void main()
{
	bool visited = false;
	runTask({
		yield();
		visited = true;
		exitEventLoop();
	});
	runApplication();
	assert(visited);
}
