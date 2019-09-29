/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.database;

import logger = std.experimental.logger;
import std.algorithm : map;
import std.array : array;
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

/// The updater beats ones per minute.
struct UpdaterBeat {
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

            alias Schema = AliasSeq!(VersionTbl, ServerTbl, UpdaterBeat, ClientBeat);

            if (schemaVersion.version_ < SchemaVersion) {
                db.begin;
                static foreach (tbl; Schema)
                    db.run("DROP TABLE " ~ tbl.stringof).collectException;
                db.commit;
            }
            db.run(buildSchema!Schema);
            db.run(insert!VersionTbl, VersionTbl(SchemaVersion));
            return db;
        } catch (Exception e) {
            logger.warningf("Trying to open/create database %s: %s", dbFile,
                    e.msg).collectException;
        }

        rndSleep(10.dur!"msecs", 20);
    }
}

/// Get all servers.
HostLoad[] getServerLoads(ref Miniorm db) nothrow {
    auto getData() {
        return db.run(select!ServerTbl).map!(a => HostLoad(Host(a.address),
                Load(a.loadAvg, a.accessTime.dur!"msecs", a.unknown))).array;
    }

    try {
        return spinSql!getData(timeout);
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

void updaterBeat(ref Miniorm db) nothrow {
    spinSql!(() {
        db.run(insertOrReplace!UpdaterBeat, UpdaterBeat(0, Clock.currTime));
    });
}

/// The heartbeat when updater was last executed.
SysTime getUpdaterBeat(ref Miniorm db) nothrow {
    return spinSql!(() {
        foreach (a; db.run(select!UpdaterBeat.where("id = ", 0)))
            return a.beat;
        return SysTime.min;
    });
}

void clientBeat(ref Miniorm db) nothrow {
    spinSql!(() {
        db.run(insertOrReplace!ClientBeat, ClientBeat(0, Clock.currTime));
    });
}

SysTime getClientBeat(ref Miniorm db) nothrow {
    return spinSql!(() {
        foreach (a; db.run(select!ClientBeat.where("id = ", 0)))
            return a.beat;
        return SysTime.min;
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
