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
immutable globalEnvPurge = "DISTSSH_AUTO_PURGE";
immutable globalEnvPurgeWhiteList = "DISTSSH_PURGE_WLIST";
immutable distShell = "distshell";
immutable distCmd = "distcmd";
immutable distsshEnvExport = "distssh_env.export";
// arguments to ssh that turn off warning that a host key is new or requies a password to login
immutable sshNoLoginArgs = [
    "-oStrictHostKeyChecking=no", "-oPasswordAuthentication=no"
];
immutable ulong defaultTimeout_s = 2;
/// Number of the top X candidates to choose a server from to put the work on.
immutable topCandidades = 3;

@safe:

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

/// Mirror of an environment.
struct Env {
    string[string] payload;
    alias payload this;
}

/// Tag a string as a path and make it absolute+normalized.
struct Path {
    import std.path : absolutePath, buildNormalizedPath, buildPath;

    private string value_;

    this(Path p) @safe pure nothrow @nogc {
        value_ = p.value_;
    }

    this(string p) @safe {
        value_ = p.absolutePath.buildNormalizedPath;
    }

    Path dirName() @safe const {
        import std.path : dirName;

        return Path(value_.dirName);
    }

    string baseName() @safe const {
        import std.path : baseName;

        return value_.baseName;
    }

    void opAssign(string rhs) @safe pure {
        value_ = rhs.absolutePath.buildNormalizedPath;
    }

    void opAssign(typeof(this) rhs) @safe pure nothrow {
        value_ = rhs.value_;
    }

    Path opBinary(string op)(string rhs) @safe {
        static if (op == "~") {
            return Path(buildPath(value_, rhs));
        } else
            static assert(false, typeof(this).stringof ~ " does not have operator " ~ op);
    }

    void opOpAssign(string op)(string rhs) @safe nothrow {
        static if (op == "~=") {
            value_ = buildNormalizedPath(value_, rhs);
        } else
            static assert(false, typeof(this).stringof ~ " does not have operator " ~ op);
    }

    T opCast(T : string)() {
        return value_;
    }

    string toString() @safe pure nothrow const @nogc {
        return value_;
    }

    import std.range : isOutputRange;

    void toString(Writer)(ref Writer w) const if (isOutputRange!(Writer, char)) {
        import std.range : put;

        put(w, value_);
    }
}
