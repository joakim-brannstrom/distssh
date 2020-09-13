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

string[] sshArgs(Host host, string[] ssh, string[] cmd) {
    return ["ssh"] ~ ssh ~ sshNoLoginArgs ~ [
        host, thisExePath.escapeShellFileName
    ] ~ cmd;
}

string[] sshShellArgs(Host host, Path workDir) {
    // two -t forces a tty to be created and used which mean that the remote
    // shell will *think* it is an interactive shell
    return sshArgs(host, ["-q", "-t", "-t"], [
            "localshell", "--workdir", workDir.toString.escapeShellFileName
            ]);
}

string[] sshLoadArgs(Host host) {
    return sshArgs(host, ["-q"], ["localload"]);
}
