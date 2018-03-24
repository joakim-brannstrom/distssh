module eventcore.drivers.posix.dns;
@safe:

import eventcore.driver;
import eventcore.drivers.posix.driver;
import eventcore.internal.utils : ChoppedVector, print;

import std.socket : Address, AddressFamily, InternetAddress, Internet6Address, UnknownAddress;
version (Posix) {
	import std.socket : UnixAddress;
	import core.sys.posix.netdb : AI_ADDRCONFIG, AI_V4MAPPED, addrinfo, freeaddrinfo, getaddrinfo;
	import core.sys.posix.netinet.in_;
	import core.sys.posix.netinet.tcp;
	import core.sys.posix.sys.un;
	import core.stdc.errno : errno, EAGAIN, EINPROGRESS;
	import core.sys.posix.fcntl;
}
version (Windows) {
	import core.sys.windows.windows;
	import core.sys.windows.winsock2;
	alias sockaddr_storage = SOCKADDR_STORAGE;
	alias EAGAIN = WSAEWOULDBLOCK;
}


/// getaddrinfo+thread based lookup - does not support true cancellation
version (Posix)
final class EventDriverDNS_GAI(Events : EventDriverEvents, Signals : EventDriverSignals) : EventDriverDNS {
	import std.parallelism : task, taskPool;
	import std.string : toStringz;

	private {
		static struct Lookup {
			DNSLookupCallback callback;
			addrinfo* result;
			int retcode;
			string name;
		}
		ChoppedVector!Lookup m_lookups;
		Events m_events;
		EventID m_event = EventID.invalid;
		size_t m_maxHandle;
	}

	this(Events events, Signals signals)
	{
		m_events = events;
		setupEvent();
	}

	void dispose()
	{
		if (m_event != EventID.invalid) {
			m_events.cancelWait(m_event, &onDNSSignal);
			m_events.releaseRef(m_event);
			m_event = EventID.invalid;
		}
	}

	override DNSLookupID lookupHost(string name, DNSLookupCallback on_lookup_finished)
	{
		debug (EventCoreLogDNS) print("lookup %s", name);
		auto handle = getFreeHandle();
		if (handle > m_maxHandle) m_maxHandle = handle;

		setupEvent();

		assert(!m_lookups[handle].result);
		Lookup* l = () @trusted { return &m_lookups[handle]; } ();
		l.name = name;
		l.callback = on_lookup_finished;
		auto events = () @trusted { return cast(shared)m_events; } ();
		auto t = task!taskFun(l, AddressFamily.UNSPEC, events, m_event);
		try t.executeInNewThread();//taskPool.put(t);
		catch (Exception e) return DNSLookupID.invalid;
		debug (EventCoreLogDNS) print("lookup handle: %s", handle);
		m_events.loop.m_waiterCount++;
		return handle;
	}

	/// public
	static void taskFun(Lookup* lookup, int af, shared(Events) events, EventID event)
	{
		debug (EventCoreLogDNS) print("lookup %s start", lookup.name);
		addrinfo hints;
		hints.ai_flags = AI_ADDRCONFIG;
		version (linx) hints.ai_flags |= AI_V4MAPPED;
		hints.ai_family = af;
		() @trusted { lookup.retcode = getaddrinfo(lookup.name.toStringz(), null, af == AddressFamily.UNSPEC ? null : &hints, &lookup.result); } ();
		events.trigger(event, true);
		debug (EventCoreLogDNS) print("lookup %s finished", lookup.name);
	}

	override void cancelLookup(DNSLookupID handle)
	{
		m_lookups[handle].callback = null;
		m_events.loop.m_waiterCount--;
	}

	private void onDNSSignal(EventID event)
		@trusted nothrow
	{
		debug (EventCoreLogDNS) print("DNS event triggered");
		m_events.wait(m_event, &onDNSSignal);
		size_t lastmax;
		foreach (i, ref l; m_lookups) {
			if (i > m_maxHandle) break;
			if (l.callback) {
				if (l.result || l.retcode) {
					debug (EventCoreLogDNS) print("found finished lookup %s for %s", i, l.name);
					auto cb = l.callback;
					auto ai = l.result;
					DNSStatus status;
					switch (l.retcode) {
						default: status = DNSStatus.error; break;
						case 0: status = DNSStatus.ok; break;
					}
					l.callback = null;
					l.result = null;
					l.retcode = 0;
					if (i == m_maxHandle) m_maxHandle = lastmax;
					m_events.loop.m_waiterCount--;
					passToDNSCallback(cast(DNSLookupID)cast(int)i, cb, status, ai);
				} else lastmax = i;
			}
		}
		debug (EventCoreLogDNS) print("Max active DNS handle: %s", m_maxHandle);
	}

	private DNSLookupID getFreeHandle()
	@safe nothrow {
		assert(m_lookups.length <= int.max);
		foreach (i, ref l; m_lookups)
			if (!l.callback)
				return cast(DNSLookupID)cast(int)i;
		return cast(DNSLookupID)cast(int)m_lookups.length;
	}

	private void setupEvent()
	{
		if (m_event == EventID.invalid) {
			m_event = m_events.createInternal();
			m_events.wait(m_event, &onDNSSignal);
		}
	}
}


/// getaddrinfo_a based asynchronous lookups
final class EventDriverDNS_GAIA(Events : EventDriverEvents, Signals : EventDriverSignals) : EventDriverDNS {
	import core.sys.posix.signal : SIGEV_SIGNAL, SIGRTMIN, sigevent;

	private {
		static struct Lookup {
			gaicb ctx;
			DNSLookupCallback callback;
		}
		ChoppedVector!Lookup m_lookups;
		Signals m_signals;
		int m_dnsSignal;
		SignalListenID m_sighandle;
	}

	@safe nothrow:

	this(Events events, Signals signals)
	{
		m_signals = signals;
		m_dnsSignal = () @trusted { return SIGRTMIN; } ();
		m_sighandle = signals.listenInternal(m_dnsSignal, &onDNSSignal);
	}

	void dispose()
	{
		m_signals.releaseRef(m_sighandle);
	}

	override DNSLookupID lookupHost(string name, DNSLookupCallback on_lookup_finished)
	{
		import std.string : toStringz;

		auto handle = getFreeHandle();

		sigevent evt;
		evt.sigev_notify = SIGEV_SIGNAL;
		evt.sigev_signo = m_dnsSignal;
		gaicb* res = &m_lookups[handle].ctx;
		res.ar_name = name.toStringz();
		auto ret = () @trusted { return getaddrinfo_a(GAI_NOWAIT, &res, 1, &evt); } ();

		if (ret != 0)
			return DNSLookupID.invalid;

		m_lookups[handle].callback = on_lookup_finished;
		m_events.loop.m_waiterCount++;

		return handle;
	}

	override void cancelLookup(DNSLookupID handle)
	{
		gai_cancel(&m_lookups[handle].ctx);
		m_lookups[handle].callback = null;
		m_events.loop.m_waiterCount--;
	}

	private void onDNSSignal(SignalListenID, SignalStatus status, int signal)
		@safe nothrow
	{
		assert(status == SignalStatus.ok);
		foreach (i, ref l; m_lookups) {
			if (!l.callback) continue;
			auto err = gai_error(&l.ctx);
			if (err == EAI_INPROGRESS) continue;
			DNSStatus status;
			switch (err) {
				default: status = DNSStatus.error; break;
				case 0: status = DNSStatus.ok; break;
			}
			auto cb = l.callback;
			auto ai = l.ctx.ar_result;
			l.callback = null;
			l.ctx.ar_result = null;
			m_events.loop.m_waiterCount--;
			passToDNSCallback(cast(DNSLookupID)cast(int)i, cb, status, ai);
		}
	}

	private DNSLookupID getFreeHandle()
	{
		foreach (i, ref l; m_lookups)
			if (!l.callback)
				return cast(DNSLookupID)cast(int)i;
		return cast(DNSLookupID)cast(int)m_lookups.length;
	}
}

version (linux) extern(C) {
	import core.sys.posix.signal : sigevent;

	struct gaicb {
		const(char)* ar_name;
		const(char)* ar_service;
		const(addrinfo)* ar_request;
		addrinfo* ar_result;
	}

	enum GAI_NOWAIT = 1;

	enum EAI_INPROGRESS = -100;

	int getaddrinfo_a(int mode, gaicb** list, int nitems, sigevent *sevp);
	int gai_error(gaicb *req);
	int gai_cancel(gaicb *req);
}


/// ghbn based lookup - does not support cancellation and blocks the thread!
final class EventDriverDNS_GHBN(Events : EventDriverEvents, Signals : EventDriverSignals) : EventDriverDNS {
	import std.parallelism : task, taskPool;
	import std.string : toStringz;

	private {
		static struct Lookup {
			DNSLookupCallback callback;
			bool success;
			int retcode;
			string name;
		}
		size_t m_maxHandle;
	}

	this(Events events, Signals signals)
	{
	}

	void dispose()
	{
	}

	override DNSLookupID lookupHost(string name, DNSLookupCallback on_lookup_finished)
	{
		import std.string : toStringz;

		auto handle = DNSLookupID(m_maxHandle++);

		auto he = () @trusted { return gethostbyname(name.toStringz); } ();
		if (he is null) {
			on_lookup_finished(handle, DNSStatus.error, null);
			return handle;
		}
		switch (he.h_addrtype) {
			default: assert(false, "Invalid address family returned from host lookup.");
			case AF_INET: {
				sockaddr_in sa;
				sa.sin_family = AF_INET;
				sa.sin_addr = () @trusted { return *cast(in_addr*)he.h_addr_list[0]; } ();
				scope addr = new RefAddress(() @trusted { return cast(sockaddr*)&sa; } (), sa.sizeof);
				RefAddress[1] aa;
				aa[0] = addr;
				on_lookup_finished(handle, DNSStatus.ok, aa);
			} break;
			case AF_INET6: {
				sockaddr_in6 sa;
				sa.sin6_family = AF_INET6;
				sa.sin6_addr = () @trusted { return *cast(in6_addr*)he.h_addr_list[0]; } ();
				scope addr = new RefAddress(() @trusted { return cast(sockaddr*)&sa; } (), sa.sizeof);
				RefAddress[1] aa;
				aa[0] = addr;
				on_lookup_finished(handle, DNSStatus.ok, aa);
			} break;
		}

		return handle;
	}

	override void cancelLookup(DNSLookupID) {}
}

package struct DNSSlot {
	alias Handle = DNSLookupID;
	DNSLookupCallback callback;
}

private void passToDNSCallback()(DNSLookupID id, scope DNSLookupCallback cb, DNSStatus status, addrinfo* ai_orig)
	@trusted nothrow
{
	import std.typecons : scoped;

	try {
		typeof(scoped!RefAddress())[16] addrs_prealloc = [
			scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(),
			scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(),
			scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(),
			scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress()
		];
		//Address[16] addrs;
		RefAddress[16] addrs;
		auto ai = ai_orig;
		size_t addr_count = 0;
		while (ai !is null && addr_count < addrs.length) {
			RefAddress ua = addrs_prealloc[addr_count]; // FIXME: avoid heap allocation
			ua.set(ai.ai_addr, ai.ai_addrlen);
			addrs[addr_count] = ua;
			addr_count++;
			ai = ai.ai_next;
		}
		cb(id, status, addrs[0 .. addr_count]);
		freeaddrinfo(ai_orig);
	} catch (Exception e) assert(false, e.msg);
}


