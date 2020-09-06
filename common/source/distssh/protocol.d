/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This module defines the protocol for data transfer and functionality to use it.
*/
module distssh.protocol;

import std.array : appender;
import std.range : put;
import logger = std.experimental.logger;

import msgpack_ll;
import sumtype;

enum Kind : ubyte {
    none,
    heartBeat,
    /// The shell environment.
    environment,
    /// The working directory to execute the command in.
    workdir,
    /// Command to execute
    command,
    /// All configuration data has been sent.
    confDone,
}

enum KindSize = DataSize!(MsgpackType.uint8);

struct Serialize(WriterT) {
@safe:

    WriterT w;

    void pack(Kind k) {
        ubyte[KindSize] pkgtype;
        formatType!(MsgpackType.uint8)(k, pkgtype);
        put(w, pkgtype[]);
    }

    void pack(const string s) {
        import msgpack_ll;

        ubyte[5] hdr;
        // TODO a uint is potentially too big. standard says 2^32-1
        formatType!(MsgpackType.str32)(cast(uint) s.length, hdr);
        put(w, hdr[]);
        put(w, cast(const(ubyte)[]) s);
    }

    void packArray(T)(T[] value)
    in (value.length < ushort.max) {
        import msgpack_ll;

        ubyte[DataSize!(MsgpackType.array16)] hdr;
        formatType!(MsgpackType.array16)(cast(ushort) value.length, hdr);
        put(w, hdr[]);
        foreach (v; value) {
            put(w, cast(const(ubyte)[]) v);
        }
    }

    void pack(MsgpackType Type, T)(T v) {
        import msgpack_ll;

        ubyte[DataSize!Type] buf;
        formatType!Type(v, buf);
        put(w, buf[]);
    }

    void pack(T)() if (is(T == HeartBeat)) {
        pack(Kind.heartBeat);
    }

    void pack(T)() if (is(T == ConfDone)) {
        pack(Kind.confDone);
    }

    void pack(const Workdir wd) {
        // dfmt off
        const sz =
            KindSize +
            DataSize!(MsgpackType.str32) +
            (cast(const(ubyte)[]) wd.value).length;
        // dfmt on

        pack(Kind.workdir);
        pack!(MsgpackType.uint32)(cast(uint) sz);
        pack(wd.value);
    }

    void pack(const Command cmd) {
        import std.algorithm : map, sum;

        // dfmt off
        const sz =
            KindSize +
            DataSize!(MsgpackType.uint32) +
            DataSize!(MsgpackType.uint32) +
            cmd.value.map!(a => (cast(const(ubyte)[]) a).length).sum;
        // dfmt on

        pack(Kind.command);
        pack!(MsgpackType.uint32)(cast(uint) sz);
        pack!(MsgpackType.uint32)(cast(uint) cmd.value.length);

        foreach (a; cmd.value) {
            pack(a);
        }
    }

    void pack(const ProtocolEnv env) {
        import std.algorithm : map, sum;

        // dfmt off
        const tot_size =
            KindSize +
            DataSize!(MsgpackType.uint32) +
            DataSize!(MsgpackType.uint32) +
            env.value.map!(a => 2*DataSize!(MsgpackType.str32) +
                           (cast(const(ubyte)[]) a.key).length +
                           (cast(const(ubyte)[]) a.value).length).sum;
        // dfmt on

        pack(Kind.environment);
        pack!(MsgpackType.uint32)(cast(uint) tot_size);
        pack!(MsgpackType.uint32)(cast(uint) env.length);

        foreach (const kv; env) {
            pack(kv.key);
            pack(kv.value);
        }
    }
}

struct Deserialize {
    import std.conv : to;

    alias Result = SumType!(None, HeartBeat, ProtocolEnv, ConfDone, Command, Workdir);

    ubyte[] buf;

    void put(const ubyte[] v) {
        buf ~= v;
    }

    Result unpack() {
        cleanupUntilKind();

        Result rval;
        if (buf.length < KindSize)
            return rval;

        const k = () {
            auto raw = peek!(MsgpackType.uint8, ubyte)();
            if (raw > Kind.max)
                return Kind.none;
            return cast(Kind) raw;
        }();

        debug logger.tracef("%-(%X, %)", buf);

        final switch (k) {
        case Kind.none:
            consume!(MsgpackType.uint8);
            return rval;
        case Kind.heartBeat:
            consume!(MsgpackType.uint8);
            rval = HeartBeat.init;
            break;
        case Kind.environment:
            rval = unpackProtocolEnv;
            break;
        case Kind.confDone:
            consume!(MsgpackType.uint8);
            rval = ConfDone.init;
            break;
        case Kind.command:
            rval = unpackCommand;
            break;
        case Kind.workdir:
            rval = unpackWorkdir;
            break;
        }

        return rval;
    }

    /** Consume from the buffer until a valid kind is found.
     */
    private void cleanupUntilKind() nothrow {
        while (buf.length != 0) {
            if (buf.length < KindSize)
                break;

            try {
                auto raw = peek!(MsgpackType.uint8, ubyte)();
                if (raw <= Kind.max)
                    break;
                debug logger.trace("dropped ", raw);
            } catch (Exception e) {
            }

            buf = buf[1 .. $];
        }
    }

    private ProtocolEnv unpackProtocolEnv() {
        const kind_totsize = KindSize + DataSize!(MsgpackType.uint32);
        if (buf.length < kind_totsize)
            return typeof(return)();

        const tot_size = () {
            auto s = buf[KindSize .. $];
            return peek!(MsgpackType.uint32, uint)(s);
        }();

        debug logger.trace("Bytes to unpack: ", tot_size);

        if (buf.length < tot_size)
            return typeof(return)();

        // all data is received, start unpacking
        ProtocolEnv env;
        demux!(MsgpackType.uint8, ubyte);
        demux!(MsgpackType.uint32, uint);

        const kv_pairs = demux!(MsgpackType.uint32, uint);
        for (uint i; i < kv_pairs; ++i) {
            string key;
            string value;

            // may contain invalid utf8 chars but still have to consume everything
            try {
                key = demux!string();
            } catch (Exception e) {
            }

            try {
                value = demux!string();
            } catch (Exception e) {
            }

            env ~= EnvVariable(key, value);
        }

        return typeof(return)(env);
    }

    private Command unpackCommand() {
        const hdrTotalSz = KindSize + DataSize!(MsgpackType.uint32);
        if (buf.length < hdrTotalSz)
            return Command.init;

        const totalSz = () {
            auto s = buf[KindSize .. $];
            return peek!(MsgpackType.uint32, uint)(s);
        }();

        debug logger.trace("Bytes to unpack: ", totalSz);

        if (buf.length < totalSz)
            return typeof(return)();

        // all data is received, start unpacking
        demux!(MsgpackType.uint8, ubyte);
        demux!(MsgpackType.uint32, uint);

        Command cmd;
        const elems = demux!(MsgpackType.uint32, uint);
        foreach (_; 0 .. elems) {
            cmd.value ~= demux!string();
        }

        return cmd;
    }

    private Workdir unpackWorkdir() {
        const hdrTotalSz = KindSize + DataSize!(MsgpackType.uint32);
        if (buf.length < hdrTotalSz)
            return Workdir.init;

        const totalSz = () {
            auto s = buf[KindSize .. $];
            return peek!(MsgpackType.uint32, uint)(s);
        }();

        debug logger.trace("Bytes to unpack: ", totalSz);

        if (buf.length < totalSz)
            return typeof(return)();

        // all data is received, start unpacking
        demux!(MsgpackType.uint8, ubyte);
        demux!(MsgpackType.uint32, uint);

        return Workdir(demux!string);
    }

private:
    void consume(MsgpackType type)() {
        buf = buf[DataSize!type .. $];
    }

    void consume(size_t len) {
        buf = buf[len .. $];
    }

    T peek(MsgpackType Type, T)() {
        return peek!(Type, T)(buf);
    }

    static T peek(MsgpackType Type, T)(ref ubyte[] buf) {
        import std.exception : enforce;

        enforce(getType(buf[0]) == Type);
        T v = parseType!Type(buf[0 .. DataSize!Type]);

        return v;
    }

    T demux(MsgpackType Type, T)() {
        import std.exception : enforce;
        import msgpack_ll;

        enforce(getType(buf[0]) == Type);
        T v = parseType!Type(buf[0 .. DataSize!Type]);
        consume!Type();

        return v;
    }

    string demux(T)() if (is(T == string)) {
        import std.exception : enforce;
        import std.utf : validate;
        import msgpack_ll;

        enforce(getType(buf[0]) == MsgpackType.str32);
        auto len = parseType!(MsgpackType.str32)(buf[0 .. DataSize!(MsgpackType.str32)]);
        consume!(MsgpackType.str32);

        // 2^32-1 according to the standard
        enforce(len < int.max);

        char[] raw = cast(char[]) buf[0 .. len];
        consume(len);
        validate(raw);

        return raw.idup;
    }
}

struct None {
}

struct HeartBeat {
}

struct ConfDone {
}

struct EnvVariable {
    string key;
    string value;
}

struct ProtocolEnv {
    EnvVariable[] value;
    alias value this;
}

struct Command {
    string[] value;
}

struct Workdir {
    string value;
}

@("shall pack and unpack a HeartBeat")
unittest {
    auto app = appender!(ubyte[])();
    auto ser = Serialize!(typeof(app))(app);

    ser.pack!HeartBeat;
    assert(app.data.length > 0);

    auto deser = Deserialize(app.data);
    deser.unpack.match!((None x) { assert(false); }, (ConfDone x) {
        assert(false);
    }, (ProtocolEnv x) { assert(false); }, (HeartBeat) { assert(true); });
}

@("shall clean the buffer until a valid kind is found")
unittest {
    auto app = appender!(ubyte[])();
    app.put(cast(ubyte) 42);
    auto ser = Serialize!(typeof(app))(app);
    ser.pack!HeartBeat;

    auto deser = Deserialize(app.data);
    assert(deser.buf.length == 3);
    deser.cleanupUntilKind;
    assert(deser.buf.length == 2);
}

@("shall pack and unpack an environment")
unittest {
    auto app = appender!(ubyte[])();
    auto ser = Serialize!(typeof(app))(app);

    ser.pack(ProtocolEnv([EnvVariable("foo", "bar")]));
    logger.trace(app.data);
    logger.trace(app.data.length);
    assert(app.data.length > 0);

    auto deser = Deserialize(app.data);
    deser.unpack.match!((None x) { assert(false); }, (ConfDone x) {
        assert(false);
    }, (ProtocolEnv x) { assert(true); logger.trace(x); }, (HeartBeat) {
        assert(false);
    });
}
