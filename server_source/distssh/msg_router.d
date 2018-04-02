/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This module contains a MsgPack router where the MsgPack is of the kind TAG:<custom data>.
It routes on the tag.
*/
module distssh.msg_router;

import eventcore.core;
import eventcore.socket;
import eventcore.internal.utils;

// testing
import std.file : exists, remove;
import std.socket : UnixAddress;
import std.functional : toDelegate;
import core.time : Duration, msecs, dur;
import std.datetime : Clock;

class Router(RouterT) if (is(RouterT == enum)) {
@safe: /*@nogc:*/ nothrow:
    /// If true the socket is closed. Otherwise it is up to the receiver.
    alias PacketDg = bool delegate(ref StreamSocketFD client, ubyte[]);
    alias ClientT = ClientRouter!RouterT;

    PacketDg[RouterT] routes;

    void onClientConnect(StreamListenSocketFD listener, StreamSocketFD client, scope RefAddress) @trusted /*@nogc*/ nothrow {
        import core.stdc.stdlib : calloc;

        auto handler = cast(ClientT*) calloc(1, ClientT.sizeof);
        handler.router = this;
        handler.client = client;

        handler.handleConnection();
    }

    void route(RouterT kind, PacketDg dg) {
        routes[kind] = dg;
    }

private:
    bool routeImpl(StreamSocketFD client, ubyte[] data) {
        import msgpack_ll;

        alias pt = MsgpackType.uint16;
        alias psz = DataSize!pt;

        if (data.length < psz)
            return true;
        else if (getType(data[0]) != pt) {
            return true;
        }

        auto raw = parseType!pt(data[0 .. psz]);
        if (raw > RouterT.max)
            return true;

        auto pkgid = cast(RouterT) raw;

        if (auto v = pkgid in routes) {
            return (*v)(client, data[psz .. $]);
        } else {
            debug {
                () @trusted{
                    print("Unable to route %d %s %s", client, pkgid, data);
                }();
            }

            auto v = RouterT.min in routes;
            return (*v)(client, data);
        }
    }
}

private:

struct ClientRouter(RouterT) {
@safe: /*@nogc:*/ nothrow:
    Router!RouterT router;
    StreamSocketFD client;
    Store store;

    // first 2 bytes (unsigned) specify the length of the data to receive from the client
    size_t packetLen;

    @disable this(this);

    /// Setup handling of client connection.
    void handleConnection() {
        import core.thread;

        debug {
            () @trusted{
                print("Connection %d %s", client, cast(void*) Thread.getThis());
            }();
        }

        eventDriver.sockets.read(client, store.data[0 .. $], IOMode.once, &onReadPacketLen);
    }

    void putData(size_t bytes_read) @nogc {
        store.updateLength(bytes_read);
    }

    void onReadPacketLen(StreamSocketFD, IOStatus status, size_t bytes_read) {
        if (status != IOStatus.ok) {
            debug print("Client disconnect");
            eventDriver.sockets.shutdown(client, true, true);
            eventDriver.sockets.releaseRef(client);
            return;
        }

        debug print("onReadPacketLen bytes_read: %d", bytes_read);

        putData(bytes_read);

        if (store.length < 2) {
            eventDriver.sockets.read(client, store.data[store.length .. $],
                    IOMode.once, &onReadPacketLen);
            return;
        }

        import std.bitmanip;

        packetLen = store.slice.peek!(ushort, Endian.littleEndian);
        debug print("onReadPacketLen len: %d", packetLen);

        debug print("store.length: %s", store.length);
        store.drop(ushort.sizeof);
        debug print("store.length: %s", store.length);

        if (store.length >= packetLen) {
            onPacketFinished();
        } else {
            eventDriver.sockets.read(client, store.data[0 .. $], IOMode.once, &onReadPacketData);
        }
    }

    void onReadPacketData(StreamSocketFD, IOStatus status, size_t bytes_read) {
        if (status != IOStatus.ok) {
            debug print("Client disconnect");
            eventDriver.sockets.shutdown(client, true, true);
            eventDriver.sockets.releaseRef(client);
            return;
        }

        putData(bytes_read);

        debug print("onReadPacket len: %s", store.length);

        if (store.length < packetLen) {
            eventDriver.sockets.read(client, store.data[store.length .. $],
                    IOMode.once, &onReadPacketLen);
        } else {
            onPacketFinished;
        }
    }

    void onPacketFinished() {
        if (router.routeImpl(client, store.slice)) {
            eventDriver.sockets.shutdown(client, true, true);
            eventDriver.sockets.releaseRef(client);
        }
    }
}

// Buffer backing recvBuf
struct Store {
    ubyte[1024 * 64] data = void;
    size_t length;

    void updateLength(size_t bytes_read) @safe pure nothrow @nogc {
        if (bytes_read + length < data.length) {
            length += bytes_read;
        } else {
            length = data.length;
        }
    }

    void drop(size_t len) @safe pure nothrow @nogc {
        ubyte[data.length] tmp;
        tmp[0 .. (length - len)] = data[len .. length];
        length = length - len;
        data[0 .. length] = tmp[0 .. length];
    }

    void reset() @safe pure nothrow @nogc {
        length = 0;
    }

    ubyte[] slice() @safe pure nothrow @nogc {
        return data[0 .. length];
    }
}

version (unittest) {
    enum RT {
        none,
        myPkg,
    }

    struct Fixture {
        import core.sys.posix.signal : SIGPIPE;

        enum addr1 = "/tmp/distssh-test-msg_router.uds";

        bool sig_pipe;
        Router!RT router;

        ~this() {
            eventDriver.core.exit();
        }

        auto addr() nothrow {
            try
                return new UnixAddress(addr1);
            catch (Exception)
                assert(0);
        }

        void setup() {
            void sigPipe(SignalListenID, SignalStatus, int) nothrow @safe {
                print("broken pipe");
                sig_pipe = true;
            }

            eventDriver.signals.listen(SIGPIPE, &sigPipe);

            if (exists(addr1)) {
                try {
                    remove(addr1);
                }
                catch (Exception e) {
                }
            }

            router = new Router!RT;
        }

        void run(string msg) {
            print("Listening for requests on port %s", addr1);
            auto timeout = Clock.currTime + 2.dur!"seconds";
            while (eventDriver.core.waiterCount && Clock.currTime < timeout) {
                eventDriver.core.processEvents(1.dur!"seconds");
            }

            print("Shutdown ", msg);
        }
    }
}

@("shall route the package to the receiver, receiver answer with 84")
unittest {
    import std.conv : to;

    Fixture fix;
    fix.setup;

    bool recv_pkg;
    ubyte recv_data;
    ubyte answer;

    bool testRecv(ref StreamSocketFD client, ubyte[] data) nothrow @safe {
        assert(data.length != 0);
        recv_pkg = true;
        recv_data = data[0];

        void dummyWrite(StreamSocketFD client, IOStatus wstatus, size_t) nothrow @safe {
            assert(wstatus == IOStatus.ok);
            print("Packet sent");
            eventDriver.sockets.shutdown(client, true, true);
            eventDriver.sockets.releaseRef(client);
        }

        ubyte[] answer = [84];

        const st = eventDriver.sockets.getConnectionState(client);
        print("Client is %s %s", client, st);
        eventDriver.sockets.write(client, answer, IOMode.once, &dummyWrite);

        return false;
    }

    fix.router.route(RT.myPkg, &testRecv);

    auto addr = fix.addr;
    auto server = eventDriver.sockets.listenStream(addr, &fix.router.onClientConnect);

    ubyte[1024] client_readbuf;

    void fakeClient() {
        import std.bitmanip : nativeToLittleEndian;
        import msgpack_ll;

        enum pkg_sz = DataSize!(MsgpackType.uint16);

        ubyte[2] pack1 = nativeToLittleEndian(cast(ushort)(pkg_sz + 1));
        ubyte[pkg_sz] pack2;
        try {
            formatType!(MsgpackType.uint16)(cast(ushort) RT.myPkg, pack2);
        }
        catch (Exception e) {
            assert(0);
        }
        ubyte[1] pack3 = [42];

        StreamSocket client;

        connectStream!((sock, status) {
            client = sock;
            assert(status == ConnectStatus.connected);
            client.write!((wstatus, bytes) {
                assert(wstatus == IOStatus.ok);
                assert(bytes == 2);
            })(pack1, IOMode.all);

            client.write!((wstatus, bytes) {
                assert(wstatus == IOStatus.ok);
                assert(bytes == pkg_sz);
            })(pack2, IOMode.all);

            client.write!((wstatus, bytes) {
                assert(wstatus == IOStatus.ok);
                assert(bytes == 1);
            })(pack3, IOMode.all);

            client.read!((wstatus, bytes) {
                assert(wstatus == IOStatus.ok);
                assert(bytes == 1);
            })(client_readbuf, IOMode.all);
        })(addr);
    }

    fakeClient;

    fix.run(__FUNCTION__);

    assert(recv_pkg, "failed to receive the package");
    assert(recv_data == 42, "failed to receive 42 from the client: " ~ recv_data.to!string);
    assert(client_readbuf[0] == 84,
            "failed to write 84 to the client: " ~ client_readbuf[0 .. 2].to!string);
    assert(!fix.sig_pipe, "sigpipe occured which mean the client wasn't waiting for data");
}

@("shall not do anything when no client send data")
unittest {
    import std.conv : to;

    Fixture fix;
    fix.setup;

    bool testRecv(ref StreamSocketFD client, ubyte[] data) nothrow @safe {
        assert(0);
    }

    fix.router.route(RT.myPkg, &testRecv);

    auto addr = fix.addr;
    auto server = eventDriver.sockets.listenStream(addr, &fix.router.onClientConnect);

    void fakeClient() {
        StreamSocket client;

        connectStream!((sock, status) {
            client = sock;
            assert(status == ConnectStatus.connected);
        })(addr);
    }

    fakeClient;

    fix.run(__FUNCTION__);

    assert(!fix.sig_pipe, "sigpipe occured which mean the client wasn't waiting for data");
}
