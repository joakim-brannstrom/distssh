/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Methods prefixed with `cli_` are strongly related to user commands.
They more or less fully implement a command line interface command.
*/
module distssh.main_;

import core.time : Duration;
import std.algorithm : splitter, map, filter, joiner;
import std.exception : collectException;
import std.stdio : File;
import std.typecons : Nullable, NullableRef;
import logger = std.experimental.logger;

import colorlog;

import from_;

import distssh.config;
import distssh.metric;
import distssh.types;
import distssh.utility;

static import std.getopt;

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

    import std.file : symlink;
    import std.stdio : writeln;
    import std.variant : visit;

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

int cli(Config conf) {
    conf.printHelp;
    return 0;
}

int cli(const Config fconf, Config.Shell conf) nothrow {
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.file : thisExePath;
    import std.process : spawnProcess, wait, escapeShellFileName;
    import std.stdio : writeln, writefln;

    auto hosts = RemoteHostCache.make(fconf.global.dbPath, fconf.global.cluster);

    if (hosts.empty) {
        logger.errorf("No remote host online").collectException;
    }

    const timout_until_considered_successfull_connection = fconf.global.timeout * 2;

    while (!hosts.empty) {
        auto host = hosts.randomAndPop;

        try {
            writeln("Connecting to ", host);

            auto sw = StopWatch(AutoStart.yes);

            // two -t forces a tty to be created and used which mean that the remote shell will *think* it is an interactive shell
            auto exit_status = spawnProcess(["ssh", "-q", "-t",
                    "-t"] ~ sshNoLoginArgs ~ [
                    host, thisExePath.escapeShellFileName, "localshell",
                    "--workdir", fconf.global.workDir.escapeShellFileName
                    ]).wait;

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
    auto hosts = RemoteHostCache.make(fconf.global.dbPath, fconf.global.cluster);

    if (hosts.empty) {
        logger.errorf("No remote host online").collectException;
        return 1;
    }

    return executeOnHost(ExecuteOnHostConf(fconf.global.workDir, fconf.global.command.dup,
            fconf.global.importEnv, fconf.global.cloneEnv, fconf.global.noImportEnv),
            hosts.randomAndPop);
}

// #SPC-fast_env_startup
int cli(const Config fconf, Config.LocalRun conf) {
    import core.time : dur;
    import std.stdio : File, stdin;
    import std.file : exists;
    import std.process : thisProcessID;
    import std.process : PConfig = Config;
    import std.utf : toUTF8;
    import process;
    import distssh.timer : makeTimers, makeInterval;

    if (fconf.global.command.length == 0)
        return 0;

    static auto updateEnv(const Config fconf, ref PipeReader pread, ref string[string] out_env) {
        import distssh.protocol : ProtocolEnv;

        ProtocolEnv env;

        if (fconf.global.stdinMsgPackEnv) {
            auto timers = makeTimers;
            makeInterval(timers, () @trusted {
                pread.update;

                try {
                    auto tmp = pread.unpack!(ProtocolEnv);
                    if (!tmp.isNull) {
                        env = tmp;
                        return false;
                    }
                } catch (Exception e) {
                }
                return true;
            }, 10.dur!"msecs");
            while (!timers.empty) {
                timers.tick(10.dur!"msecs");
            }
        } else {
            env = readEnv(fconf.global.importEnv);
        }

        foreach (kv; env) {
            out_env[kv.key] = kv.value;
        }
    }

    try {
        string[string] env;
        auto pread = PipeReader(stdin.fileno);

        try {
            updateEnv(fconf, pread, env);
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
        }

        auto res = () {
            if (exists(fconf.global.command[0]) && fconf.global.command.length == 1) {
                return spawnProcess(fconf.global.command, env, PConfig.none, fconf.global.workDir)
                    .sandbox.scopeKill;
            }
            return spawnShell(fconf.global.command.dup.joiner(" ").toUTF8, env,
                    PConfig.none, fconf.global.workDir).sandbox.scopeKill;
        }();

        import core.sys.posix.unistd : getppid;

        const parent_pid = getppid;
        bool loop_running = true;

        bool sigintEvent() {
            if (getppid != parent_pid) {
                loop_running = false;
            }
            return true;
        }

        auto timers = makeTimers;
        makeInterval(timers, &sigintEvent, 500.dur!"msecs");
        // a dummy event that ensure that it tick each 50 msec.
        makeInterval(timers, () => true, 50.dur!"msecs");

        int exit_status = 1;

        auto wd = Watchdog(pread, fconf.global.timeout * 2);

        while (!wd.isTimeout && loop_running) {
            pread.update;

            try {
                if (res.tryWait) {
                    exit_status = res.status;
                    loop_running = false;
                }
                wd.update;
            } catch (Exception e) {
            }

            // #SPC-sigint_detection
            timers.tick(50.dur!"msecs");
        }

        return exit_status;
    } catch (Exception e) {
        logger.error(e.msg).collectException;
    }

    return 1;
}

int cli(const Config fconf, Config.Install conf, void delegate(string src, string dst) symlink) nothrow {
    import std.path : buildPath;

    try {
        symlink(fconf.global.selfBinary, buildPath(fconf.global.selfDir, distShell));
        symlink(fconf.global.selfBinary, buildPath(fconf.global.selfDir, distCmd));
        return 0;
    } catch (Exception e) {
        logger.error(e.msg).collectException;
    }

    return 1;
}

// #SPC-measure_remote_hosts
int cli(const Config fconf, Config.MeasureHosts conf) nothrow {
    import std.conv : to;
    import std.stdio : writefln, writeln;
    import distssh.table;

    auto hosts = RemoteHostCache.make(fconf.global.dbPath, fconf.global.cluster);

    writeln("Host is overloaded if Load is >1").collectException;

    string[3] row = ["Host", "Access Time", "Load"];
    auto tbl = Table!3(row);

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

    foreach (a; hosts.remoteByLoad) {
        try {
            row[0] = a[0];
            row[1] = toInternal(a[1].accessTime);
            row[2] = a[1].loadAvg.to!string;
            tbl.put(row);
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
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

    writefln("Configured hosts (%s): %(%s|%)", globalEnvHostKey, fconf.global.cluster)
        .collectException;

    bool exit_status = true;
    foreach (a; fconf.global.cluster.dup.sort) {
        stdout.writefln("Connecting to %s.", a).collectException;
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
    import std.array : assocArray, empty, array;
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
unittest {
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
unittest {
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
unittest {
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
unittest {
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

/**
  * Searches all dirs on path for exe if required,
  * or simply calls it if it's a relative or absolute path
  */
string pathToExe(string exe) {
    import std.path : dirSeparator, pathSeparator, buildPath;
    import std.algorithm : splitter;
    import std.file : exists;
    import std.process : environment;

    // if it already has a / or . at the start, assume the exe is correct
    if (exe[0 .. 1] == dirSeparator || exe[0 .. 1] == ".")
        return exe;
    auto matches = environment["PATH"].splitter(pathSeparator).map!(path => buildPath(path, exe))
        .filter!(path => exists(path));
    return matches.empty ? exe : matches.front;
}
