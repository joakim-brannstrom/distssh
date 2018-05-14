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

import distssh.from;
import distssh.process : Pid;

static import std.getopt;

immutable globalEnvHostKey = "DISTSSH_HOSTS";
immutable globalEnvFileKey = "DISTSSH_IMPORT_ENV";
immutable globalEnvFilterKey = "DISTSSH_ENV_EXPORT_FILTER";
immutable distShell = "distshell";
immutable distCmd = "distcmd";
immutable distsshEnvExport = "distssh_env.export";
immutable ulong defaultTimeout_s = 2;

int rmain(string[] args) nothrow {
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

/** Export the environment to a file for later import.

  */
int cli_exportEnv(const Options opts) nothrow {
    try {
        writeEnv(opts.importEnv, cloneEnv);
        logger.info("Exported environment to ", opts.importEnv);
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
        return 1;
    }

    return 0;
}

unittest {
    import std.conv : to;
    import std.string : toStringz;
    import std.file;

    immutable remove_me = "remove_me.export";
    scope (exit)
        remove(remove_me);

    auto opts = parseUserArgs(["distssh", "--export-env", "--export-env-file", remove_me]);

    // make sure there are at least one environment variable
    import core.sys.posix.stdlib : putenv, unsetenv;

    const env_key = "DISTSSH_ENV_TEST";
    const env_var = (env_key ~ "=" ~ remove_me).toStringz;
    putenv(cast(char*) env_var);
    scope (exit)
        unsetenv(cast(char*) env_key.ptr);

    // shall export the environment to the file
    void verify1() {
        // test normal export
        cli_exportEnv(opts);

        auto env = readEnv(remove_me);
        assert(!env.filter!(a => a.key == env_key).empty, env.to!string);
    }

    verify1;

    // shall filter out specified env before exporting to the file
    const env_filter_var = (globalEnvFilterKey ~ "=DISTSSH_ENV_TEST;junk ").toStringz;
    putenv(cast(char*) env_filter_var);
    scope (exit)
        unsetenv(cast(char*) globalEnvFilterKey.ptr);

    void verify2() {
        cli_exportEnv(opts);

        auto env = readEnv(remove_me);
        assert(env.filter!(a => a.key == env_key).empty, env.to!string);
    }

    verify2;
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

/** Execute a command on a remote host.
 *
 * #SPC-automatic_env_import
 */
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
        else if (!opts.noImportEnv)
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
            env = readEnv(opts.importEnv);
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
        const flush_stdout_interval = 1.dur!"seconds";

        int exit_status = 1;
        bool sigint_cleanup;

        auto check_parent = MonoTime.currTime + check_parent_interval;
        auto flush_stdout = MonoTime.currTime + flush_stdout_interval;

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

            if (MonoTime.currTime > flush_stdout) {
                import std.stdio : stdout;

                stdout.flush;
                flush_stdout = MonoTime.currTime + flush_stdout_interval;
            }

            Thread.sleep(50.dur!"msecs");
        }

        import core.sys.posix.signal : kill, killpg, SIGKILL;
        import core.sys.posix.unistd : getpid;
        import distssh.process : cleanupProcess;

        // #SPC-early_terminate_no_processes_left
        if (wd.isTimeout) {
            // cleanup all subprocesses of sshd. Should catch those that fork and create another process group.
            cleanupProcess(.Pid(parent_pid), (int a) => kill(a, SIGKILL),
                    (int a) => killpg(a, SIGKILL));
        }

        if (sigint_cleanup || wd.isTimeout) {
            // sshd has already died on a SIGINT on the host side thus it is only possible to reliabley cleanup *this* process tree if anything is left.
            cleanupProcess(.Pid(getpid), (int a) => kill(a, SIGKILL), (int a) => killpg(a, SIGKILL)).killpg(
                    SIGKILL);
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

    writefln("Configured hosts (%s='%s')", globalEnvHostKey, hosts.remoteHosts.joiner(";"))
        .collectException;
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

/** Print the load of localhost.
 *
 * #SPC-measure_local_load
 */
int cli_localLoad(WriterT)(scope WriterT writer) nothrow {
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

    writefln("Configured hosts (%s): %(%s|%)", globalEnvHostKey, shosts).collectException;

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
    bool noImportEnv;
    bool cloneEnv;
    bool verbose;
    bool stdinMsgPackEnv;
    std.getopt.GetoptResult help_info;

    Duration timeout = defaultTimeout_s.dur!"seconds";

    string selfBinary;
    string selfDir;

    string importEnv;
    string workDir;
    string[] command;
}

/** Update a Configs object's file to import the environment from.
 *
 * This should only be called after all other command line parsing has been
 * done. It is because this function take into consideration the priority as
 * specified in the requirement:
 * #SPC-configure_env_import_file
 *
 * Params:
 *  opts = config to update the file to import the environment from.
 */
void configImportEnvFile(ref Options opts) nothrow {
    import std.process : environment;

    if (opts.noImportEnv) {
        opts.importEnv = null;
    } else if (opts.importEnv.length != 0) {
        // do nothing. the user has specified a file
    } else {
        try {
            opts.importEnv = environment.get(globalEnvFileKey, distsshEnvExport);
        }
        catch (Exception e) {
        }
    }
}

/**
 * #SPC-remote_command_parse
 *
 * Params:
 *  args = the command line arguments to parse.
 */
Options parseUserArgs(string[] args) {
    import std.algorithm : among;
    import std.file : thisExePath;
    import std.path : dirName, baseName, buildPath;

    Options opts;

    opts.selfBinary = buildPath(thisExePath.dirName, args[0].baseName);
    opts.selfDir = opts.selfBinary.dirName;

    switch (opts.selfBinary.baseName) {
    case distShell:
        opts.mode = Options.Mode.shell;
        return opts;
    case distCmd:
        opts.mode = Options.Mode.cmd;
        opts.command = args.length > 1 ? args[1 .. $] : null;
        opts.help = args.length > 1 && args[1].among("-h", "--help");
        configImportEnvFile(opts);
        return opts;
    default:
    }

    try {
        bool export_env;
        string export_env_file;
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
            "clone-env", "clone the current environment to the remote host without an intermediate file", &opts.cloneEnv,
            "export-env", "export the current environment to a file that is used on the remote host", &export_env,
            "export-env-file", "export the current environment to the specified file", &export_env_file,
            "install", "install distssh by setting up the correct symlinks", &install,
            "i|import-env", "import the env from the file (default: " ~ distsshEnvExport ~ ")", &opts.importEnv,
            "no-import-env", "do not automatically import the environment from " ~ distsshEnvExport, &opts.noImportEnv,
            "measure", "measure the login time and load of all remote hosts", &measure_hosts,
            "local-load", "measure the load on the current host", &local_load,
            "local-run", "import env and run the command locally", &local_run,
            "local-shell", "run the shell locally", &local_shell,
            "run-on-all", "run the command on all remote hosts", &run_on_all,
            "shell", "open an interactive shell on the remote host", &remote_shell,
            "stdin-msgpack-env", "import env from stdin as a msgpack stream", &opts.stdinMsgPackEnv,
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
        else if (export_env) {
            opts.mode = Options.Mode.exportEnv;
            if (export_env_file.length != 0)
                opts.importEnv = export_env_file;
        } else if (remote_shell)
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

    configImportEnvFile(opts);

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
    import core.thread : Thread;
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
    // 25 because it is at the perception of human "lag" and less than the 100
    // msecs that is the intention of the average delay.
    const loop_sleep = 25.dur!"msecs";
    double load = int.max;

    try {
        immutable abs_distssh = thisExePath;
        // -T ensure that an interactive prompt for the password never happen (NOT VERIFIED)
        auto res = pipeProcess(["ssh", "-T", "-q", "-oStrictHostKeyChecking=no", h,
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

            // sleep to avoid massive CPU usage
            Thread.sleep(loop_sleep);
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
                .strip.splitter(';').map!(a => a.strip).filter!(a => a.length != 0)) {
            if (env.remove(k)) {
                logger.infof("Removed '%s' from the exported environment", k);
            }
        }

        foreach (const a; env.byKeyValue) {
            app ~= EnvVariable(a.key, a.value);
        }
    }
    catch (Exception e) {
        logger.warning(e.msg).collectException;
    }

    return app;
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

auto readEnv(string filename) nothrow {
    import distssh.protocol : ProtocolEnv, EnvVariable, Deserialize;
    import std.file : exists;
    import std.stdio : File;

    ProtocolEnv rval;

    if (!exists(filename)) {
        logger.info("File to import the environment from do not exist: ",
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
    }
    catch (Exception e) {
        logger.error(e.msg).collectException;
        logger.errorf("Unable to import environment from '%s'", filename).collectException;
    }

    return rval;
}

void writeEnv(string filename, from!"distssh.protocol".ProtocolEnv env) {
    import core.sys.posix.sys.stat : fchmod, S_IRUSR, S_IWUSR;
    import std.stdio : File;
    import distssh.protocol : Serialize;

    auto fout = File(filename, "w");
    fchmod(fout.fileno, S_IRUSR | S_IWUSR);

    auto ser = Serialize!(void delegate(const(ubyte)[]) @safe)((const(ubyte)[] a) => fout.rawWrite(
            a));

    ser.pack(env);
}

Host[] hostsFromEnv() nothrow {
    import std.array : array;
    import std.string : strip;
    import std.process : environment;

    static import core.stdc.stdlib;

    typeof(return) rval;

    try {
        string hosts_env = environment.get(globalEnvHostKey, "").strip;
        rval = hosts_env.splitter(";").map!(a => a.strip)
            .filter!(a => a.length > 0).map!(a => Host(a)).array;

        if (rval.length == 0) {
            logger.errorf("No remote host configured (%s='%s')", globalEnvHostKey, hosts_env);
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
    auto matches = environment["PATH"].splitter(pathSeparator)
        .map!(path => buildPath(path, exe)).filter!(path => exists(path));
    return matches.empty ? exe : matches.front;
}
