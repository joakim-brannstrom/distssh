#!/usr/bin/env rdmd
/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh;

import std.algorithm;
import std.exception;
import std.typecons : Nullable;
import logger = std.experimental.logger;

int main(string[] args) {
    import std.process;

    auto host = selectLowest;
    if (!host.isNull) {
        return spawnProcess(["ssh", "-oStrictHostKeyChecking=no", host]).wait;
    }

    return 0;
}

private:

struct Host {
    string payload;
    alias payload this;
}

/// Returns: the lowest loaded server.
Nullable!Host selectLowest() nothrow {
    import std.array : array;
    import std.range;
    import std.typecons : tuple;
    import std.algorithm : sort;
    import std.random : uniform;
    import std.parallelism : taskPool;
    import std.string : fromStringz;
    import core.stdc.stdlib;

    try {
        auto hosts = core.stdc.stdlib.getenv("DISTSSH_HOSTS").fromStringz.idup;
        if (hosts.length == 0)
            return typeof(return)();

        static auto loadHost(Host host) {
            return tuple(host, getLoad(host));
        }

        auto shosts = hosts.splitter(":").map!Host.array;

        // dfmt off
        auto measured =
            taskPool.map!loadHost(shosts, 100, 1)
            .filter!(a => !a[1].isNull)
            .map!(a => tuple(a[0], a[1].get))
            .array
            .sort!((a,b) => a[1] < b[1])
            .take(2).array;
        // dfmt on

        if (measured.length > 0) {
            auto ridx = uniform(0, measured.length);
            return typeof(return)(measured[ridx][0]);
        }
    }
    catch (Exception e) {
        logger.trace(e.msg).collectException;
    }

    return typeof(return)();
}

/// The load of a host.
struct Load {
    double payload;
    alias payload this;
}

/**
 * Params:
 *  h = remote host to check
 *
 * Returns: the Load of the remote host
 */
Nullable!Load getLoad(Host h) nothrow {
    import std.conv : to;
    import std.process : tryWait, pipeProcess, kill;
    import std.range : takeOne;
    import std.stdio : writeln;
    import core.time : dur, MonoTime;
    import core.sys.posix.signal : SIGKILL;

    enum timeout = 2.dur!"seconds";

    try {
        auto res = pipeProcess(["ssh", "-oStrictHostKeyChecking=no", h, "cat", "/proc/loadavg"]);

        auto stop_at = MonoTime.currTime + timeout;
        while (true) {
            auto st = res.pid.tryWait;

            if (st.terminated && st.status == 0)
                break;
            else if (st.terminated && st.status != 0) {
                writeln(res.stderr.byLine);
                return typeof(return)();
            } else if (stop_at < MonoTime.currTime) {
                res.pid.kill(SIGKILL);
                return typeof(return)();
            }
        }

        foreach (a; res.stdout.byLine.takeOne.map!(a => a.splitter(" ")).joiner.takeOne) {
            return typeof(return)(a.to!double.Load);
        }
    }
    catch (Exception e) {
        logger.trace(e.msg).collectException;
    }

    return typeof(return)();
}
