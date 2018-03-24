/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import eventcore.socket;
import std.socket : InternetAddress;
import core.time : Duration, msecs;

DatagramSocket s_baseSocket;
DatagramSocket s_freeSocket;
DatagramSocket s_connectedSocket;
ubyte[256] s_rbuf;
bool s_done;

void main()
{
	static ubyte[] pack1 = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
	static ubyte[] pack2 = [4, 3, 2, 1, 0];

	auto baddr = new InternetAddress(0x7F000001, 40001);
	auto anyaddr = new InternetAddress(0x7F000001, 0);
	s_baseSocket = createDatagramSocket(baddr);
	s_freeSocket = createDatagramSocket(anyaddr);
	s_connectedSocket = createDatagramSocket(anyaddr, baddr);
	s_baseSocket.receive!((status, bytes, addr) {
		log("receive initial: %s %s", status, bytes);
		assert(status == IOStatus.wouldBlock);
	})(s_rbuf, IOMode.immediate);
	s_baseSocket.receive!((status, bts, address) {
		log("receive1: %s %s", status, bts);
		assert(status == IOStatus.ok);
		assert(bts == pack1.length);
		assert(s_rbuf[0 .. pack1.length] == pack1);

		s_freeSocket.send!((status, bytes) {
			log("send2: %s %s", status, bytes);
			assert(status == IOStatus.ok);
			assert(bytes == pack2.length);
		})(pack2, IOMode.once, baddr);

		auto tm = eventDriver.timers.create();
		eventDriver.timers.set(tm, 50.msecs, 0.msecs);
		eventDriver.timers.wait(tm, (tm) {
			s_baseSocket.receive!((status, bts, scope addr) {
				log("receive2: %s %s", status, bts);
				assert(status == IOStatus.ok);
				assert(bts == pack2.length);
				assert(s_rbuf[0 .. pack2.length] == pack2);

				destroy(s_baseSocket);
				destroy(s_freeSocket);
				destroy(s_connectedSocket);
				s_done = true;
				log("done.");
			})(s_rbuf, IOMode.immediate);
		});
	})(s_rbuf, IOMode.once);
	s_connectedSocket.send!((status, bytes) {
		log("send1: %s %s", status, bytes);
		assert(status == IOStatus.ok);
		assert(bytes == 10);
	})(pack1, IOMode.immediate);

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
}

void log(ARGS...)(string fmt, ARGS args)
@trusted {
	import std.stdio;
	try writefln(fmt, args);
	catch (Exception e) assert(false, e.msg);
}
