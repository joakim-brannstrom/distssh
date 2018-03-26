module eventcore.drivers.winapi.events;

version (Windows)  : import eventcore.driver;
import eventcore.drivers.winapi.core;
import eventcore.internal.win32;
import eventcore.internal.consumablequeue;
import eventcore.internal.utils : nogc_assert;

final class WinAPIEventDriverEvents : EventDriverEvents {
@safe: /*@nogc:*/ nothrow:
    private {
        static struct Trigger {
            EventID id;
            bool notifyAll;
        }

        static struct EventSlot {
            uint refCount;
            ConsumableQueue!EventCallback waiters;
        }

        WinAPIEventDriverCore m_core;
        HANDLE m_event;
        EventSlot[EventID] m_events;
        CRITICAL_SECTION m_mutex;
        ConsumableQueue!Trigger m_pending;
        uint m_idCounter;
    }

    this(WinAPIEventDriverCore core) {
        m_core = core;
        m_event = () @trusted{ return CreateEvent(null, false, false, null); }();
        m_pending = new ConsumableQueue!Trigger; // FIXME: avoid GC allocation
        InitializeCriticalSection(&m_mutex);
        m_core.registerEvent(m_event, &triggerPending);
    }

    void dispose() @trusted {
        scope (failure)
            assert(false);
        destroy(m_pending);
    }

    override EventID create() {
        auto id = EventID(m_idCounter++);
        if (id == EventID.invalid)
            id = EventID(m_idCounter++);
        m_events[id] = EventSlot(1, new ConsumableQueue!EventCallback); // FIXME: avoid GC allocation
        return id;
    }

    override void trigger(EventID event, bool notify_all = true) {
        auto pe = event in m_events;
        assert(pe !is null, "Invalid event ID passed to triggerEvent.");
        if (notify_all) {
            foreach (w; pe.waiters.consume) {
                m_core.removeWaiter();
                w(event);
            }
        } else {
            if (!pe.waiters.empty) {
                m_core.removeWaiter();
                pe.waiters.consumeOne()(event);
            }
        }
    }

    override void trigger(EventID event, bool notify_all = true) shared {
        import core.atomic : atomicStore;

        auto pe = event in m_events;
        assert(pe !is null, "Invalid event ID passed to shared triggerEvent.");

        () @trusted{
            auto thisus = cast(WinAPIEventDriverEvents) this;
            EnterCriticalSection(&thisus.m_mutex);
            thisus.m_pending.put(Trigger(event, notify_all));
            LeaveCriticalSection(&thisus.m_mutex);
            SetEvent(thisus.m_event);
        }();
    }

    override void wait(EventID event, EventCallback on_event) {
        m_core.addWaiter();
        return m_events[event].waiters.put(on_event);
    }

    override void cancelWait(EventID event, EventCallback on_event) {
        import std.algorithm.searching : countUntil;
        import std.algorithm.mutation : remove;

        m_events[event].waiters.removePending(on_event);
        m_core.removeWaiter();
    }

    override void addRef(EventID descriptor) {
        assert(m_events[descriptor].refCount > 0);
        m_events[descriptor].refCount++;
    }

    override bool releaseRef(EventID descriptor) {
        auto pe = descriptor in m_events;
        nogc_assert(pe.refCount > 0, "Releasing unreference event.");
        if (--pe.refCount == 0) {
            // make sure to not leak any waiter references for pending waits
            foreach (i; 0 .. pe.waiters.length)
                m_core.removeWaiter();

            () @trusted nothrow{
                scope (failure)
                    assert(false);
                destroy(pe.waiters);
                CloseHandle(idToHandle(descriptor));
            }();
            m_events.remove(descriptor);
            return false;
        }
        return true;
    }

    protected override void* rawUserData(EventID descriptor, size_t size,
            DataInitializer initialize, DataInitializer destroy) @system {
        return m_core.rawUserDataImpl(idToHandle(descriptor), size, initialize, destroy);
    }

    private void triggerPending() {
        while (true) {
            Trigger t;
            {
                () @trusted{ EnterCriticalSection(&m_mutex); }();
                scope (exit)
                    () @trusted{ LeaveCriticalSection(&m_mutex); }();
                if (m_pending.empty)
                    break;
                t = m_pending.consumeOne;
            }

            trigger(t.id, t.notifyAll);
        }
    }

    private static HANDLE idToHandle(EventID event) @trusted {
        return cast(HANDLE) cast(size_t) event;
    }
}
