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
}

enum KindSize = DataSize!(MsgpackType.uint8);

struct Serialize(WriterT) {
    WriterT w;

    void pack(Kind k) {
        ubyte[KindSize] pkgtype;
        formatType!(MsgpackType.uint8)(k, pkgtype);
        put(w, pkgtype[]);
    }

    void pack(T)() if (is(T == HeartBeat)) {
        pack(Kind.heartBeat);
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
            }
            catch (Exception e) {
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

private:
    void consume(MsgpackType type)() {
        buf = buf[DataSize!type .. $];
    }

    void consume(size_t len) {
        buf = buf[len .. $];
    }

    T peek(MsgpackType type, T)() {
        import std.exception : enforce;

        enforce(getType(buf[0]) == type);
        T v = parseType!type(buf[0 .. DataSize!type]);

        return v;
    }

    T demux(MsgpackType type, T)() {
        import std.exception : enforce;
        import msgpack_ll;

        enforce(getType(buf[0]) == type);
        T v = parseType!type(buf[0 .. DataSize!type]);
        consume!type();

        return v;
    }
}

struct HeartBeat {
}

struct EnvVariable {
    string key;
    string value;
}

struct Env {
    EnvVariable[] value;
}

@("shall pack and unpack a HeartBeat")
unittest {
    auto app = appender!(ubyte[])();
    auto ser = Serialize!(typeof(app))(app);

    ser.pack!HeartBeat;
    assert(app.data.length > 0);

    auto deser = Deserialize(app.data);
    assert(deser.nextKind == Kind.heartBeat);
    auto hb = deser.unpack!HeartBeat;
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
