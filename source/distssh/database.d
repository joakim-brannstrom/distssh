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

version (unittest) {
    import unit_threaded.assertions;
}

immutable timeout = 30.dur!"seconds";
enum SchemaVersion = 2;

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

    // Last time used the entry in unix time. Assuming that it is always
    // running locally.
    long lastUse;
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

Miniorm openDatabase(Path dbFile) nothrow {
    return openDatabase(dbFile.toString);
}

Miniorm openDatabase(string dbFile) nothrow {
    logger.trace("opening database ", dbFile).collectException;
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
 * Waiting up to `timeout` for servers to be added. This handles the case where
 * a daemon have been spawned in the background.
 *
 * Params:
 *  db = database instance to read from
 *  filterBy_ = only hosts that are among these are added to the online set
 *  timeout = max time to wait for the `online` set to contain at least one host
 *  maxAge = only hosts that have a status newer than this is added to online
 */
Tuple!(HostLoad[], "online", HostLoad[], "unused") getServerLoads(ref Miniorm db,
        const Host[] filterBy_, const Duration timeout, const Duration maxAge) @trusted {
    import std.datetime : Clock, dur;
    import my.set;

    const lastUseLimit = Clock.currTime - maxAge;
    auto onlineHostSet = toSet(filterBy_.map!(a => a.get));
    bool filterBy(ServerTbl host) {
        return host.address in onlineHostSet && host.lastUpdate > lastUseLimit;
    }

    auto stopAt = Clock.currTime + timeout;
    while (Clock.currTime < stopAt) {
        typeof(return) rval;
        foreach (a; spinSql!(() => db.run(select!ServerTbl), logger.trace)(timeout)) {
            auto h = HostLoad(Host(a.address), Load(a.loadAvg,
                    a.accessTime.dur!"msecs", a.unknown), a.lastUpdate);
            if (!a.unknown && filterBy(a)) {
                rval.online ~= h;
            } else {
                rval.unused ~= h;
            }
        }

        if (!rval.online.empty || filterBy_.empty)
            return rval;
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
        return db.prepare(`INSERT OR IGNORE INTO ServerTbl (address,lastUpdate,accessTime,loadAvg,unknown,lastUse) VALUES(:address, :lastUpdate, :accessTime, :loadAvg, :unknown, :lastUse)`);
    }, logger.trace)(timeout);

    foreach (const h; cluster) {
        spinSql!(() {
            stmt.get.reset;
            stmt.get.bind(":address", h.get);
            stmt.get.bind(":lastUpdate", forceEarlyUpdate.toSqliteDateTime);
            stmt.get.bind(":accessTime", highAccessTime);
            stmt.get.bind(":loadAvg", highLoadAvg);
            stmt.get.bind(":unknown", true);
            stmt.get.bind(":lastUse", Clock.currTime.toUnixTime);
            stmt.get.execute;
        }, logger.trace)(timeout);
    }
}

void updateLastUse(ref Miniorm db, const Host[] cluster) {
    auto stmt = spinSql!(() {
        return db.prepare(
            `UPDATE OR IGNORE ServerTbl SET lastUse = :lastUse WHERE address = :address`);
    }, logger.trace)(timeout);

    const lastUse = Clock.currTime.toUnixTime;

    foreach (const h; cluster) {
        spinSql!(() {
            stmt.get.reset;
            stmt.get.bind(":address", h.get);
            stmt.get.bind(":lastUse", lastUse);
            stmt.get.execute;
        }, logger.trace)(timeout);
    }
}

/// Update the data for a server.
void newServer(ref Miniorm db, HostLoad a) {
    spinSql!(() {
        db.run(insertOrReplace!ServerTbl, ServerTbl(a.host, Clock.currTime,
            a.load.accessTime.total!"msecs", a.load.loadAvg, a.load.unknown,
            Clock.currTime.toUnixTime));
    }, logger.trace)(timeout, 100.dur!"msecs", 300.dur!"msecs");
}

/// Update the data for a server.
void updateServer(ref Miniorm db, HostLoad a, SysTime updateTime = Clock.currTime) {
    spinSql!(() {
        // using IGNORE because the host could have been removed.
        auto stmt = db.prepare(`UPDATE OR IGNORE ServerTbl SET lastUpdate = :lastUpdate, accessTime = :accessTime, loadAvg = :loadAvg, unknown = :unknown WHERE address = :address`);
        stmt.get.bind(":address", a.host.get);
        stmt.get.bind(":lastUpdate", updateTime.toSqliteDateTime);
        stmt.get.bind(":accessTime", a.load.accessTime.total!"msecs");
        stmt.get.bind(":loadAvg", a.load.loadAvg);
        stmt.get.bind(":unknown", a.load.unknown);
        stmt.get.execute;
    }, logger.trace)(timeout, 100.dur!"msecs", 300.dur!"msecs");
}

/// Those that haven't been used for `unused` seconds.
void removeUnusedServers(ref Miniorm db, Duration unused) {
    spinSql!(() {
        auto stmt = db.prepare(`DELETE FROM ServerTbl WHERE lastUse < :lastUse`);
        stmt.get.bind(":lastUse", Clock.currTime.toUnixTime - unused.total!"seconds");
        stmt.get.execute();
    }, logger.trace)(timeout);
}

void daemonBeat(ref Miniorm db) {
    spinSql!(() {
        db.run(insertOrReplace!DaemonBeat, DaemonBeat(0, Clock.currTime));
    }, logger.trace)(timeout);
}

SysTime getDaemonBeatClock(ref Miniorm db) {
    return spinSql!(() {
        foreach (a; db.run(select!DaemonBeat.where("id = 0", null))) {
            return a.beat;
        }
        return Clock.currTime;
    }, logger.trace)(timeout);
}

/// The heartbeat when daemon was last executed.
Duration getDaemonBeat(ref Miniorm db) {
    auto d = spinSql!(() {
        foreach (a; db.run(select!DaemonBeat.where("id = 0", null))) {
            return Clock.currTime - a.beat;
        }
        return Duration.max;
    }, logger.trace)(timeout);

    // can happen if there is a "junk" value but it has to be a little bit
    // robust against possible "jitter" thus accepting up to 1 minute "lag".
    if (d < (-1).dur!"minutes") {
        d = Duration.max;
    } else if (d < Duration.zero) {
        d = Duration.zero;
    }
    return d;
}

void clientBeat(ref Miniorm db) {
    spinSql!(() {
        db.run(insertOrReplace!ClientBeat, ClientBeat(0, Clock.currTime));
    }, logger.trace)(timeout);
}

Duration getClientBeat(ref Miniorm db) {
    auto d = spinSql!(() {
        foreach (a; db.run(select!ClientBeat.where("id = 0", null)))
            return Clock.currTime - a.beat;
        return Duration.max;
    }, logger.trace)(timeout);

    // can happen if there is a "junk" value but it has to be a little bit
    // robust against possible "jitter" thus accepting up to 1 minute "lag".
    if (d < (-1).dur!"minutes") {
        d = Duration.max;
    } else if (d < Duration.zero) {
        d = Duration.zero;
    }
    return d;
}

/// Returns: the server that have the oldest update timestamp.
Nullable!Host getOldestServer(ref Miniorm db) {
    auto stmt = spinSql!(() {
        return db.prepare(
            `SELECT address FROM ServerTbl ORDER BY datetime(lastUpdate) ASC LIMIT 1`);
    }, logger.trace)(timeout);

    return spinSql!(() {
        foreach (a; stmt.get.execute) {
            auto address = a.peek!string(0);
            return Nullable!Host(Host(address));
        }
        return Nullable!Host.init;
    }, logger.trace)(timeout);
}

Host[] getLeastLoadedServer(ref Miniorm db) {
    import std.format : format;

    auto stmt = spinSql!(() {
        return db.prepare(
            format!`SELECT address,lastUse,loadAvg FROM ServerTbl ORDER BY lastUse DESC, loadAvg ASC LIMIT %s`(
            topCandidades));
    }, logger.trace)(timeout);

    return spinSql!(() {
        return stmt.get.execute.map!(a => Host(a.peek!string(0))).array;
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

version (unittest) {
    private struct UnittestDb {
        string name;
        Miniorm db;
        Host[] hosts;

        alias db this;

        ~this() {
            import std.file : remove;

            db.close;
            remove(name);
        }
    }

    private UnittestDb makeUnittestDb(string file = __FILE__, uint line = __LINE__)() {
        import std.format : format;
        import std.path : baseName;

        immutable dbFname = format!"%s_%s.sqlite3"(file.baseName, line);
        return UnittestDb(dbFname, openDatabase(dbFname));
    }

    private void populate(ref UnittestDb db, uint nr) {
        import std.format : format;
        import std.range;
        import std.algorithm;

        db.hosts = iota(0, nr).map!(a => Host(format!"h%s"(a))).array;
        syncCluster(db, db.hosts);
    }

    private void fejkLoad(ref UnittestDb db, double start, double step) {
        foreach (a; db.hosts) {
            updateServer(db, HostLoad(a, Load(start, 50.dur!"msecs", false)));
            start += step;
        }
    }
}

@("shall filter out all servers with an unknown status")
unittest {
    auto db = makeUnittestDb();
    populate(db, 10);
    auto res = getServerLoads(db, db.hosts[0 .. $ / 2], 1.dur!"seconds", 10.dur!"minutes");
    res.online.length.shouldEqual(0);
}

@("shall split the returned hosts by the host set when retrieving the load")
unittest {
    auto db = makeUnittestDb();
    populate(db, 10);
    fejkLoad(db, 0.1, 0.3);

    auto res = getServerLoads(db, db.hosts[0 .. $ / 2], 1.dur!"seconds", 10.dur!"minutes");
    res.online.length.shouldEqual(5);
    res.online.map!(a => a.host).array.shouldEqual([
            "h0", "h1", "h2", "h3", "h4"
            ]);
    res.unused.length.shouldEqual(5);
}

@("shall put hosts with a too old status update in the unused set when splitting")
unittest {
    auto db = makeUnittestDb();
    populate(db, 10);
    fejkLoad(db, 0.1, 0.3);
    updateServer(db, HostLoad(Host("h3"), Load(0.5, 50.dur!"msecs", false)),
            Clock.currTime - 11.dur!"minutes");

    auto res = getServerLoads(db, db.hosts[0 .. $ / 2], 1.dur!"seconds", 10.dur!"minutes");
    res.online.length.shouldEqual(4);
    res.online.map!(a => a.host).array.shouldEqual(["h0", "h1", "h2", "h4"]);
    res.unused.length.shouldEqual(6);
}
