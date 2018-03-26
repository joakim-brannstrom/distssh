/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Methods prefixed with `cli_` are strongly related to user commands.
They more or less fully implement a command line interface command.
*/
module distssh.app;

import core.time : Duration;
import std.algorithm : splitter, map, filter, joiner;
import std.exception : collectException;
import std.stdio : File;
import std.typecons : Nullable, NullableRef;
import logger = std.experimental.logger;

static import std.getopt;

immutable globalEnvironemntKey = "DISTSSH_HOSTS";
immutable distShell = "distshell";
immutable distCmd = "distcmd";
immutable distsshEnvExport = "distssh_env.export";
immutable ulong defaultTimeout_s = 2;

version (unittest) {
} else {
    int main(string[] args) nothrow {
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

int appMain(const Options opts) nothrow {
    final switch (opts.mode) with (Options.Mode) {
    case exportEnv:
        return cli_exportEnv(opts);
    case install:
        import std.file : symlink;

        return cli_install(opts, (string src, string dst) => symlink(src, dst));
    case shell:
        return cli_shell(opts);
    case localShell:
        return cli_localShell(opts);
    case cmd:
        return cli_cmd(opts);
    case importEnvCmd:
        return cli_cmdWithImportedEnv(opts);
    case measureHosts:
        return cli_measureHosts(opts);
    case localLoad:
        import std.stdio : writeln;

        return cli_localLoad((string s) => writeln(s));
    case runOnAll:
        return cli_runOnAll(opts);
    }
}

private:

int cli_exportEnv(const Options opts) nothrow {
    import std.stdio : writeln;
    import core.sys.posix.sys.stat : fchmod, S_IRUSR, S_IWUSR;
    import std.process : environment;

    string[string] env;
    try {
        env = environment.toAA;
    }
    catch (Exception e) {
        logger.warning(e.msg).collectException;
        return 1;
    }

    try {
        auto fout = File(opts.importEnv, "w");
        fchmod(fout.fileno, S_IRUSR | S_IWUSR);
        foreach (kv; env.byKeyValue) {
            fout.writefln("%s=%s", kv.key, kv.value);
        }
        writeln("Exported environment to ", opts.importEnv);
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }

    return 0;
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

    // make sure there are at least one environment variable
    import core.sys.posix.stdlib : putenv;

    const env_var = "DISTSSH_ENV_TEST=foo";
    putenv(cast(char*) env_var.ptr);

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
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.file : thisExePath, getcwd;
    import std.process : spawnProcess, wait;
    import std.stdio : writeln, writefln;

    auto hosts = RemoteHostCache.make(opts.timeout);
    hosts.sortByLoad;

    if (hosts.empty) {
        logger.errorf("No remote host online").collectException;
    }

    const timout_until_considered_successfull_connection = opts.timeout * 2;

    while (!hosts.empty) {
        auto host = hosts.randomAndPop;

        try {
            if (host.isNull) {
                logger.error("No remote host online");
                return 1;
            }

            writeln("Connecting to ", host);

            auto sw = StopWatch(AutoStart.yes);

            // two -t forces a tty to be created and used which mean that the remote shell will *think* it is an interactive shell
            auto exit_status = spawnProcess(["ssh", "-q", "-t", "-t", "-oStrictHostKeyChecking=no",
                    host, thisExePath, "--local-shell", "--workdir", getcwd]).wait;

            // #SPC-fallback_remote_host
            if (exit_status == 0 || sw.peek > timout_until_considered_successfull_connection) {
                writefln("Connection to %s closed.", host);
                return exit_status;
            } else {
                logger.warningf("Connection failed to %s. Falling back on next available host",
                        host);
            }
        }
        catch (Exception e) {
            logger.error(e.msg).collectException;
        }
    }

    return 1;
}

// #SPC-shell_current_dir
int cli_localShell(const Options opts) nothrow {
    import std.file : exists;
    import std.process : spawnProcess, wait, userShell, Config, Pid;

    try {
        Pid pid;
        if (exists(opts.workDir))
            pid = spawnProcess([userShell], null, Config.none, opts.workDir);
        else
            pid = spawnProcess([userShell]);

        return pid.wait;
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }
}

int cli_cmd(const Options opts) nothrow {
    auto hosts = RemoteHostCache.make(opts.timeout);
    hosts.sortByLoad;

    if (hosts.empty) {
        logger.errorf("No remote host online").collectException;
        return 1;
    }

    auto host = hosts.randomAndPop;
    if (host.isNull)
        return 1;

    return executeOnHost(opts, host);
}

int executeOnHost(const Options opts, Host host) nothrow {
    import distssh.protocol : ProtocolEnv;
    import core.thread : Thread;
    import core.time : dur, MonoTime;
    import std.file : thisExePath;
    import std.path : absolutePath;
    import std.process : tryWait, Redirect, pipeProcess;

    // #SPC-draft_remote_cmd_spec
    try {
        import std.file : getcwd;

        auto args = ["ssh", "-oStrictHostKeyChecking=no", host, thisExePath,
            "--local-run", "--workdir", getcwd, "--stdin-msgpack-env", "--"] ~ opts.command;

        logger.info("Connecting to: ", host);
        logger.info("run: ", args.joiner(" "));

        auto p = pipeProcess(args, Redirect.stdin);

        auto pwriter = PipeWriter(p.stdin);

        ProtocolEnv env;
        if (opts.cloneEnv)
            env = cloneEnv;
        else
            env = readEnv(opts.importEnv.absolutePath);
        pwriter.pack(env);

        while (true) {
            try {
                auto st = p.pid.tryWait;
                if (st.terminated)
                    return st.status;

                Watchdog.ping(pwriter);
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

// #SPC-fast_env_startup
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

    static auto updateEnv(const Options opts, ref PipeReader pread, ref string[string] out_env) {
        import distssh.protocol : ProtocolEnv;

        ProtocolEnv env;

        if (opts.stdinMsgPackEnv) {
            while (true) {
                pread.update;

                try {
                    auto tmp = pread.unpack!(ProtocolEnv);
                    if (!tmp.isNull) {
                        env = tmp;
                        break;
                    }
                }
                catch (Exception e) {
                }

                Thread.sleep(10.dur!"msecs");
            }
        } else {
            readEnv(opts.importEnv);
        }

        foreach (kv; env) {
            out_env[kv.key] = kv.value;
        }
    }

    try {
        string[string] env;
        auto pread = PipeReader(stdin.fileno);

        try {
            updateEnv(opts, pread, env);
        }
        catch (Exception e) {
            logger.trace(e.msg).collectException;
        }

        Pid res;

        if (exists(opts.command[0])) {
            res = spawnProcess(opts.command, env, Config.none, opts.workDir);
        } else {
            res = spawnShell(opts.command.dup.joiner(" ").toUTF8, env, Config.none, opts.workDir);
        }

        import core.time : MonoTime, dur;
        import core.sys.posix.unistd : getppid;

        const parent_pid = getppid;
        const check_parent_interval = 500.dur!"msecs";
        const timeout = opts.timeout * 2;

        int exit_status = 1;
        bool sigint_cleanup;

        auto check_parent = MonoTime.currTime + check_parent_interval;

        auto wd = Watchdog(pread, timeout);

        while (!wd.isTimeout) {
            pread.update;

            try {
                auto status = tryWait(res);
                if (status.terminated) {
                    exit_status = status.status;
                    break;
                }
                wd.update;
            }
            catch (Exception e) {
            }

            // #SPC-sigint_detection
            if (MonoTime.currTime > check_parent) {
                check_parent = MonoTime.currTime + check_parent_interval;
                if (getppid != parent_pid) {
                    sigint_cleanup = true;
                    break;
                }
            }

            Thread.sleep(50.dur!"msecs");
        }

        import core.sys.posix.signal : kill, killpg, SIGKILL;
        import core.sys.posix.unistd : getpid;

        // #SPC-early_terminate_no_processes_left
        if (wd.isTimeout) {
            // cleanup all subprocesses of sshd. Should catch those that fork and create another process group.
            cleanupProcess(distssh.app.Pid(parent_pid), (int a) => kill(a,
                    SIGKILL), (int a) => killpg(a, SIGKILL));
        }

        if (sigint_cleanup || wd.isTimeout) {
            // sshd has already died on a SIGINT on the host side thus it is only possible to reliabley cleanup *this* process tree if anything is left.
            cleanupProcess(distssh.app.Pid(getpid), (int a) => kill(a, SIGKILL),
                    (int a) => killpg(a, SIGKILL)).killpg(SIGKILL);
        }

        return exit_status;
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }
}

// #SPC-measure_remote_hosts
int cli_measureHosts(const Options opts) nothrow {
    import std.conv : to;
    import std.stdio : writefln, writeln;
    import distssh.table;

    auto hosts = RemoteHostCache.make(opts.timeout);
    hosts.sortByLoad;

    writefln("Configured hosts (%s='%s')", globalEnvironemntKey, hosts.remoteHosts.joiner(";"))
        .collectException;

    string[3] row = ["Host", "Access Time", "Load"];
    auto tbl = Table!3(row);

    foreach (a; hosts.remoteByLoad) {
        try {
            row[0] = a[0];
            row[1] = a[1].accessTime.to!string;
            row[2] = a[1].loadAvg.to!string;
            tbl.put(row);
            //writefln("%s | %s | %s", a[0], a[1].accessTime.to!string, a[1].loadAvg.to!string);
        }
        catch (Exception e) {
            logger.trace(e.msg).collectException;
        }
    }

    try {
        writeln(tbl);
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
    }

    return 0;
}

/**
DESCRIPTION

     The getloadavg() function returns the number of processes in the system
     run queue averaged over various periods of time.  Up to nelem samples are
     retrieved and assigned to successive elements of loadavg[].  The system
     imposes a maximum of 3 samples, representing averages over the last 1, 5,
     and 15 minutes, respectively.


DIAGNOSTICS

     If the load average was unobtainable, -1 is returned; otherwise, the num-
     ber of samples actually retrieved is returned.
 */
extern (C) int getloadavg(double* loadavg, int nelem);

/** Print the load of localhost.
 *
 * #SPC-measure_local_load
 */
int cli_localLoad(WriterT)(scope WriterT writer) nothrow {
    import std.ascii : newline;
    import std.conv : to;
    import std.parallelism : totalCPUs;

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
    }
    catch (Exception e) {
        logger.trace(e.msg).collectException;
        return -1;
    }

    return 0;
}

int cli_runOnAll(const Options opts) nothrow {
    import std.algorithm : sort;
    import std.stdio : writefln, writeln, stdout;

    auto shosts = hostsFromEnv;

    writefln("Configured hosts (%s): %(%s|%)", globalEnvironemntKey, shosts).collectException;

    bool exit_status = true;
    foreach (a; shosts.sort) {
        stdout.writefln("Connecting to %s.", a).collectException;
        try {
            // #SPC-flush_buffers
            stdout.flush;
        }
        catch (Exception e) {
        }

        auto status = executeOnHost(opts, a);

        if (status != 0) {
            writeln("Failed, error code: ", status).collectException;
            exit_status = false;
        }

        stdout.writefln("Connection to %s closed.", a).collectException;
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
        localShell,
        exportEnv,
    }

    Mode mode;

    bool help;
    bool cloneEnv;
    bool verbose;
    bool stdinMsgPackEnv;
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
        bool export_env;
        bool remote_shell;
        bool install;
        bool measure_hosts;
        bool local_load;
        bool local_run;
        bool local_shell;
        bool run_on_all;
        ulong timeout_s;

        // alphabetical order
        // dfmt off
        opts.help_info = std.getopt.getopt(args, std.getopt.config.passThrough,
            std.getopt.config.keepEndOfOptions,
            "clone-env", "clone the current environment to the remote host", &opts.cloneEnv,
            "export-env", "export the current environment to a file that is used on the remote host", &export_env,
            "install", "install distssh by setting up the correct symlinks", &install,
            "i|import-env", "import the env from the file", &opts.importEnv,
            "measure", "measure the login time and load of all remote hosts", &measure_hosts,
            "local-load", "measure the load on the current host", &local_load,
            "local-run", "import env and run the command locally", &local_run,
            "local-shell", "run the shell locally", &local_shell,
            "run-on-all", "run the command on all remote hosts", &run_on_all,
            "shell", "open an interactive shell on the remote host", &remote_shell,
            "stdin-msgpack-env", "import env from stdin as a msgpacked stream", &opts.stdinMsgPackEnv,
            "timeout", "timeout to use when checking remote hosts", &timeout_s,
            "v|verbose", "verbose logging", &opts.verbose,
            "workdir", "working directory to run the command in", &opts.workDir,
            );
        // dfmt on
        opts.help = opts.help_info.helpWanted;

        import core.time : dur;

        if (timeout_s > 0)
            opts.timeout = timeout_s.dur!"seconds";

        if (install)
            opts.mode = Options.Mode.install;
        else if (export_env)
            opts.mode = Options.Mode.exportEnv;
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
        else if (local_shell)
            opts.mode = Options.Mode.localShell;
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
    }

    if (opts.mode == Options.Mode.cmd && opts.command.length == 0)
        opts.help = true;

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

    auto help_txt = "usage: %s [options] -- [COMMAND]\n";
    if (opts.selfBinary.baseName == distCmd) {
        help_txt = "usage: %s [COMMAND]\n";
    }

    try {
        defaultGetoptPrinter(format(help_txt, opts.selfBinary.baseName), opts.help_info.options.dup);
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
    }
}

struct Host {
    string payload;
    alias payload this;
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

@("shall sort the loads")
unittest {
    import std.algorithm : sort;
    import std.array : array;
    import core.time : dur;

    {
        auto raw = [Load(0.6, 500.dur!"msecs"), Load(0.5, 500.dur!"msecs")].sort.array;
        assert(raw[0].loadAvg == 0.5);
    }

    {
        auto raw = [Load(0.5, 600.dur!"msecs"), Load(0.5, 500.dur!"msecs")].sort.array;
        assert(raw[0].accessTime == 500.dur!"msecs");
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
                break;
            }
        }

        // must read the exit or a zombie process is left behind
        res.pid.wait;

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
auto cloneEnv() nothrow {
    import distssh.protocol : ProtocolEnv, EnvVariable;
    import std.process : environment;

    ProtocolEnv app;

    try {
        foreach (const a; environment.toAA.byKeyValue) {
            app ~= EnvVariable(a.key, a.value);
        }
    }
    catch (Exception e) {
        logger.warning(e.msg).collectException;
    }

    return app;
}

import core.sys.posix.unistd : pid_t;

struct Pid {
    pid_t value;
    alias value this;
}

Pid[] getShallowChildren(int parent_pid) {
    import core.sys.posix.unistd : pid_t;
    import std.conv : to;
    import std.array : appender;
    import std.file : dirEntries, SpanMode, exists;
    import std.path : buildPath, baseName;

    auto children = appender!(Pid[])();

    foreach (const p; File(buildPath("/proc", parent_pid.to!string, "task",
            parent_pid.to!string, "children")).readln.splitter(" ").filter!(a => a.length > 0)) {
        try {
            children.put(p.to!pid_t.Pid);
        }
        catch (Exception e) {
            logger.trace(e.msg).collectException;
        }
    }

    return children.data;
}

@("shall return the immediate children of the init process")
unittest {
    import std.conv;

    auto res = getShallowChildren(1);
    //logger.trace(res);
    assert(res.length > 0);
}

/** Returns: a list of all processes with the top being at the back
 */
Pid[] getDeepChildren(int parent_pid) {
    import std.array : appender;
    import std.container : DList;

    auto children = DList!Pid();

    children.insert(getShallowChildren(parent_pid));
    auto res = appender!(Pid[])();

    while (!children.empty) {
        const p = children.front;
        res.put(p);
        children.insertBack(getShallowChildren(p));
        children.removeFront;
    }

    return res.data;
}

@("shall return a list of all children of the init process")
unittest {
    import std.conv;

    auto direct = getShallowChildren(1);
    auto deep = getDeepChildren(1);

    //logger.trace(direct);
    //logger.trace(deep);

    assert(deep.length > direct.length);
}

struct PidGroup {
    pid_t value;
    alias value this;
}

/** Returns: a list of the process groups in the same order as the input.
 */
PidGroup[] getPidGroups(const Pid[] pids) {
    import core.sys.posix.unistd : getpgid;
    import std.array : array;
    import std.array : appender;

    auto res = appender!(PidGroup[])();
    bool[pid_t] pgroups;

    foreach (const p; pids.map!(a => getpgid(a)).filter!(a => a != -1)) {
        if (p !in pgroups) {
            pgroups[p] = true;
            res.put(PidGroup(p));
        }
    }

    return res.data;
}

/** Cleanup the children processes.
 *
 * Create an array of children process groups.
 * Create an array of children pids.
 * Kill the children pids to prohibit them from spawning more processes.
 * Kill the groups from top to bottom.
 *
 * Params:
 *  parent_pid = pid of the parent to analyze and kill the children of
 *  kill = a function that kill a process
 *  killpg = a function that kill a process group
 *
 * Returns: the process group of "this".
 */
pid_t cleanupProcess(KillT, KillPgT)(Pid parent_pid, KillT kill, KillPgT killpg) nothrow {
    import core.sys.posix.unistd : getpgrp, getpid, getppid;

    const this_pid = getpid();
    const this_gid = getpgrp();

    try {
        auto children_groups = getDeepChildren(parent_pid).getPidGroups;
        auto direct_children = getShallowChildren(parent_pid);

        foreach (const p; direct_children.filter!(a => a != this_pid)) {
            kill(p);
        }

        foreach (const p; children_groups.filter!(a => a != this_gid)) {
            killpg(p);
        }
    }
    catch (Exception e) {
        logger.trace(e.msg).collectException;
    }

    return this_gid;
}

@("shall return a list of all children pid groups of the init process")
unittest {
    import std.conv;
    import core.sys.posix.unistd : getpgrp, getpid, getppid;

    auto direct = getShallowChildren(1);
    auto deep = getDeepChildren(1);
    auto groups = getPidGroups(deep);

    //logger.trace(direct.length, direct);
    //logger.trace(deep.length, deep);
    //logger.trace(groups.length, groups);

    assert(groups.length < deep.length);
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
        }
        catch (Exception e) {
        }

        deser.cleanupUntilKind;
    }
}

struct PipeWriter {
    import distssh.protocol : Serialize;

    File fout;
    Serialize!(void delegate(const(ubyte)[])) ser;

    alias ser this;

    this(File f) {
        this.fout = f;
        this.ser = typeof(ser)(&this.put);
    }

    void put(const(ubyte)[] v) {
        fout.rawWrite(v);
        fout.flush;
    }
}

auto readEnv(string filename) nothrow {
    import distssh.protocol : ProtocolEnv, EnvVariable;
    import std.file : exists;
    import std.stdio : File;

    ProtocolEnv rval;

    if (!exists(filename))
        return rval;

    try {
        foreach (kv; File(filename).byLine.map!(a => a.splitter("="))) {
            string k = kv.front.idup;
            string v;
            kv.popFront;
            if (!kv.empty)
                v = kv.front.idup;
            rval ~= EnvVariable(k, v);
        }
    }
    catch (Exception e) {
        logger.trace(e.msg).collectException;
    }

    return rval;
}

Host[] hostsFromEnv() nothrow {
    import std.array : array;
    import std.string : strip;
    import std.process : environment;

    static import core.stdc.stdlib;

    typeof(return) rval;

    try {
        string hosts_env = environment.get(globalEnvironemntKey, "").strip;
        rval = hosts_env.splitter(";").map!(a => a.strip)
            .filter!(a => a.length > 0).map!(a => Host(a)).array;

        if (rval.length == 0) {
            logger.errorf("No remote host configured (%s='%s')", globalEnvironemntKey, hosts_env);
        }
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
    }

    return rval;
}

/**
 * #SPC-load_balance
 * #SPC-best_remote_host
 */
struct RemoteHostCache {
    import std.array : array;
    import std.typecons : Tuple, tuple;

    alias HostLoad = Tuple!(Host, Load);

    Duration timeout;
    Host[] remoteHosts;
    HostLoad[] remoteByLoad;

    static auto make(Duration timeout) nothrow {
        return RemoteHostCache(timeout, hostsFromEnv);
    }

    /// Measure and sort the remote hosts.
    void sortByLoad() nothrow {
        import std.algorithm : sort;
        import std.parallelism : TaskPool;

        static auto loadHost(T)(T host_timeout) nothrow {
            return HostLoad(host_timeout[0], getLoad(host_timeout[0], host_timeout[1]));
        }

        auto shosts = remoteHosts.map!(a => tuple(a, timeout)).array;

        try {
            auto pool = new TaskPool(shosts.length + 1);
            scope (exit)
                pool.stop;

            // dfmt off
            remoteByLoad =
                pool.map!loadHost(shosts)
                .array
                .sort!((a,b) => a[1] < b[1])
                .array;
            // dfmt on

            if (remoteByLoad.length == 0) {
                // this should be very uncommon but may happen.
                remoteByLoad = remoteHosts.map!(a => HostLoad(a, Load.init)).array;
            }
        }
        catch (Exception e) {
            logger.trace(e.msg).collectException;
        }
    }

    /// Returns: the lowest loaded server.
    Nullable!Host randomAndPop() @safe nothrow {
        import std.range : take;
        import std.random : uniform;

        typeof(return) rval;

        if (empty)
            return rval;

        try {
            auto top3 = remoteByLoad.take(3).array;
            auto ridx = uniform(0, top3.length);
            rval = top3[ridx][0];
        }
        catch (Exception e) {
            rval = remoteByLoad[0][0];
        }

        remoteByLoad = remoteByLoad.filter!(a => a[0] != rval).array;

        return rval;
    }

    Host front() @safe pure nothrow {
        assert(!empty);
        return remoteByLoad[0][0];
    }

    void popFront() @safe pure nothrow {
        assert(!empty);
        remoteByLoad = remoteByLoad[1 .. $];
    }

    bool empty() @safe pure nothrow {
        return remoteByLoad.length == 0;
    }
}
