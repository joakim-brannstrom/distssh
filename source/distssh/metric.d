/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.metric;

import logger = std.experimental.logger;
import std.algorithm : map, filter, splitter, joiner, sort, copy;
import std.array : empty, array, appender;
import std.datetime : Duration, dur;
import std.exception : collectException, ifThrown;
import std.range : take, drop, only;
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

            rval = Load(last_line.to!double, sw.peek, false);
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

    return Load.init;
}

/**
 * #SPC-load_balance
 * #SPC-best_remote_host
 *
 * TODO: it can be empty. how to handle that?
 */
struct RemoteHostCache {
    private {
        HostLoad[] online;
        HostLoad[] unused;
    }

    static auto make(Path dbPath, const Host[] cluster) nothrow {
        import distssh.daemon : startDaemon, updateLeastLoadTimersInterval;
        import distssh.database;

        try {
            auto db = openDatabase(dbPath);
            db.clientBeat;
            const started = startDaemon(db, Yes.background);
            if (!started) {
                db.syncCluster(cluster);
            }
            db.updateLastUse(cluster);

            // if no hosts are found in the db within the timeout then go over
            // into a fast mode. This happens if the client e.g. switches the
            // cluster it is using.
            auto servers = db.getServerLoads(cluster, 1.dur!"seconds",
                    updateLeastLoadTimersInterval[$ - 1]);
            if (servers.online.empty) {
                logger.trace("starting daemon in oneshot mode");
                startDaemon(db, No.background);

                import core.thread : Thread;
                import core.time : dur;

                // give the background process time to update some servers
                Thread.sleep(2.dur!"seconds");
                servers = db.getServerLoads(cluster, 60.dur!"seconds",
                        updateLeastLoadTimersInterval[$ - 1]);
            }

            return RemoteHostCache(servers.online, servers.unused);
        } catch (Exception e) {
            logger.error(e.msg).collectException;
        }
        return RemoteHostCache.init;
    }

    /// Returns: a range starting with the best server to use going to the worst.
    auto bestSelectRange() @safe nothrow {
        return BestSelectRange(online);
    }

    auto unusedRange() @safe nothrow {
        return unused.sort!((a, b) => a.host < b.host);
    }

    /// Returns: a range over the online servers
    auto onlineRange() @safe nothrow {
        return online.sort!((a, b) => a.host < b.host);
    }

    /// Returns: a range over all servers
    auto allRange() @safe nothrow {
        return only(online, unused).joiner.array.sort!((a, b) => a.host < b.host);
    }
}

@safe struct BestSelectRange {
    private {
        HostLoad[] servers;
    }

    this(HostLoad[] servers) nothrow {
        import std.algorithm : sort;

        this.servers = reorder(servers.sort!((a, b) => a.load < b.load)
                .filter!(a => !a.load.unknown)
                .array);
    }

    /// Reorder the first three candidates in the server list in a random order.
    static private HostLoad[] reorder(HostLoad[] servers) @safe nothrow {
        import std.random : randomCover;

        auto app = appender!(HostLoad[])();

        if (servers.length < 3) {
            servers.randomCover.copy(app);
        } else {
            servers.take(topCandidades).randomCover.copy(app);
            servers.drop(topCandidades).copy(app);
        }

        return app.data;
    }

    Host front() @safe pure nothrow {
        assert(!empty, "should never happen");
        return servers[0].host;
    }

    void popFront() @safe pure nothrow {
        assert(!empty, "should never happen");
        servers = servers[1 .. $];
    }

    bool empty() @safe pure nothrow {
        return servers.empty;
    }
}
