/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import eventcore.socket;
import eventcore.internal.utils : print;
import std.socket : InternetAddress;
import core.time : Duration, msecs;

ubyte[256] s_rbuf;
bool s_done;

void main() {
    // watchdog timer in case of starvation/deadlocks
    auto tm = eventDriver.timers.create();
    eventDriver.timers.set(tm, 10000.msecs, 0.msecs);
    eventDriver.timers.wait(tm, (tm) { assert(false, "Test hung."); });

    static ubyte[] pack1 = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
    static ubyte[] pack2 = [4, 3, 2, 1, 0];

    auto baddr = new InternetAddress(0x7F000001, 40001);
    auto server = listenStream(baddr);
    StreamSocket client;
    StreamSocket incoming;

    server.waitForConnections!((incoming_, addr) {
        incoming = incoming_; // work around ref counting issue
        assert(incoming.state == ConnectionState.connected);
        print("Got incoming, reading data");
        incoming.read!((status, bts) {
            print("Got data");
            assert(status == IOStatus.ok);
            assert(bts == pack1.length);
            assert(s_rbuf[0 .. pack1.length] == pack1);

            print("Second write");
            client.write!((status, bytes) {
                print("Second write done");
                assert(status == IOStatus.ok);
                assert(bytes == pack2.length);
            })(pack2, IOMode.once);

            print("Second read");
            incoming.read!((status, bts) {
                print("Second read done");
                assert(status == IOStatus.ok);
                assert(bts == pack2.length);
                assert(s_rbuf[0 .. pack2.length] == pack2);

                destroy(client);
                destroy(incoming);
                destroy(server);
                s_done = true;
                eventDriver.timers.stop(tm);

                // NOTE: one reference to incoming is still held by read()
                //assert(eventDriver.core.waiterCount == 1);
            })(s_rbuf, IOMode.once);
        })(s_rbuf, IOMode.once);
    });

    print("Connect...");
    connectStream!((sock, status) {
        client = sock;
        assert(status == ConnectStatus.connected);
        assert(sock.state == ConnectionState.connected);
        print("Initial write");
        client.write!((wstatus, bytes) {
            print("Initial write done");
            assert(wstatus == IOStatus.ok);
            assert(bytes == 10);
        })(pack1, IOMode.all);
    })(baddr);

    ExitReason er;
    do
        er = eventDriver.core.processEvents(Duration.max);
    while (er == ExitReason.idle);
    assert(er == ExitReason.outOfWaiters);
    assert(s_done);
    s_done = false;
}
