/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This is copied and modified from iz.
iz is licensed under Boost-1.0.
Author is Basile B.
*/
module distssh.server.ipc;

import core.thread;
import std.path : baseName;
static import std.file;
import std.string, std.file, std.traits, std.conv, std.stdio;
import iz.memory, iz.types;
import iz.ipc : SharedMemoryIPC, SharedmemSemaphore;

enum traceFuncIO = q{
    //writeln("enter: ", __PRETTY_FUNCTION__); stdout.flush;
    //scope(exit) writeln("leave: ", __PRETTY_FUNCTION__); stdout.flush;
};

/// Enumerates the possible status of a command in the $(D SimpleIpcProtocol).
enum CommandStatus : ubyte {
    /// Command just has been sent
    waiting,
    /// The server has answered to the command.
    answered,
    /// The command emitter has read the answer. The command can be deleted.
    processed,
}

/**
 * The types and a few helpers used by the SimpleIpcProtocol server and client.
 */
template SimpleIpcProtocol(CommandKind) {
    static assert(is(CommandKind == enum) && isOrderedEnum!CommandKind
            && CommandKind.init >= 2, "CommandKind must be an ordered enum starting from 2");

    /// Proptotype of the handlers a client can register.
    alias Handler = void delegate(Command* header, Data* answer);
    /// Alternative handler type.
    alias HandlerFunc = void function(Command* header, Data* answer);

    /// The command type
    struct Command {
        /// The kind.
        CommandKind commandKind;
        /// The status.
        CommandStatus commandStatus;
        /// The emitter.
        ulong clientId;
        /// The index of the data associated to this command.
        int dataIndex;
    }

    /// The stream of commands.
    struct CommandChannel {
        /// Indicates the count of commands in the channel.
        uint length;
        /// Returns: The command indexed by index.
        Command* items(size_t index) {
            return (cast(Command*)((cast(void*)&this) + CommandChannel.sizeof)) + index;
        }
    }

    enum dataClusterSize = 4090;

    /// The data type
    struct Data {
        /// Indicates in how many clusters the data is splitted in.
        uint numClusters;
        /// Indicates the count of bytes used by the cluster.
        ushort numBytes;
        /// Data storage.
        ubyte[dataClusterSize] cluster;
        /**
         * Merges the clusters of the data starting from this cluster.
         *
         * Params:
         *      T = Defines the type of the returned array. Must have a size of 1.
         *
         * Returns: The data starting from this cluster.
         */
        T[] merge(T = ubyte)() if (T.sizeof == 1) {
            T[] result;
            Data* current = &this;
            foreach (i; 0 .. numClusters - 1) {
                result.length += dataClusterSize;
                moveMem(result.ptr + result.length - dataClusterSize,
                        current.cluster.ptr, dataClusterSize);
                current += 1;
            }
            result.length += current.numBytes;
            moveMem(result.ptr + result.length - current.numBytes,
                    current.cluster.ptr, current.numBytes);
            return result;
        }
    }

    static assert(Data.sizeof == 4096);

    /// The stream of Data.
    static struct DataChannel {
        /// Indicates how many clusters are in the channel.
        uint length;
        /// Returns: The cluster at index.
        Data* items(size_t index) {
            return (cast(Data*)((cast(void*)&this) + Data.sizeof)) + index;
        }
    }
}

/**
 * Simple IPC protocol server.
 *
 * Params:
 *      CommandKind = The enumeration listing the possible commands.
 *      auxiliaryThread = When set to $(D false), the default, the main thread
 *      is used, which locks the application. When set to $(D true), another
 *      thread is used to listen, which may be desirable if the application
 *      purpose is not only to be a daemon.
 */
struct SimpleIpcProtocolServer(CommandKind, bool auxiliaryThread = false) {
private:

    SharedMemoryIPC _cmdsChannel;
    SharedMemoryIPC _dataChannel;
    SharedmemSemaphore* _semaphore;
    bool _running;

    static if (auxiliaryThread) {
        Thread _listener;
    }

    alias Sip = SimpleIpcProtocol!CommandKind;

    Sip.Handler[CommandKind.max + 1] _handlers;

    Sip.CommandChannel* commandChannel() {
        return cast(Sip.CommandChannel*) _cmdsChannel.ptr();
    }

    Sip.DataChannel* dataChannel() {
        return cast(Sip.DataChannel*) _dataChannel.ptr();
    }

    void listen() {
        mixin(traceFuncIO);

        while (true) {
            static if (auxiliaryThread) {
                _listener.sleep(dur!"usecs"(1));
            } else
                Thread.sleep(dur!"usecs"(1));

            _semaphore.lock;

            size_t numProcessed;
            Sip.CommandChannel* cc = commandChannel();
            Sip.DataChannel* dc = dataChannel();

            foreach (i; 0 .. cc.length) {
                Sip.Data* d;
                Sip.Command* c = cc.items(i);

                // client stops the server
                if (cast(int) c.commandKind == 0) {
                    _running = false;
                    _semaphore.unlock;
                    return;
                }  // client leaves, mark its remaining commands for deletion
                else if (cast(int) c.commandKind == 1) {
                    foreach (j; 0 .. cc.length) {
                        Sip.Command* o = cc.items(j);
                        if (o.clientId == c.clientId)
                            o.commandStatus = CommandStatus.processed;
                    }
                    _semaphore.unlock;
                    return;
                }

                if (c.commandStatus == CommandStatus.processed) {
                    numProcessed++;
                    continue;
                }

                Sip.Handler h = _handlers[c.commandKind];

                if (h !is null && c.commandStatus == CommandStatus.waiting) {
                    if (c.dataIndex != -1)
                        d = dc.items(c.dataIndex);
                    h(c, d);
                }
            }

            if (cc.length != 0 && numProcessed == cc.length) {
                //writeln("server cleanup..."); stdout.flush();
                cc.length = 0;
                dc.length = 0;
            }
            _semaphore.unlock;
        }
    }

public:

     ~this() {
        _cmdsChannel.disconnect();
        _dataChannel.disconnect();

        static if (auxiliaryThread) {
            destroy(_listener);
        }
    }

    /**
     * Start listening.
     *
     * Start listening to clients commands and only returns when a client
     * stops the server.
     *
     * Params:
     *      ids = An identifier used to create the shared memory.
     *          The clients must use the same.
     *      ids = An identifier used to create the shared memory.
     *          The clients must use the same.
     *      uint = The size, in bytes, of the command and data channels.
     */
    void startListening(string ids, ubyte idb, uint channelsSize) {
        mixin(traceFuncIO);

        _cmdsChannel.connect(ids ~ "_cmd", idb, channelsSize);
        _dataChannel.connect(ids ~ "_dat", idb, channelsSize);
        _semaphore = new SharedmemSemaphore(ids.baseName ~ "_sem", false);
        static if (auxiliaryThread) {
            _listener = new Thread(&listen);
            _listener.start();
        } else {
            _running = true;
            listen();
        }
    }

    /**
     * Returns: $(D true) if the client is running, $(D false) otherwise.
     */
    bool running() {
        static if (auxiliaryThread) {
            return _listener.isRunning;
        } else
            return _running;
    }

    /**
     * Adds or replaces a command handler.
     *
     * Params:
     *      c = The command kind.
     *      h = The command handler.
     */
    void setCommandHandler(CommandKind c, Sip.Handler h) {
        Sip.CommandChannel* cc = commandChannel();
        Sip.DataChannel* dc = dataChannel();
        _handlers[cast(uint) c] = h;

    }

    /// ditto
    void setCommandHandler(CommandKind c, Sip.HandlerFunc h) {
        import std.functional : toDelegate;

        setCommandHandler(c, toDelegate(h));
    }

    /**
     * Adds data to the data channel.
     * This function is only thread safe when called in a command handler.
     * This function must only be called when the client is running.
     *
     * Params:
     *      data = The data to add.
     *
     * Returns: The index of the data channel cluster where the data starts.
     */
    uint addData(T)(T[] data) if (T.sizeof == 1) {
        Sip.DataChannel* dc = dataChannel();
        Sip.Data* firstCluster = dc.items(dc.length);
        uint numClusters;
        uint result = dc.length;

        while (data.length != 0) {
            dc.length = dc.length + 1;
            Sip.Data* current = dc.items(dc.length - 1);
            numClusters += 1;
            if (data.length >= Sip.dataClusterSize) {
                moveMem(current.cluster.ptr, data.ptr, Sip.dataClusterSize);
                data = data[Sip.dataClusterSize .. $];
            } else {
                current.numBytes = cast(ushort) data.length;
                moveMem(current.cluster.ptr, data.ptr, data.length);
                break;
            }
        }
        firstCluster.numClusters = numClusters;
        return result;
    }
}

/**
 * Simple IPC protocol client.
 *
 * Params:
 *      CommandKind = The enumeration listing the possible commands.
 */
struct SimpleIpcProtocolClient(CommandKind) {
private:

    SharedMemoryIPC _cmdsChannel;
    SharedMemoryIPC _dataChannel;
    SharedmemSemaphore* _semaphore;

    Thread _control;

    alias Sip = SimpleIpcProtocol!CommandKind;

    Sip.Handler[CommandKind.max + 1] _handlers;

    ulong _clientId;

    Sip.CommandChannel* commandChannel() {
        return cast(Sip.CommandChannel*) _cmdsChannel.ptr();
    }

    Sip.DataChannel* dataChannel() {
        return cast(Sip.DataChannel*) _dataChannel.ptr();
    }

    void controlLoop() {
        mixin(traceFuncIO);

        while (true) {
            _control.sleep(dur!"usecs"(1));

            _semaphore.lock;

            Sip.CommandChannel* cc = commandChannel();
            Sip.DataChannel* dc = dataChannel();
            foreach (i; 0 .. cc.length) {
                Sip.Data* d;
                Sip.Command* c = cc.items(i);

                if (cast(int) c.commandKind < 2) {
                    _semaphore.unlock;
                    return;
                }

                if (c.clientId != _clientId || c.commandStatus == CommandStatus.processed)
                    continue;

                Sip.Handler h = _handlers[c.commandKind];

                if (h !is null && c.commandStatus == CommandStatus.answered) {
                    if (c.dataIndex != -1)
                        d = dc.items(c.dataIndex);
                    h(c, d);
                }
            }

            _semaphore.unlock;
        }
    }

public:

     ~this() {
        destroy(_control);
        _cmdsChannel.disconnect();
        _dataChannel.disconnect();
    }

    /**
     * Start listening.
     *
     * Start listening to the server answers and only return when
     * this or another client sends a command with a kind equal to 0.
     *
     * Params:
     *      ids = An identifier used to create the shared memory.
     *          The other clients and the server must use the same.
     *      ids = An identifier used to create the shared memory.
     *          The other clients and the server must use the same.
     *      uint = The size, in bytes, of the command and data channels.
     */
    void startListening(string ids, ubyte idb, uint channelsSize) {
        mixin(traceFuncIO);

        if (_control is null)
            _control = new Thread(&controlLoop);
        _cmdsChannel.connect(ids ~ "_cmd", idb, channelsSize);
        _dataChannel.connect(ids ~ "_dat", idb, channelsSize);
        if (_semaphore is null)
            _semaphore = new SharedmemSemaphore(ids.baseName ~ "_sem", true);
        _clientId = _cmdsChannel.id();
        _control.start();
    }

    /**
     * Leaves the control loop.
     */
    void stopListening() {
        mixin(traceFuncIO);

        _semaphore.lock;

        Sip.CommandChannel* cc = commandChannel();
        cc.length = cc.length + 1;
        Sip.Command* h = cc.items(cc.length - 1);
        h.commandKind = cast(CommandKind) 1;
        h.commandStatus = CommandStatus.waiting;
        h.clientId = _clientId;
        h.dataIndex = -1;

        _semaphore.unlock;
    }

    /**
     * Leaves the control loop and stops the server.
     */
    void stopServer() {
        mixin(traceFuncIO);

        _semaphore.lock;

        Sip.CommandChannel* cc = commandChannel();
        cc.length = cc.length + 1;
        Sip.Command* h = cc.items(cc.length - 1);
        h.commandKind = cast(CommandKind) 0;
        h.commandStatus = CommandStatus.waiting;
        h.clientId = _clientId;
        h.dataIndex = -1;

        _semaphore.unlock;
    }

    /**
     * Returns: $(D true) if the client is running, $(D false) otherwise.
     */
    bool running() {
        return _control.isRunning();
    }

    /**
     * Adds or replaces a command handler.
     *
     * Params:
     *      c = The command kind.
     *      h = The command handler.
     */
    void setCommandHandler(CommandKind c, Sip.Handler h) {
        _handlers[cast(uint) c] = h;
    }

    /// ditto
    void setCommandHandler(CommandKind c, Sip.HandlerFunc h) {
        import std.functional : toDelegate;

        setCommandHandler(c, toDelegate(h));
    }

    /**
     * Sends a command.
     *
     * Params:
     *      c = The command kind.
     *      data = The data associated to this command.
     */
    void send(T = ubyte)(CommandKind c, T[] data) if (T.sizeof == 1) {
        mixin(traceFuncIO);

        _semaphore.lock;

        Sip.CommandChannel* cc = commandChannel();
        Sip.DataChannel* dc = dataChannel();
        cc.length = cc.length + 1;
        Sip.Command* h = cc.items(cc.length - 1);
        h.commandKind = c;
        h.commandStatus = CommandStatus.waiting;
        h.clientId = _clientId;

        if (data.length)
            h.dataIndex = addData(data);
        else
            h.dataIndex = -1;

        _semaphore.unlock;
    }

    /**
     * Adds data to the data channel.
     * This function is only thread safe when called in a command handler.
     * This function must only be called when the client is running.
     *
     * Params:
     *      data = The data to add.
     *
     * Returns: The index of the data channel cluster where the data starts.
     */
    uint addData(T)(T[] data) if (T.sizeof == 1) {
        Sip.DataChannel* dc = dataChannel();
        Sip.Data* firstCluster = dc.items(dc.length);
        uint numClusters;
        uint result = dc.length;

        while (data.length != 0) {
            dc.length = dc.length + 1;
            Sip.Data* current = dc.items(dc.length - 1);
            numClusters += 1;
            if (data.length >= Sip.dataClusterSize) {
                moveMem(current.cluster.ptr, data.ptr, Sip.dataClusterSize);
                data = data[Sip.dataClusterSize .. $];
            } else {
                current.numBytes = cast(ushort) data.length;
                moveMem(current.cluster.ptr, data.ptr, data.length);
                break;
            }
        }
        firstCluster.numClusters = numClusters;
        return result;
    }
}
/// Represents what would be done in two different processes.
unittest {
    // 0 and 1 are reserved for leaving commands
    enum SayStuff : ubyte {
        hello = 2,
        goodbye
    }

    alias Sip = SimpleIpcProtocol!SayStuff;
    alias SayStuffSever = SimpleIpcProtocolServer!(SayStuff, true);
    alias SayStuffClient = SimpleIpcProtocolClient!SayStuff;

    SayStuffSever server;
    SayStuffClient client;

    // server says "hello".
    void sayHello(Sip.Command* header, Sip.Data* answer) {
        header.commandStatus = CommandStatus.answered;
        header.dataIndex = server.addData("hello");
    }

    // server says "goodbye".
    void sayGoodbye(Sip.Command* header, Sip.Data* answer) {
        header.commandStatus = CommandStatus.answered;
        header.dataIndex = server.addData("goodbye");
    }

    // client handles the server answer and mark the command for deletion.
    void getHelloOrGoodBye(Sip.Command* header, Sip.Data* data) {
        if (header.commandKind == SayStuff.hello)
            assert(data.merge!char == "hello");
        else if (header.commandKind == SayStuff.goodbye)
            assert(data.merge!char == "goodbye");
        header.commandStatus = CommandStatus.processed;
    }

    // setup the handlers.
    server.setCommandHandler(SayStuff.hello, &sayHello);
    server.setCommandHandler(SayStuff.goodbye, &sayGoodbye);
    client.setCommandHandler(SayStuff.hello, &getHelloOrGoodBye);
    client.setCommandHandler(SayStuff.goodbye, &getHelloOrGoodBye);

    // launch
    server.startListening("mlqsdkfmlsd", 45, 4096 * 3);
    client.startListening("mlqsdkfmlsd", 45, 4096 * 3);
    scope (exit)
        std.file.remove("mlqsdkfmlsd_cmd");
    scope (exit)
        std.file.remove("mlqsdkfmlsd_dat");

    client.send(SayStuff.hello, []);
    Thread.sleep(dur!"msecs"(2));
    client.send(SayStuff.goodbye, []);
    Thread.sleep(dur!"msecs"(2));
    client.stopServer();
    Thread.sleep(dur!"msecs"(2));
}

unittest {
    enum SayStuff : ubyte {
        hello = 2,
    }

    alias Sip = SimpleIpcProtocol!SayStuff;
    alias SayStuffSever = SimpleIpcProtocolServer!(SayStuff, true);
    alias SayStuffClient = SimpleIpcProtocolClient!SayStuff;

    SayStuffSever server;
    SayStuffClient client;

    server.startListening("mlqsdkfmlsd", 45, 4096 * 3);
    client.startListening("mlqsdkfmlsd", 45, 4096 * 3);
    scope (exit)
        std.file.remove("mlqsdkfmlsd_cmd");
    scope (exit)
        std.file.remove("mlqsdkfmlsd_dat");

    assert(server.running());
    assert(client.running());

    Thread.sleep(dur!"msecs"(2));
    client.stopListening();
    Thread.sleep(dur!"msecs"(2));
    client.stopServer();
    Thread.sleep(dur!"msecs"(2));
}

unittest {
    import std.range, std.random, std.array;

    enum Cmd : ubyte {
        sendChunk = 2,
    }

    alias Sip = SimpleIpcProtocol!Cmd;
    alias Sever = SimpleIpcProtocolServer!(Cmd, true);
    alias Client = SimpleIpcProtocolClient!Cmd;

    Sever server;
    Client client;

    static void handleChunk(Sip.Command* header, Sip.Data* data) {
        assert(data.merge.length == 5000);
    }

    server.setCommandHandler(Cmd.sendChunk, &handleChunk);

    server.startListening("some_ident", 45, 4096 * 3);
    client.startListening("some_ident", 45, 4096 * 3);
    scope (exit)
        std.file.remove("some_ident_cmd");
    scope (exit)
        std.file.remove("some_ident_dat");

    client.send(Cmd.sendChunk, generate!(() => uniform('a', 'z')).takeExactly(5000).array);

    Thread.sleep(dur!"msecs"(2));
    client.stopServer();
    Thread.sleep(dur!"msecs"(2));
}
