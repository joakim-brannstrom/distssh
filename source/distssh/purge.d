/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Run in the background a continious purge of all process trees that do not have
a distssh client in the root.
*/
module distssh.purge;

import core.time : Duration;
import logger = std.experimental.logger;
import std.algorithm : splitter, map, filter, joiner, sort;
import std.array : array, appender, empty;
import std.conv;
import std.exception : collectException, ifThrown;
import std.file;
import std.path;
import std.range : iota, only;
import std.stdio : File, writeln, writefln;
import std.typecons : Nullable, NullableRef;

import core.sys.posix.sys.types : uid_t;

import process;
import colorlog;

import distssh.config;
import distssh.metric;
import distssh.set;
import distssh.types;
import distssh.utility;

@safe:

int cli(const Config fconf, Config.LocalPurge conf) @trusted nothrow {
    Whitelist wl;
    try {
        wl = Whitelist(conf.whiteList);
    } catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }

    try {
        auto pmap = makePidMap.filterByCurrentUser;
        updateProc(pmap);

        foreach (ref t; pmap.splitToSubMaps) {
            bool hasWhiteListProc;
            foreach (c; t.map.proc) {
                if (wl.match(c)) {
                    hasWhiteListProc = true;
                    break;
                }
            }

            if (conf.kill && !hasWhiteListProc) {
                auto killed = process.kill(t.map);
                reap(killed);
            }
            if (conf.print) {
                if (hasWhiteListProc && fconf.global.verbosity == VerboseMode.info) {
                    logger.info("whitelist".color(Color.green), " process tree");
                    printTree!(writefln)(t);
                } else if (!hasWhiteListProc) {
                    logger.info("terminate".color(Color.red), " process tree");
                    printTree!(writefln)(t);
                }
            }
        }
    } catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }

    return 0;
}

int cli(const Config fconf, Config.Purge conf) @trusted nothrow {
    import std.algorithm : sort;
    import std.stdio : writefln, writeln, stdout;

    auto hosts = RemoteHostCache.make(fconf.global.dbPath, fconf.global.cluster);

    if (hosts.empty) {
        logger.errorf("No remote host online").collectException;
        return 1;
    }

    auto failed = appender!(Host[])();
    auto econf = ExecuteOnHostConf(fconf.global.workDir, null,
            fconf.global.importEnv, fconf.global.cloneEnv, fconf.global.noImportEnv);

    foreach (a; hosts) {
        logger.info("Connecting to ", a).collectException;
        if (purgeServer(econf, conf, a) != 0) {
            failed.put(a);
        }
    }

    if (!failed.data.empty) {
        logger.warning("Failed to purge").collectException;
        foreach (a; failed.data) {
            logger.info(a).collectException;
        }
    }

    return failed.data.empty ? 0 : 1;
}

int purgeServer(ExecuteOnHostConf econf, const Config.Purge pconf, Host a) @safe nothrow {
    import std.file : thisExePath;
    import std.process : escapeShellFileName;

    econf.command = () {
        string[] r;
        try {
            r = [thisExePath.escapeShellFileName];
        } catch (Exception e) {
            r = ["distssh"];
        }
        return r ~ "localpurge";
    }();

    if (pconf.print) {
        econf.command ~= "-p";
    }
    if (pconf.kill) {
        econf.command ~= "-k";
    }

    econf.command ~= pconf.whiteList.map!(a => ["--whitelist", a]).joiner.array;
    econf.command ~= readPurgeEnvWhiteList.map!(a => ["--whitelist", a]).joiner.array;

    logger.trace("Purge command ", econf.command).collectException;

    return () @trusted { return executeOnHost(econf, a); }();
}

string[] readPurgeEnvWhiteList() @safe nothrow {
    import std.process : environment;
    import std.string : strip;

    try {
        return environment.get(globalEnvPurgeWhiteList, "").strip.splitter(";").map!(a => a.strip)
            .filter!(a => !a.empty)
            .array;
    } catch (Exception e) {
    }

    return null;
}

private:

void printTree(alias printT, T)(T t) {
    printT("root:%s %s", t.root.to!string.color(Color.magenta)
            .mode(Mode.bold), t.map.getProc(t.root).color(Color.cyan).mode(Mode.underline));
    foreach (p; t.map.pids.filter!(a => a != t.root)) {
        printT("  pid:%s %s", p.to!string.color(Color.magenta), t.map.getProc(p));
    }
}

struct Whitelist {
    import std.regex : regex, matchFirst, Regex;

    Regex!char[] list;

    this(string[] whitelist) {
        foreach (w; whitelist) {
            list ~= regex(w, "i");
        }
    }

    bool match(string s) {
        foreach (ref l; list) {
            auto m = matchFirst(s, l);
            if (!m.empty) {
                return true;
            }
        }
        return false;
    }
}
