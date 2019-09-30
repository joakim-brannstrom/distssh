/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.set;

import std.range : ElementType;

struct Set(T) {
    alias Type = void[0][T];
    Type data;

    void add(T value) @safe pure nothrow {
        data[value] = (void[0]).init;
    }

    void add(Set!T set) @safe pure nothrow {
        add(set.data);
    }

    void add(Type set) @safe pure nothrow {
        foreach (key; set.byKey)
            data[key] = (void[0]).init;
    }

    void remove(T value) {
        data.remove(value);
    }

    Set!T clone() @safe pure nothrow {
        Set!T result;
        result.add(data);
        return result;
    }

    bool contains(T value) {
        return (value in data) !is null;
    }

    /** The set difference according to Set Theory.
     *
     * It is the set of all members in self that are not members of set.
     */
    Set!T setDifference(Set!T set) @safe pure nothrow {
        import std.algorithm : filter;

        typeof(this) r;
        foreach (k; toRange.filter!(a => !set.contains(a)))
            r.add(k);

        return r;
    }

    /** The symmetric difference according to Set Theory.
     *
     * It is the set of all objects that are a member of exactly one of self and set.
     */
    Set!T symmetricDifference(Set!T set) @safe pure nothrow {
        import std.algorithm : filter;

        typeof(this) r;
        foreach (k; toRange.filter!(a => !contains(a)))
            r.add(k);
        foreach (k; toRange.filter!(a => !contains(a)))
            r.add(k);

        return r;
    }

    /** The intersection according to Set Theory.
     *
     * It is the set of all objects that are members of both self and set.
     */
    Set!T intersect(Set!T set) {
        import std.algorithm : filter;

        typeof(this) r;
        foreach (k; toRange.filter!(a => set.contains(a)))
            r.add(k);

        return r;
    }

    auto toList() {
        import std.array : appender;

        auto app = appender!(T[])();
        foreach (key; toRange)
            app.put(key);
        return app.data;
    }

    /// Specify the template type or it doesn't work.
    auto toRange() {
        return data.byKey;
    }
}

Set!T toSet(T)(T[] list) {
    import std.traits : Unqual;

    Set!(Unqual!T) result;
    foreach (item; list)
        result.add(item);
    return result;
}

auto toSet(RangeT)(RangeT range) {
    import std.traits : Unqual;

    alias T = ElementType!RangeT;

    Set!(Unqual!T) result;
    foreach (item; range)
        result.add(item);
    return result;
}
