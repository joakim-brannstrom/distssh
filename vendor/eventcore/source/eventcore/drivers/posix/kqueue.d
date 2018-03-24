/**
	BSD kqueue based event driver implementation.

	Kqueue is an efficient API for asynchronous I/O on BSD flavors, including
	OS X/macOS, suitable for large numbers of concurrently open sockets.
*/
module eventcore.drivers.posix.kqueue;
@safe: /*@nogc:*/ nothrow:

version (FreeBSD) enum have_kqueue = true;
else version (DragonFlyBSD) enum have_kqueue = true;
else version (OSX) enum have_kqueue = true;
else enum have_kqueue = false;

static if (have_kqueue):

public import eventcore.drivers.posix.driver;
import eventcore.internal.utils;

import core.time : Duration;
import core.sys.posix.sys.time : timespec, time_t;

version (OSX) import core.sys.darwin.sys.event;
else version (FreeBSD) import core.sys.freebsd.sys.event;
else version (DragonFlyBSD) import core.sys.dragonflybsd.sys.event;
else static assert(false, "Kqueue not supported on this OS.");


import core.sys.linux.epoll;


alias KqueueEventDriver = PosixEventDriver!KqueueEventLoop;

final class KqueueEventLoop : PosixEventLoop {
	private {
		int m_queue;
		kevent_t[] m_changes;
		kevent_t[] m_events;
	}

	this()
	@safe nothrow {
		m_queue = () @trusted { return kqueue(); } ();
		m_events.length = 100;
		assert(m_queue >= 0, "Failed to create kqueue.");
	}

	override bool doProcessEvents(Duration timeout)
	@trusted {
		import std.algorithm : min;
		//assert(Fiber.getThis() is null, "processEvents may not be called from within a fiber!");

		//print("wait %s", m_events.length);
		timespec ts;
		long secs, hnsecs;
		timeout.split!("seconds", "hnsecs")(secs, hnsecs);
		ts.tv_sec = cast(time_t)secs;
		ts.tv_nsec = cast(uint)hnsecs * 100;

		auto ret = kevent(m_queue, m_changes.ptr, cast(int)m_changes.length, m_events.ptr, cast(int)m_events.length, timeout == Duration.max ? null : &ts);
		m_changes.length = 0;
		m_changes.assumeSafeAppend();

		//print("kevent returned %s", ret);

		if (ret > 0) {
			foreach (ref evt; m_events[0 .. ret]) {
				//print("event %s %s", evt.ident, evt.filter, evt.flags);
				assert(evt.ident <= uint.max);
				auto fd = cast(FD)cast(int)evt.ident;
				if (evt.flags & (EV_EOF|EV_ERROR))
					notify!(EventType.status)(fd);
				switch (evt.filter) {
					default: break;
					case EVFILT_READ: notify!(EventType.read)(fd); break;
					case EVFILT_WRITE: notify!(EventType.write)(fd); break;
				}
				// EV_SIGNAL, EV_TIMEOUT
			}
			return true;
		} else return false;
	}

	override void dispose()
	{

		import core.sys.posix.unistd : close;
		close(m_queue);
	}

	override void registerFD(FD fd, EventMask mask, bool edge_triggered = true)
	{
		//print("register %s %s", fd, mask);
		kevent_t ev;
		ev.ident = fd;
		ev.flags = EV_ADD|EV_ENABLE;
		if (edge_triggered) ev.flags |= EV_CLEAR;
		if (mask & EventMask.read) {
			ev.filter = EVFILT_READ;
			m_changes ~= ev;
		}
		if (mask & EventMask.write) {
			ev.filter = EVFILT_WRITE;
			m_changes ~= ev;
		}
		//if (mask & EventMask.status) ev.events |= EPOLLERR|EPOLLRDHUP;
	}

	override void unregisterFD(FD fd, EventMask mask)
	{
		kevent_t ev;
		ev.ident = fd;
		ev.flags = EV_DELETE;
		m_changes ~= ev;
	}

	override void updateFD(FD fd, EventMask old_mask, EventMask new_mask, bool edge_triggered = true)
	{
		//print("update %s %s", fd, mask);
		kevent_t ev;
		auto changes = old_mask ^ new_mask;

		if (changes & EventMask.read) {
			ev.filter = EVFILT_READ;
			ev.flags = new_mask & EventMask.read ? EV_ADD : EV_DELETE;
			if (edge_triggered) ev.flags |= EV_CLEAR;
			m_changes ~= ev;
		}

		if (changes & EventMask.write) {
			ev.filter = EVFILT_WRITE;
			ev.flags = new_mask & EventMask.write ? EV_ADD : EV_DELETE;
			if (edge_triggered) ev.flags |= EV_CLEAR;
			m_changes ~= ev;
		}

		//if (mask & EventMask.status) ev.events |= EPOLLERR|EPOLLRDHUP;
	}
}
