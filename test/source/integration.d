/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module integration;

import config;

@("shall build the distssh command")
unittest {
    prepareDistssh;
}

@("shall install the symlinks beside the binary")
unittest {
    prepareDistssh;
    spawnShell(distssh ~ " install").wait.shouldEqual(0); // failed installing symlinks;
    exists(buildPath(buildDir, "distcmd")).shouldBeTrue; // no symlink created
    exists(buildPath(buildDir, "distshell")).shouldBeTrue; // no symlink created
}

@("shall export the env and import it")
unittest {
    prepareDistssh;
    assert(spawnShell(distssh ~ " env -e").wait == 0, "failed exporting env");
    assert(spawnShell(distssh ~ " localrun --import-env=distssh_env.export -- ls")
            .wait == 0, "failed importing env");
}

@("shall run the command successfully even though the working directory have a space in the name")
unittest {
    prepareDistssh;

    if (environment.get("DISTSSH_HOSTS").length == 0) {
        writeln("Unable to run the test because DISTSSH_HOSTS is not set. Skipping...");
        return;
    }

    auto area = TestArea(__FILE__, __LINE__);
    const wdir = buildPath(area, "foo bar");
    mkdirRecurse(wdir);
    File(buildPath(wdir, "my_dummy_file.txt"), "w");

    assert(spawnProcess([distssh, "--", "cat", "my_dummy_file.txt"], null,
            Config.none, wdir).wait == 0, "failed to cat my_dummy_file.txt via distssh --");
    assert(spawnProcess([distcmd, "cat", "my_dummy_file.txt"], null, Config.none,
            wdir).wait == 0, "failed to cat my_dummy_file.txt via distcmd");
}

@("shall print the environment")
unittest {
    prepareDistssh;

    if (environment.get("DISTSSH_HOSTS").length == 0) {
        writeln("Unable to run the test because DISTSSH_HOSTS is not set. Skipping...");
        return;
    }

    auto area = TestArea(__FILE__, __LINE__);

    assert(spawnProcess([distssh, "env", "-e"], null, Config.none, area)
            .wait == 0, "failed to export the environment");
    auto res = execute([distssh, "env", "--print"], null, Config.none, size_t.max, area);
    assert(res.status == 0);
    assert(res.output.canFind("PWD"), "failed to print the environment");
}
