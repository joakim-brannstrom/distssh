/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.types;

import core.thread : Thread;
import std.datetime : SysTime, dur;

public import my.path : Path;

immutable globalEnvHostKey = "DISTSSH_HOSTS";
immutable globalEnvFileKey = "DISTSSH_IMPORT_ENV";
immutable globalEnvFilterKey = "DISTSSH_ENV_EXPORT_FILTER";
immutable globalEnvPurge = "DISTSSH_AUTO_PURGE";
immutable globalEnvPurgeWhiteList = "DISTSSH_PURGE_WLIST";
immutable distShell = "distshell";
immutable distCmd = "distcmd";
immutable distsshEnvExport = "distssh_env.export";
immutable ulong defaultTimeout_s = 2;
/// Number of the top X candidates to choose a server from to put the work on.
immutable topCandidades = 3;

@safe:

struct HostLoad {
    Host host;
    Load load;
    /// When the host was last updated
    SysTime updated;
}

struct Host {
    string payload;
    alias payload this;
}

/// The load of a host.
struct Load {
    import std.datetime : Duration;

    double loadAvg = int.max;
    Duration accessTime = 1.dur!"hours";
    bool unknown = true;

    bool opEquals(const typeof(this) o) nothrow @safe pure @nogc {
        if (unknown && o.unknown)
            return true;
        return loadAvg == o.loadAvg && accessTime == o.accessTime;
    }

    int opCmp(const typeof(this) o) pure @safe @nogc nothrow {
        if (unknown && o.unknown)
            return 0;
        else if (unknown)
            return 1;
        else if (o.unknown)
            return -1;

        if (loadAvg < o.loadAvg)
            return -1;
        else if (loadAvg > o.loadAvg)
            return 1;

        if (accessTime < o.accessTime)
            return -1;
        else if (accessTime > o.accessTime)
            return 1;

        return this == o ? 0 : 1;
    }
}

@("shall sort the loads")
unittest {
    import std.algorithm : sort;
    import std.array : array;
    import core.time : dur;
    import std.conv : to;

    {
        auto raw = [
            Load(0.6, 500.dur!"msecs", false), Load(0.5, 500.dur!"msecs", false)
        ].sort.array;
        assert(raw[0].loadAvg == 0.5, raw[0].to!string);
    }

    {
        auto raw = [
            Load(0.5, 600.dur!"msecs", false), Load(0.5, 500.dur!"msecs", false)
        ].sort.array;
        assert(raw[0].accessTime == 500.dur!"msecs");
    }
}

/// Mirror of an environment.
struct Env {
    string[string] payload;
    alias payload this;
}
