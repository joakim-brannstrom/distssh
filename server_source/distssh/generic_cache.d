/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Originally developed by Dicebot and virtulis
    Modified by Joakim Brännström (joakim.brannstrom@gmx.com)

Basic content-agnostic cache implementation
*/
module distssh.generic_cache;

/**
    Cache is defined as shared pointer to immutable cache data. When cache
    needs to be updated, whole new immutable data set gets built and pointer
    to "current" cache gets updated with an atomic operation.

    This relies on the fact that posts are changed rarely but served often
    and allows no-lock implicit sharing of cache between worker threads.
 */
struct Cache(EntryT) {
    /// pointer to latest cached content
    shared immutable(CacheData!EntryT)* data = new CacheData!EntryT;
    alias data this;

    /// Updates cache pointer in a thread-safe manner
    void replaceWith(Cache!EntryT new_cache) {
        this.replaceWith(new_cache.data);
    }

    /// ditto
    void replaceWith(immutable(CacheData!EntryT)* new_data) {
        import core.atomic;

        atomicStore(this.data, new_data);
    }

    /// remove all entries
    void removeAll() {
        import core.atomic;

        atomicStore(this.data, new immutable CacheData!EntryT);
    }
}

///
unittest {
    struct DummyEntry {
        string data;
        alias data this;

        static DummyEntry create(string key, string source) {
            return DummyEntry(source);
        }
    }

    Cache!DummyEntry cache;

    // empty cache by default
    assert(cache.entries.length == 0);

    // can't modify data directly, immutable
    static assert(!__traits(compiles, { cache.entries["key"].data = "data"; }));

    // can build a new immutable cache instead
    auto new_cache = cache.add("key", "data1");
    new_cache = cache.add("key", "data2");
    assert(new_cache.entries["key"] == "data2");

    // and replace old reference (uses be atomic operation)
    cache.replaceWith(new_cache);
    assert(cache.entries["key"] == "data2");
}

/**
    Core cache payload implementation.

    Supposed to be used via `Cache` alias.
 */
struct CacheData(TEntry) {
    static assert(is(typeof(TEntry.create(string.init, string.init)) == TEntry));

    /// Mapping of relative URL (also relative file path on disk) to raw data
    TEntry[string] entries;

    /**
        Builds new immutable cache with additional entry added

        Params:
            key = relative URL of the post this must be used as source for
            data = new entry

        Returns:
            pointer to new immtable cache built on top of this one
     */
    Cache!TEntry add(string key, TEntry data) immutable {
        auto cache = new CacheData;
        foreach (old_key, old_data; this.entries)
            cache.entries[old_key] = old_data;
        cache.entries[key] = data;

        return Cache!TEntry(assumePayloadUnique(cache));
    }

    /**
        Builds new immutable cache with additional entry added

        Params:
            key = relative URL of the post this must be used as source for
            data = markdown content used as that post source

        Returns:
            pointer to new immtable cache built on top of this one
     */
    Cache!TEntry add(T)(string key, T data) immutable {
        auto entry = TEntry.create(key, data);
        return this.add(key, entry);
    }
}

/*
    Can't use assumeUnique in cases when only tail is immutable, not pointer
    itself.

    Params:
        ptr = pointer to data in shared memory that doesn't have any other
            references to at the moment

    Returns:
        same pointer but with payload considered immutable
 */
private auto assumePayloadUnique(T)(T* ptr) {
    return cast(immutable(T)*) ptr;
}

///
unittest {
    auto ptr1 = cast(int*) 0x42;
    auto ptr2 = assumePayloadUnique(ptr1);
    assert(ptr2 is ptr1);
    static assert(is(typeof(ptr2) == immutable(int)*));
}
