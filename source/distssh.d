#!/usr/bin/env rdmd
/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh;

import std.algorithm : splitter, map, filter, joiner;
import std.exception : collectException;
import std.typecons : Nullable;
import logger = std.experimental.logger;

static import std.getopt;

extern extern(C) __gshared char** environ;

immutable globalEnvironemntKey = "DISTSSH_HOSTS";
immutable distShell = "distshell";
immutable distCmd = "distcmd";
immutable distsshCmdRecv = "distcmd_recv";
immutable distsshEnvExport = "distssh_env.export";

int main(string[] args) nothrow {
    const opts = parseUserArgs(args);

    if (opts.help) {
        printHelp(opts);
        return 0;
    }

    if (opts.exportEnv) {
        import std.stdio : File;
        auto s = cloneEnv(environ);
        try {
            auto fout = File(distsshEnvExport, "w");
            foreach (kv; s.byKeyValue) {
                fout.writefln("%s=%s", kv.key, kv.value);
            }
        }
        catch(Exception e) {
            logger.error(e.msg).collectException;
        }
    }

    import std.string : fromStringz;
    static import core.stdc.stdlib;

    string hosts_env;
    Nullable!Host host;

    switch (opts.mode) with (Options.Mode) {
    case importEnvCmd:
        break;
    default:
        hosts_env = core.stdc.stdlib.getenv(&globalEnvironemntKey[0]).fromStringz.idup;
        host = selectLowest(hosts_env);

        if (host.isNull) {
            logger.errorf("No remote host found (%s='%s')", globalEnvironemntKey, hosts_env).collectException;
            return 1;
        }
    }

    import std.process : spawnProcess, wait, Config;
    import std.path : absolutePath, expandTilde, dirName, baseName, buildPath, buildNormalizedPath;
    import std.file : symlink;

    final switch (opts.mode) with (Options.Mode) {
    case install:
        try {
            immutable original = opts.selfBinary.expandTilde.absolutePath;
            immutable base = original.dirName;
            symlink(original, buildPath(base, distShell));
            symlink(original, buildPath(base, distCmd));
            symlink(original, buildPath(base, distsshCmdRecv));
            return 0;
        }
        catch(Exception e) {
            logger.error(e.msg).collectException;
            return 1;
        }
    case shell:
        try {
            return spawnProcess(["ssh", "-oStrictHostKeyChecking=no", host]).wait;
        }
        catch(Exception e) {
            logger.error(e.msg).collectException;
            return 1;
        }
    case cmd:
        // #SPC-draft_remote_cmd_spec
        try {
            import std.file : getcwd;
            immutable abs_cmd = buildNormalizedPath(opts.selfDir, distsshCmdRecv);
            return spawnProcess(["ssh", "-oStrictHostKeyChecking=no", host, abs_cmd, getcwd, distsshEnvExport.absolutePath] ~ opts.command).wait;
        }
        catch(Exception e) {
            logger.error(e.msg).collectException;
            return 1;
        }
    case importEnvCmd:
        import std.stdio : File;
        import std.file : exists;
        import std.process : spawnShell;
        import std.utf : toUTF8;

        if (opts.command.length == 0)
            return 0;

        string[string] env;
        try {
            foreach (kv; File(opts.importEnv).byLine.map!(a => a.splitter("="))) {
                string k = kv.front.idup;
                string v;
                kv.popFront;
                if (!kv.empty)
                    v = kv.front.idup;
                env[k] = v;
            }
        } catch(Exception e) {
        }

        try {
            if (exists(opts.command[0])) {
                return spawnProcess(opts.command, env, Config.none, opts.workDir).wait;
            } else {
                return spawnShell(opts.command.dup.joiner(" ").toUTF8, env, Config.none, opts.workDir).wait;
            }
        }
        catch(Exception e) {
            logger.error(e.msg).collectException;
            return 1;
        }
    }
}

private:

struct Options {
    enum Mode {
        shell,
        cmd,
        importEnvCmd,
        install,
    }

    Mode mode;

    bool help;
    bool exportEnv;
    std.getopt.GetoptResult help_info;

    string selfBinary;
    string selfDir;

    string importEnv;
    string workDir;
    string[] command;
}

Options parseUserArgs(string[] args) nothrow {
    import std.path : dirName, expandTilde, absolutePath, baseName;

    Options opts;
    opts.selfBinary = args[0];
    try {
        opts.selfDir = opts.selfBinary.expandTilde.absolutePath.dirName;
    }
    catch(Exception e) {
        logger.warning(e.msg).collectException;
    }

    switch (opts.selfBinary.baseName) {
    case distShell:
        opts.mode = Options.Mode.shell;
        return opts;
    case distCmd:
        opts.mode = Options.Mode.cmd;
        opts.command = args.length > 1 ? args[1 .. $] : null;
        return opts;
    case distsshCmdRecv:
        opts.mode = Options.Mode.importEnvCmd;
        opts.workDir = args[1];
        opts.importEnv = args[2];
        opts.command = args.length > 3 ? args[3 .. $] : null;
        return opts;
    default:
    }

    bool remote_shell;
    bool install;

    try {
        // dfmt off
        opts.help_info = std.getopt.getopt(args, std.getopt.config.passThrough,
            std.getopt.config.keepEndOfOptions,
            "install", "install distssh by setting up the correct symlinks", &install,
            "shell", "open an interactive shell on the remote host", &remote_shell,
            "export-env", "export the current env to the remote host to be used", &opts.exportEnv,
            );
        // dfmt on
        opts.help = opts.help_info.helpWanted;
    }
    catch (std.getopt.GetOptException e) {
        // unknown option
        opts.help = true;
        logger.error(e.msg).collectException;
    }
    catch (Exception e) {
        opts.help = true;
        logger.error(e.msg).collectException;
    }

    if (install)
        opts.mode = Options.Mode.install;
    else if (remote_shell)
        opts.mode = Options.Mode.shell;
    else
        opts.mode = Options.Mode.cmd;

    if (args.length > 1) {
        import std.algorithm : find;
        import std.range : drop;
        import std.array : array;

        opts.command = args.find("--").drop(1).array();
        if (opts.command.length == 0)
            opts.command = args[1 .. $];
    }

    return opts;
}

void printHelp(const Options opts) nothrow {
    import std.getopt : defaultGetoptPrinter;
    import std.format : format;
    import std.path : baseName;

    try {
        defaultGetoptPrinter(format("usage: %s [options] [COMMAND]\n", opts.selfBinary.baseName), opts.help_info.options.dup);
    }
    catch(Exception e) {
        logger.error(e.msg).collectException;
    }
}

struct Host {
    string payload;
    alias payload this;
}

/// Returns: the lowest loaded server.
Nullable!Host selectLowest(string hosts) nothrow {
    import std.array : array;
    import std.range : take;
    import std.typecons : tuple;
    import std.algorithm : sort;
    import std.random : uniform;
    import std.parallelism : taskPool;

    try {
        if (hosts.length == 0)
            return typeof(return)();

        static auto loadHost(Host host) {
            return tuple(host, getLoad(host));
        }

        auto shosts = hosts.splitter(";").map!Host.array;
        if (shosts.length == 1)
            return typeof(return)(Host(shosts[0]));

        // dfmt off
        auto measured =
            taskPool.map!loadHost(shosts, 100, 1)
            .filter!(a => !a[1].isNull)
            .map!(a => tuple(a[0], a[1].get))
            .array
            .sort!((a,b) => a[1] < b[1])
            .take(2).array;
        // dfmt on

        if (measured.length > 0) {
            auto ridx = uniform(0, measured.length);
            return typeof(return)(measured[ridx][0]);
        }
    }
    catch (Exception e) {
        logger.trace(e.msg).collectException;
    }

    return typeof(return)();
}

/// The load of a host.
struct Load {
    double payload;
    alias payload this;
}

/** Login on host and measure its load.
 *
 * Params:
 *  h = remote host to check
 *
 * Returns: the Load of the remote host
 */
Nullable!Load getLoad(Host h) nothrow {
    import std.conv : to;
    import std.process : tryWait, pipeProcess, kill;
    import std.range : takeOne;
    import std.stdio : writeln;
    import core.time : dur, MonoTime;
    import core.sys.posix.signal : SIGKILL;

    enum timeout = 2.dur!"seconds";

    try {
        auto res = pipeProcess(["ssh", "-oStrictHostKeyChecking=no", h, "cat", "/proc/loadavg"]);

        auto stop_at = MonoTime.currTime + timeout;
        while (true) {
            auto st = res.pid.tryWait;

            if (st.terminated && st.status == 0)
                break;
            else if (st.terminated && st.status != 0) {
                writeln(res.stderr.byLine);
                return typeof(return)();
            } else if (stop_at < MonoTime.currTime) {
                res.pid.kill(SIGKILL);
                return typeof(return)();
            }
        }

        foreach (a; res.stdout.byLine.takeOne.map!(a => a.splitter(" ")).joiner.takeOne) {
            return typeof(return)(a.to!double.Load);
        }
    }
    catch (Exception e) {
        logger.trace(e.msg).collectException;
    }

    return typeof(return)();
}

/// Mirror of an environment.
struct Env {
    string[string] payload;
    alias payload this;
}

/**
 * Params:
 *  env = a null terminated array of C strings
 *
 * Returns: a clone of the environment.
 */
Env cloneEnv(char** env) nothrow {
    import std.array : appender;
    import std.string : fromStringz, indexOf;

    static import core.stdc.stdlib;

    Env app;

    for (size_t i; env[i] !is null; ++i) {
        const raw = env[i].fromStringz;
        const pos = raw.indexOf('=');

        if (pos != -1) {
            string key = raw[0 .. pos].idup;
            string value;
            if (pos < raw.length)
                value = raw[pos + 1 .. $].idup;
            app[key] = value;
        }
    }

    return app;
}