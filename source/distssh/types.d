/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.types;

public import std.typecons : Tuple, tuple;

alias HostLoad = Tuple!(Host, Load);

immutable globalEnvHostKey = "DISTSSH_HOSTS";
immutable globalEnvFileKey = "DISTSSH_IMPORT_ENV";
immutable globalEnvFilterKey = "DISTSSH_ENV_EXPORT_FILTER";
immutable distShell = "distshell";
immutable distCmd = "distcmd";
immutable distsshEnvExport = "distssh_env.export";
// arguments to ssh that turn off warning that a host key is new or requies a password to login
immutable sshNoLoginArgs = [
    "-oStrictHostKeyChecking=no", "-oPasswordAuthentication=no"
];
immutable ulong defaultTimeout_s = 2;

struct Host {
    string payload;
    alias payload this;
}

/// The load of a host.
struct Load {
    import std.datetime : Duration;

    double loadAvg;
    Duration accessTime;
    bool unknown;

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

    {
        auto raw = [Load(0.6, 500.dur!"msecs"), Load(0.5, 500.dur!"msecs")].sort.array;
        assert(raw[0].loadAvg == 0.5);
    }

    {
        auto raw = [Load(0.5, 600.dur!"msecs"), Load(0.5, 500.dur!"msecs")].sort.array;
        assert(raw[0].accessTime == 500.dur!"msecs");
    }
}
