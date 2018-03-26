module eventcore.socket;

import eventcore.core : eventDriver;
import eventcore.driver;
import std.exception : enforce;
import std.socket : Address;

StreamSocket connectStream(alias callback)(scope Address peer_address) @safe {
    void cb(StreamSocketFD fd, ConnectStatus status) @safe nothrow {
        if (fd != StreamSocketFD.invalid)
            eventDriver.sockets.addRef(fd);
        callback(StreamSocket(fd), status);
        if (fd != StreamSocketFD.invalid)
            eventDriver.sockets.releaseRef(fd);
    }

    auto fd = eventDriver.sockets.connectStream(peer_address, null, &cb);
    enforce(fd != StreamSocketFD.invalid, "Failed to create socket.");
    eventDriver.sockets.addRef(fd);
    return StreamSocket(fd);
}

StreamListenSocket listenStream(scope Address bind_address) @safe {
    auto fd = eventDriver.sockets.listenStream(bind_address, null);
    enforce(fd != StreamListenSocketFD.invalid, "Failed to create socket.");
    return StreamListenSocket(fd);
}

DatagramSocket createDatagramSocket(scope Address bind_address, scope Address target_address = null) @safe {
    auto fd = eventDriver.sockets.createDatagramSocket(bind_address, target_address);
    enforce(fd != DatagramSocketFD.invalid, "Failed to create socket.");
    return DatagramSocket(fd);
}

struct StreamSocket {
@safe:
nothrow:

    private StreamSocketFD m_fd;

    private this(StreamSocketFD fd) {
        m_fd = fd;
    }

    this(this) {
        if (m_fd != StreamSocketFD.invalid)
            eventDriver.sockets.addRef(m_fd);
    }

    ~this() {
        if (m_fd != StreamSocketFD.invalid)
            eventDriver.sockets.releaseRef(m_fd);
    }

    @property ConnectionState state() {
        return eventDriver.sockets.getConnectionState(m_fd);
    }

    @property void tcpNoDelay(bool enable) {
        eventDriver.sockets.setTCPNoDelay(m_fd, enable);
    }
}

void read(alias callback)(ref StreamSocket socket, ubyte[] buffer, IOMode mode) {
    void cb(StreamSocketFD, IOStatus status, size_t nbytes) @safe nothrow {
        callback(status, nbytes);
    }

    eventDriver.sockets.read(socket.m_fd, buffer, mode, &cb);
}

void cancelRead(ref StreamSocket socket) {
    eventDriver.sockets.cancelRead(socket.m_fd);
}

void waitForData(alias callback)(ref StreamSocket socket) {
    void cb(StreamSocketFD, IOStatus status, size_t nbytes) @safe nothrow {
        callback(status, nbytes);
    }

    eventDriver.sockets.waitForData(socket.m_fd, &cb);
}

void write(alias callback)(ref StreamSocket socket, const(ubyte)[] buffer, IOMode mode) {
    void cb(StreamSocketFD, IOStatus status, size_t nbytes) @safe nothrow {
        callback(status, nbytes);
    }

    eventDriver.sockets.write(socket.m_fd, buffer, mode, &cb);
}

void cancelWrite(ref StreamSocket socket) {
    eventDriver.sockets.cancelWrite(socket.m_fd);
}

void shutdown(ref StreamSocket socket, bool shut_read = true, bool shut_write = true) {
    eventDriver.sockets.shutdown(socket.m_fd, shut_read, shut_write);
}

struct StreamListenSocket {
@safe:
nothrow:

    private StreamListenSocketFD m_fd;

    private this(StreamListenSocketFD fd) {
        m_fd = fd;
    }

    this(this) {
        if (m_fd != StreamListenSocketFD.invalid)
            eventDriver.sockets.addRef(m_fd);
    }

    ~this() {
        if (m_fd != StreamListenSocketFD.invalid)
            eventDriver.sockets.releaseRef(m_fd);
    }
}

void waitForConnections(alias callback)(ref StreamListenSocket socket) {
    void cb(StreamListenSocketFD, StreamSocketFD sock, scope RefAddress addr) @safe nothrow {
        auto ss = StreamSocket(sock);
        callback(ss, addr);
    }

    eventDriver.sockets.waitForConnections(socket.m_fd, &cb);
}

struct DatagramSocket {
@safe:
nothrow:

    private DatagramSocketFD m_fd;

    private this(DatagramSocketFD fd) {
        m_fd = fd;
    }

    this(this) {
        if (m_fd != DatagramSocketFD.invalid)
            eventDriver.sockets.addRef(m_fd);
    }

    ~this() {
        if (m_fd != DatagramSocketFD.invalid)
            eventDriver.sockets.releaseRef(m_fd);
    }

    @property void broadcast(bool enable) {
        eventDriver.sockets.setBroadcast(m_fd, enable);
    }
}

void receive(alias callback)(ref DatagramSocket socket, ubyte[] buffer, IOMode mode) {
    void cb(DatagramSocketFD fd, IOStatus status, size_t bytes_written, scope RefAddress address) @safe nothrow {
        callback(status, bytes_written, address);
    }

    eventDriver.sockets.receive(socket.m_fd, buffer, mode, &cb);
}

void cancelReceive(ref DatagramSocket socket) {
    eventDriver.sockets.cancelReceive(socket.m_fd);
}

void send(alias callback)(ref DatagramSocket socket, const(ubyte)[] buffer,
        IOMode mode, Address target_address = null) {
    void cb(DatagramSocketFD fd, IOStatus status, size_t bytes_written, scope RefAddress) @safe nothrow {
        callback(status, bytes_written);
    }

    eventDriver.sockets.send(socket.m_fd, buffer, mode, target_address, &cb);
}

void cancelSend(ref DatagramSocket socket) {
    eventDriver.sockets.cancelSend(socket.m_fd);
}
