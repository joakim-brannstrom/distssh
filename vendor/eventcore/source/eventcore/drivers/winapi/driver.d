/**
	WinAPI based event driver implementation.

	This driver uses overlapped I/O to model asynchronous I/O operations
	efficiently. The driver's event loop processes UI messages, so that
	it integrates with GUI applications transparently.
*/
module eventcore.drivers.winapi.driver;

version (Windows)  : import eventcore.driver;
import eventcore.drivers.timer;
import eventcore.drivers.winapi.core;
import eventcore.drivers.winapi.dns;
import eventcore.drivers.winapi.events;
import eventcore.drivers.winapi.files;
import eventcore.drivers.winapi.signals;
import eventcore.drivers.winapi.sockets;
import eventcore.drivers.winapi.watchers;
import core.sys.windows.windows;

static assert(HANDLE.sizeof <= FD.BaseType.sizeof);
static assert(FD(cast(size_t) INVALID_HANDLE_VALUE) == FD.init);

final class WinAPIEventDriver : EventDriver {
    private {
        WinAPIEventDriverCore m_core;
        WinAPIEventDriverFiles m_files;
        WinAPIEventDriverSockets m_sockets;
        WinAPIEventDriverDNS m_dns;
        LoopTimeoutTimerDriver m_timers;
        WinAPIEventDriverEvents m_events;
        WinAPIEventDriverSignals m_signals;
        WinAPIEventDriverWatchers m_watchers;
    }

    static WinAPIEventDriver threadInstance;

    this() @safe {
        assert(threadInstance is null);
        threadInstance = this;

        import std.exception : enforce;

        WSADATA wd;
        enforce(() @trusted{ return WSAStartup(0x0202, &wd); }() == 0,
                "Failed to initialize WinSock");

        m_signals = new WinAPIEventDriverSignals();
        m_timers = new LoopTimeoutTimerDriver();
        m_core = new WinAPIEventDriverCore(m_timers);
        m_events = new WinAPIEventDriverEvents(m_core);
        m_files = new WinAPIEventDriverFiles(m_core);
        m_sockets = new WinAPIEventDriverSockets(m_core);
        m_dns = new WinAPIEventDriverDNS();
        m_watchers = new WinAPIEventDriverWatchers(m_core);
    }

@safe: /*@nogc:*/ nothrow:

    override @property inout(WinAPIEventDriverCore) core() inout {
        return m_core;
    }

    override @property shared(inout(WinAPIEventDriverCore)) core() inout shared {
        return m_core;
    }

    override @property inout(WinAPIEventDriverFiles) files() inout {
        return m_files;
    }

    override @property inout(WinAPIEventDriverSockets) sockets() inout {
        return m_sockets;
    }

    override @property inout(WinAPIEventDriverDNS) dns() inout {
        return m_dns;
    }

    override @property inout(LoopTimeoutTimerDriver) timers() inout {
        return m_timers;
    }

    override @property inout(WinAPIEventDriverEvents) events() inout {
        return m_events;
    }

    override @property shared(inout(WinAPIEventDriverEvents)) events() inout shared {
        return m_events;
    }

    override @property inout(WinAPIEventDriverSignals) signals() inout {
        return m_signals;
    }

    override @property inout(WinAPIEventDriverWatchers) watchers() inout {
        return m_watchers;
    }

    override void dispose() {
        if (!m_events)
            return;
        m_events.dispose();
        m_events = null;
        assert(threadInstance !is null);
        threadInstance = null;
    }
}
