/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.database;

import logger = std.experimental.logger;
import std.algorithm : map, filter;
import std.array : array, empty;
import std.datetime;
import std.exception : collectException, ifThrown;
import std.meta : AliasSeq;
import std.typecons : Nullable, Tuple;

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

        rndSleep(25.dur!"msecs", 50);
    }
}

/** Get all servers.
 *
 * Waiting for up to 10s for servers to be added. This handles the case where a
 * daemon have been spawned in the background.
 */
Tuple!(HostLoad[], "online", Host[], "unused") getServerLoads(ref Miniorm db, const Host[] filterBy_) nothrow {
    import std.datetime : Clock, dur;
    import distssh.set;

    auto getData() {
        return db.run(select!ServerTbl).map!(a => HostLoad(Host(a.address),
                Load(a.loadAvg, a.accessTime.dur!"msecs", a.unknown))).array;
    }

    auto filterBy = toSet(filterBy_.map!(a => a.payload));

    try {
        auto stopAt = Clock.currTime + timeout;
        while (Clock.currTime < stopAt) {
            typeof(return) rval;
            foreach (h; spinSql!(getData, logger.trace)(timeout).filter!(a => !a[1].unknown)) {
                if (filterBy.contains(h[0].payload))
                    rval.online ~= h;
                else
                    rval.unused ~= h[0];
            }

            if (!rval.online.empty)
                return rval;
        }
    } catch (Exception e) {
        logger.warning("Failed reading from the database: ", e.msg).collectException;
    }

    return typeof(return).init;
}

/** Sync the hosts in the database with those that the client expect to exist.
 *
 * The client may from one invocation to another change the cluster. Those in
 * the database should in that case be updated.
 */
void syncCluster(ref Miniorm db, const Host[] cluster) {
    immutable highAccessTime = 1.dur!"minutes"
        .total!"msecs";
    immutable highLoadAvg = 9999.0;
    immutable forceEarlyUpdate = Clock.currTime - 1.dur!"hours";

    auto stmt = spinSql!(() {
        return db.prepare(`INSERT OR IGNORE INTO ServerTbl (address,lastUpdate,accessTime,loadAvg,unknown) VALUES(:address, :lastUpdate, :accessTime, :loadAvg, :unknown)`);
    }, logger.trace)(timeout);

    foreach (const h; cluster) {
        spinSql!(() {
            stmt.reset;
            stmt.bind(":address", h.payload);
            stmt.bind(":lastUpdate", forceEarlyUpdate.toSqliteDateTime);
            stmt.bind(":accessTime", highAccessTime);
            stmt.bind(":loadAvg", highLoadAvg);
            stmt.bind(":unknown", true);
            stmt.execute;
        }, logger.trace)(timeout);
    }
}

/// Update the data for a server.
void newServer(ref Miniorm db, HostLoad a) {
    spinSql!(() {
        db.run(insertOrReplace!ServerTbl, ServerTbl(a[0].payload,
            Clock.currTime, a[1].accessTime.total!"msecs", a[1].loadAvg, a[1].unknown));
    }, logger.trace)(timeout, 100.dur!"msecs", 300.dur!"msecs");
}

/// Update the data for a server.
void updateServer(ref Miniorm db, HostLoad a) {
    spinSql!(() {
        // using IGNORE because the host could have been removed.
        auto stmt = db.prepare(`UPDATE OR IGNORE ServerTbl SET lastUpdate = :lastUpdate, accessTime = :accessTime, loadAvg = :loadAvg, unknown = :unknown WHERE address = :address`);
        stmt.bind(":address", a[0].payload);
        stmt.bind(":lastUpdate", Clock.currTime.toSqliteDateTime);
        stmt.bind(":accessTime", a[1].accessTime.total!"msecs");
        stmt.bind(":loadAvg", a[1].loadAvg);
        stmt.bind(":unknown", a[1].unknown);
        stmt.execute;
    }, logger.trace)(timeout, 100.dur!"msecs", 300.dur!"msecs");
}

void removeUnusedServers(ref Miniorm db, Host[] hosts) {
    if (hosts.empty)
        return;

    auto stmt = spinSql!(() {
        return db.prepare(`DELETE FROM ServerTbl WHERE address = :address`);
    }, logger.trace)(timeout);

    foreach (h; hosts) {
        spinSql!(() {
            stmt.reset;
            stmt.bind(":address", h.payload);
            stmt.execute;
        }, logger.trace)(timeout);
    }
}

void daemonBeat(ref Miniorm db) {
    spinSql!(() {
        db.run(insertOrReplace!DaemonBeat, DaemonBeat(0, Clock.currTime));
    }, logger.trace)(timeout);
}

/// The heartbeat when daemon was last executed.
Duration getDaemonBeat(ref Miniorm db) {
    return spinSql!(() {
        foreach (a; db.run(select!DaemonBeat.where("id =", 0)))
            return Clock.currTime - a.beat;
        return Duration.max;
    }, logger.trace)(timeout);
}

void clientBeat(ref Miniorm db) {
    spinSql!(() {
        db.run(insertOrReplace!ClientBeat, ClientBeat(0, Clock.currTime));
    }, logger.trace)(timeout);
}

Duration getClientBeat(ref Miniorm db) {
    return spinSql!(() {
        foreach (a; db.run(select!ClientBeat.where("id =", 0)))
            return Clock.currTime - a.beat;
        return Duration.max;
    }, logger.trace)(timeout);
}

/// Returns: the server that have the oldest update timestamp.
Nullable!Host getOldestServer(ref Miniorm db) {
    auto stmt = spinSql!(() {
        return db.prepare(
            `SELECT address FROM ServerTbl ORDER BY datetime(lastUpdate) ASC LIMIT 1`);
    }, logger.trace)(timeout);

    return spinSql!(() {
        foreach (a; stmt.execute) {
            auto address = a.peek!string(0);
            return Nullable!Host(Host(address));
        }
        return Nullable!Host.init;
    }, logger.trace)(timeout);
}

Nullable!Host getLeastLoadedServer(ref Miniorm db) {
    auto stmt = spinSql!(() {
        return db.prepare(`SELECT address FROM ServerTbl ORDER BY loadAvg ASC LIMIT 1`);
    }, logger.trace)(timeout);

    return spinSql!(() {
        foreach (a; stmt.execute) {
            auto address = a.peek!string(0);
            return Nullable!Host(Host(address));
        }
        return Nullable!Host.init;
    }, logger.trace)(timeout);
}

void purgeServers(ref Miniorm db) {
    spinSql!(() { db.run("DELETE FROM ServerTbl"); })(timeout);
}

/** Sleep for a random time that is min_ + rnd(0, span).
 *
 * Params:
 *  span = unit is msecs.
 */
private void rndSleep(Duration min_, ulong span) nothrow @trusted {
    import core.thread : Thread;
    import core.time : dur;
    import std.random : uniform;

    auto t_span = () {
        try {
            return uniform(0, span).dur!"msecs";
        } catch (Exception e) {
        }
        return span.dur!"msecs";
    }();

    Thread.sleep(min_ + t_span);
}
