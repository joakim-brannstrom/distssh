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
import std.exception : collectException;
import std.file;
import std.path;
import std.range : iota;
import std.stdio : File, writeln, writefln;
import std.typecons : Nullable, NullableRef;

import core.sys.posix.sys.types : uid_t;

import process;
import colorlog;

import distssh.config;
import distssh.metric;
import distssh.set;
import distssh.types;

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

            if (conf.print) {
                if (hasWhiteListProc) {
                    logger.info("whitelist".color(Color.green), " process tree");
                } else {
                    logger.info("terminate".color(Color.red), " process tree");
                }
                writefln("root:%s %s", t.root.to!string.color(Color.magenta)
                        .mode(Mode.bold), t.map.getProc(t.root)
                        .color(Color.cyan).mode(Mode.underline));
                foreach (p; t.map.pids.filter!(a => a != t.root)) {
                    writefln("  pid:%s %s", p.to!string.color(Color.magenta), t.map.getProc(p));
                }
            }
            if (conf.kill && !hasWhiteListProc) {
                auto killed = process.kill(t.map);
                reap(killed);
            }
        }
    } catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }

    return 0;
}

int cli(const Config fconf, Config.Purge conf) @trusted nothrow {
    return 0;
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
