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
import std.algorithm : map;
import std.array : array;
import std.datetime;
import std.exception : collectException;

import colorlog;
import miniorm : SpinSqlTimeout;

import from_;

import distssh.database;
import distssh.types;
import distssh.config;
import distssh.database;
import distssh.metric;
import distssh.timer;

int cli(const Config fconf, Config.Daemon conf) {
    auto db = openDatabase(fconf.global.dbPath);
    const origNode = getInode(fconf.global.dbPath);

    {
        const beat = db.getDaemonBeat;
        logger.trace("daemon beat: ", beat);
        // do not spawn if a daemon is already running.
        if (beat < heartBeatDaemonTimeout)
            return 0;
    }

    db.daemonBeat;
    initMetrics(db, fconf.global.cluster, fconf.global.timeout);

    bool running = true;
    auto clientBeat = db.getClientBeat;

    auto timers = makeTimers;

    makeInterval(timers, () @trusted {
        clientBeat = db.getClientBeat;
        logger.trace("client beat: ", clientBeat);
        // no client is interested in the metric so stop collecting
        if (clientBeat > heartBeatClientTimeout)
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
    bool updateLeastLoadedTimer(Duration begin, Duration end) @trusted {
        if (clientBeat >= begin && clientBeat < end) {
            auto host = db.getLeastLoadedServer;
            if (!host.isNull)
                updateServer(db, host.get, fconf.global.timeout);
        }
        return running;
    }

    makeInterval(timers, () @safe {
        return updateLeastLoadedTimer(0.dur!"seconds", 30.dur!"seconds");
    }, 10.dur!"seconds");
    makeInterval(timers, () @safe {
        return updateLeastLoadedTimer(30.dur!"seconds", 90.dur!"seconds");
    }, 20.dur!"seconds");
    makeInterval(timers, () @safe {
        return updateLeastLoadedTimer(90.dur!"seconds", Duration.max);
    }, 60.dur!"seconds");

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

void startDaemon(ref from.miniorm.Miniorm db) nothrow {
    import distssh.process : spawnDaemon;
    import std.file : thisExePath;

    try {
        db.clientBeat;
        if (db.getDaemonBeat > heartBeatDaemonTimeout) {
            db.purgeServers; // assuming the data is old
            spawnDaemon([thisExePath, "daemon"]);
            logger.trace("daemon spawned");
        }
    } catch (Exception e) {
        logger.error(e.msg).collectException;
    }
}

private:

immutable heartBeatDaemonTimeout = 60.dur!"seconds";
immutable heartBeatClientTimeout = 30.dur!"minutes";
immutable updateOldestInterval = 30.dur!"seconds";

void initMetrics(ref from.miniorm.Miniorm db, const(Host)[] cluster, Duration timeout) nothrow {
    import std.parallelism : TaskPool;
    import std.random : randomCover;

    static auto loadHost(T)(T host_timeout) nothrow {
        import std.concurrency : thisTid;

        logger.trace("load testing thread id: ", thisTid).collectException;
        return HostLoad(host_timeout[0], getLoad(host_timeout[0], host_timeout[1]));
    }

    try {
        auto shosts = cluster.randomCover.map!(a => tuple(a, timeout)).array;

        auto pool = new TaskPool();
        scope (exit)
            pool.stop;

        foreach (v; pool.amap!(loadHost)(shosts)) {
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

struct Inode {
    ulong dev;
    ulong ino;

    bool opEquals()(auto ref const typeof(this) s) const {
        return dev == s.dev && ino == s.ino;
    }
}

Inode getInode(const string p) @trusted nothrow {
    import core.sys.posix.sys.stat : stat_t, stat;
    import std.file : isSymlink, exists;
    import std.string : toStringz;

    const pz = p.toStringz;

    if (!exists(p)) {
        return Inode(0, 0);
    } else {
        stat_t st = void;
        // should NOT use lstat because we want to know even if the symlink is
        // redirected etc.
        stat(pz, &st);
        return Inode(st.st_dev, st.st_ino);
    }
}
