/** Definition of the core event driver interface.

	This module contains all declarations necessary for defining and using
	event drivers. Event driver implementations will usually inherit from
	`EventDriver` using a `final` class to avoid virtual function overhead.

	Callback_Behavior:
		All callbacks follow the same rules to enable generic implementation
		of high-level libraries, such as vibe.d. Except for "listen" style
		callbacks, each callback will only ever be called at most once.

		If the operation does not get canceled, the callback will be called
		exactly once. In case it gets manually canceled using the corresponding
		API function, the callback is guaranteed to not be called. However,
		the associated operation might still finish - either before the
		cancellation function returns, or afterwards.
*/
module eventcore.driver;
@safe: /*@nogc:*/ nothrow:

import core.time : Duration;
import std.socket : Address;
import std.stdint : intptr_t;


/** Encapsulates a full event driver.

	This interface provides access to the individual driver features, as well as
	a central `dispose` method that must be called before the driver gets
	destroyed or before the process gets terminated.
*/
interface EventDriver {
@safe: /*@nogc:*/ nothrow:
	/// Core event loop functionality
	@property inout(EventDriverCore) core() inout;
	/// Core event loop functionality
	@property shared(inout(EventDriverCore)) core() shared inout;
	/// Single shot and recurring timers
	@property inout(EventDriverTimers) timers() inout;
	/// Cross-thread events (thread local access)
	@property inout(EventDriverEvents) events() inout;
	/// Cross-thread events (cross-thread access)
	@property shared(inout(EventDriverEvents)) events() shared inout;
	/// UNIX/POSIX signal reception
	@property inout(EventDriverSignals) signals() inout;
	/// Stream and datagram sockets
	@property inout(EventDriverSockets) sockets() inout;
	/// DNS queries
	@property inout(EventDriverDNS) dns() inout;
	/// Local file operations
	@property inout(EventDriverFiles) files() inout;
	/// Directory change watching
	@property inout(EventDriverWatchers) watchers() inout;

	/// Releases all resources associated with the driver
	void dispose();
}


/** Provides generic event loop control.
*/
interface EventDriverCore {
@safe: /*@nogc:*/ nothrow:
	/** The number of pending callbacks.

		When this number drops to zero, the event loop can safely be quit. It is
		guaranteed that no callbacks will be made anymore, unless new callbacks
		get registered.
	*/
	size_t waiterCount();

	/** Runs the event loop to process a chunk of events.

		This method optionally waits for an event to arrive if none are present
		in the event queue. The function will return after either the specified
		timeout has elapsed, or once the event queue has been fully emptied.

		Params:
			timeout = Maximum amount of time to wait for an event. A duration of
				zero will cause the function to only process pending events. A
				duration of `Duration.max`, if necessary, will wait indefinitely
				until an event arrives.
	*/
	ExitReason processEvents(Duration timeout);

	/** Causes `processEvents` to return with `ExitReason.exited` as soon as
		possible.

		A call to `processEvents` that is currently in progress will be notified
		so that it returns immediately. If no call is in progress, the next call
		to `processEvents` will immediately return with `ExitReason.exited`.
	*/
	void exit();

	/** Resets the exit flag.

		`processEvents` will automatically reset the exit flag before it returns
		with `ExitReason.exited`. However, if `exit` is called outside of
		`processEvents`, the next call to `processEvents` will return with
		`ExitCode.exited` immediately. This function can be used to avoid this.
	*/
	void clearExitFlag();

	/** Executes a callback in the thread owning the driver.
	*/
	void runInOwnerThread(ThreadCallback del, intptr_t param) shared;

	/// Low-level user data access. Use `getUserData` instead.
	protected void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
	/// ditto
	protected void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;

	/** Deprecated - use `EventDriverSockets.userData` instead.
	*/
	deprecated("Use `EventDriverSockets.userData` instead.")
	@property final ref T userData(T, FD)(FD descriptor)
	@trusted {
		import std.conv : emplace;
		static void init(void* ptr) { emplace(cast(T*)ptr); }
		static void destr(void* ptr) { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}
}


/** Provides access to socket functionality.

	The interface supports two classes of sockets - stream sockets and datagram
	sockets.
*/
interface EventDriverSockets {
@safe: /*@nogc:*/ nothrow:
	/** Connects to a stream listening socket.
	*/
	StreamSocketFD connectStream(scope Address peer_address, scope Address bind_address, ConnectCallback on_connect);

	/** Aborts asynchronous connect by closing the socket.

		This function may only invoked if the connection state is
		`ConnectionState.connecting`. It will cancel the connection attempt and
		guarantees that the connection callback will not be invoked in the
		future.

		Note that upon completion, the socket handle will be invalid, regardless
		of the number of calls to `addRef`, and must not be used for further
		operations.

		Params:
			sock = Handle of the socket that is currently establishing a
				connection
	*/
	void cancelConnectStream(StreamSocketFD sock);

	/** Adopts an existing stream socket.

		The given socket must be in a connected state. It will be automatically
		switched to non-blocking mode if necessary. Beware that this may have
		side effects in other code that uses the socket and assumes blocking
		operations.

		Params:
			socket = Socket file descriptor to adopt

		Returns:
			Returns a socket handle corresponding to the passed socket
				descriptor. If the same file descriptor is already registered,
				`StreamSocketFD.invalid` will be returned instead.
	*/
	StreamSocketFD adoptStream(int socket);

	/// Creates a socket listening for incoming stream connections.
	StreamListenSocketFD listenStream(scope Address bind_address, StreamListenOptions options, AcceptCallback on_accept);

	final StreamListenSocketFD listenStream(scope Address bind_address, AcceptCallback on_accept) {
		return listenStream(bind_address, StreamListenOptions.defaults, on_accept);
	}

	/// Starts to wait for incoming connections on a listening socket.
	void waitForConnections(StreamListenSocketFD sock, AcceptCallback on_accept);

	/// Determines the current connection state.
	ConnectionState getConnectionState(StreamSocketFD sock);

	/** Retrieves the bind address of a socket.

		Example:
		The following code can be used to retrieve an IPv4/IPv6 address
		allocated on the stack. Note that Unix domain sockets require a larger
		buffer (e.g. `sockaddr_storage`).
		---
		scope storage = new UnknownAddress;
		scope sockaddr = new RefAddress(storage.name, storage.nameLen);
		eventDriver.sockets.getLocalAddress(sock, sockaddr);
		---
	*/
	bool getLocalAddress(SocketFD sock, scope RefAddress dst);

	/** Retrieves the address of the connected peer.

		Example:
		The following code can be used to retrieve an IPv4/IPv6 address
		allocated on the stack. Note that Unix domain sockets require a larger
		buffer (e.g. `sockaddr_storage`).
		---
		scope storage = new UnknownAddress;
		scope sockaddr = new RefAddress(storage.name, storage.nameLen);
		eventDriver.sockets.getLocalAddress(sock, sockaddr);
		---
	*/
	bool getRemoteAddress(SocketFD sock, scope RefAddress dst);

	/// Sets the `TCP_NODELAY` option on a socket
	void setTCPNoDelay(StreamSocketFD socket, bool enable);

	/// Sets to `SO_KEEPALIVE` socket option on a socket.
	void setKeepAlive(StreamSocketFD socket, bool enable);

	/** Reads data from a stream socket.

		Note that only a single read operation is allowed at once. The caller
		needs to make sure that either `on_read_finish` got called, or
		`cancelRead` was called before issuing the next call to `read`.
		However, concurrent writes are legal.

		Waiting_for_data_availability:
			With the special combination of a zero-length buffer and `mode`
			set to either `IOMode.once` or `IOMode.all`, this function will
			wait until data is available on the socket without reading
			anything.

			Note that in this case the `IOStatus` parameter of the callback
			will not reliably reflect a passive connection close. It is
			necessary to actually read some data to make sure this case
			is detected.
	*/
	void read(StreamSocketFD socket, ubyte[] buffer, IOMode mode, IOCallback on_read_finish);

	/** Cancels an ongoing read operation.

		After this function has been called, the `IOCallback` specified in
		the call to `read` is guaranteed to not be called.
	*/
	void cancelRead(StreamSocketFD socket);

	/** Reads data from a stream socket.

		Note that only a single write operation is allowed at once. The caller
		needs to make sure that either `on_write_finish` got called, or
		`cancelWrite` was called before issuing the next call to `write`.
		However, concurrent reads are legal.
	*/
	void write(StreamSocketFD socket, const(ubyte)[] buffer, IOMode mode, IOCallback on_write_finish);

	/** Cancels an ongoing write operation.

		After this function has been called, the `IOCallback` specified in
		the call to `write` is guaranteed to not be called.
	*/
	void cancelWrite(StreamSocketFD socket);

	/** Waits for incoming data without actually reading it.
	*/
	void waitForData(StreamSocketFD socket, IOCallback on_data_available);

	/** Initiates a connection close.
	*/
	void shutdown(StreamSocketFD socket, bool shut_read, bool shut_write);

	/** Creates a connection-less datagram socket.

		Params:
			bind_address = The local bind address to use for the socket. It
				will be able to receive any messages sent to this address.
			target_address = Optional default target address. If this is
				specified and the target address parameter of `send` is
				left to `null`, it will be used instead.

		Returns:
			Returns a datagram socket handle if the socket was created
			successfully. Otherwise returns `DatagramSocketFD.invalid`.
	*/
	DatagramSocketFD createDatagramSocket(scope Address bind_address, scope Address target_address);

	/** Adopts an existing datagram socket.

		The socket must be properly bound before this function is called.

		Params:
			socket = Socket file descriptor to adopt

		Returns:
			Returns a socket handle corresponding to the passed socket
				descriptor. If the same file descriptor is already registered,
				`DatagramSocketFD.invalid` will be returned instead.
	*/
	DatagramSocketFD adoptDatagramSocket(int socket);

	/** Sets an address to use as the default target address for sent datagrams.
	*/
	void setTargetAddress(DatagramSocketFD socket, scope Address target_address);

	/// Sets the `SO_BROADCAST` socket option.
	bool setBroadcast(DatagramSocketFD socket, bool enable);

	/// Joins the multicast group associated with the given IP address.
	bool joinMulticastGroup(DatagramSocketFD socket, scope Address multicast_address, uint interface_index = 0);

	/// Receives a single datagram.
	void receive(DatagramSocketFD socket, ubyte[] buffer, IOMode mode, DatagramIOCallback on_receive_finish);
	/// Cancels an ongoing wait for an incoming datagram.
	void cancelReceive(DatagramSocketFD socket);
	/// Sends a single datagram.
	void send(DatagramSocketFD socket, const(ubyte)[] buffer, IOMode mode, Address target_address, DatagramIOCallback on_send_finish);
	/// Cancels an ongoing wait for an outgoing datagram.
	void cancelSend(DatagramSocketFD socket);

	/** Increments the reference count of the given socket.
	*/
	void addRef(SocketFD descriptor);

	/** Decrements the reference count of the given socket.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.
	*/
	bool releaseRef(SocketFD descriptor);

	/** Enables or disables a socket option.
	*/
	bool setOption(DatagramSocketFD socket, DatagramSocketOption option, bool enable);
	/// ditto
	bool setOption(StreamSocketFD socket, StreamSocketOption option, bool enable);

	/** Retrieves a reference to a user-defined value associated with a descriptor.
	*/
	@property final ref T userData(T, FD)(FD descriptor)
	@trusted {
		import std.conv : emplace;
		static void init(void* ptr) { emplace(cast(T*)ptr); }
		static void destr(void* ptr) { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}

	/// Low-level user data access. Use `getUserData` instead.
	protected void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
	/// ditto
	protected void* rawUserData(StreamListenSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
	/// ditto
	protected void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
}


/** Performs asynchronous DNS queries.
*/
interface EventDriverDNS {
@safe: /*@nogc:*/ nothrow:
	/// Looks up addresses corresponding to the given DNS name.
	DNSLookupID lookupHost(string name, DNSLookupCallback on_lookup_finished);

	/// Cancels an ongoing DNS lookup.
	void cancelLookup(DNSLookupID handle);
}


/** Provides read/write operations on the local file system.
*/
interface EventDriverFiles {
@safe: /*@nogc:*/ nothrow:
	FileFD open(string path, FileOpenMode mode);
	FileFD adopt(int system_file_handle);

	/** Disallows any reads/writes and removes any exclusive locks.

		Note that this function may not actually close the file handle. The
		handle is only guaranteed to be closed one the reference count drops
		to zero. However, the remaining effects of calling this function will
		be similar to actually closing the file.
	*/
	void close(FileFD file);

	ulong getSize(FileFD file);

	void write(FileFD file, ulong offset, const(ubyte)[] buffer, IOMode mode, FileIOCallback on_write_finish);
	void read(FileFD file, ulong offset, ubyte[] buffer, IOMode mode, FileIOCallback on_read_finish);
	void cancelWrite(FileFD file);
	void cancelRead(FileFD file);

	/** Increments the reference count of the given file.
	*/
	void addRef(FileFD descriptor);

	/** Decrements the reference count of the given file.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.
	*/
	bool releaseRef(FileFD descriptor);

	/** Retrieves a reference to a user-defined value associated with a descriptor.
	*/
	@property final ref T userData(T)(FileFD descriptor)
	@trusted {
		import std.conv : emplace;
		static void init(void* ptr) { emplace(cast(T*)ptr); }
		static void destr(void* ptr) { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}

	/// Low-level user data access. Use `userData` instead.
	protected void* rawUserData(FileFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
}


/** Cross-thread notifications

	"Events" can be used to wake up the event loop of a foreign thread. This is
	the basis for all kinds of thread synchronization primitives, such as
	mutexes, condition variables, message queues etc. Such primitives, in case
	of extended wait periods, should use events rather than traditional means
	to block, such as busy loops or kernel based wait mechanisms to avoid
	stalling the event loop.
*/
interface EventDriverEvents {
@safe: /*@nogc:*/ nothrow:
	/// Creates a new cross-thread event.
	EventID create();

	/// Triggers an event owned by the current thread.
	void trigger(EventID event, bool notify_all);

	/// Triggers an event possibly owned by a different thread.
	void trigger(EventID event, bool notify_all) shared;

	/** Waits until an event gets triggered.

		Multiple concurrent waits are allowed.
	*/
	void wait(EventID event, EventCallback on_event);

	/// Cancels an ongoing wait operation.
	void cancelWait(EventID event, EventCallback on_event);

	/** Increments the reference count of the given event.
	*/
	void addRef(EventID descriptor);

	/** Decrements the reference count of the given event.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.
	*/
	bool releaseRef(EventID descriptor);

	/** Retrieves a reference to a user-defined value associated with a descriptor.
	*/
	@property final ref T userData(T)(EventID descriptor)
	@trusted {
		import std.conv : emplace;
		static void init(void* ptr) { emplace(cast(T*)ptr); }
		static void destr(void* ptr) { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}

	/// Low-level user data access. Use `userData` instead.
	protected void* rawUserData(EventID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
}


/** Handling of POSIX signals.
*/
interface EventDriverSignals {
@safe: /*@nogc:*/ nothrow:
	/** Starts listening for the specified POSIX signal.

		Note that if a default signal handler exists for the signal, it will be
		disabled by using this function.

		Params:
			sig = The number of the signal to listen for
			on_signal = Callback that gets called whenever a matching signal
				gets received

		Returns:
			Returns an identifier that identifies the resource associated with
			the signal. Giving up ownership of this resource using `releaseRef`
			will re-enable the default signal handler, if any was present.

			For any error condition, `SignalListenID.invalid` will be returned
			instead.
	*/
	SignalListenID listen(int sig, SignalCallback on_signal);

	/** Increments the reference count of the given resource.
	*/
	void addRef(SignalListenID descriptor);

	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.
	*/
	bool releaseRef(SignalListenID descriptor);
}

interface EventDriverTimers {
@safe: /*@nogc:*/ nothrow:
	TimerID create();
	void set(TimerID timer, Duration timeout, Duration repeat);
	void stop(TimerID timer);
	bool isPending(TimerID timer);
	bool isPeriodic(TimerID timer);
	void wait(TimerID timer, TimerCallback callback);
	void cancelWait(TimerID timer);

	/** Increments the reference count of the given resource.
	*/
	void addRef(TimerID descriptor);

	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.
	*/
	bool releaseRef(TimerID descriptor);

	/// Determines if the given timer's reference count equals one.
	bool isUnique(TimerID descriptor) const;

	/** Retrieves a reference to a user-defined value associated with a descriptor.
	*/
	@property final ref T userData(T)(TimerID descriptor)
	@trusted {
		import std.conv : emplace;
		static void init(void* ptr) { emplace(cast(T*)ptr); }
		static void destr(void* ptr) { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}

	/// Low-level user data access. Use `userData` instead.
	protected void* rawUserData(TimerID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
}

interface EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
	/// Watches a directory or a directory sub tree for changes.
	WatcherID watchDirectory(string path, bool recursive, FileChangesCallback callback);

	/** Increments the reference count of the given resource.
	*/
	void addRef(WatcherID descriptor);

	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.
	*/
	bool releaseRef(WatcherID descriptor);

	/** Retrieves a reference to a user-defined value associated with a descriptor.
	*/
	@property final ref T userData(T)(WatcherID descriptor)
	@trusted {
		import std.conv : emplace;
		static void init(void* ptr) { emplace(cast(T*)ptr); }
		static void destr(void* ptr) { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}

	/// Low-level user data access. Use `userData` instead.
	protected void* rawUserData(WatcherID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
}


// Helper class to enable fully stack allocated `std.socket.Address` instances.
final class RefAddress : Address {
	version (Posix) import 	core.sys.posix.sys.socket : sockaddr, socklen_t;
	version (Windows) import core.sys.windows.winsock2 : sockaddr, socklen_t;

	private {
		sockaddr* m_addr;
		socklen_t m_addrLen;
	}

	this() @safe nothrow {}
	this(sockaddr* addr, socklen_t addr_len) @safe nothrow { set(addr, addr_len); }

	override @property sockaddr* name() { return m_addr; }
	override @property const(sockaddr)* name() const { return m_addr; }
	override @property socklen_t nameLen() const { return m_addrLen; }

	void set(sockaddr* addr, socklen_t addr_len) @safe nothrow { m_addr = addr; m_addrLen = addr_len; }

	void cap(socklen_t new_len)
	@safe nothrow {
		assert(new_len <= m_addrLen, "Cannot grow size of a RefAddress.");
		m_addrLen = new_len;
	}
}


alias ConnectCallback = void delegate(StreamSocketFD, ConnectStatus);
alias AcceptCallback = void delegate(StreamListenSocketFD, StreamSocketFD, scope RefAddress remote_address);
alias IOCallback = void delegate(StreamSocketFD, IOStatus, size_t);
alias DatagramIOCallback = void delegate(DatagramSocketFD, IOStatus, size_t, scope RefAddress);
alias DNSLookupCallback = void delegate(DNSLookupID, DNSStatus, scope RefAddress[]);
alias FileIOCallback = void delegate(FileFD, IOStatus, size_t);
alias EventCallback = void delegate(EventID);
alias SignalCallback = void delegate(SignalListenID, SignalStatus, int);
alias TimerCallback = void delegate(TimerID);
alias FileChangesCallback = void delegate(WatcherID, in ref FileChange change);
@system alias DataInitializer = void function(void*);

enum ExitReason {
	timeout,
	idle,
	outOfWaiters,
	exited
}

enum ConnectStatus {
	connected,
	refused,
	timeout,
	bindFailure,
	socketCreateFailure,
	unknownError
}

enum ConnectionState {
	initialized,
	connecting,
	connected,
	passiveClose,
	activeClose,
	closed
}

enum StreamListenOptions {
	defaults = 0,
	reusePort = 1<<0,
}

enum StreamSocketOption {
	noDelay,
	keepAlive
}

enum DatagramSocketOption {
	broadcast,
	multicastLoopback
}

/**
	Specifies how a file is manipulated on disk.
*/
enum FileOpenMode {
	/// The file is opened read-only.
	read,
	/// The file is opened for read-write random access.
	readWrite,
	/// The file is truncated if it exists or created otherwise and then opened for read-write access.
	createTrunc,
	/// The file is opened for appending data to it and created if it does not exist.
	append
}

enum IOMode {
	immediate, /// Process only as much as possible without waiting
	once,      /// Process as much as possible with a single call
	all        /// Process the full buffer
}

enum IOStatus {
	ok,           /// The data has been transferred normally
	disconnected, /// The connection was closed before all data could be transterred
	error,        /// An error occured while transferring the data
	wouldBlock    /// Returned for `IOMode.immediate` when no data is readily readable/writable
}

enum DNSStatus {
	ok,
	error
}

/** Specifies the kind of change in a watched directory.
*/
enum FileChangeKind {
	/// A file or directory was added
	added,
	/// A file or directory was deleted
	removed,
	/// A file or directory was modified
	modified
}

enum SignalStatus {
	ok,
	error
}


/** Describes a single change in a watched directory.
*/
struct FileChange {
	/// The type of change
	FileChangeKind kind;

	/// The root directory of the watcher
	string baseDirectory;

	/// Subdirectory containing the changed file
	string directory;

	/// Name of the changed file
	const(char)[] name;

	/** Determines if the changed entity is a file or a directory.

		Note that depending on the platform this may not be accurate for
		`FileChangeKind.removed`.
	*/
	bool isDirectory;
}

struct Handle(string NAME, T, T invalid_value = T.init) {
	import std.traits : isInstanceOf;
	static if (isInstanceOf!(.Handle, T)) alias BaseType = T.BaseType;
	else alias BaseType = T;

	alias name = NAME;

	enum invalid = Handle.init;

	T value = invalid_value;

	this(BaseType value) { this.value = T(value); }

	U opCast(U : Handle!(V, M), V, int M)() {
		// TODO: verify that U derives from typeof(this)!
		return U(value);
	}

	U opCast(U : BaseType)()
	{
		return cast(U)value;
	}

	alias value this;
}

alias ThreadCallback = void function(intptr_t param) @safe nothrow;

alias FD = Handle!("fd", size_t, size_t.max);
alias SocketFD = Handle!("socket", FD);
alias StreamSocketFD = Handle!("streamSocket", SocketFD);
alias StreamListenSocketFD = Handle!("streamListen", SocketFD);
alias DatagramSocketFD = Handle!("datagramSocket", SocketFD);
alias FileFD = Handle!("file", FD);
alias EventID = Handle!("event", FD);
alias TimerID = Handle!("timer", size_t, size_t.max);
alias WatcherID = Handle!("watcher", size_t, size_t.max);
alias EventWaitID = Handle!("eventWait", size_t, size_t.max);
alias SignalListenID = Handle!("signal", size_t, size_t.max);
alias DNSLookupID = Handle!("dns", size_t, size_t.max);
