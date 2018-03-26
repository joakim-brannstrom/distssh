/**
	Generic connection pool for reusing persistent connections across fibers.

	Copyright: © 2012-2016 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.connectionpool;

import vibe.core.log;

import core.thread;
import vibe.core.sync;
import vibe.internal.freelistref;

/**
	Generic connection pool class.

	The connection pool is creating connections using the supplied factory
	function as needed whenever `lockConnection` is called. Connections are
	associated to the calling fiber, as long as any copy of the returned
	`LockedConnection` object still exists. Connections that are not associated
	to any fiber will be kept in a pool of open connections for later reuse.

	Note that, after retrieving a connection with `lockConnection`, the caller
	has to make sure that the connection is actually physically open and to
	reopen it if necessary. The `ConnectionPool` class has no knowledge of the
	internals of the connection objects.
*/
final class ConnectionPool(Connection)
{
	private {
		Connection delegate() @safe m_connectionFactory;
		Connection[] m_connections;
		int[const(Connection)] m_lockCount;
		FreeListRef!LocalTaskSemaphore m_sem;
		debug Thread m_thread;
	}

	this(Connection delegate() @safe connection_factory, uint max_concurrent = uint.max)
	{
		m_connectionFactory = connection_factory;
		() @trusted { m_sem = FreeListRef!LocalTaskSemaphore(max_concurrent); } ();
		debug m_thread = () @trusted { return Thread.getThis(); } ();
	}

	deprecated("Use an @safe callback instead")
	this(Connection delegate() connection_factory, uint max_concurrent = uint.max)
	@system {
		this(cast(Connection delegate() @safe)connection_factory, max_concurrent);
	}

	/** Determines the maximum number of concurrently open connections.

		Attempting to lock more connections that this number will cause the
		calling fiber to be blocked until one of the locked connections
		becomes available for reuse.
	*/
	@property void maxConcurrency(uint max_concurrent) {
		m_sem.maxLocks = max_concurrent;
	}
	/// ditto
	@property uint maxConcurrency() {
		return m_sem.maxLocks;
	}

	/** Retrieves a connection to temporarily associate with the calling fiber.

		The returned `LockedConnection` object uses RAII and reference counting
		to determine when to unlock the connection.
	*/
	LockedConnection!Connection lockConnection()
	@safe {
		debug assert(m_thread is () @trusted { return Thread.getThis(); } (), "ConnectionPool was called from a foreign thread!");

		() @trusted { m_sem.lock(); } ();
		size_t cidx = size_t.max;
		foreach( i, c; m_connections ){
			auto plc = c in m_lockCount;
			if( !plc || *plc == 0 ){
				cidx = i;
				break;
			}
		}

		Connection conn;
		if( cidx != size_t.max ){
			logTrace("returning %s connection %d of %d", Connection.stringof, cidx, m_connections.length);
			conn = m_connections[cidx];
		} else {
			logDebug("creating new %s connection, all %d are in use", Connection.stringof, m_connections.length);
			conn = m_connectionFactory(); // NOTE: may block
			static if (is(typeof(cast(void*)conn)))
				logDebug(" ... %s", () @trusted { return cast(void*)conn; } ());
		}
		m_lockCount[conn] = 1;
		if( cidx == size_t.max ){
			m_connections ~= conn;
			logDebug("Now got %d connections", m_connections.length);
		}
		auto ret = LockedConnection!Connection(this, conn);
		return ret;
	}
}

///
unittest {
	class Connection {
		void write() {}
	}

	auto pool = new ConnectionPool!Connection({
		return new Connection; // perform the connection here
	});

	// create and lock a first connection
	auto c1 = pool.lockConnection();
	c1.write();

	// create and lock a second connection
	auto c2 = pool.lockConnection();
	c2.write();

	// writing to c1 will still write to the first connection
	c1.write();

	// free up the reference to the first connection, so that it can be reused
	destroy(c1);

	// locking a new connection will reuse the first connection now instead of creating a new one
	auto c3 = pool.lockConnection();
	c3.write();
}

unittest { // issue vibe-d#2109
	import vibe.core.net : TCPConnection, connectTCP;
	new ConnectionPool!TCPConnection({ return connectTCP("127.0.0.1", 8080); });
}


struct LockedConnection(Connection) {
	import vibe.core.task : Task;

	private {
		ConnectionPool!Connection m_pool;
		Task m_task;
		Connection m_conn;
		debug uint m_magic = 0xB1345AC2;
	}

	@safe:

	private this(ConnectionPool!Connection pool, Connection conn)
	{
		assert(!!conn);
		m_pool = pool;
		m_conn = conn;
		m_task = Task.getThis();
	}

	this(this)
	{
		debug assert(m_magic == 0xB1345AC2, "LockedConnection value corrupted.");
		if (!!m_conn) {
			auto fthis = Task.getThis();
			assert(fthis is m_task);
			m_pool.m_lockCount[m_conn]++;
			static if (is(typeof(cast(void*)conn)))
				logTrace("conn %s copy %d", () @trusted { return cast(void*)m_conn; } (), m_pool.m_lockCount[m_conn]);
		}
	}

	~this()
	{
		debug assert(m_magic == 0xB1345AC2, "LockedConnection value corrupted.");
		if (!!m_conn) {
			auto fthis = Task.getThis();
			assert(fthis is m_task, "Locked connection destroyed in foreign task.");
			auto plc = m_conn in m_pool.m_lockCount;
			assert(plc !is null);
			assert(*plc >= 1);
			//logTrace("conn %s destroy %d", cast(void*)m_conn, *plc-1);
			if( --*plc == 0 ){
				() @trusted { m_pool.m_sem.unlock(); } ();
				//logTrace("conn %s release", cast(void*)m_conn);
			}
			m_conn = Connection.init;
		}
	}


	@property int __refCount() const { return m_pool.m_lockCount.get(m_conn, 0); }
	@property inout(Connection) __conn() inout { return m_conn; }

	alias __conn this;
}
