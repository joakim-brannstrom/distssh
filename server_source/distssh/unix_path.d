/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.unix_path;

import std.typecons : Nullable;
import std.exception : collectException;
import logger = std.experimental.logger;

struct UnixSocketPath {
@safe:
    import std.typecons : Nullable;

    Nullable!string value;
    alias value this;

    static auto make(const string s) {
        import std.conv : to;

        auto res = unixDomainSocketSafetyCheck(s);
        if (res == Reason.ok)
            return UnixSocketPath(s);
        else
            throw new Exception(
                    "Safety check of the unix domain socket failed " ~ s
                    ~ " reason " ~ res.to!string);
    }

nothrow:

    private this(string s) {
        this.value = s;
    }
}

/** Returns: a full path that can be used to create a unix domain socket.

  Using an own variant of mkdir so the numbers are in sequential order.
  */
Nullable!UnixSocketPath createUnixDomainSocketPath(string dir) @safe nothrow {
    import core.sys.posix.sys.stat : S_IRWXU, mkdir;
    import std.conv : to;
    import std.file : tempDir;
    import std.string : toStringz;
    import std.path : dirName;

    import core.sys.posix.stdio : perror;

    typeof(return) rval;

    for (int i = 0; i != int.max && rval.isNull; ++i) {
        try {
            auto possible_path = makeUnixDomainSocketPath(dir, i.to!string);
            auto c_path = possible_path.dirName.toStringz;

            auto res = () @trusted{ return mkdir(c_path, S_IRWXU); }();

            if (res == 0) {
                rval = UnixSocketPath.make(possible_path);
            } else {
                () @trusted{ debug perror(null); }();
            }
        }
        catch (Exception e) {
            debug logger.trace(e.msg).collectException;
        }
    }

    return rval;
}

bool isUserUnixDomainSocket(string p) @safe {
    import core.sys.posix.unistd : geteuid;
    import std.format : format;
    import std.path : baseName;
    import std.string : startsWith;

    immutable prefix = format("distssh-server-%s-", geteuid);

    return baseName(p).startsWith(prefix);
}

private:

enum Reason {
    ok,
    directoryDoNotExist,
    directoryIsSymlink,
    directoryAccessableByOthers,
    directoryInaccessableToUser,
    fileIsSymlink,
    fileAccessibleByOthers,
    fileInaccessableToUser,
}

/** Check that the path is safe to use.

  This function is **extremly** important that it is correct.
  Otherwise there may be a security issue.

  Ensure the directory is **secure** to use.
  1. Check the directory exists.
  2. Check that the directory is not a symlink.
  3. Check that the directory is only read/writeable by the user.
  5. If the directory contains the socket file then check that:
  6. file is not a symlink
  7. file is read/write by the user (ignoring if others can because the directory protects).
  */
Reason unixDomainSocketSafetyCheck(const string s) @safe {
    import core.sys.posix.sys.stat;
    import std.file : getAttributes, exists, isSymlink;
    import std.path : dirName;

    static bool onlyUserHasAccess(uint attr) {
        return (attr & (S_IRWXG | S_IRWXO)) == 0;
    }

    static bool userHasAccess(uint attr, uint check_attr) {
        return (attr & check_attr) == check_attr;
    }

    const dir_name = s.dirName;

    if (!exists(dir_name))
        return Reason.directoryDoNotExist;
    if (isSymlink(dir_name))
        return Reason.directoryIsSymlink;
    else {
        const dir_attr = getAttributes(dir_name);
        if (!onlyUserHasAccess(dir_attr))
            return Reason.directoryAccessableByOthers;
        if (!userHasAccess(dir_attr, S_IRWXU))
            return Reason.directoryInaccessableToUser;
    }

    if (exists(s)) {
        if (isSymlink(s))
            return Reason.fileIsSymlink;

        const attr = getAttributes(s);
        if (!userHasAccess(attr, S_IRUSR | S_IWUSR))
            return Reason.fileInaccessableToUser;
    }

    return Reason.ok;
}

string makeUnixDomainSocketPath(string dir, string idx) @safe {
    import core.sys.posix.unistd : geteuid;
    import std.format : format;
    import std.path : buildPath;

    return buildPath(dir, format("distssh-server-%s-%s", geteuid, idx), "socket.uds");
}

/** Find a unix domain socket in `dir`.
  */
//Nullable!UnixSocketPath findDistsshUnixDomainSocket(string dir) @safe nothrow {
//    typeof(return) rval;
//
//    for (int i = 0; i != int.max; ++i) {
//        string test_path;
//        try {
//            test_path = makeUnixDomainSocketPath(dir, i);
//        }
//        catch(Exception e) {
//            logger.error("Unable to create a unix domain socket path").collectException;
//            logger.error(e.msg).collectException;
//            break;
//        }
//
//        try {
//            if (unixDomainSocketSafetyCheck(test_path)) {
//                rval = UnixSocketPath(test_path);
//                break;
//            }
//        }
//        catch(Exception e) {
//        }
//    }
//
//    return rval;
//}
