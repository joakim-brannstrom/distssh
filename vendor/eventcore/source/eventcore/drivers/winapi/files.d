module eventcore.drivers.winapi.files;

version (Windows)  : import eventcore.driver;
import eventcore.drivers.winapi.core;
import eventcore.internal.win32;

private extern (Windows) @trusted nothrow @nogc {
    BOOL SetEndOfFile(HANDLE hFile);
}

final class WinAPIEventDriverFiles : EventDriverFiles {
@safe /*@nogc*/ nothrow:
    private {
        WinAPIEventDriverCore m_core;
    }

    this(WinAPIEventDriverCore core) {
        m_core = core;
    }

    override FileFD open(string path, FileOpenMode mode) {
        import std.utf : toUTF16z;

        auto access = mode == FileOpenMode.readWrite || mode == FileOpenMode.createTrunc
            ? (GENERIC_WRITE | GENERIC_READ) : mode == FileOpenMode.append
            ? GENERIC_WRITE : GENERIC_READ;
        auto shareMode = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
        auto creation = mode == FileOpenMode.createTrunc ? CREATE_ALWAYS
            : mode == FileOpenMode.append ? OPEN_ALWAYS : OPEN_EXISTING;

        auto handle = () @trusted{
            scope (failure)
                assert(false);
            return CreateFileW(path.toUTF16z, access, shareMode, null,
                    creation, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, null);
        }();
        auto errorcode = GetLastError();
        if (handle == INVALID_HANDLE_VALUE)
            return FileFD.invalid;

        if (mode == FileOpenMode.createTrunc && errorcode == ERROR_ALREADY_EXISTS) {
            BOOL ret = SetEndOfFile(handle);
            if (!ret) {
                CloseHandle(handle);
                return FileFD.invalid;
            }
        }

        return adoptInternal(handle);
    }

    override FileFD adopt(int system_handle) {
        return adoptInternal(() @trusted{ return cast(HANDLE) system_handle; }());
    }

    private FileFD adoptInternal(HANDLE handle) {
        DWORD f;
        if (!()@trusted{ return GetHandleInformation(handle, &f); }())
            return FileFD.invalid;

        auto s = m_core.setupSlot!FileSlot(handle);

        s.read.overlapped.driver = m_core;
        s.read.overlapped.hEvent = handle;
        s.write.overlapped.driver = m_core;
        s.write.overlapped.hEvent = handle;

        return FileFD(cast(size_t) handle);
    }

    override void close(FileFD file) {
        auto h = idToHandle(file);
        auto slot = () @trusted{ return &m_core.m_handles[h].file(); }();
        if (slot.read.overlapped.hEvent != INVALID_HANDLE_VALUE)
            slot.read.overlapped.hEvent = slot.write.overlapped.hEvent = INVALID_HANDLE_VALUE;
    }

    override ulong getSize(FileFD file) {
        LARGE_INTEGER size;
        auto succeeded = () @trusted{
            return GetFileSizeEx(idToHandle(file), &size);
        }();
        if (!succeeded || size.QuadPart < 0)
            return ulong.max;
        return size.QuadPart;
    }

    override void write(FileFD file, ulong offset, const(ubyte)[] buffer,
            IOMode mode, FileIOCallback on_write_finish) {
        auto h = idToHandle(file);
        auto slot = &m_core.m_handles[h].file.write;

        if (slot.overlapped.hEvent == INVALID_HANDLE_VALUE) {
            on_write_finish(file, IOStatus.disconnected, 0);
            return;
        }

        if (!buffer.length) {
            on_write_finish(file, IOStatus.ok, 0);
            return;
        }

        slot.bytesTransferred = 0;
        slot.offset = offset;
        slot.buffer = buffer;
        slot.mode = mode;
        slot.callback = on_write_finish;
        m_core.addWaiter();
        startIO!(WriteFileEx, true)(h, slot);
    }

    override void read(FileFD file, ulong offset, ubyte[] buffer, IOMode mode,
            FileIOCallback on_read_finish) {
        auto h = idToHandle(file);
        auto slot = &m_core.m_handles[h].file.read;

        if (slot.overlapped.hEvent == INVALID_HANDLE_VALUE) {
            on_read_finish(file, IOStatus.disconnected, 0);
            return;
        }

        if (!buffer.length) {
            on_read_finish(file, IOStatus.ok, 0);
            return;
        }

        slot.bytesTransferred = 0;
        slot.offset = offset;
        slot.buffer = buffer;
        slot.mode = mode;
        slot.callback = on_read_finish;
        m_core.addWaiter();
        startIO!(ReadFileEx, false)(h, slot);
    }

    override void cancelWrite(FileFD file) {
        auto h = idToHandle(file);
        cancelIO!true(h, m_core.m_handles[h].file.write);
    }

    override void cancelRead(FileFD file) {
        auto h = idToHandle(file);
        cancelIO!false(h, m_core.m_handles[h].file.read);
    }

    override void addRef(FileFD descriptor) {
        m_core.m_handles[idToHandle(descriptor)].addRef();
    }

    override bool releaseRef(FileFD descriptor) {
        auto h = idToHandle(descriptor);
        auto slot = &m_core.m_handles[h];
        return slot.releaseRef({
            CloseHandle(h);
            m_core.discardEvents(&slot.file.read.overlapped, &slot.file.write.overlapped);
            m_core.freeSlot(h);
        });
    }

    protected override void* rawUserData(FileFD descriptor, size_t size,
            DataInitializer initialize, DataInitializer destroy) @system {
        return m_core.rawUserDataImpl(idToHandle(descriptor), size, initialize, destroy);
    }

    private static void startIO(alias fun, bool RO)(HANDLE h, FileSlot.Direction!RO* slot) {
        import std.algorithm.comparison : min;

        with (slot.overlapped.overlapped) {
            Internal = 0;
            InternalHigh = 0;
            Offset = cast(uint)(slot.offset & 0xFFFFFFFF);
            OffsetHigh = cast(uint)(slot.offset >> 32);
            hEvent = h;
        }

        auto nbytes = min(slot.buffer.length, DWORD.max);
        auto handler = &overlappedIOHandler!(onIOFinished!(fun, RO));
        if (!()@trusted{
                return fun(h, &slot.buffer[0], nbytes, &slot.overlapped.overlapped, handler);
            }()) {
            slot.overlapped.driver.removeWaiter();
            slot.invokeCallback(IOStatus.error, slot.bytesTransferred);
        }
    }

    private void cancelIO(bool RO)(HANDLE h, ref FileSlot.Direction!RO slot) {
        if (slot.callback) {
            m_core.removeWaiter();
            () @trusted{ CancelIoEx(h, &slot.overlapped.overlapped); }();
            slot.callback = null;
            slot.buffer = null;
        }
    }

    private static nothrow void onIOFinished(alias fun, bool RO)(DWORD error,
            DWORD bytes_transferred, OVERLAPPED_CORE* overlapped) {
        FileFD id = cast(FileFD) cast(size_t) overlapped.hEvent;
        auto handle = idToHandle(id);
        static if (RO)
            auto slot = () @trusted{
                return &overlapped.driver.m_handles[handle].file.write;
            }();
        else
            auto slot = () @trusted{
                return &overlapped.driver.m_handles[handle].file.read;
            }();
        assert(slot !is null);

        if (!slot.callback) {
            // request was already cancelled
            return;
        }

        if (error != 0) {
            overlapped.driver.removeWaiter();
            slot.invokeCallback(IOStatus.error, slot.bytesTransferred + bytes_transferred);
            return;
        }

        slot.bytesTransferred += bytes_transferred;
        slot.offset += bytes_transferred;

        if (slot.bytesTransferred >= slot.buffer.length || slot.mode != IOMode.all) {
            overlapped.driver.removeWaiter();
            slot.invokeCallback(IOStatus.ok, slot.bytesTransferred);
        } else {
            startIO!(fun, RO)(handle, slot);
        }
    }

    private static HANDLE idToHandle(FileFD id) @trusted {
        return cast(HANDLE) cast(size_t) id;
    }
}
