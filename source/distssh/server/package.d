/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This is the server that is running in the background surveying the cluster for
performance.
*/
module distssh.server;

import logger = std.experimental.logger;

import distssh.main_ : Options;

int serverGroup(const Options opts) nothrow {
    return 0;
}

@safe:
private:

import std.format : format;

import distssh.server.ipc;

immutable channelFormat = "u%s-shm_distssh-%s";

/// A channel specification for communication.
struct Channel {
    string name;
    ubyte id;
    uint size;

    /// Returns: the path to the semaphore.
    string semPath() {
        return format!"sem.%s_sem"(name);
    }
}

/** Create the shared channel in the root directory
 *
 * Only the server can create it.
 */
Channel createChannel(string root) {
    static import core.sys.posix.unistd;
    import std.path : buildPath;

    // Magic number. This is *probably* so big that it will hold whatever wants
    // to be sent over the channel.
    immutable baseSize = 4096 * 3;
    immutable baseId = 42;

    const uid = core.sys.posix.unistd.getuid();

    return Channel(buildPath(root, format!channelFormat(uid, baseId)), baseId, baseSize);
}

/** Setup the directory in `$HOME` that the shared memory files are created in.
 */
string setupLocalShareDir() {
    import std.path : buildPath, expandTilde;
    import std.file : exists, mkdirRecurse;

    const d = buildPath("~".expandTilde, ".local", "share", "distssh");
    if (!exists(d))
        mkdirRecurse(d);
    return d;
}

enum RequestReply : ubyte {
    getHost = 2,
}

alias Sip = SimpleIpcProtocol!RequestReply;
alias SipServer = SimpleIpcProtocolServer!(RequestReply, true);
alias SipClient = SimpleIpcProtocolClient!RequestReply;

char[] gen() {
    return "abc".dup;
}

@("shall")
@system unittest {
    import core.thread : Thread;
    import core.time : dur;

    auto c = createChannel(setupLocalShareDir);
    auto server = DServer(c);

    static void clientGetHost(Sip.Command* hdr, Sip.Data* d) {
        import std.stdio : writeln;

        auto tmp = d.merge!char;
        writeln(tmp);
        hdr.commandStatus = CommandStatus.processed;
    }

    SipClient client;
    client.setCommandHandler(RequestReply.getHost, &clientGetHost);

    server.start;
    client.startListening(c.name, c.id, c.size);

    client.send(RequestReply.getHost, []);
    Thread.sleep(dur!"msecs"(2));
    client.send(RequestReply.getHost, []);
    Thread.sleep(dur!"msecs"(2));

    server.stop;
}

struct DServer {
    SipServer server;
    Channel channel;

    /** A `DServer` listening for client requests on a `Channel` address.
     *
     * Params:
     * c = ?
     */
    this(Channel c) @safe pure nothrow @nogc {
        channel = c;
    }

    void start() @system {
        logger.trace(channel.name);
        server.setCommandHandler(RequestReply.getHost, &handleGetHost);
        server.startListening(channel.name, channel.id, channel.size);
    }

    void stop() @system {
        import core.thread : Thread;
        import core.time : dur;

        try {
            SipClient client;
            client.startListening(channel.name, channel.id, channel.size);
            client.stopServer;
            Thread.sleep(dur!"msecs"(2));
        } catch (Exception e) {
        }
    }

private:
    void handleGetHost(Sip.Command* hdr, Sip.Data* d) @system {
        hdr.commandStatus = CommandStatus.answered;
        hdr.dataIndex = server.addData(gen());
    }
}
