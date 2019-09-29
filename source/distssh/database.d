/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.database;

import logger = std.experimental.logger;
import std.algorithm : map;
import std.array : array, empty;
import std.datetime;
import std.exception : collectException, ifThrown;
import std.meta : AliasSeq;
import std.typecons : Nullable;

import miniorm;

import distssh.types;

immutable timeout = 30.dur!"seconds";
enum SchemaVersion = 1;

struct VersionTbl {
    @ColumnName("version")
    ulong version_;
}

@TablePrimaryKey("address")
struct ServerTbl {
    string address;
    SysTime lastUpdate;
    long accessTime;
    double loadAvg;
    bool unknown;
}

/// The daemon beats ones per minute.
struct DaemonBeat {
    ulong id;
    SysTime beat;
}

/// Clients beat each time they access the database.
struct ClientBeat {
    ulong id;
    SysTime beat;
}

Miniorm openDatabase(string dbFile) nothrow {
    while (true) {
        try {
            auto db = Miniorm(dbFile);
            const schemaVersion = () {
                foreach (a; db.run(select!VersionTbl))
                    return a;
                return VersionTbl(0);
            }().ifThrown(VersionTbl(0));

            alias Schema = AliasSeq!(VersionTbl, ServerTbl, DaemonBeat, ClientBeat);

            if (schemaVersion.version_ < SchemaVersion) {
                db.begin;
                static foreach (tbl; Schema)
                    db.run("DROP TABLE " ~ tbl.stringof).collectException;
                db.run(buildSchema!Schema);
                db.run(insert!VersionTbl, VersionTbl(SchemaVersion));
                db.commit;
            }
            return db;
        } catch (Exception e) {
            logger.tracef("Trying to open/create database %s: %s", dbFile, e.msg).collectException;
        }

        rndSleep(10.dur!"msecs", 200);
    }
}

/** Get all servers.
 *
 * Waiting for up to 10s for servers to be added. This handles the case where a
 * daemon have been spawned in the background.
 */
HostLoad[] getServerLoads(ref Miniorm db) nothrow {
    import std.datetime : Clock, dur;

    auto getData() {
        return db.run(select!ServerTbl).map!(a => HostLoad(Host(a.address),
                Load(a.loadAvg, a.accessTime.dur!"msecs", a.unknown))).array;
    }

    try {
        auto stopAt = Clock.currTime + timeout;
        while (Clock.currTime < stopAt) {
            auto a = spinSql!(getData, logger.trace)(timeout);
            if (!a.empty)
                return a;
            rndSleep(500.dur!"msecs", 1000);
        }
    } catch (Exception e) {
        logger.warning("Failed reading from the database: ", e.msg).collectException;
    }

    return null;
}

/// Update the data for a server.
void updateServer(ref Miniorm db, HostLoad a) nothrow {
    while (true) {
        try {
            db.run(insertOrReplace!ServerTbl, ServerTbl(a[0].payload,
                    Clock.currTime, a[1].accessTime.total!"msecs", a[1].loadAvg, a[1].unknown));
            return;
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
        }
        rndSleep(10.dur!"msecs", 20);
    }
}

void daemonBeat(ref Miniorm db) nothrow {
    spinSql!(() {
        db.run(insertOrReplace!DaemonBeat, DaemonBeat(0, Clock.currTime));
    });
}

/// The heartbeat when daemon was last executed.
Duration getDaemonBeat(ref Miniorm db) nothrow {
    return spinSql!(() {
        foreach (a; db.run(select!DaemonBeat.where("id = ", 0)))
            return Clock.currTime - a.beat;
        return Duration.max;
    });
}

void clientBeat(ref Miniorm db) nothrow {
    spinSql!(() {
        db.run(insertOrReplace!ClientBeat, ClientBeat(0, Clock.currTime));
    });
}

Duration getClientBeat(ref Miniorm db) nothrow {
    return spinSql!(() {
        foreach (a; db.run(select!ClientBeat.where("id = ", 0)))
            return Clock.currTime - a.beat;
        return Duration.max;
    });
}

/// Returns: the server that have the oldest update timestamp.
Nullable!Host getServerToUpdate(ref Miniorm db) nothrow {
    return spinSql!(() {
        foreach (a; db.run(select!ServerTbl.orderBy(OrderingTermSort.ASC,
            ["lastUpdate"]).limit(1)))
            return Nullable!Host(Host(a.address));
        return Nullable!Host.init;
    });
}
