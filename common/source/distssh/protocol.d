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

enum Kind : ubyte {
    none,
    heartBeat,
    environment,
    remoteHost,
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

    void pack(MsgpackType Type, T)(T v) {
        import msgpack_ll;

        ubyte[DataSize!Type] buf;
        formatType!Type(v, buf);
        put(w, buf[]);
    }

    void pack(T)() if (is(T == HeartBeat)) {
        pack(Kind.heartBeat);
    }

    void pack(const ProtocolEnv env) {
        import std.algorithm : map, sum;

        // dfmt off
        const tot_size =
            KindSize +
            DataSize!(MsgpackType.uint32) +
            DataSize!(MsgpackType.uint32) +
            env.value.map!(a => 2*DataSize!(MsgpackType.str32) + a.key.length + a.value.length).sum;
        // dfmt on

        pack(Kind.environment);
        pack!(MsgpackType.uint32)(cast(uint) tot_size);
        pack!(MsgpackType.uint32)(cast(uint) env.length);

        foreach (const kv; env) {
            pack(kv.key);
            pack(kv.value);
        }
    }

    void pack(const RemoteHost host) {
        pack(Kind.remoteHost);
        pack(host.address);
    }
}

struct Deserialize {
    import std.conv : to;
    import std.typecons : Nullable;

    ubyte[] buf;

    void put(const ubyte[] v) {
        buf ~= v;
    }

    /** Consume from the buffer until a valid kind is found.
     */
    void cleanupUntilKind() nothrow {
        while (buf.length != 0) {
            if (buf.length < KindSize)
                break;

            try {
                auto raw = peek!(MsgpackType.uint8, ubyte)();
                if (raw <= Kind.max && raw != Kind.none)
                    break;
                debug logger.trace("dropped ", raw);
            } catch (Exception e) {
            }

            buf = buf[1 .. $];
        }
    }

    Kind nextKind() {
        if (buf.length < KindSize)
            return Kind.none;
        auto raw = peek!(MsgpackType.uint8, ubyte)();
        if (raw > Kind.max)
            throw new Exception("Malformed packet kind: " ~ raw.to!string);
        return cast(Kind) raw;
    }

    Nullable!HeartBeat unpack(T)() if (is(T == HeartBeat)) {
        if (buf.length < KindSize)
            return typeof(return)();

        auto k = demux!(MsgpackType.uint8, ubyte)();
        if (k == Kind.heartBeat)
            return typeof(return)(HeartBeat());
        return typeof(return)();
    }

    Nullable!ProtocolEnv unpack(T)() if (is(T == ProtocolEnv)) {
        if (nextKind != Kind.environment)
            return typeof(return)();

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

    Nullable!RemoteHost unpack(T)() if (is(T == RemoteHost)) {
        if (nextKind != Kind.remoteHost)
            return typeof(return)();

        // strip the kind
        demux!(MsgpackType.uint8, ubyte);

        try {
            auto host = RemoteHost(demux!string());
            return typeof(return)(host);
        } catch (Exception e) {
        }

        return typeof(return)();
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

struct HeartBeat {
}

struct EnvVariable {
    string key;
    string value;
}

struct ProtocolEnv {
    EnvVariable[] value;
    alias value this;
}

struct RemoteHost {
    string address;
}

@("shall pack and unpack a HeartBeat")
unittest {
    auto app = appender!(ubyte[])();
    auto ser = Serialize!(typeof(app))(app);

    ser.pack!HeartBeat;
    assert(app.data.length > 0);

    auto deser = Deserialize(app.data);
    assert(deser.nextKind == Kind.heartBeat);
    const hb = deser.unpack!HeartBeat;
    assert(!hb.isNull);
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
    logger.trace(deser.unpack!ProtocolEnv);
}
