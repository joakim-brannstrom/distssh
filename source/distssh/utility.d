/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.utility;

import core.time : Duration;
import std.algorithm : splitter, map, filter, joiner;
import std.exception : collectException;
import std.stdio : File;
import std.typecons : Nullable, NullableRef;
import logger = std.experimental.logger;

import colorlog;

import from_;
import my.path;

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
    import std.process : tryWait, Redirect, pipeProcess, escapeShellFileName;

    import distssh.protocol : ProtocolEnv;

    // #SPC-draft_remote_cmd_spec
    try {
        auto args = ["ssh"] ~ sshNoLoginArgs ~ [
            host, thisExePath, "localrun", "--workdir",
            conf.workDir.escapeShellFileName, "--stdin-msgpack-env", "--"
        ] ~ format!"'%-(%s %)'"(conf.command);

        logger.tracef("Connecting to %s. Run %s", host, args.joiner(" "));

        auto p = pipeProcess(args, Redirect.stdin);

        auto pwriter = PipeWriter(p.stdin);

        ProtocolEnv env;
        if (conf.cloneEnv)
            env = cloneEnv;
        else if (!conf.noImportEnv)
            env = readEnv(conf.importEnv.absolutePath);
        pwriter.pack(env);

        while (true) {
            try {
                auto st = p.pid.tryWait;
                if (st.terminated)
                    return st.status;

                Watchdog.ping(pwriter);
            } catch (Exception e) {
            }

            Thread.sleep(50.dur!"msecs");
        }
    } catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }
}

struct PipeReader {
    import distssh.protocol : Deserialize;

    NonblockingFd nfd;
    Deserialize deser;

    alias deser this;

    this(int fd) {
        this.nfd = NonblockingFd(fd);
    }

    // Update the buffer with data from the pipe.
    void update() nothrow {
        ubyte[128] buf;
        ubyte[] s = buf[];

        try {
            nfd.read(s);
            if (s.length > 0)
                deser.put(s);
        } catch (Exception e) {
        }

        deser.cleanupUntilKind;
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

struct NonblockingFd {
    int fileno;

    private const int old_fcntl;

    this(int fd) {
        this.fileno = fd;

        import core.sys.posix.fcntl : fcntl, F_SETFL, F_GETFL, O_NONBLOCK;

        old_fcntl = fcntl(fileno, F_GETFL);
        fcntl(fileno, F_SETFL, old_fcntl | O_NONBLOCK);
    }

    ~this() {
        import core.sys.posix.fcntl : fcntl, F_SETFL;

        fcntl(fileno, F_SETFL, old_fcntl);
    }

    void read(ref ubyte[] buf) {
        static import core.sys.posix.unistd;

        auto len = core.sys.posix.unistd.read(fileno, buf.ptr, buf.length);
        if (len > 0)
            buf = buf[0 .. len];
    }
}

from.distssh.protocol.ProtocolEnv readEnv(string filename) nothrow {
    import distssh.protocol : ProtocolEnv, EnvVariable, Deserialize;
    import std.file : exists;
    import std.stdio : File;

    ProtocolEnv rval;

    if (!exists(filename)) {
        logger.trace("File to import the environment from do not exist: ",
                filename).collectException;
        return rval;
    }

    try {
        auto fin = File(filename);
        Deserialize deser;

        ubyte[128] buf;
        while (!fin.eof) {
            auto read_ = fin.rawRead(buf[]);
            deser.put(read_);
        }

        rval = deser.unpack!(ProtocolEnv);
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

struct Watchdog {
    import std.datetime.stopwatch : StopWatch;

    enum State {
        ok,
        timeout
    }

    private {
        State st;
        Duration timeout;
        NullableRef!PipeReader pread;
        StopWatch sw;
    }

    this(ref PipeReader pread, Duration timeout) {
        this.pread = &pread;
        this.timeout = timeout;
        sw.start;
    }

    void update() {
        import distssh.protocol : HeartBeat;

        if (!pread.unpack!HeartBeat.isNull) {
            sw.reset;
            sw.start;
        } else if (sw.peek > timeout) {
            st = State.timeout;
        }
    }

    bool isTimeout() {
        return State.timeout == st;
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
