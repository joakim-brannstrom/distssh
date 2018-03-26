module eventcore.drivers.winapi.watchers;

version (Windows)  : import eventcore.driver;
import eventcore.drivers.winapi.core;
import eventcore.drivers.winapi.driver : WinAPIEventDriver; // FIXME: this is an ugly dependency
import eventcore.internal.win32;
import std.experimental.allocator : dispose, makeArray, theAllocator;

final class WinAPIEventDriverWatchers : EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
    private {
        WinAPIEventDriverCore m_core;
    }

    this(WinAPIEventDriverCore core) {
        m_core = core;
    }

    override WatcherID watchDirectory(string path, bool recursive, FileChangesCallback callback) {
        import std.utf : toUTF16z;

        auto handle = () @trusted{
            scope (failure)
                assert(false);
            return CreateFileW(path.toUTF16z, FILE_LIST_DIRECTORY,
                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                    null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, null);
        }();

        if (handle == INVALID_HANDLE_VALUE)
            return WatcherID.invalid;

        auto id = WatcherID(cast(size_t) handle);

        auto slot = m_core.setupSlot!WatcherSlot(handle);
        slot.directory = path;
        slot.recursive = recursive;
        slot.callback = callback;
        slot.overlapped.driver = m_core;
        slot.buffer = () @trusted{
            try
                return theAllocator.makeArray!ubyte(16384);
            catch (Exception e)
                assert(false, "Failed to allocate directory watcher buffer.");
        }();
        if (!triggerRead(handle, *slot)) {
            releaseRef(id);
            return WatcherID.invalid;
        }

        // keep alive as long as the overlapped I/O operation is pending
        addRef(id);

        m_core.addWaiter();

        return id;
    }

    override void addRef(WatcherID descriptor) {
        m_core.m_handles[idToHandle(descriptor)].addRef();
    }

    override bool releaseRef(WatcherID descriptor) {
        return doReleaseRef(idToHandle(descriptor));
    }

    protected override void* rawUserData(WatcherID descriptor, size_t size,
            DataInitializer initialize, DataInitializer destroy) @system {
        return m_core.rawUserDataImpl(idToHandle(descriptor), size, initialize, destroy);
    }

    private static bool doReleaseRef(HANDLE handle) {
        auto core = WinAPIEventDriver.threadInstance.core;
        auto slot = () @trusted{ return &core.m_handles[handle]; }();

        if (!slot.releaseRef(()nothrow{
                CloseHandle(handle);

                ()@trusted{
                    try
                        theAllocator.dispose(slot.watcher.buffer);
                    catch (Exception e)
                        assert(false, "Freeing directory watcher buffer failed.");
                }();
                slot.watcher.buffer = null;
                core.discardEvents(&slot.watcher.overlapped);
                core.freeSlot(handle);
            })) {
            return false;
        }

        // If only one reference left, then this is the reference created for
        // the current wait operation. Simply cancel the I/O to let the
        // completion callback
        if (slot.refCount == 1) {
            () @trusted{
                CancelIoEx(handle, &slot.watcher.overlapped.overlapped);
            }();
            slot.watcher.callback = null;
            core.removeWaiter();
        }

        return true;
    }

    private static nothrow void onIOCompleted(DWORD dwError, DWORD cbTransferred,
            OVERLAPPED_CORE* overlapped) {
        import std.conv : to;
        import std.file : isDir;
        import std.path : dirName, baseName, buildPath;

        auto handle = overlapped.hEvent; // *file* handle
        auto id = WatcherID(cast(size_t) handle);

        auto gslot = () @trusted{
            return &WinAPIEventDriver.threadInstance.core.m_handles[handle];
        }();
        auto slot = () @trusted{ return &gslot.watcher(); }();

        if (dwError != 0 || gslot.refCount == 1) {
            // FIXME: error must be propagated to the caller (except for ABORTED
            // errors)
            //logWarn("Failed to read directory changes: %s", dwError);
            doReleaseRef(handle);
            return;
        }

        if (!slot.callback)
            return;

        // NOTE: cbTransferred can be 0 if the buffer overflowed
        ubyte[] result = slot.buffer[0 .. cbTransferred];
        while (result.length) {
            assert(result.length >= FILE_NOTIFY_INFORMATION._FileName.offsetof);
            auto fni = () @trusted{
                return cast(FILE_NOTIFY_INFORMATION*) result.ptr;
            }();
            if (fni.NextEntryOffset > result.length) {
                import std.stdio : stderr;

                () @trusted{
                    try
                        stderr.writeln("ERROR: Invalid directory watcher event received.");
                    catch (Exception e) {
                    }
                }();
                break;
            }
            result = result[fni.NextEntryOffset .. $];

            FileChange ch;
            switch (fni.Action) {
            default:
                ch.kind = FileChangeKind.modified;
                break;
            case 0x1:
                ch.kind = FileChangeKind.added;
                break;
            case 0x2:
                ch.kind = FileChangeKind.removed;
                break;
            case 0x3:
                ch.kind = FileChangeKind.modified;
                break;
            case 0x4:
                ch.kind = FileChangeKind.removed;
                break;
            case 0x5:
                ch.kind = FileChangeKind.added;
                break;
            }

            ch.baseDirectory = slot.directory;
            auto path = () @trusted{
                scope (failure)
                    assert(false);
                return to!string(fni.FileName[0 .. fni.FileNameLength / 2]);
            }();
            auto fullpath = buildPath(slot.directory, path);
            ch.directory = dirName(path);
            if (ch.directory == ".")
                ch.directory = "";
            ch.name = baseName(path);
            try
                ch.isDirectory = isDir(fullpath);
            catch (Exception e) {
            } // FIXME: can happen if the base path is relative and the CWD has changed
            if (ch.kind != FileChangeKind.modified || !ch.isDirectory)
                slot.callback(id, ch);
            if (fni.NextEntryOffset == 0 || !slot.callback)
                break;
        }

        if (slot.callback)
            triggerRead(handle, *slot);
        else if (gslot.refCount == 1)
            doReleaseRef(handle);
    }

    private static bool triggerRead(HANDLE handle, ref WatcherSlot slot) {
        enum UINT notifications = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME
                | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE;

        slot.overlapped.Internal = 0;
        slot.overlapped.InternalHigh = 0;
        slot.overlapped.Offset = 0;
        slot.overlapped.OffsetHigh = 0;
        slot.overlapped.hEvent = handle;

        BOOL ret;
        auto handler = &overlappedIOHandler!onIOCompleted;
        () @trusted{
            ret = ReadDirectoryChangesW(handle, slot.buffer.ptr, cast(DWORD) slot.buffer.length,
                    slot.recursive, notifications, null, &slot.overlapped.overlapped, handler);
        }();

        if (!ret) {
            //logError("Failed to read directory changes in '%s'", m_path);
            return false;
        }

        return true;
    }

    static private HANDLE idToHandle(WatcherID id) @trusted {
        return cast(HANDLE) cast(size_t) id;
    }
}
