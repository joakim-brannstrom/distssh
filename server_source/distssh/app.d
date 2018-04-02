/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This file contains the P2P daemon.
For now only "local" support without any communication with other daemons are supported.
*/
module distssh_server.app;

import std.exception : collectException;
import std.typecons : Nullable;
import logger = std.experimental.logger;

import eventcore.driver : StreamSocketFD, IOStatus;

import distssh.unix_path;

static import std.getopt;

version (Posix) {
} else {
    static assert(0, "Not a posix system. Support for Unix domain sockets are required");
}

version (unittest) {
} else {
    int main(string[] args) {
        try {
            import distssh.app_logger;

            auto simple_logger = new SimpleLogger();
            logger.sharedLog(simple_logger);
        }
        catch (Exception e) {
            logger.warning(e.msg).collectException;
        }

        Options opts;
        try {
            opts = parseUserArgs(args);
        }
        catch (Exception e) {
            logger.error(e.msg).collectException;
            return 1;
        }

        try {
            if (opts.verbose) {
                logger.globalLogLevel(logger.LogLevel.all);
            } else {
                logger.globalLogLevel(logger.LogLevel.warning);
            }
        }
        catch (Exception e) {
            logger.warning(e.msg).collectException;
        }

        if (opts.help) {
            printHelp(opts);
            return 0;
        }

        return appMain(opts);
    }
}

enum PacketKind {
    none,
    // Client requests a remote host to connect to
    getRemoteHost,
}

int appMain(const Options opts) nothrow {
    import core.sys.posix.signal : SIGPIPE;
    import core.time : Duration;
    import std.functional : toDelegate;
    import std.file : tempDir;
    import eventcore.core;
    import eventcore.socket;
    import eventcore.internal.utils;
    import std.socket : UnixAddress;

    static void sigPipe(SignalListenID, SignalStatus, int) @safe pure nothrow @nogc {
    }

    eventDriver.signals.listen(SIGPIPE, toDelegate(&sigPipe));

    auto addr = () {
        try {
            const safe_socket_p = createUnixDomainSocketPath(tempDir);
            setTimerCleanupStaleSocket(safe_socket_p);
            logger.trace("Socket at ", safe_socket_p);
            return new UnixAddress(safe_socket_p);
        }
        catch (Exception e) {
            logger.error(e.msg).collectException;
        }

        return null;
    }();

    if (addr is null) {
        logger.error("Unable to create a domain socket. For more information execute with -v")
            .collectException;
        return 1;
    }

    import distssh.msg_router : Router;

    auto router = new Router!PacketKind;
    router.route(PacketKind.none, toDelegate(&packetNone));
    router.route(PacketKind.getRemoteHost, toDelegate(&packetGetRemoteHost));

    auto server = eventDriver.sockets.listenStream(addr, &router.onClientConnect);

    print("Listening for requests on port %s", addr);
    while (eventDriver.core.waiterCount) {
        eventDriver.core.processEvents(Duration.max);
    }

    return 0;
}

struct Options {
    string selfBinary;

    bool help;
    bool verbose;
    std.getopt.GetoptResult help_info;
}

Options parseUserArgs(string[] args) {
    import std.path : buildPath, dirName, baseName;
    import std.file : thisExePath;

    Options opts;

    opts.selfBinary = buildPath(thisExePath.dirName, args[0].baseName);

    try {
        // dfmt off
        opts.help_info = std.getopt.getopt(args, std.getopt.config.passThrough,
            std.getopt.config.keepEndOfOptions,
            "v|verbose", "verbose logging", &opts.verbose,
            );
        // dfmt on
    }
    catch (Exception e) {
        opts.help = true;
        logger.error(e.msg).collectException;
    }

    return opts;
}

void printHelp(const Options opts) nothrow {
    import std.getopt : defaultGetoptPrinter;
    import std.format : format;
    import std.path : baseName;

    auto help_txt = "usage: %s [options]\n";

    try {
        defaultGetoptPrinter(format(help_txt, opts.selfBinary.baseName), opts.help_info.options.dup);
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
    }
}

/** Cleaup stale sockets after startup.

  10s is intended to be "after" the server has started and hopefully answered the first client request.
  The important thing is that it doesn't slow down the "first" answer to the client.

  #SPC-cleanup_stale_sockets
  */
void setTimerCleanupStaleSocket(UnixSocketPath self_p) @safe nothrow {
    import core.time : dur;
    import std.path : dirName;
    import eventcore.core;
    import eventcore.internal.utils;

    const self_dir = self_p.dirName;
    const self_scan_dir = self_dir.dirName;

    static struct TryCleanup {
        string p;

        void dg(TimerID tm) @trusted nothrow {
            import std.file : rmdirRecurse;

            scope (exit)
                eventDriver.timers.releaseRef(tm);

            logger.trace("Removing stale socket ", p).collectException;

            try {
                rmdirRecurse(p);
            }
            catch (Exception e) {
            }
        }
    }

    void findPotentialSockets(TimerID tm) @trusted nothrow {
        import std.algorithm : filter;
        import std.file : dirEntries, SpanMode;
        import distssh.unix_path;

        scope (exit)
            eventDriver.timers.releaseRef(tm);

        try {
            foreach (p; dirEntries(self_scan_dir, SpanMode.shallow).filter!(
                    a => a.isUserUnixDomainSocket).filter!(a => a != self_dir)) {
                auto tc = new TryCleanup(p.name);

                auto ptm = eventDriver.timers.create;
                eventDriver.timers.set(ptm, 50.dur!"msecs", 0.dur!"msecs");
                eventDriver.timers.wait(ptm, &tc.dg);
            }
        }
        catch (Exception e) {
        }
    }

    auto tm = eventDriver.timers.create();
    eventDriver.timers.set(tm, 10.dur!"seconds", 0.dur!"msecs");
    eventDriver.timers.wait(tm, &findPotentialSockets);
}

/// An invalid packet so do nothing.
bool packetNone(ref StreamSocketFD, ubyte[]) @safe nothrow {
    return true;
}

/// Answer a client with a potential remote host.
bool packetGetRemoteHost(ref StreamSocketFD client, ubyte[]) @safe nothrow {
    import std.array : appender;
    import std.functional : toDelegate;
    import eventcore.core;
    import distssh.protocol;
    import distssh.socket_protocol;

    // TODO this is inefficient. Multiple copies of data.

    auto app = appender!(ubyte[])();
    {
        ubyte[ushort.sizeof] len;
        app.put(len[]);
    }

    auto ser = Serialize!(typeof(app))(app);
    ser.pack(RemoteHost("localhost"));

    mux(app.data);

    auto cb = () @trusted{ return toDelegate(&ignoreWriteCallback); }();

    eventDriver.sockets.write(client, app.data, IOMode.all, cb);

    return true;
}

void ignoreWriteCallback(StreamSocketFD, IOStatus, size_t) nothrow @safe {
}
