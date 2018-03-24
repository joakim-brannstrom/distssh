module eventcore.internal.dlist;

struct StackDList(T) {
	@safe nothrow @nogc:

	private {
		T* m_first, m_last;
		size_t m_length;
	}

	@disable this(this);

	void clear()
	{
		T* itm = m_first;
		while (itm) {
			auto next = itm.next;
			itm.prev = null;
			itm.next = null;
			itm = next;
		}
		m_length = 0;
	}

	@property bool empty() const { return m_first is null; }

	@property size_t length() const { return m_length; }

	@property T* front() { return m_first; }
	@property T* back() { return m_last; }

	void insertFront(T* item)
	{
		assert(!item.prev && !item.next);
		item.next = m_first;
		if (m_first) {
			m_first.prev = item;
			m_first = item;
		} else {
			m_last = item;
			m_first = item;
		}
		m_length++;
	}

	void insertBack(T* item)
	{
		assert(!item.prev && !item.next);
		item.prev = m_last;
		if (m_last) {
			m_last.next = item;
			m_last = item;
		} else {
			m_first = item;
			m_last = item;
		}
		m_length++;
	}

	void insertAfter(T* item, T* after)
	{
		assert(!item.prev && !item.next);
		if (!after) insertBack(item);
		else {
			item.prev = after;
			item.next = after.next;
			after.next = item;
			if (item.next) item.next.prev = item;
			else m_last = item;
		}
		m_length++;
	}

	void remove(T* item)
	{
		if (item.prev) item.prev.next = item.next;
		else m_first = item.next;
		if (item.next) item.next.prev = item.prev;
		else m_last = item.prev;
		item.prev = null;
		item.next = null;
		m_length--;
	}

	void removeFront()
	{
		 if (m_first) remove(m_first);
		m_length--;
	}

	void removeBack()
	{
		 if (m_last) remove(m_last);
		m_length--;
	}

	static struct Range {
		private T* m_first, m_last;

		this(T* first, T* last)
		{
			m_first = first;
			m_last = last;
		}

		@property bool empty() const { return m_first is null; }
		@property T* front() { return m_first; }
		@property T* back() { return m_last; }

		void popFront() {
			assert(m_first !is null);
			m_first = m_first.next;
			if (!m_first) m_last = null;
		}

		void popBack() {
			assert(m_last !is null);
			m_last = m_last.prev;
			if (!m_last) m_first = null;
		}
	}

	Range opSlice() { return Range(m_first, m_last); }
}

unittest {
	import std.algorithm.comparison : equal;
	import std.algorithm.iteration : map;

	struct S { size_t i; S* prev, next; }

	S[10] s;
	foreach (i, ref rs; s) rs.i = i;

	StackDList!S list;

	assert(list.empty);
	assert(list[].empty);
	list.insertBack(&s[0]);
	assert(list[].map!(s => s.i).equal([0]));
	list.insertBack(&s[1]);
	assert(list[].map!(s => s.i).equal([0, 1]));
	list.insertAfter(&s[2], &s[0]);
	assert(list[].map!(s => s.i).equal([0, 2, 1]));
	list.insertFront(&s[3]);
	assert(list[].map!(s => s.i).equal([3, 0, 2, 1]));
	list.removeBack();
	assert(list[].map!(s => s.i).equal([3, 0, 2]));
	list.remove(&s[0]);
	assert(list[].map!(s => s.i).equal([3, 2]));
	list.remove(&s[3]);
	assert(list[].map!(s => s.i).equal([2]));
	list.remove(&s[2]);
	assert(list.empty);
	assert(list[].empty);
}
