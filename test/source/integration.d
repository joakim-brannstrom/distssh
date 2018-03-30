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
immutable tmpDir = "./build/testdata";

struct TestArea {
    const string workdir;

    alias workdir this;

    this(ulong id) {
        this.workdir = buildPath(tmpDir, id.to!string).absolutePath;
        setup();
    }

    void setup() {
        if (exists(workdir)) {
            rmdirRecurse(workdir);
        }

        mkdirRecurse(workdir);
    }
}

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

@("shall export the env and import it")
unittest {
    assert(spawnShell(distssh ~ " --export-env").wait == 0, "failed exporting env");
    assert(spawnShell(distssh ~ " --local-run --import-env=distssh_env.export -- ls")
            .wait == 0, "failed importing env");
}

@(
        "shall print the environment variable that is part of the export when executing on the remote host")
unittest {
    immutable script = `#!/bin/bash
echo "smurf is $SMURF"`;

    // arrange
    auto area = TestArea(__LINE__);
    const script_file = buildPath(area, "script.sh");
    string[string] fake_env;

    // action
    File(script_file, "w").write(script);
    fake_env["SMURF"] = "42";
    spawnShell(distssh ~ " --export-env", stdin, stdout, stderr, fake_env).wait;
    auto res = executeShell(distssh ~ " --local-run -- bash " ~ script_file);

    // assert
    assert(res.status == 0, "failed executing: " ~ res.output);
    assert(res.output.canFind("42"),
            "failed finding 42 which should have been part of the imported env");
}
