/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Updates the distssh server cache.
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

import from_;

import distssh.database;
import distssh.types;
import distssh.config;
import distssh.database;
import distssh.metric;

int cli(const Config fconf, Config.Daemon conf) {
    auto db = openDatabase(fconf.global.dbPath);
    const origNode = getInode(fconf.global.dbPath);

    logger.trace("daemon beat: ", db.getDaemonBeat);

    // do not spawn if a daemon is already running.
    if (db.getDaemonBeat < heartBeatDaemonTimeout)
        return 0;

    db.daemonBeat;
    initMetrics(db, fconf.global.timeout);

    auto updateOldestAt = Clock.currTime + updateOldestInterval;
    while (true) {
        Thread.sleep(heartBeatUpdate);
        // the database may have been removed/recreated
        if (getInode(fconf.global.dbPath) != origNode)
            break;

        logger.trace("client beat: ", db.getClientBeat);
        // no client is interested in the metric so stop collecting
        if (db.getClientBeat > heartBeatClientTimeout)
            break;

        db.daemonBeat;

        if (updateOldestAt < Clock.currTime) {
            updateOldest(db, fconf.global.timeout);
            updateOldestAt = Clock.currTime + updateOldestInterval;
        }
    }

    return 0;
}

void startDaemon(ref from.miniorm.Miniorm db) nothrow {
    import distssh.process : spawnDaemon;
    import std.file : thisExePath;

    try {
        db.clientBeat;
        if (db.getDaemonBeat > heartBeatDaemonTimeout)
            spawnDaemon([thisExePath, "daemon"]);
    } catch (Exception e) {
        logger.error(e.msg).collectException;
    }
}

private:

immutable heartBeatUpdate = 15.dur!"seconds";
immutable heartBeatDaemonTimeout = 60.dur!"seconds";
immutable heartBeatClientTimeout = 5.dur!"minutes";
immutable updateOldestInterval = 30.dur!"seconds";

void initMetrics(ref from.miniorm.Miniorm db, Duration timeout) nothrow {
    import std.parallelism : TaskPool;

    static auto loadHost(T)(T host_timeout) nothrow {
        import std.concurrency : thisTid;

        logger.trace("load testing thread id: ", thisTid).collectException;
        return HostLoad(host_timeout[0], getLoad(host_timeout[0], host_timeout[1]));
    }

    try {
        auto shosts = hostsFromEnv.map!(a => tuple(a, timeout)).array;

        auto pool = new TaskPool();
        scope (exit)
            pool.stop;

        foreach (v; pool.amap!(loadHost)(shosts)) {
            db.updateServer(v);
        }
    } catch (Exception e) {
        logger.trace(e.msg).collectException;
    }
}

void updateOldest(ref from.miniorm.Miniorm db, Duration timeout) nothrow {
    auto host = db.getServerToUpdate;
    if (host.isNull)
        return;

    auto load = getLoad(host.get, timeout);
    db.updateServer(HostLoad(Host(host.get), load));
    logger.tracef("Update %s with %s", host.get, load).collectException;
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
