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
    assert(spawnShell(distssh ~ " --install").wait == 0, "failed installing symlinks");
    assert(exists(buildPath(buildDir, "distcmd")), "no symlink created)");
    assert(exists(buildPath(buildDir, "distshell")), "no symlink created)");
}

@("shall export the env and import it")
unittest {
    prepareDistssh;
    assert(spawnShell(distssh ~ " --export-env").wait == 0, "failed exporting env");
    assert(spawnShell(distssh ~ " --fake-terminal=no --local-run --import-env=distssh_env.export -- ls")
            .wait == 0, "failed importing env");
}
