/++ dub.sdl:
	name "http-server-example"
	description "Simple pseudo HTTP server suitable for benchmarking"
	dependency "eventcore" path=".."
+/
module http_server_example;

import eventcore.core;
import eventcore.internal.utils;
import std.functional : toDelegate;
import std.socket : InternetAddress;
import std.exception : enforce;
import core.time : Duration;


void main()
{
	print("Starting up...");
	auto addr = new InternetAddress("127.0.0.1", 8080);
	auto listener = eventDriver.sockets.listenStream(addr, toDelegate(&onClientConnect));
	enforce(listener != StreamListenSocketFD.invalid, "Failed to listen for connections.");

	print("Listening for requests on port 8080...");
	while (eventDriver.core.waiterCount)
		eventDriver.core.processEvents(Duration.max);
}

void onClientConnect(StreamListenSocketFD listener, StreamSocketFD client, scope RefAddress)
@trusted /*@nogc*/ nothrow {
	import core.stdc.stdlib;
	auto handler = cast(ClientHandler*)calloc(1, ClientHandler.sizeof);
	handler.client = client;
	handler.handleConnection();
}

struct ClientHandler {
	@safe: /*@nogc:*/ nothrow:

	alias LineCallback = void delegate(ubyte[]);

	StreamSocketFD client;
	ubyte[1024] linebuf = void;
	size_t linefill = 0;
	LineCallback onLine;

	@disable this(this);

	void handleConnection()
	{
		//import core.thread;
		//() @trusted { print("Connection %d %s", client, cast(void*)Thread.getThis()); } ();
		readLine(&onRequestLine);
	}

	void readLine(LineCallback on_line)
	{
		onLine = on_line;
		if (linefill >= 2) onReadData(client, IOStatus.ok, 0);
		else eventDriver.sockets.read(client, linebuf[linefill .. $], IOMode.once, &onReadData);
	}

	void onRequestLine(ubyte[] ln)
	{
		//print("Request: %s", cast(char[])ln);
		if (ln.length == 0) {
			//print("Error: empty request line");
			eventDriver.sockets.shutdown(client, true, true);
			eventDriver.sockets.releaseRef(client);
		}

		readLine(&onHeaderLine);
	}

	void onHeaderLine(ubyte[] ln)
	{
		if (ln.length == 0) {
			auto reply = cast(const(ubyte)[])"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nKeep-Alive: timeout=10\r\n\r\nHello, World!";
			eventDriver.sockets.write(client, reply, IOMode.all, &onWriteFinished);
		} else readLine(&onHeaderLine);
	}

	void onWriteFinished(StreamSocketFD fd, IOStatus status, size_t len)
	{
		readLine(&onRequestLine);
	}

	void onReadData(StreamSocketFD, IOStatus status, size_t bytes_read)
	{
		import std.algorithm : countUntil;

		if (status != IOStatus.ok) {
			print("Client disconnect");
			eventDriver.sockets.shutdown(client, true, true);
			eventDriver.sockets.releaseRef(client);
			return;
		}

		linefill += bytes_read;

		assert(linefill <= linebuf.length);

		auto idx = linebuf[0 .. linefill].countUntil(cast(const(ubyte)[])"\r\n");
		if (idx >= 0) {
			assert(linefill + idx <= linebuf.length, "Not enough space to buffer the incoming line.");
			linebuf[linefill .. linefill + idx] = linebuf[0 .. idx];
			foreach (i; 0 .. linefill - idx - 2)
				linebuf[i] = linebuf[idx+2+i];
			linefill -= idx + 2;

			onLine(linebuf[linefill + idx + 2 .. linefill + idx + 2 + idx]);
		} else if (linebuf.length - linefill > 0) {
			eventDriver.sockets.read(client, linebuf[linefill .. $], IOMode.once, &onReadData);
		} else {
			// ERROR: header line too long
			print("Header line too long");
			eventDriver.sockets.shutdown(client, true, true);
			eventDriver.sockets.releaseRef(client);
		}
	}
}
