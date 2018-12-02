/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.process;

import std.algorithm : filter, splitter, map;
import std.exception : collectException;
import std.stdio : File;
import std.string : fromStringz;
import logger = std.experimental.logger;

public import distssh.process.type;

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
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
        }
    }

    return children.data;
}

@("shall return the immediate children of the init process")
unittest {
    auto res = getShallowChildren(1);
    //logger.trace(res);
    assert(res.length > 0);
}

/** Returns: a list of all processes with the leafs being at the back
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
    auto direct = getShallowChildren(1);
    auto deep = getDeepChildren(1);

    //logger.trace(direct);
    //logger.trace(deep);

    assert(deep.length > direct.length);
}

/** Returns: a list of the process groups in the same order as the input.
 */
PidGroup[] getPidGroups(const Pid[] pids) {
    import core.sys.posix.unistd : getpgid;
    import std.array : array, appender;

    auto res = appender!(PidGroup[])();
    bool[pid_t] pgroups;

    foreach (const p; pids.map!(a => getpgid(a))
            .filter!(a => a != -1)) {
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
    } catch (Exception e) {
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
