/**
	Multi-threaded task pool implementation.

	Copyright: © 2012-2017 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.taskpool;

import vibe.core.concurrency : isWeaklyIsolated;
import vibe.core.core : exitEventLoop, logicalProcessorCount, runEventLoop, runTask, runTask_internal;
import vibe.core.log;
import vibe.core.sync : ManualEvent, Monitor, SpinLock, createSharedManualEvent, createMonitor;
import vibe.core.task : Task, TaskFuncInfo, callWithMove;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.concurrency : prioritySend, receiveOnly;
import std.traits : isFunctionPointer;


/** Implements a shared, multi-threaded task pool.
*/
shared final class TaskPool {
	private {
		struct State {
			WorkerThread[] threads;
			TaskQueue queue;
			bool term;
		}
		vibe.core.sync.Monitor!(State, shared(SpinLock)) m_state;
		shared(ManualEvent) m_signal;
		immutable size_t m_threadCount;
	}

	/** Creates a new task pool with the specified number of threads.

		Params:
			thread_count: The number of worker threads to create
	*/
	this(size_t thread_count = logicalProcessorCount())
	@safe {
		import std.format : format;

		m_threadCount = thread_count;
		m_signal = createSharedManualEvent();

		with (m_state.lock) {
			queue.setup();
			threads.length = thread_count;
			foreach (i; 0 .. thread_count) {
				WorkerThread thr;
				() @trusted {
					thr = new WorkerThread(this);
					thr.name = format("vibe-%s", i);
					thr.start();
				} ();
				threads[i] = thr;
			}
		}
	}

	/** Returns the number of worker threads.
	*/
	@property size_t threadCount() const shared { return m_threadCount; }

	/** Instructs all worker threads to terminate and waits until all have
		finished.
	*/
	void terminate()
	@safe nothrow {
		m_state.lock.term = true;
		m_signal.emit();

		auto ec = m_signal.emitCount;
		while (true) {
			WorkerThread th;
			with (m_state.lock)
				if (threads.length) {
					th = threads[0];
					threads = threads[1 .. $];
				}
			if (!th) break;

			() @trusted {
				try th.join();
				catch (Exception e) {
					logWarn("Failed to wait for worker thread exit: %s", e.msg);
				}
			} ();
		}

		size_t cnt = m_state.lock.queue.length;
		if (cnt > 0) logWarn("There were still %d worker tasks pending at exit.", cnt);
	}

	/** Instructs all worker threads to terminate as soon as all tasks have
		been processed and waits for them to finish.
	*/
	void join()
	@safe nothrow {
		assert(false, "TODO!");
	}

	/** Runs a new asynchronous task in a worker thread.

		Only function pointers with weakly isolated arguments are allowed to be
		able to guarantee thread-safety.
	*/
	void runTask(FT, ARGS...)(FT func, auto ref ARGS args)
		if (isFunctionPointer!FT)
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		runTask_unsafe(func, args);
	}

	/// ditto
	void runTask(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
		if (is(typeof(__traits(getMember, object, __traits(identifier, method)))))
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		auto func = &__traits(getMember, object, __traits(identifier, method));
		runTask_unsafe(func, args);
	}

	/** Runs a new asynchronous task in a worker thread, returning the task handle.

		This function will yield and wait for the new task to be created and started
		in the worker thread, then resume and return it.

		Only function pointers with weakly isolated arguments are allowed to be
		able to guarantee thread-safety.
	*/
	Task runTaskH(FT, ARGS...)(FT func, auto ref ARGS args)
		if (isFunctionPointer!FT)
	{
		import std.typecons : Typedef;

		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");

		alias PrivateTask = Typedef!(Task, Task.init, __PRETTY_FUNCTION__);
		Task caller = Task.getThis();

		// workaround for runWorkerTaskH to work when called outside of a task
		if (caller == Task.init) {
			Task ret;
			.runTask(&runTaskHWrapper!(FT, ARGS), () @trusted { return &ret; } (), func, args).join();
			return ret;
		}

		assert(caller != Task.init, "runWorkderTaskH can currently only be called from within a task.");
		static void taskFun(Task caller, FT func, ARGS args) {
			PrivateTask callee = Task.getThis();
			caller.tid.prioritySend(callee);
			mixin(callWithMove!ARGS("func", "args"));
		}
		runTask_unsafe(&taskFun, caller, func, args);
		return cast(Task)receiveOnly!PrivateTask();
	}
	/// ditto
	Task runTaskH(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
		if (is(typeof(__traits(getMember, object, __traits(identifier, method)))))
	{
		static void wrapper()(shared(T) object, ref ARGS args) {
			__traits(getMember, object, __traits(identifier, method))(args);
		}
		return runTaskH(&wrapper!(), object, args);
	}


	/** Runs a new asynchronous task in all worker threads concurrently.

		This function is mainly useful for long-living tasks that distribute their
		work across all CPU cores. Only function pointers with weakly isolated
		arguments are allowed to be able to guarantee thread-safety.

		The number of tasks started is guaranteed to be equal to
		`workerThreadCount`.
	*/
	void runTaskDist(FT, ARGS...)(FT func, auto ref ARGS args)
		if (is(typeof(*func) == function))
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		runTaskDist_unsafe(func, args);
	}
	/// ditto
	void runTaskDist(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
	{
		auto func = &__traits(getMember, object, __traits(identifier, method));
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");

		runTaskDist_unsafe(func, args);
	}

	private void runTaskHWrapper(FT, ARGS...)(Task* ret, FT func, ARGS args)
	{
		*ret = runTaskH!(FT, ARGS)(func, args);
	}

	private void runTask_unsafe(CALLABLE, ARGS...)(CALLABLE callable, ref ARGS args)
	{
		import std.traits : ParameterTypeTuple;
		import vibe.internal.traits : areConvertibleTo;
		import vibe.internal.typetuple;

		alias FARGS = ParameterTypeTuple!CALLABLE;
		static assert(areConvertibleTo!(Group!ARGS, Group!FARGS),
			"Cannot convert arguments '"~ARGS.stringof~"' to function arguments '"~FARGS.stringof~"'.");

		m_state.lock.queue.put(callable, args);
		m_signal.emitSingle();
	}

	private void runTaskDist_unsafe(CALLABLE, ARGS...)(ref CALLABLE callable, ARGS args) // NOTE: no ref for args, to disallow non-copyable types!
	{
		import std.traits : ParameterTypeTuple;
		import vibe.internal.traits : areConvertibleTo;
		import vibe.internal.typetuple;

		alias FARGS = ParameterTypeTuple!CALLABLE;
		static assert(areConvertibleTo!(Group!ARGS, Group!FARGS),
			"Cannot convert arguments '"~ARGS.stringof~"' to function arguments '"~FARGS.stringof~"'.");

		{
			auto st = m_state.lock;
			foreach (thr; st.threads) {
				// create one TFI per thread to properly account for elaborate assignment operators/postblit
				thr.m_queue.put(callable, args);
			}
		}
		m_signal.emit();
	}
}

private final class WorkerThread : Thread {
	private {
		shared(TaskPool) m_pool;
		TaskQueue m_queue;
	}

	this(shared(TaskPool) pool)
	{
		m_pool = pool;
		m_queue.setup();
		super(&main);
	}

	private void main()
	nothrow {
		import core.stdc.stdlib : abort;
		import core.exception : InvalidMemoryOperationError;
		import std.encoding : sanitize;

		try {
			if (m_pool.m_state.lock.term) return;
			logDebug("entering worker thread");
			runTask(&handleWorkerTasks);
			logDebug("running event loop");
			if (!m_pool.m_state.lock.term) runEventLoop();
			logDebug("Worker thread exit.");
		} catch (Exception e) {
			scope (failure) abort();
			logFatal("Worker thread terminated due to uncaught exception: %s", e.msg);
			logDebug("Full error: %s", e.toString().sanitize());
		} catch (Throwable th) {
			logFatal("Worker thread terminated due to uncaught error: %s", th.msg);
			logDebug("Full error: %s", th.toString().sanitize());
			abort();
		}
	}

	private void handleWorkerTasks()
	nothrow @safe {
		import std.algorithm.iteration : filter;
		import std.algorithm.mutation : swap;
		import std.algorithm.searching : count;
		import std.array : array;

		logDebug("worker thread enter");
		TaskFuncInfo taskfunc;
		while(true){
			auto emit_count = m_pool.m_signal.emitCount;

			with (m_pool.m_state.lock) {
				logDebug("worker thread check");

				if (term) break;

				if (m_queue.consume(taskfunc)) {
					logDebug("worker thread got specific task");
				} else if (queue.consume(taskfunc)) {
					logDebug("worker thread got specific task");
				}
			}

			if (taskfunc.func !is null)
				.runTask_internal!((ref tfi) { swap(tfi, taskfunc); });
			else emit_count = m_pool.m_signal.waitUninterruptible(emit_count);
		}

		logDebug("worker thread exit");

		if (!m_queue.empty)
			logWarn("Worker thread shuts down with specific worker tasks left in its queue.");

		with (m_pool.m_state.lock) {
			threads = threads.filter!(t => t !is this).array;
			if (threads.length > 0 && !queue.empty)
				logWarn("Worker threads shut down with worker tasks still left in the queue.");
		}

		exitEventLoop();
	}
}

private struct TaskQueue {
nothrow @safe:
	// TODO: avoid use of GC

	import vibe.internal.array : FixedRingBuffer;
	FixedRingBuffer!TaskFuncInfo* m_queue;

	void setup()
	{
		m_queue = new FixedRingBuffer!TaskFuncInfo;
	}

	@property bool empty() const { return m_queue.empty; }

	@property size_t length() const { return m_queue.length; }

	void put(CALLABLE, ARGS...)(ref CALLABLE c, ref ARGS args)
	{
		import std.algorithm.comparison : max;
		if (m_queue.full) m_queue.capacity = max(16, m_queue.capacity * 3 / 2);
		assert(!m_queue.full);

		m_queue.peekDst[0].set(c, args);
		m_queue.putN(1);
	}

	bool consume(ref TaskFuncInfo tfi)
	{
		import std.algorithm.mutation : swap;

		if (m_queue.empty) return false;
		swap(tfi, m_queue.front);
		m_queue.popFront();
		return true;
	}
}
