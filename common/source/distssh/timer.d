/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This module contain timer utilities.

*/
module distssh.timer;

import std.datetime.systime : Clock, SysTime;
import core.time : Duration;

@safe:

/** Use the interval function to *wait* the specified time.
 */
struct Interval {
    Duration interval;
    alias WaitFn = void delegate(Duration) @safe;
    WaitFn wait_fn;

    this(Duration d, WaitFn wait_fn) {
        this.interval = d;
        this.wait_fn = wait_fn;
    }

    void tick() {
        wait_fn(interval);
    }
}

struct IntervalSleep {
    Interval interval;
    alias interval this;

    this(Duration d) {
        interval = Interval(d, &this.sleep_);
    }

    void sleep_(Duration d) @trusted {
        import core.thread : Thread;

        Thread.sleep(d);
    }
}

/** A timer is constructed with an interval.
 *
 * Each interval the registered callbacks are triggered.
*/
struct Timer {
    const Duration interval;
    SysTime expire;

    alias CallbackT = void delegate() @safe;
    CallbackT[] callbacks;

@safe:

    this(Duration interval) {
        this.interval = interval;
        this.expire = Clock.currTime + interval;
    }

    void register(CallbackT c) {
        callbacks ~= c;
    }

    void tick() {
        if (Clock.currTime < expire)
            return;
        scope(exit)
            expire = Clock.currTime + interval;
        foreach (c; callbacks)
            c();
    }
}

struct TimerCollection {
    Timer[] timers;
    size_t next_timer;

    /** Tick all timers in the collection until either all have ticked or one
     * throws an exception.
     *
     * It ensures that no timer that continously throws an exception will block
     * other timers from doing there thing.
     */
    void tick() {
        if (next_timer > timers.length)
            next_timer = 0;

        for (auto i = next_timer; i < timers.length; ++i) {
            try {
                timers[i].tick;
            } catch(Exception e) {
                next_timer = i + 1;
                throw e;
            }
        }

        next_timer = 0;
    }
}
