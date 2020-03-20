/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.process;

import std.algorithm : filter, splitter, map;
import std.exception : collectException;
import std.stdio : File;
import std.string : fromStringz;
import logger = std.experimental.logger;

import from_;

auto spawnDaemon(scope const(char[])[] args, scope const char[] workDir = null) {
    import std.process : spawnProcess, Config;
    import std.stdio : File;

    auto devNullIn = File("/dev/null");
    auto devNullOut = File("/dev/null", "w");
    return spawnProcess(args, devNullIn, devNullOut, devNullOut, null, Config.detached, workDir);
}
