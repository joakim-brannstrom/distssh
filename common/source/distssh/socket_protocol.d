/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This module handles mux/demux of packets over a socket.

The protocol is simple.
1. Type: ushort, Endian: LittleEndian. The length of the packet EXCLUDING this length marker.
2. ubytes[].
*/
module distssh.socket_protocol;

import std.range : put;
import std.typecons : Nullable;
import logger = std.experimental.logger;

enum Status {
    ok,
    tooBigPacket,
    tooSmallBuffer,
}

/// Write the length of the packet to the first two bytes.
Status mux(ubyte[] data) @safe nothrow {
    import std.bitmanip;

    if (data.length < ushort.sizeof)
        return Status.tooSmallBuffer;

    if ((data.length - ushort.sizeof) > ushort.max)
        return Status.tooBigPacket;

    ubyte[2] len = nativeToLittleEndian(cast(ushort) data.length);
    data[0 .. 2] = len[];

    return Status.ok;
}

/// Returns: the length of the packet
Nullable!ushort demuxLen(const(ubyte)[] data) @safe nothrow {
    import std.bitmanip;

    typeof(return) len;

    if (data.length >= 2) {
        len = data.peek!(ushort, Endian.littleEndian);
    }

    return len;
}

/** Demux a packet by checking the length and then stripping it.
    Returns: The length of the packet. Null if the packet is invalid.
  */
Nullable!ushort demux(ref const(ubyte)[] data) @safe nothrow {
    auto len = demuxLen(data);

    if (len.isNull)
        return len;
    if ((len + ushort.sizeof) > data.length)
        return typeof(return)();

    data = data[2 .. $];
    return len;
}
