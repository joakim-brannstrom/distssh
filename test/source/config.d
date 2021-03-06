/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module config;

public import core.stdc.stdlib;
public import std.algorithm;
public import std.array;
public import std.ascii;
public import std.conv;
public import std.file;
public import std.process;
public import std.path;
public import std.range;
public import std.stdio;
public import std.string;
public import logger = std.experimental.logger;

public import unit_threaded.assertions;

immutable buildDir = "../build";
immutable tmpDir = "./build/testdata";

private shared(bool) g_isDistsshPrepared = false;

string distssh() {
    return buildPath(buildDir, "distssh").absolutePath;
}

string distcmd() {
    return buildPath(buildDir, "distcmd").absolutePath;
}

void prepareDistssh() {
    synchronized {
        if (g_isDistsshPrepared)
            return;
        g_isDistsshPrepared = true;

        auto es = spawnShell("cd .. && dub build").wait;
        assert(es == 0, "failed compilation");

        assert(exists(distssh), "no binary produced");
    }
}

struct TestArea {
    const string workdir;

    alias workdir this;

    this(string file, ulong id) {
        prepareDistssh;
        this.workdir = buildPath(tmpDir, file ~ id.to!string).absolutePath;
        setup();
    }

    void setup() {
        if (exists(workdir)) {
            rmdirRecurse(workdir);
        }

        mkdirRecurse(workdir);
    }
}
