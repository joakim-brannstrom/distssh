/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This module contain timer utilities.
*/
module distssh.timer;

import logger = std.experimental.logger;
import core.time : Duration, dur;
import std.datetime : SysTime, Clock;
import std.container.rbtree;
import std.typecons : Nullable;

@safe:

/// A collection of timers.
struct Timers {
    private {
        RedBlackTree!Timer timers;
        Nullable!Timer front_;
    }

    void put(Timer.Action action, Duration d) {
        timers.stableInsert(Timer(Clock.currTime + d, action));
    }

    void put(Timer.Action action, SysTime t) {
        timers.stableInsert(Timer(t, action));
    }

    /// Get how long until the next timer expire. The minimum is minSleep.
    Duration expireAt(Duration minSleep) nothrow {
        import std.algorithm : max;

        if (empty) {
            return minSleep;
        }
        return max(minSleep, timers.front.expire - Clock.currTime);
    }

    /// Sleep until the next action triggers.
    void sleep(Duration minSleep) @trusted {
        import core.thread : Thread;

        Thread.sleep(expireAt(minSleep));
    }

    /// Sleep until the next action triggers and execute it, if there are any.
    void tick(Duration minSleep) {
        sleep(minSleep);
        if (!empty) {
            front.action(this);
            popFront;
        }
    }

    Timer front() pure nothrow {
        assert(!empty, "Can't get front of an empty range");
        if (front_.isNull && !timers.empty)
            front_ = timers.front;
        return front_.get;
    }

    void popFront() {
        assert(!empty, "Can't pop front of an empty range");
        if (!front_.isNull) {
            timers.removeKey(front_.get);
            front_.nullify;
        } else {
            timers.removeFront;
        }
    }

    bool empty() pure nothrow @nogc {
        return timers.empty && front_.isNull;
    }
}

auto makeTimers() {
    return Timers(new RedBlackTree!Timer);
}

/// An individual timer.
struct Timer {
    private {
        alias Action = void delegate(ref Timers);
        SysTime expire;
        size_t id;
    }

    Action action;

    this(SysTime expire, Action action) {
        this.expire = expire;
        this.action = action;
        this.id = () @trusted { return cast(size_t)&action; }();
    }

    bool opEquals()(auto ref const typeof(this) s) const {
        return expire == s.expire && id == s.id;
    }

    int opCmp(ref const typeof(this) rhs) const {
        // return -1 if "this" is less than rhs, 1 if bigger and zero equal
        if (expire < rhs.expire)
            return -1;
        if (expire > rhs.expire)
            return 1;
        if (id < rhs.id)
            return -1;
        if (id > rhs.id)
            return 1;
        return 0;
    }
}

@("shall pop the first timer;")
unittest {
    int timerPopped;
    auto timers = makeTimers;

    timers.put((ref Timers) { timerPopped = 42; }, 1000.dur!"msecs");
    timers.put((ref Timers) { timerPopped = 2; }, 2.dur!"msecs");

    timers.sleep(1.dur!"msecs");
    timers.front.action(timers);
    assert(timerPopped == 2);
}

alias IntervalAction = bool delegate();

/// Timers that fire each interval as long as the action return true.
auto makeInterval(ref Timers ts, IntervalAction action, Duration interval) {
    void repeatFn(ref Timers ts) @safe {
        const res = action();
        if (res) {
            ts.put(&repeatFn, interval);
        }
    }

    ts.put(&repeatFn, interval);
}

@("shall remove the interval timer when it return false")
unittest {
    int ticks;
    auto timers = makeTimers;

    makeInterval(timers, () { ticks++; return ticks < 3; }, 2.dur!"msecs");
    while (!timers.empty) {
        timers.tick(Duration.zero);
    }

    assert(ticks == 3);
}
