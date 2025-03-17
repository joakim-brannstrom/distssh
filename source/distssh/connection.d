/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

ssh connection for both normal and multiplex.
*/
module distssh.connection;

import logger = std.experimental.logger;
import std.exception : collectException;
import std.file : thisExePath;
import std.process : escapeShellFileName;

import my.path;

import distssh.types;

// arguments to ssh that turn off warning that a host key is new or requies a
// password to login
immutable sshNoLoginArgs = [
    "-oStrictHostKeyChecking=no", "-oPasswordAuthentication=no"
];

immutable sshMultiplexClient = ["-oControlMaster=auto", "-oControlPersist=300"];

SshArgs sshArgs(Host host, string[] ssh, string[] cmd) {
    return SshArgs("ssh", ssh ~ sshNoLoginArgs ~ [
            host, thisExePath.escapeShellFileName
            ], cmd);
}

SshArgs sshCmdArgs(Host host, string[] cmd) {
    // must ensure it exists
    setupMultiplexDir;
    return sshArgs(host, MultiplexPath(multiplexDir).toArgs ~ sshMultiplexClient.dup, cmd);
}

SshArgs sshShellArgs(Host host, Path workDir) {
    // two -t forces a tty to be created and used which mean that the remote
    // shell will *think* it is an interactive shell
    return sshArgs(host, ["-q", "-t", "-t"], [
            "localshell", "--workdir", workDir.toString.escapeShellFileName
            ]);
}

SshArgs sshLoadArgs(Host host) {
    return sshArgs(host, ["-q"], ["localload"]);
}

/// Arguments for creating a ssh connection and execute a command.
struct SshArgs {
    string ssh;
    string[] sshArgs;
    string[] cmd;

    ///
    ///
    /// Params:
    /// ssh     = command to use for establishing the ssh connection
    /// sshArgs = arguments to the `ssh`
    /// cmd     = command to execute
    this(string ssh, string[] sshArgs, string[] cmd) @safe pure nothrow @nogc {
        this.ssh = ssh;
        this.sshArgs = sshArgs;
        this.cmd = cmd;
    }

    string[] toArgs() @safe pure nothrow const {
        return [ssh] ~ sshArgs.dup ~ cmd.dup;
    }
}

AbsolutePath multiplexDir() @safe {
    import my.xdg : xdgRuntimeDir;

    return (xdgRuntimeDir ~ "distssh/multiplex").AbsolutePath;
}

struct MultiplexPath {
    AbsolutePath dir;
    string tokens = `%C`;

    string[] toArgs() @safe pure const {
        return ["-S", toString];
    }

    import std.range : isOutputRange;

    string toString() @safe pure const {
        import std.array : appender;

        auto buf = appender!string;
        toString(buf);
        return buf.data;
    }

    void toString(Writer)(ref Writer w) const if (isOutputRange!(Writer, char)) {
        import std.format : formattedWrite;

        formattedWrite(w, "%s/%s", dir, tokens);
    }
}

struct MultiplexMaster {
    import core.time : dur;
    import std.array : array, empty;
    import proc;

    MultiplexPath socket;
    SshArgs ssh;

    void connect() @safe {
        SshArgs a = ssh;
        a.cmd = ["true"];
        a.sshArgs = ["-oControlMaster=yes"] ~ a.sshArgs;
        auto p = pipeProcess(a.toArgs);
        const ec = p.wait;
        if (ec != 0) {
            logger.trace("Failed starting multiplex master. Exit code ", ec);
            logger.trace(p.drainByLineCopy);
        }
    }

    bool isAlive() @trusted {
        import std.algorithm : filter;
        import std.string : startsWith, toLower;

        SshArgs a = ssh;
        a.sshArgs = ["-O", "check"] ~ a.sshArgs;
        auto p = pipeProcess(a.toArgs).timeout(10.dur!"seconds").rcKill;

        auto lines = p.drainByLineCopy.filter!(a => !a.empty).array;
        logger.trace(lines);

        auto ec = p.wait;
        if (ec != 0 || lines.empty) {
            return false;
        }

        return lines[0].toLower.startsWith("master");
    }
}

MultiplexMaster makeMaster(Host host) {
    setupMultiplexDir;

    MultiplexMaster master;
    master.socket = MultiplexPath(multiplexDir);
    master.ssh = SshArgs("ssh", master.socket.toArgs ~ [
            "-oControlPersist=300", host
            ], null);

    return master;
}

void setupMultiplexDir() @safe nothrow {
    import std.file : mkdirRecurse, exists;

    try {
        const p = multiplexDir;
        if (!exists(p)) {
            mkdirRecurse(p);
        }
    } catch (Exception e) {
        try {
            logger.warning(e.msg);
        } catch(Exception e) {
        }
    }
}
