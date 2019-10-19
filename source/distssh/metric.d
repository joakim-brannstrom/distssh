/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.metric;

import logger = std.experimental.logger;
import std.algorithm : map, filter, splitter;
import std.array : empty, array;
import std.datetime : Duration, dur;
import std.exception : collectException, ifThrown;
import std.typecons : Nullable, Yes, No;

import distssh.types;

/** Login on host and measure its load.
 *
 * Params:
 *  h = remote host to check
 *
 * Returns: the Load of the remote host
 */
Load getLoad(Host h, Duration timeout) nothrow {
    import std.conv : to;
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.file : thisExePath;
    import std.process : tryWait, pipeProcess, kill, wait, escapeShellFileName;
    import std.range : takeOne, retro;
    import std.stdio : writeln;
    import core.sys.posix.signal : SIGKILL;
    import distssh.timer : makeTimers, makeInterval;

    enum ExitCode {
        none,
        error,
        timeout,
        ok,
    }

    ExitCode exit_code;

    Nullable!Load measure() {
        auto sw = StopWatch(AutoStart.yes);

        immutable abs_distssh = thisExePath;
        auto res = pipeProcess(["ssh", "-q"] ~ sshNoLoginArgs ~ [
                h, abs_distssh.escapeShellFileName, "localload"
                ]);

        bool checkExitCode() @trusted {
            auto st = res.pid.tryWait;

            if (st.terminated && st.status == 0) {
                exit_code = ExitCode.ok;
            } else if (st.terminated && st.status != 0) {
                exit_code = ExitCode.error;
            } else if (sw.peek >= timeout) {
                exit_code = ExitCode.timeout;
                res.pid.kill(SIGKILL);
                // must read the exit or a zombie process is left behind
                res.pid.wait;
            }
            return exit_code == ExitCode.none;
        }

        // 25 because it is at the perception of human "lag" and less than the 100
        // msecs that is the intention of the average delay.
        auto timers = makeTimers;
        makeInterval(timers, &checkExitCode, 25.dur!"msecs");

        while (!timers.empty) {
            timers.tick(25.dur!"msecs");
        }

        sw.stop;

        Nullable!Load rval;

        if (exit_code != ExitCode.ok)
            return rval;

        try {
            string last_line;
            foreach (a; res.stdout.byLineCopy) {
                last_line = a;
            }

            rval = Load(last_line.to!double, sw.peek);
        } catch (Exception e) {
            logger.trace(res.stdout).collectException;
            logger.trace(res.stderr).collectException;
            logger.trace(e.msg).collectException;
        }

        return rval;
    }

    try {
        auto r = measure();
        if (!r.isNull)
            return r.get;
    } catch (Exception e) {
        logger.trace(e.msg).collectException;
    }

    return Load(int.max, 3600.dur!"seconds", true);
}

/**
 * #SPC-load_balance
 * #SPC-best_remote_host
 *
 * TODO: it can be empty. how to handle that?
 */
struct RemoteHostCache {
    HostLoad[] remoteByLoad;

    static auto make(string dbPath, const Host[] cluster) nothrow {
        import distssh.daemon : startDaemon;
        import distssh.database;
        import std.algorithm : sort;

        try {
            auto db = openDatabase(dbPath);
            db.clientBeat;
            const started = startDaemon(db, Yes.background);
            if (!started) {
                db.syncCluster(cluster);
            }

            // if no hosts are found in the db within the timeout then go over
            // into a fast mode. This happens if the client e.g. switches the
            // cluster it is using.
            auto servers = db.getServerLoads(cluster, 5.dur!"seconds")
                .ifThrown(typeof(db.getServerLoads(cluster, Duration.zero)).init);
            if (servers.online.empty) {
                logger.trace("starting daemon in oneshot mode");
                startDaemon(db, No.background);
                servers = db.getServerLoads(cluster, 60.dur!"seconds");
            }

            db.removeUnusedServers(servers.unused);
            return RemoteHostCache(servers.online.sort!((a, b) => a[1] < b[1]).array);
        } catch (Exception e) {
            logger.error(e.msg).collectException;
        }
        return RemoteHostCache.init;
    }

    /// Returns: the lowest loaded server.
    Host randomAndPop() @safe nothrow {
        import std.range : take;
        import std.random : randomSample;

        assert(!empty, "should never happen");

        auto rval = remoteByLoad[0][0];

        try {
            auto topX = remoteByLoad.filter!(a => !a[1].unknown).array;
            if (topX.length == 0) {
                rval = remoteByLoad[0][0];
            } else if (topX.length < topCandidades) {
                rval = topX[0][0];
            } else {
                rval = topX.take(topCandidades).randomSample(1).front[0];
            }
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
        }

        remoteByLoad = remoteByLoad.filter!(a => a[0] != rval).array;

        return rval;
    }

    Host front() @safe pure nothrow {
        assert(!empty);
        return remoteByLoad[0][0];
    }

    void popFront() @safe pure nothrow {
        assert(!empty);
        remoteByLoad = remoteByLoad[1 .. $];
    }

    bool empty() @safe pure nothrow {
        return remoteByLoad.length == 0;
    }
}
