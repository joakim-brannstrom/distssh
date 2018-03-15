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
immutable distsshEnvExport = "distssh_env.export";
immutable ulong defaultTimeout_s = 2;

version (unittest) {
} else {
    int main(string[] args) nothrow {
        try {
            import app_logger;

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

int appMain(const Options opts) nothrow {
    if (opts.exportEnv) {
        try {
            auto fout = File(opts.importEnv, "w");

            import core.sys.posix.sys.stat : fchmod, S_IRUSR, S_IWUSR;

            fchmod(fout.fileno, S_IRUSR | S_IWUSR);

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
    case localLoad:
        import std.stdio : writeln;

        return cli_localLoad((string s) => writeln(s));
    case runOnAll:
        return cli_runOnAll(opts);
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
    try {
        auto host = selectLowestFromEnv(opts.timeout);
        return executeOnHost(opts, host);
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }
}

int executeOnHost(const Options opts, Host host) nothrow {
    import core.thread : Thread;
    import core.time : dur;
    import std.file : thisExePath;
    import std.path : absolutePath;
    import std.process : tryWait, Redirect, pipeProcess;

    // #SPC-draft_remote_cmd_spec
    try {
        import std.file : getcwd;

        logger.info("Connecting to: ", host);
        logger.info("run: ", opts.command.dup.joiner(" "));

        auto p = pipeProcess(["ssh", "-oStrictHostKeyChecking=no", host,
                thisExePath, "--local-run", "--workdir", getcwd,
                "--import-env", opts.importEnv.absolutePath, "--"] ~ opts.command, Redirect.stdin);

        while (true) {
            try {
                auto st = p.pid.tryWait;
                if (st.terminated)
                    return st.status;

                Watchdog.ping(p.stdin);
            }
            catch (Exception e) {
            }

            Thread.sleep(50.dur!"msecs");
        }
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }
}

int cli_cmdWithImportedEnv(const Options opts) nothrow {
    import core.thread : Thread;
    import core.time : dur;
    import std.stdio : File, stdin;
    import std.file : exists;
    import std.process : spawnProcess, Config, spawnShell, Pid, tryWait,
        thisProcessID;
    import std.utf : toUTF8;

    if (opts.command.length == 0)
        return 0;

    string[string] env;
    if (exists(opts.importEnv)) {
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
    }

    try {
        Pid res;

        if (exists(opts.command[0])) {
            res = spawnProcess(opts.command, env, Config.none, opts.workDir);
        } else {
            res = spawnShell(opts.command.dup.joiner(" ").toUTF8, env, Config.none, opts.workDir);
        }

        const timeout = opts.timeout * 2;
        auto wd = Watchdog(stdin.fileno, timeout);

        while (!wd.isTimeout) {
            try {
                auto status = tryWait(res);
                if (status.terminated)
                    return status.status;
                wd.update;
            }
            catch (Exception e) {
            }

            Thread.sleep(50.dur!"msecs");
        }

        // #SPC-early_terminate_no_processes_left
        if (wd.isTimeout) {
            import core.sys.posix.signal : killpg, SIGKILL;

            killpg(res.processID, SIGKILL);
            killpg(thisProcessID, SIGKILL);
        }

        return 1;
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
    import std.stdio : writefln, writeln;
    import std.string : fromStringz;
    import std.typecons : tuple;
    import std.parallelism : TaskPool;

    static import core.stdc.stdlib;

    string hosts_env = core.stdc.stdlib.getenv(&globalEnvironemntKey[0]).fromStringz.idup;

    static auto loadHost(T)(T host_to) {
        return tuple(host_to[0], getLoad(host_to[0], host_to[1]));
    }

    auto shosts = hosts_env.splitter(";").map!(a => tuple(Host(a), opts.timeout)).array;

    writefln("Configured hosts (%s): %(%s|%)", globalEnvironemntKey, shosts.map!(a => a[0]));
    writeln("Host | Access Time | Load");

    auto pool = new TaskPool(shosts.length + 1);
    scope (exit)
        pool.stop;

    // dfmt off
    foreach(a; pool.map!loadHost(shosts)
        .array
        .sort!((a,b) => a[1] < b[1])) {

        writefln("%s | %s | %s", a[0], a[1].accessTime.to!string, a[1].loadAvg.to!string);
    }
    // dfmt on

    return 0;
}

/** Print the load of localhost.
 *
 * #SPC-measure_local_load
 */
int cli_localLoad(WriterT)(scope WriterT writer) nothrow {
    import std.algorithm : count;
    import std.string : startsWith;
    import std.conv : to;
    import std.range : takeOne;

    try {
        double loadavg;
        foreach (a; File("/proc/loadavg").readln.splitter(" ").takeOne) {
            loadavg = a.to!double;
        }

        double cores = File("/proc/cpuinfo").byLine.filter!(a => a.startsWith("processor")).count;

        if (cores > 0)
            writer((loadavg / cores).to!string);
        else
            writer(loadavg.to!string);
    }
    catch (Exception e) {
        logger.trace(e.msg).collectException;
        return -1;
    }

    return 0;
}

int cli_runOnAll(const Options opts) nothrow {
    import std.array : array;
    import std.algorithm : sort;
    import std.stdio : writefln, writeln;
    import std.string : fromStringz;

    static import core.stdc.stdlib;

    string hosts_env = core.stdc.stdlib.getenv(&globalEnvironemntKey[0]).fromStringz.idup;

    auto shosts = hosts_env.splitter(";").map!(a => Host(a)).array;

    writefln("Configured hosts (%s): %(%s|%)", globalEnvironemntKey, shosts).collectException;

    bool exit_status = true;
    foreach (a; shosts.sort) {
        writefln("Connecting to %s.", a).collectException;

        auto status = executeOnHost(opts, a);

        if (status != 0) {
            writeln("Failed, error code: ", status).collectException;
            exit_status = false;
        }

        writefln("Connection to %s closed.", a).collectException;
    }

    return exit_status ? 0 : 1;
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

struct Watchdog {
    import std.datetime.stopwatch : StopWatch;

    enum State {
        ok,
        timeout
    }

    private {
        State st;
        Duration timeout;
        NonblockingFd nfd;
        StopWatch sw;
    }

    static const pingWord = "x";

    this(int fd, Duration timeout) {
        this.nfd = NonblockingFd(fd);
        this.timeout = timeout;
        sw.start;
    }

    void update() {
        char[pingWord.length * 2] raw_buf;
        ubyte[] s = cast(ubyte[]) raw_buf;

        nfd.read(s);

        if (s.length >= pingWord.length + 1 && s[0 .. pingWord.length] == cast(ubyte[]) pingWord) {
            sw.reset;
            sw.start;
        } else if (sw.peek > timeout) {
            st = State.timeout;
        }
    }

    bool isTimeout() {
        return State.timeout == st;
    }

    static void ping(File f) {
        f.writeln(pingWord);
        f.flush;
    }
}

@("shall print the load of the localhost")
unittest {
    string load;
    auto exit_status = cli_localLoad((string s) => load = s);
    assert(exit_status == 0);
    assert(load.length > 0, load);
}

struct Options {
    import core.time : dur;

    enum Mode {
        shell,
        cmd,
        importEnvCmd,
        install,
        measureHosts,
        localLoad,
        runOnAll,
    }

    Mode mode;

    bool help;
    bool exportEnv;
    bool verbose;
    std.getopt.GetoptResult help_info;

    Duration timeout = defaultTimeout_s.dur!"seconds";

    string selfBinary;
    string selfDir;

    string importEnv = distsshEnvExport;
    string workDir;
    string[] command;
}

Options parseUserArgs(string[] args) {
    import std.algorithm : among;
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
        opts.help = args.length > 1 && args[1].among("-h", "--help");
        return opts;
    default:
    }

    try {
        bool remote_shell;
        bool install;
        bool measure_hosts;
        bool local_load;
        bool local_run;
        bool run_on_all;
        ulong timeout_s;

        // dfmt off
        opts.help_info = std.getopt.getopt(args, std.getopt.config.passThrough,
            std.getopt.config.keepEndOfOptions,
            "install", "install distssh by setting up the correct symlinks", &install,
            "shell", "open an interactive shell on the remote host", &remote_shell,
            "export-env", "export the current env to the remote host to be used", &opts.exportEnv,
            "timeout", "timeout to use when checking remote hosts", &timeout_s,
            "measure", "measure the login time and load of all remote hosts", &measure_hosts,
            "local-load", "measure the load on the current host", &local_load,
            "local-run", "import env and run the command locally", &local_run,
            "v|verbose", "verbose logging", &opts.verbose,
            "i|import-env", "import the env from the file", &opts.importEnv,
            "workdir", "working directory to run the command in", &opts.workDir,
            "run-on-all", "run the command on all remote hosts", &run_on_all,
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
        else if (local_load)
            opts.mode = Options.Mode.localLoad;
        else if (local_run)
            opts.mode = Options.Mode.importEnvCmd;
        else if (run_on_all)
            opts.mode = Options.Mode.runOnAll;
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
    import std.parallelism : TaskPool;

    try {
        if (hosts.length == 0)
            return typeof(return)();

        static auto loadHost(T)(T host_to) {
            return tuple(host_to[0], getLoad(host_to[0], host_to[1]));
        }

        auto shosts = hosts.splitter(";").map!(a => tuple(Host(a), timeout)).array;
        if (shosts.length == 1)
            return typeof(return)(Host(shosts[0][0]));

        auto pool = new TaskPool(shosts.length + 1);
        scope (exit)
            pool.stop;

        // dfmt off
        auto measured =
            pool.map!loadHost(shosts)
            .map!(a => tuple(a[0], a[1]))
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
    double loadAvg;
    Duration accessTime;

    bool opEquals(const this o) nothrow @safe pure @nogc {
        return loadAvg == o.loadAvg && accessTime == o.accessTime;
    }

    int opCmp(const this o) pure @safe @nogc nothrow {
        if (loadAvg < o.loadAvg)
            return  - 1;
        else if (loadAvg > o.loadAvg)
            return 1;

        if (accessTime < o.accessTime)
            return  - 1;
        else if (accessTime > o.accessTime)
            return 1;

        return this == o ? 0 : 1;
    }
}

/** Login on host and measure its load.
 *
 * Params:
 *  h = remote host to check
 *
 * Returns: the Load of the remote host
 */
Load getLoad(Host h, Duration timeout) nothrow {
    import std.conv : to;
    import std.file : thisExePath;
    import std.process : tryWait, pipeProcess, kill, wait;
    import std.range : takeOne, retro;
    import std.stdio : writeln;
    import core.time : MonoTime, dur;
    import core.sys.posix.signal : SIGKILL;

    enum ExitCode {
        error,
        timeout,
        ok,
    }

    ExitCode exit_code;
    const start_at = MonoTime.currTime;
    const stop_at = start_at + timeout;

    auto elapsed = 3600.dur!"seconds";
    double load = int.max;

    try {
        immutable abs_distssh = thisExePath;
        auto res = pipeProcess(["ssh", "-q", "-oStrictHostKeyChecking=no", h,
                abs_distssh, "--local-load"]);

        while (true) {
            auto st = res.pid.tryWait;

            if (st.terminated && st.status == 0) {
                exit_code = ExitCode.ok;
                break;
            } else if (st.terminated && st.status != 0) {
                exit_code = ExitCode.error;
                break;
            } else if (stop_at < MonoTime.currTime) {
                exit_code = ExitCode.timeout;
                res.pid.kill(SIGKILL);
                // must read the exit or a zombie process is left behind
                res.pid.wait;
                break;
            }
        }

        elapsed = MonoTime.currTime - start_at;

        if (exit_code != ExitCode.ok)
            return Load(load, elapsed);

        try {
            string last_line;
            foreach (a; res.stdout.byLineCopy) {
                last_line = a;
            }

            load = last_line.to!double;
        }
        catch (Exception e) {
            logger.trace(res.stdout).collectException;
            logger.trace(res.stderr).collectException;
            logger.trace(e.msg).collectException;
        }
    }
    catch (Exception e) {
        logger.trace(e.msg).collectException;
    }

    return Load(load, elapsed);
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
