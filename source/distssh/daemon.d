/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Updates the distssh server cache.

# Design

The overall design is based around a shared, local database that is used by
both the daemon and clients to exchange statistics about the cluster. By
leveraging sqlite for the database it becomes safe for processes to read/write
to it concurrently.

The heartbeats are used by both the client and daemon:

 * The client spawn a daemon if the daemon heartbeats have stopped being
   updated.
 * The server slow down the update of the cluster statistics if no client has
   used it in a while until it finally terminates itself.
*/
module distssh.daemon;

import core.thread : Thread;
import core.time : dur;
import logger = std.experimental.logger;
import std.algorithm : map, filter;
import std.array : array;
import std.datetime;
import std.exception : collectException;
import std.process : environment;
import std.typecons : Flag;

import colorlog;
import miniorm : SpinSqlTimeout;

import from_;

import distssh.config;
import distssh.database;
import distssh.metric;
import distssh.set;
import distssh.timer;
import distssh.types;
import distssh.utility;

immutable updateLeastLoadTimersInterval = [
    10.dur!"seconds", 20.dur!"seconds", 60.dur!"seconds"
];

int cli(const Config fconf, Config.Daemon conf) {
    auto db = openDatabase(fconf.global.dbPath);
    const origNode = getInode(fconf.global.dbPath);

    if (fconf.global.verbosity == VerboseMode.trace)
        db.log(true);

    if (conf.background) {
        const beat = db.getDaemonBeat;
        logger.trace("daemon beat: ", beat);
        // do not spawn if a daemon is already running.
        if (beat < heartBeatDaemonTimeout && !conf.forceStart)
            return 0;
        // by only updating the beat when in background mode it ensures that
        // the daemon will sooner or later start in persistant background mode.
        db.daemonBeat;
    }

    initMetrics(db, fconf.global.cluster, fconf.global.timeout);

    if (!conf.background)
        return 0;

    // when starting the daemon for the first time we assume that if there are
    // any data in the database that it is old.
    db.removeUnusedServers(1.dur!"minutes");

    bool running = true;
    // the daemon is at most running for 24h. This is a workaround for if/when
    // the client beat error out in such a way that it is always "zero".
    const forceShutdown = Clock.currTime + 24.dur!"hours";
    auto clientBeat = db.getClientBeat;

    auto timers = makeTimers;

    makeInterval(timers, () @trusted {
        clientBeat = db.getClientBeat;
        logger.trace("client beat: ", clientBeat);
        // no client is interested in the metric so stop collecting
        if (clientBeat > conf.timeout)
            running = false;
        if (Clock.currTime > forceShutdown)
            running = false;
        return running;
    }, 5.dur!"seconds");

    makeInterval(timers, () @safe {
        // the database may have been removed/recreated
        if (getInode(fconf.global.dbPath) != origNode)
            running = false;
        return running;
    }, 5.dur!"seconds");

    makeInterval(timers, () @trusted { db.daemonBeat; return running; }, 15.dur!"seconds");

    // the times are arbitrarily chosen.
    // assumption. The oldest statistic do not have to be updated that often
    // because the other loop, updating the best candidate, is running "fast".
    // assumption. If a user use distssh slower than five minutes it mean that
    // a long running processes is used and the user wont interact with distssh
    // for a while.
    bool updateOldestTimer(Duration begin, Duration end) @trusted {
        if (clientBeat >= begin && clientBeat < end) {
            auto host = db.getOldestServer;
            if (!host.isNull)
                updateServer(db, host.get, fconf.global.timeout);
        }
        return running;
    }

    makeInterval(timers, () @safe {
        return updateOldestTimer(0.dur!"seconds", 5.dur!"minutes");
    }, 30.dur!"seconds");
    makeInterval(timers, () @safe {
        return updateOldestTimer(5.dur!"minutes", Duration.max);
    }, 60.dur!"seconds");

    // the times are arbitrarily chosen.
    // assumption. The least loaded server will be getting jobs put on it not
    // only from *this* instance of distssh but also from all other instances
    // using the cluster. For this instance to be quick at moving job to
    // another host it has to update the statistics often.
    // assumption. A user that is using distssh less than 90s isn't using
    // distssh interactively/in quick succession. By backing of/slowing down
    // the update it lowers the network load.
    long updateLeastLoadedTimerTick;
    bool updateLeastLoadedTimer(Duration begin, Duration end) @trusted {
        import std.range : drop, take;

        if (clientBeat >= begin && clientBeat < end) {
            auto hosts = db.getLeastLoadedServer;
            // if the servers ever are less than topCandidades it will start
            // updating slower.
            foreach (h; hosts.drop(updateLeastLoadedTimerTick).take(1)) {
                updateServer(db, h, fconf.global.timeout);
            }

            updateLeastLoadedTimerTick = ++updateLeastLoadedTimerTick % topCandidades;
        }
        return running;
    }

    makeInterval(timers, () @safe {
        return updateLeastLoadedTimer(0.dur!"seconds", 30.dur!"seconds");
    }, updateLeastLoadTimersInterval[0]);
    makeInterval(timers, () @safe {
        return updateLeastLoadedTimer(30.dur!"seconds", 90.dur!"seconds");
    }, updateLeastLoadTimersInterval[1]);
    makeInterval(timers, () @safe {
        return updateLeastLoadedTimer(90.dur!"seconds", Duration.max);
    }, updateLeastLoadTimersInterval[2]);

    makeInterval(timers, () @trusted nothrow{
        try {
            db.removeUnusedServers(30.dur!"minutes");
        } catch (Exception e) {
            logger.warning(e.msg).collectException;
        }
        return true;
    }, 1.dur!"minutes");

    if (globalEnvPurge in environment && globalEnvPurgeWhiteList in environment) {
        import distssh.purge : readPurgeEnvWhiteList;

        Config.Purge pconf;
        pconf.kill = true;
        pconf.userFilter = true;
        auto econf = ExecuteOnHostConf(fconf.global.workDir, null, null, false, true);
        Set!Host clearedServers;

        logger.tracef("Server purge whitelist from %s is %s",
                globalEnvPurgeWhiteList, readPurgeEnvWhiteList);

        makeInterval(timers, () @safe nothrow{
            try {
                purgeServer(db, econf, pconf, clearedServers, fconf.global.timeout);
            } catch (Exception e) {
                logger.warning(e.msg).collectException;
            }
            return true;
        }, 2.dur!"minutes");
    } else {
        logger.tracef("Automatic purge not running because both %s and %s must be set",
                globalEnvPurge, globalEnvPurgeWhiteList);
    }

    while (running && !timers.empty) {
        try {
            timers.tick(100.dur!"msecs");
        } catch (SpinSqlTimeout e) {
            // the database is removed or something else "bad" has happend that
            // the database access has started throwing exceptions.
            return 1;
        }
    }

    return 0;
}

/** Start the daemon in either as a persistant background process or a oneshot
 * update.
 *
 * Returns: true if the daemon where started.
 */
bool startDaemon(ref from.miniorm.Miniorm db, Flag!"background" bg) nothrow {
    import distssh.process : spawnDaemon;
    import std.file : thisExePath;

    try {
        if (bg && db.getDaemonBeat < heartBeatDaemonTimeout) {
            return false;
        }

        const flags = () {
            if (bg)
                return ["--background"];
            return null;
        }();

        spawnDaemon([thisExePath, "daemon"] ~ flags);
        logger.trace("daemon spawned");
        return true;
    } catch (Exception e) {
        logger.error(e.msg).collectException;
    }

    return false;
}

private:

immutable heartBeatDaemonTimeout = 60.dur!"seconds";

void initMetrics(ref from.miniorm.Miniorm db, const(Host)[] cluster, Duration timeout) nothrow {
    import std.parallelism : TaskPool;
    import std.random : randomCover;

    static auto loadHost(T)(T host_timeout) nothrow {
        import std.concurrency : thisTid;

        logger.trace("load testing thread id: ", thisTid).collectException;
        return HostLoad(host_timeout[0], getLoad(host_timeout[0], host_timeout[1]));
    }

    try {
        auto pool = new TaskPool();
        scope (exit)
            pool.stop;

        foreach (v; pool.amap!(loadHost)(cluster.randomCover.map!(a => tuple(a, timeout)).array)) {
            db.newServer(v);
        }
    } catch (Exception e) {
        logger.trace(e.msg).collectException;
    }
}

void updateServer(ref from.miniorm.Miniorm db, Host host, Duration timeout) {
    auto load = getLoad(host, timeout);
    distssh.database.updateServer(db, HostLoad(host, load));
    logger.tracef("Update %s with %s", host, load).collectException;
}

/// Round robin clearing of the servers.
void purgeServer(ref from.miniorm.Miniorm db, ExecuteOnHostConf econf,
        const Config.Purge pconf, ref Set!Host clearedServers, const Duration timeout) @safe {
    import std.random : randomCover;
    import distssh.purge;

    auto servers = distssh.database.getServerLoads(db, clearedServers.toArray,
            timeout, 10.dur!"minutes");

    logger.trace("Round robin server purge list ", clearedServers.toArray);

    bool clearedAServer;
    foreach (a; servers.unused.randomCover.filter!(a => !clearedServers.contains(a))) {
        logger.trace("Purge server ", a);
        clearedAServer = true;
        distssh.purge.purgeServer(econf, pconf, a);
        clearedServers.add(a);
        break;
    }

    if (!clearedAServer) {
        logger.trace("Reset server purge list ");
        () @trusted { clearedServers.clear; }();
    }
}

struct Inode {
    ulong dev;
    ulong ino;

    bool opEquals()(auto ref const typeof(this) s) const {
        return dev == s.dev && ino == s.ino;
    }
}

Inode getInode(const Path p) @trusted nothrow {
    import core.sys.posix.sys.stat : stat_t, stat;
    import std.file : isSymlink, exists;
    import std.string : toStringz;

    const pz = p.toString.toStringz;

    if (!exists(p.toString)) {
        return Inode(0, 0);
    } else {
        stat_t st = void;
        // should NOT use lstat because we want to know even if the symlink is
        // redirected etc.
        stat(pz, &st);
        return Inode(st.st_dev, st.st_ino);
    }
}
