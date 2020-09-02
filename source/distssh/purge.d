/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Run in the background a continious purge of all process trees that do not have
a distssh client in the root.
*/
module distssh.purge;

import logger = std.experimental.logger;
import std.algorithm : splitter, map, filter, joiner;
import std.array : array, appender, empty;
import std.conv;
import std.exception : collectException;
import std.file;
import std.path;
import std.range : only;
import std.typecons : Flag;

import core.sys.posix.sys.types : uid_t;

import colorlog;
import my.set;
import proc;

import distssh.config;
import distssh.metric;
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

    void iterate(alias fn)() {
        auto pmap = () {
            auto rval = makePidMap;
            if (conf.userFilter)
                return rval.filterByCurrentUser;
            // assuming that processes owned by root such as init never
            // interesting to kill. 4294967295 is a magic number used in linux
            // for system processes.
            return rval.removeUser(0).removeUser(4294967295);
        }();
        updateProc(pmap);
        debug logger.trace(pmap);

        foreach (ref t; pmap.splitToSubMaps) {
            bool hasWhiteListProc;
            foreach (c; t.map.proc) {
                if (wl.match(c)) {
                    hasWhiteListProc = true;
                    break;
                }
            }

            fn(hasWhiteListProc, t.map, t.root);
        }
    }

    void purgeKill(bool hasWhiteListProc, ref PidMap pmap, RawPid root) {
        if (conf.kill && !hasWhiteListProc) {
            auto killed = proc.kill(pmap, cast(Flag!"onlyCurrentUser") conf.userFilter);
            reap(killed);
        }
    }

    void purgePrint(bool hasWhiteListProc, ref PidMap pmap, RawPid root) {
        import std.stdio : writeln;

        if (conf.print) {
            if (hasWhiteListProc && fconf.global.verbosity >= VerboseMode.info) {
                logger.info("whitelist".color(Color.green), " process tree");
                writeln(toTreeString(pmap));
            } else if (!hasWhiteListProc) {
                logger.info("terminate".color(Color.red), " process tree");
                writeln(toTreeString(pmap));
            }
        }
    }

    try {
        iterate!purgeKill();
        iterate!purgePrint();
    } catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }

    return 0;
}

int cli(const Config fconf, Config.Purge conf) @trusted nothrow {
    import std.algorithm : sort;

    auto hosts = RemoteHostCache.make(fconf.global.dbPath, fconf.global.cluster).allRange;

    if (hosts.empty) {
        logger.errorf("No remote host online").collectException;
        return 1;
    }

    auto failed = appender!(Host[])();
    auto econf = ExecuteOnHostConf(fconf.global.workDir, null,
            fconf.global.importEnv, fconf.global.cloneEnv, fconf.global.noImportEnv);

    foreach (a; hosts.map!(a => a.host)) {
        logger.info("Connecting to ", a).collectException;
        if (purgeServer(econf, conf, a, fconf.global.verbosity) != 0) {
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

int purgeServer(ExecuteOnHostConf econf, const Config.Purge pconf, Host host,
        VerboseMode vmode = VerboseMode.init) @safe nothrow {
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

    try {
        econf.command ~= ["-v", vmode.to!string];
    } catch (Exception e) {
    }

    if (pconf.print) {
        econf.command ~= "-p";
    }
    if (pconf.kill) {
        econf.command ~= "-k";
    }
    if (pconf.userFilter) {
        econf.command ~= "--user-filter";
    }

    Set!string wlist;
    foreach (a; only(pconf.whiteList, readPurgeEnvWhiteList).joiner) {
        wlist.add(a);
    }

    econf.command ~= wlist.toArray.map!(a => ["--whitelist", a]).joiner.array;

    logger.trace("Purge command ", econf.command).collectException;

    return () @trusted { return executeOnHost(econf, host); }();
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
