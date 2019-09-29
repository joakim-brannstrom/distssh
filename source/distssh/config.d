/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.config;

import core.time : dur, Duration;
import logger = std.experimental.logger;
import std.algorithm : among, remove, filter, find;
import std.array : array, empty;
import std.file : thisExePath, getcwd;
import std.format : format;
import std.getopt : defaultGetoptPrinter;
import std.meta : AliasSeq;
import std.path : baseName, buildPath, dirName, absolutePath;
import std.range : drop;
import std.stdio : writeln;
import std.string : toLower;
import std.traits : EnumMembers, hasMember;
import std.variant : Algebraic, visit;
static import std.getopt;

import colorlog : VerboseMode;

import distssh.types;

version (unittest) {
    import unit_threaded.assertions;
}

struct Config {
    struct Help {
        std.getopt.GetoptResult helpInfo;
    }

    struct Global {
        std.getopt.GetoptResult helpInfo;
        VerboseMode verbosity;
        string progName;
        bool noImportEnv;
        bool cloneEnv;
        bool stdinMsgPackEnv;
        Duration timeout = defaultTimeout_s.dur!"seconds";

        string selfBinary;
        string selfDir;

        string importEnv;
        string workDir;
        string[] command;
    }

    struct Shell {
        std.getopt.GetoptResult helpInfo;
        static string helpDescription = "open an interactive shell on the remote host";
    }

    struct Cmd {
        std.getopt.GetoptResult helpInfo;
        static string helpDescription = "run a command on a remote host";
    }

    struct LocalRun {
        std.getopt.GetoptResult helpInfo;
        static string helpDescription = "import env and run the command locally";
    }

    struct Install {
        std.getopt.GetoptResult helpInfo;
        static string helpDescription = "install distssh by setting up the correct symlinks";
    }

    struct MeasureHosts {
        std.getopt.GetoptResult helpInfo;
        static string helpDescription = "measure the login time and load of all remote hosts";
    }

    struct LocalLoad {
        std.getopt.GetoptResult helpInfo;
        static string helpDescription = "measure the load on the current host";
    }

    struct RunOnAll {
        std.getopt.GetoptResult helpInfo;
        static string helpDescription = "run the command on all remote hosts";
    }

    struct LocalShell {
        std.getopt.GetoptResult helpInfo;
        static string helpDescription = "run the shell locally";
    }

    struct Env {
        std.getopt.GetoptResult helpInfo;
        static string helpDescription = "manipulate the stored environment";
        /// Print the environment.
        bool print;
        /// Env variable to set in the config specified in importEnv.
        string[] envSet;
        /// Env variables to remove from the onespecified in importEnv.
        string[] envDel;
        /// Export the current environment
        bool exportEnv;
    }

    alias Type = Algebraic!(Help, Shell, Cmd, LocalRun, Install, MeasureHosts,
            LocalLoad, RunOnAll, LocalShell, Env);
    Type data;

    Global global;

    void printHelp() {
        static void printGroup(T)(std.getopt.GetoptResult global,
                std.getopt.GetoptResult helpInfo, string progName) {
            const helpDescription = () {
                static if (hasMember!(T, "helpDescription"))
                    return T.helpDescription ~ "\n";
                else
                    return null;
            }();
            defaultGetoptPrinter(format("usage: %s %s <options>\n%s", progName,
                    T.stringof.toLower, helpDescription), global.options);
            defaultGetoptPrinter(null, helpInfo.options.filter!(a => a.optShort != "-h").array);
        }

        static void printHelpGroup(std.getopt.GetoptResult helpInfo, string progName) {
            defaultGetoptPrinter(format("usage: %s <command>\n", progName), helpInfo.options);
            writeln("Command groups:");
            static foreach (T; Type.AllowedTypes) {
                static if (hasMember!(T, "helpDescription"))
                    writeln("  ", T.stringof.toLower, " ", T.helpDescription);
                else
                    writeln("  ", T.stringof.toLower);
            }
        }

        template printers(T...) {
            static if (T.length == 1) {
                static if (is(T[0] == Config.Help))
                    alias printers = (T[0] a) => printHelpGroup(a.helpInfo, global.progName);
                else
                    alias printers = (T[0] a) => printGroup!(T[0])(global.helpInfo,
                            a.helpInfo, global.progName);
            } else {
                alias printers = AliasSeq!(printers!(T[0]), printers!(T[1 .. $]));
            }
        }

        data.visit!(printers!(Type.AllowedTypes));
    }
}

/**
 * #SPC-remote_command_parse
 *
 * Params:
 *  args = the command line arguments to parse.
 */
Config parseUserArgs(string[] args) {
    Config conf;
    conf.data = Config.Help.init;
    conf.global.progName = args[0].baseName;
    conf.global.selfBinary = buildPath(thisExePath.dirName, args[0].baseName);
    conf.global.selfDir = conf.global.selfBinary.dirName;
    conf.global.workDir = getcwd;

    switch (conf.global.selfBinary.baseName) {
    case distShell:
        conf.data = Config.Shell.init;
        return conf;
    case distCmd:
        if (args.length > 1 && args[1].among("-h", "--help"))
            conf.data = Config.Help.init;
        else {
            conf.data = Config.Cmd.init;
            conf.global.command = args.length > 1 ? args[1 .. $] : null;
            configImportEnvFile(conf);
        }
        return conf;
    default:
    }

    string group;
    if (args.length > 1 && args[1][0] != '-') {
        group = args[1];
        args = args.remove(1);
    }

    try {
        void globalParse() {
            string export_env_file;
            ulong timeout_s = defaultTimeout_s;

            // dfmt off
            conf.global.helpInfo = std.getopt.getopt(args, std.getopt.config.passThrough, std.getopt.config.keepEndOfOptions,
                "clone-env", "clone the current environment to the remote host without an intermediate file", &conf.global.cloneEnv,
                "env-file", "file to load the environment from", &export_env_file,
                "i|import-env", "import the env from the file (default: " ~ distsshEnvExport ~ ")", &conf.global.importEnv,
                "no-import-env", "do not automatically import the environment from " ~ distsshEnvExport, &conf.global.noImportEnv,
                "stdin-msgpack-env", "import env from stdin as a msgpack stream", &conf.global.stdinMsgPackEnv,
                "timeout", "timeout to use when checking remote hosts", &timeout_s,
                "v|verbose", format("Set the verbosity (%-(%s, %))", [EnumMembers!(VerboseMode)]), &conf.global.verbosity,
                "workdir", "working directory to run the command in", &conf.global.workDir,
                );
            // dfmt on
            args ~= (conf.global.helpInfo.helpWanted ? "-h" : null);

            // must convert e.g. "."
            conf.global.workDir = conf.global.workDir.absolutePath;

            conf.global.timeout = timeout_s.dur!"seconds";

            if (!export_env_file.empty)
                conf.global.importEnv = export_env_file;

            if (!conf.global.helpInfo.helpWanted)
                conf.data = Config.Cmd.init;
        }

        void envParse() {
            Config.Env data;
            scope (success)
                conf.data = data;

            // dfmt off
            data.helpInfo = std.getopt.getopt(args, std.getopt.config.passThrough,
                std.getopt.config.keepEndOfOptions,
                "d|delete", "remove a variable from the exported environment", &data.envDel,
                "e|export", "export the current environment to a file that is used on the remote host", &data.exportEnv,
                "p|print", "print the content of an exported environment", &data.print,
                "s|set", "set a variable in the exported environment. Example: FOO=42", &data.envSet,
                );
            // dfmt on
        }

        void shellParse() {
            conf.data = Config.Shell.init;
        }

        void cmdParse() {
            conf.data = Config.Cmd.init;
        }

        void localrunParse() {
            conf.data = Config.LocalRun.init;
        }

        void installParse() {
            conf.data = Config.Install.init;
        }

        void measurehostsParse() {
            conf.data = Config.MeasureHosts.init;
        }

        void localloadParse() {
            conf.data = Config.LocalLoad.init;
        }

        void runonallParse() {
            conf.data = Config.RunOnAll.init;
        }

        void localshellParse() {
            conf.data = Config.LocalShell.init;
        }

        alias ParseFn = void delegate();
        ParseFn[string] parsers;

        static foreach (T; Config.Type.AllowedTypes) {
            static if (!is(T == Config.Help))
                mixin(format(`parsers["%1$s"] = &%1$sParse;`, T.stringof.toLower));
        }

        globalParse;

        if (auto p = group in parsers) {
            (*p)();
        }

        if (args.length > 1) {
            conf.global.command = args.find("--").drop(1).array();
        }
        configImportEnvFile(conf);
    } catch (std.getopt.GetOptException e) {
        // unknown option
        logger.error(e.msg);
    } catch (Exception e) {
        logger.error(e.msg);
    }

    return conf;
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
void configImportEnvFile(ref Config opts) nothrow {
    import std.process : environment;

    if (opts.global.noImportEnv) {
        opts.global.importEnv = null;
    } else if (opts.global.importEnv.length != 0) {
        // do nothing. the user has specified a file
    } else {
        try {
            opts.global.importEnv = environment.get(globalEnvFileKey, distsshEnvExport);
        } catch (Exception e) {
        }
    }
}

@("shall determine the absolute path of self")
unittest {
    import std.path;
    import std.file;

    auto opts = parseUserArgs(["distssh", "ls"]);
    assert(opts.global.selfBinary[0] == '/');
    assert(opts.global.selfBinary.baseName == "distssh");

    opts = parseUserArgs(["distshell"]);
    assert(opts.global.selfBinary[0] == '/');
    assert(opts.global.selfBinary.baseName == "distshell");

    opts = parseUserArgs(["distcmd"]);
    assert(opts.global.selfBinary[0] == '/');
    assert(opts.global.selfBinary.baseName == "distcmd");

    opts = parseUserArgs(["distcmd_recv", getcwd, distsshEnvExport]);
    assert(opts.global.selfBinary[0] == '/');
    assert(opts.global.selfBinary.baseName == "distcmd_recv");
}

@("shall either return the default timeout or the user specified timeout")
unittest {
    import core.time : dur;
    import std.conv;

    auto opts = parseUserArgs(["distssh", "ls"]);
    assert(opts.global.timeout == defaultTimeout_s.dur!"seconds");
    opts = parseUserArgs(["distssh", "--timeout", "10", "ls"]);
    assert(opts.global.timeout == 10.dur!"seconds");

    opts = parseUserArgs(["distshell"]);
    opts.global.timeout.shouldEqual(defaultTimeout_s.dur!"seconds");
    opts = parseUserArgs(["distshell", "--timeout", "10"]);
    assert(opts.global.timeout == defaultTimeout_s.dur!"seconds");
}

@("shall only be the default timeout because --timeout should be passed on to the command")
unittest {
    import core.time : dur;
    import std.conv;

    auto opts = parseUserArgs(["distcmd", "ls"]);
    assert(opts.global.timeout == defaultTimeout_s.dur!"seconds");

    opts = parseUserArgs(["distcmd", "--timeout", "10"]);
    assert(opts.global.timeout == defaultTimeout_s.dur!"seconds");
}

@("shall convert relative workdirs to absolute when parsing user args")
unittest {
    import std.path : isAbsolute;

    auto opts = parseUserArgs(["distssh", "--workdir", "."]);
    assert(opts.global.workDir.isAbsolute, "expected an absolute path");
}
