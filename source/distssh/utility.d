/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.utility;

import core.time : Duration;
import std.algorithm : splitter, map, filter, joiner;
import std.array : empty;
import std.exception : collectException;
import std.stdio : File;
import std.typecons : Nullable, NullableRef;
import logger = std.experimental.logger;

import colorlog;

import my.from_;
import my.path;
import my.fswatch : FdPoller, PollStatus, PollEvent, PollResult, FdPoll;

import distssh.config;
import distssh.metric;
import distssh.types;

struct ExecuteOnHostConf {
    string workDir;
    string[] command;
    string importEnv;
    bool cloneEnv;
    bool noImportEnv;
}

/** Execute a command on a remote host.
 *
 * #SPC-automatic_env_import
 */
int executeOnHost(const ExecuteOnHostConf conf, Host host) nothrow {
    import core.thread : Thread;
    import core.time : dur, MonoTime;
    import std.file : thisExePath;
    import std.format : format;
    import std.path : absolutePath;
    import std.process : tryWait, Redirect, pipeProcess;
    import std.stdio : stdin, stdout, stderr;
    static import core.sys.posix.unistd;

    import my.timer : makeInterval, makeTimers;
    import my.tty : setCBreak, CBreak;
    import distssh.protocol : ProtocolEnv, ConfDone, Command, Workdir, Key, TerminalCapability;
    import distssh.connection : sshCmdArgs, setupMultiplexDir;

    try {
        const isInteractive = core.sys.posix.unistd.isatty(stdin.fileno) == 1;

        CBreak consoleChange;
        scope (exit)
            () {
            if (isInteractive) {
                consoleChange.reset(stdin.fileno);
                consoleChange.reset(stdout.fileno);
                consoleChange.reset(stderr.fileno);
            }
        }();

        auto args = () {
            auto a = ["localrun", "--stdin-msgpack-env"];
            if (isInteractive) {
                a ~= "--pseudo-terminal";
            }
            return sshCmdArgs(host, a).toArgs;
        }();

        logger.tracef("Connecting to %s. Run %s", host, args.joiner(" "));

        auto p = pipeProcess(args, Redirect.stdin);

        auto pwriter = PipeWriter(p.stdin);

        ProtocolEnv env;
        if (conf.cloneEnv)
            env = cloneEnv;
        else if (!conf.noImportEnv)
            env = readEnv(conf.importEnv.absolutePath);
        pwriter.pack(env);
        pwriter.pack(Command(conf.command.dup));
        pwriter.pack(Workdir(conf.workDir));
        if (isInteractive) {
            import core.sys.posix.termios;

            termios mode;
            if (tcgetattr(1, &mode) == 0) {
                pwriter.pack(TerminalCapability(mode));
            }
        }
        pwriter.pack!ConfDone;

        FdPoller poller;
        poller.put(FdPoll(stdin.fileno), [PollEvent.in_]);

        if (isInteractive) {
            consoleChange = setCBreak(stdin.fileno);
        }

        auto timers = makeTimers;
        makeInterval(timers, () @trusted {
            HeartBeatMonitor.ping(pwriter);
            return 250.dur!"msecs";
        }, 50.dur!"msecs");

        // send stdin to the other side
        ubyte[4096] stdinBuf;
        makeInterval(timers, () @trusted {
            auto res = poller.wait(10.dur!"msecs");
            if (!res.empty && res[0].status[PollStatus.in_]) {
                auto len = core.sys.posix.unistd.read(stdin.fileno, stdinBuf.ptr, stdinBuf.length);
                if (len > 0) {
                    pwriter.pack(Key(stdinBuf[0 .. len]));
                }

                return 1.dur!"msecs";
            }

            // slower if not much is happening
            return 100.dur!"msecs";
        }, 25.dur!"msecs");

        // dummy event to force the timer to return after 50ms
        makeInterval(timers, () @safe { return 50.dur!"msecs"; }, 50.dur!"msecs");

        while (true) {
            try {
                auto st = p.pid.tryWait;
                if (st.terminated)
                    return st.status;

                timers.tick(50.dur!"msecs");
            } catch (Exception e) {
            }
        }
    } catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }
}

struct PipeReader {
    import distssh.protocol : Deserialize;

    private {
        FdPoller poller;
        ubyte[4096] buf;
        int fd;
    }

    Deserialize deser;

    alias deser this;

    this(int fd) {
        this.fd = fd;
        poller.put(FdPoll(fd), [PollEvent.in_]);
    }

    // Update the buffer with data from the pipe.
    void update() nothrow {
        try {
            auto s = read;
            if (!s.empty)
                deser.put(s);
        } catch (Exception e) {
        }
    }

    /// The returned slice is to a local, static array. It must be used/copied
    /// before next call to read.
    private ubyte[] read() return  {
        static import core.sys.posix.unistd;

        auto res = poller.wait();
        if (res.empty) {
            return null;
        }

        if (!res[0].status[PollStatus.in_]) {
            return null;
        }

        auto len = core.sys.posix.unistd.read(fd, buf.ptr, buf.length);
        if (len > 0)
            return buf[0 .. len];
        return null;
    }
}

struct PipeWriter {
    import distssh.protocol : Serialize;

    File fout;
    Serialize!(void delegate(const(ubyte)[]) @safe) ser;

    alias ser this;

    this(File f) {
        this.fout = f;
        this.ser = typeof(ser)(&this.put);
    }

    void put(const(ubyte)[] v) @safe {
        fout.rawWrite(v);
        fout.flush;
    }
}

from.distssh.protocol.ProtocolEnv readEnv(string filename) nothrow {
    import distssh.protocol : ProtocolEnv, EnvVariable, Deserialize;
    import std.file : exists;
    import std.stdio : File;
    import sumtype;
    import distssh.protocol;

    ProtocolEnv rval;

    if (!exists(filename)) {
        logger.trace("File to import the environment from do not exist: ",
                filename).collectException;
        return rval;
    }

    try {
        auto fin = File(filename);
        Deserialize deser;

        ubyte[4096] buf;
        while (!fin.eof) {
            auto read_ = fin.rawRead(buf[]);
            deser.put(read_);
        }

        deser.unpack.match!((None x) {}, (ConfDone x) {}, (ProtocolEnv x) {
            rval = x;
        }, (HeartBeat x) {}, (Command x) {}, (Workdir x) {}, (Key x) {}, (TerminalCapability x) {
        });
    } catch (Exception e) {
        logger.error(e.msg).collectException;
        logger.errorf("Unable to import environment from '%s'", filename).collectException;
    }

    return rval;
}

/**
 * #SPC-env_export_filter
 *
 * Params:
 *  env = a null terminated array of C strings.
 *
 * Returns: a clone of the environment.
 */
auto cloneEnv() nothrow {
    import std.process : environment;
    import std.string : strip;
    import distssh.protocol : ProtocolEnv, EnvVariable;

    ProtocolEnv app;

    try {
        auto env = environment.toAA;

        foreach (k; environment.get(globalEnvFilterKey, null)
                .strip.splitter(';').map!(a => a.strip)
                .filter!(a => a.length != 0)) {
            if (env.remove(k)) {
                logger.tracef("Removed '%s' from the exported environment", k);
            }
        }

        foreach (const a; env.byKeyValue) {
            app ~= EnvVariable(a.key, a.value);
        }
    } catch (Exception e) {
        logger.warning(e.msg).collectException;
    }

    return app;
}

/// Monitor the heartbeats from the client.
struct HeartBeatMonitor {
    import std.datetime.stopwatch : StopWatch;

    private {
        Duration timeout;
        StopWatch sw;
    }

    this(Duration timeout) {
        this.timeout = timeout;
        sw.start;
    }

    /// A heartbeat has been received.
    void beat() {
        sw.reset;
        sw.start;
    }

    bool isTimeout() {
        if (sw.peek > timeout) {
            return true;
        }
        return false;
    }

    static void ping(ref PipeWriter f) {
        import distssh.protocol : HeartBeat;

        f.pack!HeartBeat;
    }
}

/// Update the client beat in a separate thread, slowely, to keep the daemon
/// running if the client is executing a long running job.
struct BackgroundClientBeat {
    import std.concurrency : send, spawn, receiveTimeout, Tid;

    private {
        bool isRunning;
        Tid bg;

        enum Msg {
            stop,
        }
    }

    this(AbsolutePath dbPath) {
        bg = spawn(&tick, dbPath);
        isRunning = true;
    }

    ~this() @trusted {
        if (!isRunning)
            return;

        isRunning = false;
        send(bg, Msg.stop);
    }

    private static void tick(AbsolutePath dbPath) nothrow {
        import core.time : dur;
        import distssh.database;

        const tickInterval = 10.dur!"minutes";

        bool running = true;
        while (running) {
            try {
                receiveTimeout(tickInterval, (Msg x) { running = false; });
            } catch (Exception e) {
                running = false;
            }

            try {
                auto db = openDatabase(dbPath);
                db.clientBeat;
            } catch (Exception e) {
            }
        }
    }
}

/// Returns: the switches to use to execute the shell.
string[] shellSwitch(string shell) {
    import std.path : baseName;

    if (shell.baseName == "bash")
        return ["--noprofile", "--norc", "-c"];
    return ["-c"];
}
