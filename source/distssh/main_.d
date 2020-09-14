/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Methods prefixed with `cli_` are strongly related to user commands.
They more or less fully implement a command line interface command.
*/
module distssh.main_;

import core.time : Duration;
import logger = std.experimental.logger;
import std.algorithm : splitter, map, filter, joiner;
import std.array : empty;
import std.exception : collectException;
import std.stdio : File;
import std.typecons : Nullable, NullableRef;

import colorlog;

import my.from_;
import my.path;

import distssh.config;
import distssh.metric;
import distssh.types;
import distssh.utility;

static import std.getopt;

import unit_threaded.attrs : Serial;

version (unittest) {
    import unit_threaded.assertions;
}

int rmain(string[] args) {
    import distssh.daemon;
    static import distssh.purge;

    confLogger(VerboseMode.info);

    auto conf = parseUserArgs(args);

    if (conf.global.helpInfo.helpWanted) {
        return cli(conf);
    }

    confLogger(conf.global.verbosity);
    logger.trace(conf);

    import core.stdc.signal : signal;
    import std.file : symlink;
    import std.stdio : writeln;
    import std.variant : visit;

    // register a handler for writing to a closed pipe in case it ever happens.
    // the handler ignores it.
    signal(13, &handleSIGPIPE);

    // dfmt off
    return conf.data.visit!(
          (Config.Help a) => cli(conf),
          (Config.Shell a) => cli(conf, a),
          (Config.Cmd a) => cli(conf, a),
          (Config.LocalRun a) => cli(conf, a),
          (Config.Install a) => cli(conf, a, (string src, string dst) => symlink(src, dst)),
          (Config.MeasureHosts a) => cli(conf, a),
          (Config.LocalLoad a) => cli(a, (string s) => writeln(s)),
          (Config.RunOnAll a) => cli(conf, a),
          (Config.LocalShell a) => cli(conf, a),
          (Config.Env a) => cli(conf, a),
          (Config.Daemon a) => distssh.daemon.cli(conf, a),
          (Config.Purge a) => distssh.purge.cli(conf, a),
          (Config.LocalPurge a) => distssh.purge.cli(conf, a),
    );
    // dfmt on
}

private:

/// dummy used to ignore SIGPIPE
extern (C) void handleSIGPIPE(int sig) nothrow @nogc @system {
}

int cli(Config conf) {
    conf.printHelp;
    return 0;
}

int cli(const Config fconf, Config.Shell conf) {
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.process : spawnProcess, wait;
    import std.stdio : writeln, writefln;
    import distssh.connection : sshShellArgs;

    auto hosts = RemoteHostCache.make(fconf.global.dbPath, fconf.global.cluster).bestSelectRange;

    if (hosts.empty) {
        logger.errorf("No remote host online").collectException;
    }

    auto bgBeat = BackgroundClientBeat(AbsolutePath(fconf.global.dbPath));

    const timout_until_considered_successfull_connection = fconf.global.timeout * 2;

    foreach (host; hosts) {
        try {
            writeln("Connecting to ", host);

            auto sw = StopWatch(AutoStart.yes);

            auto exit_status = spawnProcess(sshShellArgs(host, fconf.global.workDir.Path).toArgs)
                .wait;

            // #SPC-fallback_remote_host
            if (exit_status == 0 || sw.peek > timout_until_considered_successfull_connection) {
                writefln("Connection to %s closed.", host);
                return exit_status;
            } else {
                logger.warningf("Connection failed to %s. Falling back on next available host",
                        host);
            }
        } catch (Exception e) {
            logger.error(e.msg).collectException;
        }
    }

    logger.error("No remote host online").collectException;
    return 1;
}

// #SPC-fast_env_startup
int cli(const Config fconf, Config.Cmd conf) {
    import std.stdio : stdout;

    if (fconf.global.command.empty) {
        logger.error("No command specified");
        logger.error("Specify by adding -- <my command>");
        return 1;
    }

    auto bgBeat = BackgroundClientBeat(AbsolutePath(fconf.global.dbPath));

    foreach (host; RemoteHostCache.make(fconf.global.dbPath, fconf.global.cluster).bestSelectRange) {
        logger.info("Connecting to ", host);
        // to ensure connecting to is at the top of e.g. logfiles when the user run
        // distcmd env > log.txt
        stdout.flush;
        return executeOnHost(ExecuteOnHostConf(fconf.global.workDir, fconf.global.command.dup,
                fconf.global.importEnv, fconf.global.cloneEnv, fconf.global.noImportEnv), host);
    }

    logger.error("No remote host online from the available ",
            fconf.global.cluster).collectException;
    return 1;
}

// #SPC-fast_env_startup
int cli(const Config fconf, Config.LocalRun conf) {
    import core.time : dur;
    import std.stdio : File, stdin, stdout;
    import std.file : exists;
    import std.process : PConfig = Config, Redirect, userShell, thisProcessID;
    import std.utf : toUTF8;
    import proc;
    import sumtype;
    import my.timer : makeTimers, makeInterval;
    import distssh.protocol;

    static struct LocalRunConf {
        import core.sys.posix.termios;

        string[string] env;
        string[] cmd;
        string workdir;
        termios mode;
    }

    static string[string] readEnvFromStdin(ProtocolEnv src) {
        string[string] rval;
        foreach (kv; src) {
            rval[kv.key] = kv.value;
        }
        return rval;
    }

    static string[string] readEnvFromFile(const Config fconf) {
        string[string] rval;
        foreach (kv; readEnv(fconf.global.importEnv)) {
            rval[kv.key] = kv.value;
        }
        return rval;
    }

    try {
        auto pread = PipeReader(stdin.fileno);

        auto localConf = () {
            LocalRunConf conf;
            conf.cmd = fconf.global.command.dup;
            conf.workdir = fconf.global.workDir;

            bool running = fconf.global.stdinMsgPackEnv;
            while (running) {
                pread.update;
                pread.unpack().match!((None x) {}, (ConfDone x) {
                    running = false;
                }, (ProtocolEnv x) { conf.env = readEnvFromStdin(x); }, (HeartBeat x) {
                }, (Command x) { conf.cmd = x.value; }, (Workdir x) {
                    conf.workdir = x.value;
                }, (Key x) {}, (TerminalCapability x) { conf.mode = x.value; });
            }

            if (!fconf.global.stdinMsgPackEnv) {
                conf.env = readEnvFromFile(fconf);
            }

            return conf;
        }();

        auto res = () {
            if (conf.useFakeTerminal) {
                import core.sys.posix.termios : tcsetattr, TCSAFLUSH;

                auto p = ttyProcess([userShell] ~ shellSwitch(userShell) ~ [
                        localConf.cmd.joiner(" ").toUTF8
                        ], localConf.env, PConfig.none, localConf.workdir).sandbox.scopeKill;
                tcsetattr(p.stdin.file.fileno, TCSAFLUSH, &localConf.mode);
                return p;
            }
            return pipeShell(localConf.cmd.joiner(" ").toUTF8,
                    Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout,
                    localConf.env, PConfig.none, localConf.workdir).sandbox.scopeKill;
        }();

        import core.sys.posix.unistd : getppid;

        const parent_pid = getppid;
        bool loop_running = true;

        auto timers = makeTimers;
        makeInterval(timers, () {
            // detect ctrl+c on the client side
            if (getppid != parent_pid) {
                loop_running = false;
            }
            return 500.dur!"msecs";
        }, 50.dur!"msecs");

        ubyte[4096] buf;
        bool pipeOutputToUser() @trusted {
            bool hasWritten;
            while (res.stdout.hasPendingData) {
                auto r = res.stdout.read(buf[]);
                stdout.rawWrite(r);
                hasWritten = true;
            }

            if (hasWritten) {
                stdout.flush;
            }
            return hasWritten;
        }

        scope (exit)
            pipeOutputToUser;

        makeInterval(timers, () @safe {
            if (pipeOutputToUser) {
                return 10.dur!"msecs";
            }
            // slower if not much is happening
            return 100.dur!"msecs";
        }, 25.dur!"msecs");

        // a dummy event that ensure that it tick each 50 msec.
        makeInterval(timers, () => 50.dur!"msecs", 50.dur!"msecs");

        int exit_status = 1;

        auto wd = HeartBeatMonitor(fconf.global.timeout * 2);

        while (!wd.isTimeout && loop_running) {
            pread.update;

            try {
                if (res.tryWait) {
                    exit_status = res.status;
                    loop_running = false;
                }

                pread.unpack().match!((None x) {}, (ConfDone x) {}, (ProtocolEnv x) {
                }, (HeartBeat x) { wd.beat; }, (Command x) {}, (Workdir x) {}, (Key x) {
                    auto data = x.value;
                    while (!data.empty) {
                        auto written = res.stdin.write(x.value);
                        data = data[written.length .. $];
                    }
                }, (TerminalCapability x) {});
            } catch (Exception e) {
            }

            timers.tick(25.dur!"msecs");
        }

        return exit_status;
    } catch (Exception e) {
        () @trusted { logger.trace(e).collectException; }();
        logger.error(e.msg).collectException;
    }

    return 1;
}

int cli(const Config fconf, Config.Install conf, void delegate(string src, string dst) symlink) nothrow {
    import std.path : buildPath;
    import std.file : exists, remove;

    void replace(string src, string dst) {
        if (exists(dst))
            remove(dst);
        symlink(src, dst);
    }

    try {
        replace(fconf.global.selfBinary, buildPath(fconf.global.selfDir, distShell));
        replace(fconf.global.selfBinary, buildPath(fconf.global.selfDir, distCmd));
        return 0;
    } catch (Exception e) {
        logger.error(e.msg).collectException;
    }

    return 1;
}

// #SPC-measure_remote_hosts
int cli(const Config fconf, Config.MeasureHosts conf) nothrow {
    import std.algorithm : sort;
    import std.conv : to;
    import std.stdio : writefln, writeln;
    import distssh.table;
    import distssh.connection;

    writeln("Host is overloaded if Load is >1").collectException;

    auto tbl = Table!5(["Host", "Load", "Access Time", "Updated", "Multiplex"]);
    void addRow(HostLoad a) nothrow {
        static string toInternal(Duration d) {
            import std.format : format;

            int seconds;
            short msecs;
            d.split!("seconds", "msecs")(seconds, msecs);
            if (seconds == 0)
                return format("%sms", msecs);
            else
                return format("%ss %sms", seconds, msecs);
        }

        string[5] row;
        try {
            row[0] = a.host;
            row[1] = a.load.loadAvg.to!string;
            row[2] = toInternal(a.load.accessTime);
            row[3] = a.updated.to!string;
            row[4] = makeMaster(a.host).isAlive ? "yes" : "no";
            tbl.put(row);
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
        }
    }

    auto hosts = RemoteHostCache.make(fconf.global.dbPath, fconf.global.cluster);

    foreach (a; hosts.onlineRange.sort!((a, b) => a.load < b.load)) {
        addRow(a);
    }

    auto unused = hosts.unusedRange;
    if (!unused.empty) {
        tbl.put(["-", "-", "-", "-", "-"]).collectException;
        foreach (a; unused) {
            addRow(a);
        }
    }

    try {
        writeln(tbl);
    } catch (Exception e) {
        logger.error(e.msg).collectException;
    }

    return 0;
}

/** Print the load of localhost.
 *
 * #SPC-measure_local_load
 */
int cli(WriterT)(Config.LocalLoad conf, scope WriterT writer) {
    import std.ascii : newline;
    import std.conv : to;
    import std.parallelism : totalCPUs;
    import distssh.libc : getloadavg;

    try {
        double[3] loadavg;
        int samples = getloadavg(&loadavg[0], 3);

        if (samples == -1 || samples == 0)
            loadavg[0] = totalCPUs > 0 ? totalCPUs : 1;

        double cores = totalCPUs;

        // make sure the loadavg is on a new line because the last line parsed is expected to contain the loadavg.
        writer(newline);

        if (cores > 0)
            writer((loadavg[0] / cores).to!string);
        else
            writer(loadavg[0].to!string);
    } catch (Exception e) {
        logger.trace(e.msg).collectException;
        return -1;
    }

    return 0;
}

int cli(const Config fconf, Config.RunOnAll conf) nothrow {
    import std.algorithm : sort;
    import std.stdio : writefln, writeln, stdout;

    auto hosts = RemoteHostCache.make(fconf.global.dbPath, fconf.global.cluster);

    writefln("Hosts (%s): %(%s|%)", globalEnvHostKey, hosts.allRange.map!(a => a.host))
        .collectException;

    bool exit_status = true;
    foreach (a; hosts.allRange
            .filter!(a => !a.load.unknown)
            .map!(a => a.host)) {
        stdout.writefln("Connecting to %s", a).collectException;
        try {
            // #SPC-flush_buffers
            stdout.flush;
        } catch (Exception e) {
        }

        auto status = executeOnHost(ExecuteOnHostConf(fconf.global.workDir,
                fconf.global.command.dup, fconf.global.importEnv,
                fconf.global.cloneEnv, fconf.global.noImportEnv), a);

        if (status != 0) {
            writeln("Failed, error code: ", status).collectException;
            exit_status = false;
        }

        stdout.writefln("Connection to %s closed.", a).collectException;
    }

    return exit_status ? 0 : 1;
}

// #SPC-shell_current_dir
int cli(const Config fconf, Config.LocalShell conf) {
    import std.file : exists;
    import std.process : spawnProcess, wait, userShell, Config, Pid;

    try {
        auto pid = () {
            if (exists(fconf.global.workDir))
                return spawnProcess([userShell], null, Config.none, fconf.global.workDir);
            return spawnProcess([userShell]);
        }();
        return pid.wait;
    } catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }
}

// #SPC-modify_env
int cli(const Config fconf, Config.Env conf) {
    import std.algorithm : map, filter;
    import std.array : assocArray, array;
    import std.path : absolutePath;
    import std.stdio : writeln, writefln;
    import std.string : split;
    import std.typecons : tuple;
    import distssh.protocol : ProtocolEnv, EnvVariable;

    if (conf.exportEnv) {
        try {
            writeEnv(fconf.global.importEnv, cloneEnv);
            logger.info("Exported environment to ", fconf.global.importEnv);
        } catch (Exception e) {
            logger.error(e.msg).collectException;
            return 1;
        }

        return 0;
    }

    string[string] set_envs;
    try {
        set_envs = conf.envSet
            .map!(a => a.split('='))
            .filter!(a => !a.empty)
            .map!(a => tuple(a[0], a[1]))
            .assocArray;
    } catch (Exception e) {
        writeln("Unable to parse supplied envs to modify: ", e.msg).collectException;
        return 1;
    }

    try {
        auto env = readEnv(fconf.global.importEnv.absolutePath).map!(a => tuple(a.key,
                a.value)).assocArray;

        foreach (k; conf.envDel.filter!(a => a in env)) {
            writeln("Removing ", k);
            env.remove(k);
        }

        foreach (kv; set_envs.byKeyValue) {
            if (kv.key in env)
                writefln("Setting %s=%s", kv.key, kv.value);
            else
                writefln("Adding %s=%s", kv.key, kv.value);
            env[kv.key] = kv.value;
        }

        if (conf.print) {
            foreach (const kv; env.byKeyValue)
                writefln(`%s="%s"`, kv.key, kv.value);
        }

        writeEnv(fconf.global.importEnv,
                ProtocolEnv(env.byKeyValue.map!(a => EnvVariable(a.key, a.value)).array));
    } catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }

    return 0;
}

@("shall export the environment")
@Serial unittest {
    import std.conv : to;
    import std.file;
    import std.process : environment;
    import std.variant : tryVisit;

    // arrange
    immutable remove_me = "remove_me.export";
    scope (exit)
        remove(remove_me);

    auto opts = parseUserArgs(["distssh", "env", "-e", "--env-file", remove_me]);
    auto envConf = opts.data.tryVisit!((Config.Env a) => a, () => Config.Env.init);

    const env_key = "DISTSSH_ENV_TEST";
    environment[env_key] = env_key ~ remove_me;
    scope (exit)
        environment.remove(env_key);

    // shall export the environment to the file
    void verify1() {
        // test normal export
        cli(opts, envConf);
        auto env = readEnv(remove_me);
        assert(!env.filter!(a => a.key == env_key).empty, env.to!string);
    }

    verify1;

    // shall filter out specified env before exporting to the file
    environment[globalEnvFilterKey] = "DISTSSH_ENV_TEST;junk ";
    scope (exit)
        environment.remove(globalEnvFilterKey);

    void verify2() {
        cli(opts, envConf);
        auto env = readEnv(remove_me);
        assert(env.filter!(a => a.key == env_key).empty, env.to!string);
    }

    verify2;
}

@("shall create symlinks to self")
@Serial unittest {
    string[2][] symlinks;
    void fakeSymlink(string src, string dst) {
        string[2] v = [src, dst];
        symlinks ~= v;
    }

    Config conf;
    conf.global.selfBinary = "/foo/src";
    conf.global.selfDir = "/bar";

    cli(conf, Config.Install.init, &fakeSymlink);

    assert(symlinks[0] == ["/foo/src", "/bar/distshell"]);
    assert(symlinks[1] == ["/foo/src", "/bar/distcmd"]);
}

@("shall modify the exported env by adding, removing and modifying")
@Serial unittest {
    import std.array;
    import std.file;
    import std.process : environment;
    import std.stdio;
    import std.typecons : tuple;
    import std.variant : tryVisit;

    // arrange
    immutable remove_me = "remove_me.export";
    scope (exit)
        remove(remove_me);

    environment["FOO_DEL"] = "del me";
    environment["FOO_MOD"] = "mod me";
    scope (exit) {
        environment.remove("FOO_DEL");
        environment.remove("FOO_MOD");
        environment.remove("FOO_ADD");
    }

    auto conf = parseUserArgs(["distssh", "env", "-e", "--env-file", remove_me]);
    auto envConf = conf.data.tryVisit!((Config.Env a) => a, () => Config.Env.init);
    cli(conf, envConf);

    // act
    conf = parseUserArgs([
            "distssh", "env", "-d", "FOO_DEL", "-s", "FOO_MOD=42", "--set",
            "FOO_ADD=42", "--env-file", remove_me
            ]);
    envConf = conf.data.tryVisit!((Config.Env a) => a, () => Config.Env.init);
    cli(conf, envConf);

    // assert
    auto env = readEnv(remove_me).map!(a => tuple(a.key, a.value)).assocArray;
    assert(env["FOO_MOD"] == "42");
    assert(env["FOO_ADD"] == "42");
    assert("FOO_DEL" !in env);
}

@("shall print the load of the localhost")
@Serial unittest {
    string load;
    auto exit_status = cli(Config.LocalLoad.init, (string s) => load = s);
    assert(exit_status == 0);
    assert(load.length > 0, load);
}

void writeEnv(string filename, from.distssh.protocol.ProtocolEnv env) {
    import core.sys.posix.sys.stat : fchmod, S_IRUSR, S_IWUSR;
    import std.stdio : File;
    import distssh.protocol : Serialize;

    auto fout = File(filename, "w");
    fchmod(fout.fileno, S_IRUSR | S_IWUSR);

    auto ser = Serialize!(void delegate(const(ubyte)[]) @safe)((const(ubyte)[] a) => fout.rawWrite(
            a));

    ser.pack(env);
}
