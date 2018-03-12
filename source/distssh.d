#!/usr/bin/env rdmd
/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Methods prefixed with `cli_` are strongly related to user commands.
They more or less fully implement a command line interface command.
*/
module distssh;

import core.time : Duration;
import std.algorithm : splitter, map, filter, joiner;
import std.exception : collectException;
import std.stdio : File;
import std.typecons : Nullable;
import logger = std.experimental.logger;

static import std.getopt;

extern extern (C) __gshared char** environ;

immutable globalEnvironemntKey = "DISTSSH_HOSTS";
immutable distShell = "distshell";
immutable distCmd = "distcmd";
immutable distsshCmdRecv = "distcmd_recv";
immutable distsshEnvExport = "distssh_env.export";
immutable ulong defaultTimeout_s = 2;

version (unittest) {
} else {
    int main(string[] args) nothrow {
        Options opts;
        try {
            opts = parseUserArgs(args);
        }
        catch (Exception e) {
            logger.error(e.msg).collectException;
            return 1;
        }

        if (opts.help) {
            printHelp(opts);
            return 0;
        }

        return appMain(opts);
    }
}

int appMain(const Options opts) nothrow {
    if (opts.exportEnv) {
        try {
            auto fout = File(distsshEnvExport, "w");
            cli_exportEnv(opts, fout);
            return 0;
        }
        catch (Exception e) {
            logger.error(e.msg).collectException;
            return 1;
        }
    }

    final switch (opts.mode) with (Options.Mode) {
    case install:
        import std.file : symlink;

        return cli_install(opts, (string src, string dst) => symlink(src, dst));
    case shell:
        return cli_shell(opts);
    case cmd:
        return cli_cmd(opts);
    case importEnvCmd:
        return cli_cmdWithImportedEnv(opts);
    case measureHosts:
        try {
            cli_measureHosts(opts);
            return 0;
        }
        catch (Exception e) {
            logger.error(e.msg).collectException;
            return 1;
        }
    }
}

private:

void cli_exportEnv(const Options opts, ref File fout) {
    auto s = cloneEnv(environ);
    foreach (kv; s.byKeyValue) {
        fout.writefln("%s=%s", kv.key, kv.value);
    }
}

@("shall export the environment to the file")
unittest {
    import std.algorithm : canFind;
    import std.file;

    immutable remove_me = "remove_me.export";
    auto fout = File(remove_me, "w");
    scope (exit)
        remove(remove_me);

    auto opts = parseUserArgs(["distssh", "--export-env"]);

    cli_exportEnv(opts, fout);

    auto first_line = File(remove_me).byLine.front;
    assert(first_line.canFind("="), first_line);
}

int cli_install(const Options opts, void delegate(string src, string dst) symlink) nothrow {
    import std.path : buildPath;

    try {
        symlink(opts.selfBinary, buildPath(opts.selfDir, distShell));
        symlink(opts.selfBinary, buildPath(opts.selfDir, distCmd));
        symlink(opts.selfBinary, buildPath(opts.selfDir, distsshCmdRecv));
        return 0;
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }
}

@("shall create symlinks to self")
unittest {
    string[2][] symlinks;
    void fakeSymlink(string src, string dst) {
        string[2] v = [src, dst];
        symlinks ~= v;
    }

    Options opts;
    opts.selfBinary = "/foo/src";
    opts.selfDir = "/bar";

    cli_install(opts, &fakeSymlink);

    assert(symlinks[0] == ["/foo/src", "/bar/distshell"]);
    assert(symlinks[1] == ["/foo/src", "/bar/distcmd"]);
    assert(symlinks[2] == ["/foo/src", "/bar/distcmd_recv"]);
}

int cli_shell(const Options opts) nothrow {
    import std.process : spawnProcess, wait;

    try {
        auto host = selectLowestFromEnv(opts.timeout);
        return spawnProcess(["ssh", "-oStrictHostKeyChecking=no", host]).wait;
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }
}

int cli_cmd(const Options opts) nothrow {
    import std.process : spawnProcess, wait;
    import std.path : absolutePath, buildNormalizedPath;

    // #SPC-draft_remote_cmd_spec
    try {
        import std.file : getcwd;

        auto host = selectLowestFromEnv(opts.timeout);

        immutable abs_cmd = buildNormalizedPath(opts.selfDir, distsshCmdRecv);
        return spawnProcess(["ssh", "-oStrictHostKeyChecking=no", host,
                abs_cmd, getcwd, distsshEnvExport.absolutePath] ~ opts.command).wait;
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }
}

int cli_cmdWithImportedEnv(const Options opts) nothrow {
    import std.stdio : File;
    import std.file : exists;
    import std.process : spawnProcess, wait, Config, spawnShell;
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
    }
    catch (Exception e) {
    }

    try {
        if (exists(opts.command[0])) {
            return spawnProcess(opts.command, env, Config.none, opts.workDir).wait;
        } else {
            return spawnShell(opts.command.dup.joiner(" ").toUTF8, env, Config.none, opts.workDir)
                .wait;
        }
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }
}

// #SPC-measure_remote_hosts
int cli_measureHosts(const Options opts) {
    import core.time : dur;
    import std.array : array;
    import std.algorithm : sort;
    import std.conv : to;
    import std.parallelism : taskPool;
    import std.stdio : writefln, writeln;
    import std.string : fromStringz;
    import std.typecons : tuple;

    static import core.stdc.stdlib;

    string hosts_env = core.stdc.stdlib.getenv(&globalEnvironemntKey[0]).fromStringz.idup;

    static auto loadHost(T)(T host_to) {
        return tuple(host_to[0], getLoad(host_to[0], host_to[1]));
    }

    auto shosts = hosts_env.splitter(";").map!(a => tuple(Host(a), opts.timeout)).array;

    writefln("Configured hosts (%s): %(%s|%)", globalEnvironemntKey, shosts.map!(a => a[0]));
    writeln("Access Time -> Host");

    // dfmt off
    foreach(a; taskPool.map!loadHost(shosts, 100, 1)
        .array
        .sort!((a,b) { if (a[1].isNull) return false; if (b[1].isNull) return true; return a[1].accessTime < b[1].accessTime; })) {

        writefln("%s -> %s", a[1].isNull ? "timeout" : a[1].get.accessTime.to!string, a[0]);
    }
    // dfmt on

    return 0;
}

struct Options {
    import core.time : dur;

    enum Mode {
        shell,
        cmd,
        importEnvCmd,
        install,
        measureHosts,
    }

    Mode mode;

    bool help;
    bool exportEnv;
    std.getopt.GetoptResult help_info;

    Duration timeout = defaultTimeout_s.dur!"seconds";

    string selfBinary;
    string selfDir;

    string importEnv;
    string workDir;
    string[] command;
}

Options parseUserArgs(string[] args) {
    import std.file : thisExePath;
    import std.path : dirName, baseName, buildPath;

    Options opts;

    opts.selfBinary = buildPath(thisExePath.dirName, args[0].baseName);
    opts.selfDir = opts.selfBinary.dirName;

    // #SPC-remote_command_parse
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

    try {
        bool remote_shell;
        bool install;
        bool measure_hosts;
        ulong timeout_s;

        // dfmt off
        opts.help_info = std.getopt.getopt(args, std.getopt.config.passThrough,
            std.getopt.config.keepEndOfOptions,
            "install", "install distssh by setting up the correct symlinks", &install,
            "shell", "open an interactive shell on the remote host", &remote_shell,
            "export-env", "export the current env to the remote host to be used", &opts.exportEnv,
            "timeout", "timeout to use when checking remote hosts", &timeout_s,
            "measure", "measure the login time and load of all remote hosts", &measure_hosts,
            );
        // dfmt on
        opts.help = opts.help_info.helpWanted;

        import core.time : dur;

        if (timeout_s > 0)
            opts.timeout = timeout_s.dur!"seconds";

        if (install)
            opts.mode = Options.Mode.install;
        else if (remote_shell)
            opts.mode = Options.Mode.shell;
        else if (measure_hosts)
            opts.mode = Options.Mode.measureHosts;
        else
            opts.mode = Options.Mode.cmd;

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

@("shall determine the absolute path of self")
unittest {
    import std.path;
    import std.file;

    auto opts = parseUserArgs(["distssh", "ls"]);
    assert(opts.selfBinary[0] == '/');
    assert(opts.selfBinary.baseName == "distssh");

    opts = parseUserArgs(["distshell"]);
    assert(opts.selfBinary[0] == '/');
    assert(opts.selfBinary.baseName == "distshell");

    opts = parseUserArgs(["distcmd"]);
    assert(opts.selfBinary[0] == '/');
    assert(opts.selfBinary.baseName == "distcmd");

    opts = parseUserArgs(["distcmd_recv", getcwd, distsshEnvExport]);
    assert(opts.selfBinary[0] == '/');
    assert(opts.selfBinary.baseName == "distcmd_recv");
}

@("shall either return the default timeout or the user specified timeout")
unittest {
    import core.time : dur;
    import std.conv;

    auto opts = parseUserArgs(["distssh", "ls"]);
    assert(opts.timeout == defaultTimeout_s.dur!"seconds");
    opts = parseUserArgs(["distssh", "--timeout", "10", "ls"]);
    assert(opts.timeout == 10.dur!"seconds");

    opts = parseUserArgs(["distshell"]);
    assert(opts.timeout == defaultTimeout_s.dur!"seconds", opts.timeout.to!string);
    opts = parseUserArgs(["distshell", "--timeout", "10"]);
    assert(opts.timeout == defaultTimeout_s.dur!"seconds");
}

@("shall only be the default timeout because --timeout should be passed on to the command")
unittest {
    import core.time : dur;
    import std.conv;

    auto opts = parseUserArgs(["distcmd", "ls"]);
    assert(opts.timeout == defaultTimeout_s.dur!"seconds");

    opts = parseUserArgs(["distcmd", "--timeout", "10"]);
    assert(opts.timeout == defaultTimeout_s.dur!"seconds");
}

void printHelp(const Options opts) nothrow {
    import std.getopt : defaultGetoptPrinter;
    import std.format : format;
    import std.path : baseName;

    try {
        defaultGetoptPrinter(format("usage: %s [options] [COMMAND]\n",
                opts.selfBinary.baseName), opts.help_info.options.dup);
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
    }
}

struct Host {
    string payload;
    alias payload this;
}

Host selectLowestFromEnv(Duration timeout) {
    import std.string : fromStringz;

    static import core.stdc.stdlib;

    string hosts_env = core.stdc.stdlib.getenv(&globalEnvironemntKey[0]).fromStringz.idup;
    auto host = selectLowest(hosts_env, timeout);

    if (host.isNull) {
        throw new Exception("No remote host found (" ~ globalEnvironemntKey ~ "='" ~ hosts_env
                ~ "')");
    }

    return host.get;
}

/**
 * #SPC-load_balance
 * #SPC-best_remote_host
 *
 * Returns: the lowest loaded server.
 */
Nullable!Host selectLowest(string hosts, Duration timeout) nothrow {
    import std.array : array;
    import std.range : take;
    import std.typecons : tuple;
    import std.algorithm : sort;
    import std.random : uniform;
    import std.parallelism : taskPool;

    try {
        if (hosts.length == 0)
            return typeof(return)();

        static auto loadHost(T)(T host_to) {
            return tuple(host_to[0], getLoad(host_to[0], host_to[1]));
        }

        auto shosts = hosts.splitter(";").map!(a => tuple(Host(a), timeout)).array;
        if (shosts.length == 1)
            return typeof(return)(Host(shosts[0][0]));

        // dfmt off
        auto measured =
            taskPool.map!loadHost(shosts, 100, 1)
            .filter!(a => !a[1].isNull)
            .map!(a => tuple(a[0], a[1].get))
            .array
            .sort!((a,b) => a[1] < b[1])
            .take(3).array;
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

    Duration accessTime;
}

/** Login on host and measure its load.
 *
 * Params:
 *  h = remote host to check
 *
 * Returns: the Load of the remote host
 */
Nullable!Load getLoad(Host h, Duration timeout) nothrow {
    import std.conv : to;
    import std.process : tryWait, pipeProcess, kill;
    import std.range : takeOne;
    import std.stdio : writeln;
    import core.time : MonoTime;
    import core.sys.posix.signal : SIGKILL;

    try {
        auto res = pipeProcess(["ssh", "-oStrictHostKeyChecking=no", h, "cat", "/proc/loadavg"]);

        const start_at = MonoTime.currTime;
        const stop_at = start_at + timeout;
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
            return typeof(return)(Load(a.to!double, MonoTime.currTime - start_at));
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

    for (size_t i; env[i]!is null; ++i) {
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
