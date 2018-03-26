module vibe.internal.list;

import core.atomic;

struct CircularDList(T)
{
	private {
		T m_pivot;
	}

	this(T pivot)
	{
		assert(pivot.prev is null && pivot.next is null);
		pivot.next = pivot.prev = pivot;
		m_pivot = pivot;
		assert(this.empty);
	}

	bool empty() const { return m_pivot.next is m_pivot; }


	@property T front() { return m_pivot.next is m_pivot ? null : m_pivot.next; }
	@property T back() { return m_pivot.prev is m_pivot ? null : m_pivot.prev; }

	void remove(T elem)
	{
		assert(elem !is m_pivot);
		elem.prev.next = elem.next;
		elem.next.prev = elem.prev;
		elem.prev = elem.next = null;
	}

	void insertBefore(T elem, T pivot)
	{
		assert(elem.prev is null && elem.next is null);
		elem.prev = pivot.prev;
		elem.next = pivot;
		pivot.prev.next = elem;
		pivot.prev = elem;
	}

	void insertAfter(T elem, T pivot)
	{
		assert(elem.prev is null && elem.next is null);
		elem.prev = pivot;
		elem.next = pivot.next;
		pivot.next.prev = elem;
		pivot.next = elem;
	}

	void insertFront(T elem) { insertAfter(elem, m_pivot); }

	void insertBack(T elem) { insertBefore(elem, m_pivot); }

	// NOTE: allowed to remove the current element
	int opApply(int delegate(T) @safe nothrow del)
	@safe nothrow {
		T prev = m_pivot;
		debug size_t counter = 0;
		while (prev.next !is m_pivot) {
			auto el = prev.next;
			if (auto ret = del(el))
				return ret;
			if (prev.next is el)
				prev = prev.next;
			debug assert (++counter < 1_000_000, "Cycle in list?");
		}
		return 0;
	}
}

unittest {
	static final class C {
		C prev, next;
		int i;
		this(int i) { this.i = i; }
	}

	alias L = CircularDList!C;
	auto l = L(new C(0));
	assert(l.empty);

	auto c = new C(1);
	l.insertBack(c);
	assert(!l.empty);
	assert(l.front is c);
	assert(l.back is c);
	foreach (c; l) assert(c.i == 1);

	auto c2 = new C(2);
	l.insertFront(c2);
	assert(!l.empty);
	assert(l.front is c2);
	assert(l.back is c);
	foreach (c; l) assert(c.i == 1 || c.i == 2);

	l.remove(c);
	assert(!l.empty);
	assert(l.front is c2);
	assert(l.back is c2);
	foreach (c; l) assert(c.i == 2);

	l.remove(c2);
	assert(l.empty);
}


struct StackSList(T)
{
@safe nothrow:

	import core.atomic : cas;

	private T m_first;

	@property T first() { return m_first; }
	@property T front() { return m_first; }

	bool empty() const { return m_first is null; }

	void add(T elem)
	{
		debug iterate((el) { assert(el !is elem, "Double-insertion of list element."); return true; });
		elem.next = m_first;
		m_first = elem;
	}

	bool remove(T elem)
	{
		debug uint counter = 0;
		T w = m_first, wp;
		while (w !is elem) {
			if (!w) return false;
			wp = w;
			w = w.next;
			debug assert(++counter < 1_000_000, "Cycle in linked list?");
		}
		if (wp) wp.next = w.next;
		else m_first = w.next;
		return true;
	}

	void filter(scope bool delegate(T el) @safe nothrow del)
	{
		debug uint counter = 0;
		T w = m_first, pw;
		while (w !is null) {
			auto wnext = w.next;
			if (!del(w)) {
				if (pw) pw.next = wnext;
				else m_first = wnext;
			} else pw = w;
			w = wnext;
			debug assert(++counter < 1_000_000, "Cycle in linked list?");
		}
	}

	void iterate(scope bool delegate(T el) @safe nothrow del)
	{
		debug uint counter = 0;
		T w = m_first;
		while (w !is null) {
			auto wnext = w.next;
			if (!del(w)) break;
			w = wnext;
			debug assert(++counter < 1_000_000, "Cycle in linked list?");
		}
	}
}

unittest {
	static final class C {
		C next;
		int i;
		this(int i) { this.i = i; }
	}

	alias L = StackSList!C;
	L l;
	assert(l.empty);

	auto c = new C(1);
	l.add(c);
	assert(!l.empty);
	assert(l.front is c);
	l.iterate((el) { assert(el.i == 1); return true; });

	auto c2 = new C(2);
	l.add(c2);
	assert(!l.empty);
	assert(l.front is c2);
	l.iterate((el) { assert(el.i == 1 || el.i == 2); return true; });

	l.remove(c);
	assert(!l.empty);
	assert(l.front is c2);
	l.iterate((el) { assert(el.i == 2); return true; });

	l.filter((el) => el.i == 0);
	assert(l.empty);
}
