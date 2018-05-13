/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Executing a program via a pty to simulate a console
*/
module distssh.process.pty;

import std.string : fromStringz, toStringz;
import logger = std.experimental.logger;

import distssh.process.type;
import distssh.libc;

/** Spawns a process in a pty session.
 *
 * By convention the first arg in args should be == program
 */
Pty spawnProcessInPty(const string[] cmd, string[string] env, string workdir) {
    import core.sys.posix.unistd : execl;
    import core.sys.posix.stdlib : putenv;
    import std.string : join;
    import std.file : chdir;

    Pty master;
    auto pid = forkpty(&(master).fd, null, null, null).Pid;

    if (pid == 0) { //child
        foreach (kv; env.byKeyValue) {
            const value = (kv.key ~ "=" ~ kv.value).toStringz;
            putenv(cast(char*) value);
        }
        chdir(workdir);

        auto args = cmd.length > 0 ? cmd.join(" ").toStringz : null;
        execl(cmd[0].toStringz, args, null);
    } else if (pid > 0) { // master
        master.pid = pid;
        setNonBlocking(master);
        return master;
    }

    return Pty(-1, Pid(-1));
}

/**
* A data structure to hold information on a Pty session
* Holds its fd and a utility property to get its name
*/
struct Pty {
    import std.typecons : Tuple;

    int fd;
    Pid pid;

    string name() {
        return ttyname(fd).fromStringz.idup;
    };

    alias Wait = Tuple!(bool, "terminated", int, "status");

    auto tryWait() {
        import core.sys.posix.unistd;
        import core.sys.posix.sys.wait;
        import core.stdc.errno : errno, ECHILD;

        int exitCode;

        while (true) {
            int status;
            auto check = waitpid(pid, &status, WNOHANG);
            if (check == -1) {
                if (errno == ECHILD) {
                    // process does not exist
                    return Wait(true, 0);
                } else {
                    // interrupted by a signal
                    continue;
                }
            }

            if (check == 0) {
                return Wait(false, 0);
            }

            if (WIFEXITED(status)) {
                exitCode = WEXITSTATUS(status);
                break;
            } else if (WIFSIGNALED(status)) {
                exitCode = -WTERMSIG(status);
                break;
            }

            break;
        }

        return Wait(true, exitCode);
    }

    ubyte[] read(ubyte[] buf) @nogc nothrow {
        static import core.sys.posix.unistd;

        immutable long len = core.sys.posix.unistd.read(fd, buf.ptr, buf.length);
        if (len >= 0) {
            return buf[0 .. len];
        }
        return null;
    }
}

private:

/// Sets the Pty session to non-blocking mode.
void setNonBlocking(Pty pty) nothrow {
    import core.sys.posix.unistd;
    import core.sys.posix.fcntl;

    int currFlags = fcntl(pty.fd, F_GETFL, 0) | O_NONBLOCK;
    fcntl(pty.fd, F_SETFL, currFlags);
}
