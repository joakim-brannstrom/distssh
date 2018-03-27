/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module integration;

import core.stdc.stdlib;
import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.file;
import std.process;
import std.path;
import std.range;
import std.stdio;
import std.string;
import logger = std.experimental.logger;

immutable buildDir = "../build";
immutable distssh = "../build/distssh";

// These tests can not be ran in parallel

@("shall build the distssh command")
unittest {
    // prepare by cleaning up
    if (exists(buildDir))
        dirEntries(buildDir, SpanMode.shallow).each!(a => remove(a));

    auto es = spawnShell("cd .. && dub build").wait;
    assert(es == 0, "failed compilation");

    assert(exists(distssh), "no binary produced");
}

@("shall install the symlinks beside the binary")
unittest {
    assert(spawnShell(distssh ~ " --install").wait == 0, "failed installing symlinks");
    assert(exists(buildPath(buildDir, "distcmd")), "no symlink created)");
    assert(exists(buildPath(buildDir, "distshell")), "no symlink created)");
}
