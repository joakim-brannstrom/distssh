module eventcore.drivers.libasync;

version (Have_libasync):

import eventcore.driver;
import std.socket : Address;
import core.time : Duration;


final class LibasyncEventDriver : EventDriver {
@safe: /*@nogc:*/ nothrow:

	private {
		LibasyncEventDriverCore m_core;
		LibasyncEventDriverFiles m_files;
		LibasyncEventDriverSockets m_sockets;
		LibasyncEventDriverDNS m_dns;
		LibasyncEventDriverTimers m_timers;
		LibasyncEventDriverEvents m_events;
		LibasyncEventDriverSignals m_signals;
		LibasyncEventDriverWatchers m_watchers;
	}

	this()
	{
		m_core = new LibasyncEventDriverCore();
		m_files = new LibasyncEventDriverFiles();
		m_sockets = new LibasyncEventDriverSockets();
		m_dns = new LibasyncEventDriverDNS();
		m_timers = new LibasyncEventDriverTimers();
		m_events = new LibasyncEventDriverEvents();
		m_signals = new LibasyncEventDriverSignals();
		m_watchers = new LibasyncEventDriverWatchers();
	}

	override @property LibasyncEventDriverCore core() { return m_core; }
	override @property LibasyncEventDriverFiles files() { return m_files; }
	override @property LibasyncEventDriverSockets sockets() { return m_sockets; }
	override @property LibasyncEventDriverDNS dns() { return m_dns; }
	override @property LibasyncEventDriverTimers timers() { return m_timers; }
	override @property LibasyncEventDriverEvents events() { return m_events; }
	override @property shared(LibasyncEventDriverEvents) events() shared { return m_events; }
	override @property LibasyncEventDriverSignals signals() { return m_signals; }
	override @property LibasyncEventDriverWatchers watchers() { return m_watchers; }

	override void dispose()
	{
		assert(false, "TODO!");
	}
}

final class LibasyncEventDriverCore : EventDriverCore {
@safe: /*@nogc:*/ nothrow:
	override size_t waiterCount()
	{
		assert(false, "TODO!");
	}

	override ExitReason processEvents(Duration timeout = Duration.max)
	{
		assert(false, "TODO!");
	}

	override void exit()
	{
		assert(false, "TODO!");
	}

	override void clearExitFlag()
	{
		assert(false, "TODO!");
	}

	protected override void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system
	{
		assert(false, "TODO!");
	}

	protected override void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system
	{
		assert(false, "TODO!");
	}
}

final class LibasyncEventDriverSockets : EventDriverSockets {
@safe: /*@nogc:*/ nothrow:
	override StreamSocketFD connectStream(scope Address peer_address, scope Address bind_address, ConnectCallback on_connect)
	{
		assert(false, "TODO!");
	}

	override void cancelConnectStream(StreamSocketFD sock)
	{
		assert(false, "TODO!");
	}

	override StreamSocketFD adoptStream(int socket)
	{
		assert(false, "TODO!");
	}

	alias listenStream = EventDriverSockets.listenStream;
	override StreamListenSocketFD listenStream(scope Address bind_address, StreamListenOptions options, AcceptCallback on_accept)
	{
		assert(false, "TODO!");
	}

	override void waitForConnections(StreamListenSocketFD sock, AcceptCallback on_accept)
	{
		assert(false, "TODO!");
	}

	override ConnectionState getConnectionState(StreamSocketFD sock)
	{
		assert(false, "TODO!");
	}

	override bool getLocalAddress(SocketFD sock, scope RefAddress dst)
	{
		assert(false, "TODO!");
	}

	override bool getRemoteAddress(SocketFD sock, scope RefAddress dst)
	{
		assert(false, "TODO!");
	}

	override void setTCPNoDelay(StreamSocketFD socket, bool enable)
	{
		assert(false, "TODO!");
	}

	override void setKeepAlive(StreamSocketFD socket, bool enable)
	{
		assert(false, "TODO!");
	}

	override void read(StreamSocketFD socket, ubyte[] buffer, IOMode mode, IOCallback on_read_finish)
	{
		assert(false, "TODO!");
	}

	override void write(StreamSocketFD socket, const(ubyte)[] buffer, IOMode mode, IOCallback on_write_finish)
	{
		assert(false, "TODO!");
	}

	override void waitForData(StreamSocketFD socket, IOCallback on_data_available)
	{
		assert(false, "TODO!");
	}

	override void shutdown(StreamSocketFD socket, bool shut_read = true, bool shut_write = true)
	{
		assert(false, "TODO!");
	}

	override void cancelRead(StreamSocketFD socket)
	{
		assert(false, "TODO!");
	}

	override void cancelWrite(StreamSocketFD socket)
	{
		assert(false, "TODO!");
	}

	override DatagramSocketFD createDatagramSocket(scope Address bind_address, scope Address target_address)
	{
		assert(false, "TODO!");
	}

	override DatagramSocketFD adoptDatagramSocket(int socket)
	{
		assert(false);
	}

	override void setTargetAddress(DatagramSocketFD socket, scope Address target_address)
	{
		assert(false);
	}

	override bool setBroadcast(DatagramSocketFD socket, bool enable)
	{
		assert(false, "TODO!");
	}

	override void receive(DatagramSocketFD socket, ubyte[] buffer, IOMode mode, DatagramIOCallback on_receive_finish)
	{
		assert(false, "TODO!");
	}

	override void cancelReceive(DatagramSocketFD socket)
	{
		assert(false, "TODO!");
	}

	override void send(DatagramSocketFD socket, const(ubyte)[] buffer, IOMode mode, Address target_address, DatagramIOCallback on_send_finish)
	{
		assert(false, "TODO!");
	}

	override void cancelSend(DatagramSocketFD socket)
	{
		assert(false, "TODO!");
	}

	override void addRef(SocketFD descriptor)
	{
		assert(false, "TODO!");
	}

	override bool releaseRef(SocketFD descriptor)
	{
		assert(false, "TODO!");
	}
}

final class LibasyncEventDriverDNS : EventDriverDNS {
@safe: /*@nogc:*/ nothrow:

	DNSLookupID lookupHost(string name, DNSLookupCallback on_lookup_finished)
	{
		assert(false, "TODO!");
	}

	void cancelLookup(DNSLookupID handle)
	{
		assert(false, "TODO!");
	}
}


final class LibasyncEventDriverFiles : EventDriverFiles {
@safe: /*@nogc:*/ nothrow:
	override FileFD open(string path, FileOpenMode mode)
	{
		assert(false, "TODO!");
	}

	override FileFD adopt(int system_file_handle)
	{
		assert(false, "TODO!");
	}

	override void close(FileFD file)
	{
		assert(false, "TODO!");
	}

	override ulong getSize(FileFD file)
	{
		assert(false, "TODO!");
	}

	override void write(FileFD file, ulong offset, const(ubyte)[] buffer, IOMode mode, FileIOCallback on_write_finish)
	{
		assert(false, "TODO!");
	}

	override void read(FileFD file, ulong offset, ubyte[] buffer, IOMode mode, FileIOCallback on_read_finish)
	{
		assert(false, "TODO!");
	}

	override void cancelWrite(FileFD file)
	{
		assert(false, "TODO!");
	}

	override void cancelRead(FileFD file)
	{
		assert(false, "TODO!");
	}

	override void addRef(FileFD descriptor)
	{
		assert(false, "TODO!");
	}

	override bool releaseRef(FileFD descriptor)
	{
		assert(false, "TODO!");
	}
}

final class LibasyncEventDriverEvents : EventDriverEvents {
@safe: /*@nogc:*/ nothrow:
	override EventID create()
	{
		assert(false, "TODO!");
	}

	override void trigger(EventID event, bool notify_all = true)
	{
		assert(false, "TODO!");
	}

	override void trigger(EventID event, bool notify_all = true) shared
	{
		assert(false, "TODO!");
	}

	override void wait(EventID event, EventCallback on_event)
	{
		assert(false, "TODO!");
	}

	override void cancelWait(EventID event, EventCallback on_event)
	{
		assert(false, "TODO!");
	}

	override void addRef(EventID descriptor)
	{
		assert(false, "TODO!");
	}

	override bool releaseRef(EventID descriptor)
	{
		assert(false, "TODO!");
	}
}

final class LibasyncEventDriverSignals : EventDriverSignals {
@safe: /*@nogc:*/ nothrow:
	override SignalListenID listen(int sig, SignalCallback on_signal)
	{
		assert(false, "TODO!");
	}

	override void addRef(SignalListenID descriptor)
	{
		assert(false, "TODO!");
	}

	override bool releaseRef(SignalListenID descriptor)
	{
		assert(false, "TODO!");
	}
}

final class LibasyncEventDriverTimers : EventDriverTimers {
@safe: /*@nogc:*/ nothrow:
	override TimerID create()
	{
		assert(false, "TODO!");
	}

	override void set(TimerID timer, Duration timeout, Duration repeat = Duration.zero)
	{
		assert(false, "TODO!");
	}

	override void stop(TimerID timer)
	{
		assert(false, "TODO!");
	}

	override bool isPending(TimerID timer)
	{
		assert(false, "TODO!");
	}

	override bool isPeriodic(TimerID timer)
	{
		assert(false, "TODO!");
	}

	override void wait(TimerID timer, TimerCallback callback)
	{
		assert(false, "TODO!");
	}

	override void cancelWait(TimerID timer)
	{
		assert(false, "TODO!");
	}

	override void addRef(TimerID descriptor)
	{
		assert(false, "TODO!");
	}

	override bool releaseRef(TimerID descriptor)
	{
		assert(false, "TODO!");
	}

	override bool isUnique(TimerID descriptor) const
	{
		assert(false, "TODO!");
	}
}

final class LibasyncEventDriverWatchers : EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
	override WatcherID watchDirectory(string path, bool recursive, FileChangesCallback callback)
	{
		assert(false, "TODO!");
	}

	override void addRef(WatcherID descriptor)
	{
		assert(false, "TODO!");
	}

	override bool releaseRef(WatcherID descriptor)
	{
		assert(false, "TODO!");
	}
}
