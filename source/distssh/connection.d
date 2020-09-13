/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

ssh connection for both normal and multiplex.
*/
module distssh.connection;

import std.file : thisExePath;
import std.process : escapeShellFileName;

import my.path;

import distssh.types;

// arguments to ssh that turn off warning that a host key is new or requies a
// password to login
immutable sshNoLoginArgs = [
    "-oStrictHostKeyChecking=no", "-oPasswordAuthentication=no"
];

SshArgs sshArgs(Host host, string[] ssh, string[] cmd) {
    return SshArgs("ssh", ssh ~ sshNoLoginArgs ~ [
            host, thisExePath.escapeShellFileName
            ], cmd);
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
