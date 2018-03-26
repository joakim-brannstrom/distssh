/+ dub.json:
{
    "name": "tests",
    "description": "Command-line argument test",
    "dependencies": {
        "vibe-core": {"path": "../"}
    }
}
+/
module test;

import vibe.core.args;
import vibe.core.log;

import std.stdio;

shared static this()
{
	string argtest;
	readOption("argtest", &argtest, "Test argument");
	writeln("argtest=", argtest);
}

void main()
{
	finalizeCommandLineOptions();
}
