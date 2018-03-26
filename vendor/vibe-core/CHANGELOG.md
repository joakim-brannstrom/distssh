1.4.1 - 2018-03-
==================

- Fixed compilation errors for `ConnectionPool!TCPConnection` - [issue vibe.d#2109][vibe.d-issue2109], [pull #70][issue70]
- Fixed destruction behavior when destructors are run in foreign threads by the GC - [issue #69][issue69], [pull #74][issue74]
- Fixed a possible assertion failure for failed `connectTCP` calls - [pull #75][issue75]
- Added missing `setCommandLineArgs` API (by Thomas Weyn) - [pull #72][issue72]

[issue69]: https://github.com/vibe-d/vibe-core/issues/69
[issue70]: https://github.com/vibe-d/vibe-core/issues/70
[issue72]: https://github.com/vibe-d/vibe-core/issues/72
[issue74]: https://github.com/vibe-d/vibe-core/issues/74
[issue75]: https://github.com/vibe-d/vibe-core/issues/75
[vibe.d-issue2109]: https://github.com/vibe-d/vibe.d/issues/2109


1.4.0 - 2018-03-08
==================

- Compiles on DMD 2.072.2 up to 2.079.0
- Uses the stdx-allocator package instead of `std.experimental.allocator` - note that this change requires version 0.8.3 of vibe-d to be used
- Added `TCPConnection.waitForDataAsync` to enable temporary detachment of a TCP connection from a fiber (by Francesco Mecca) - [pull #62][issue62]
- Fixed `TCPConnection.leastSize` to return numbers greater than one (by Pavel Chebotarev aka nexor) - [pull #52][issue52]
- Fixed a task scheduling assertion happening when worker tasks and timers were involved - [issue #58][issue58], [pull #60][issue60]
- Fixed a race condition in `TaskPool` leading to random assertion failures - [7703cc6][commit7703cc6]
- Fixed an issue where the event loop would exit prematurely when calling `yield` - [issue #66][issue66], [pull #67][issue67]
- Fixed/worked around a linker error on LDC/macOS - [issue #65][issue65], [pull #68][issue68]

[issue52]: https://github.com/vibe-d/vibe-core/issues/52
[issue58]: https://github.com/vibe-d/vibe-core/issues/58
[issue60]: https://github.com/vibe-d/vibe-core/issues/60
[issue62]: https://github.com/vibe-d/vibe-core/issues/62
[issue65]: https://github.com/vibe-d/vibe-core/issues/65
[issue66]: https://github.com/vibe-d/vibe-core/issues/66
[issue67]: https://github.com/vibe-d/vibe-core/issues/67
[issue68]: https://github.com/vibe-d/vibe-core/issues/68
[commit7703cc6]: https://github.com/vibe-d/vibe-core/commit/7703cc675f5ce56c1c8b4948e3f040453fd09791


1.3.0 - 2017-12-03
==================

- Compiles on DMD 2.071.2 up to 2.077.0
- Added a `timeout` parameter in `connectTCP` (by Boris Baboris) - [pull #44][issue44], [pull #41][issue41]
- Fixes the fiber event scheduling mechanism to not cause any heap allocations - this alone gives a performance boost of around 20% in the bench-dummy-http example - [pull #27][issue27]
- Added `FileInfo.hidden` property
- `pipe()` now returns the actual number of bytes written
- Fixed `TCPListener.bindAddress`
- Fixed a segmentation fault when logging from a non-D thread
- Fixed `setupWorkerThreads` and `workerThreadCount` - [issue #35][issue35]
- Added `TaskPool.threadCount` property
- Added an `interface_index` parameter to `UDPConnection.addMembership`
- `Task.tid` can now be called on a `const(Task)`

[issue27]: https://github.com/vibe-d/vibe-core/issues/27
[issue35]: https://github.com/vibe-d/vibe-core/issues/35
[issue41]: https://github.com/vibe-d/vibe-core/issues/41
[issue44]: https://github.com/vibe-d/vibe-core/issues/44


1.2.0 - 2017-09-05
==================

- Compiles on DMD 2.071.2 up to 2.076.0
- Marked a number of classes as `final` that were accidentally left as overridable
- Un-deprecated `GenericPath.startsWith` due to the different semantics compared to the replacement suggestion
- Added a `listenUDP(ref NetworkAddress)` overload
- Implemented the multicast related methods of `UDPConnection` - [pull #34][issue34]
- `HTMLLogger` now logs the fiber/task ID
- Fixed a deadlock caused by an invalid lock count in `LocalTaskSemaphore` (by Boris-Barboris) - [pull #31][issue31]
- Fixed `FileDescriptorEvent` to adhere to the given event mask
- Fixed `FileDescriptorEvent.wait` in conjunction with a finite timeout
- Fixed the return value of `FileDescriptorEvent.wait`
- Fixed handling of the `periodic` argument to the `@system` overload of `setTimer`

[issue31]: https://github.com/vibe-d/vibe-core/issues/31
[issue34]: https://github.com/vibe-d/vibe-core/issues/34


1.1.1 - 2017-07-20
==================

- Fixed/implemented `TCPListener.stopListening`
- Fixed a crash when using `NullOutputStream` or other class based streams
- Fixed a "dwarfeh(224) fatal error" when the process gets terminated due to an `Error` - [pull #24][issue24]
- Fixed assertion error when `NetworkAddress.to(Address)String` is called with no address set
- Fixed multiple crash and hanging issues with `(Local)ManualEvent` - [pull #26][issue26]

[issue24]: https://github.com/vibe-d/vibe-core/issues/24
[issue26]: https://github.com/vibe-d/vibe-core/issues/26


1.1.0 - 2017-07-16
==================

- Added a new debug hook `setTaskCreationCallback`
- Fixed a compilation error for `VibeIdleCollect`
- Fixed a possible double-free in `ManualEvent` that resulted in an endless loop - [pull #23][issue23]

[issue23]: https://github.com/vibe-d/vibe-core/issues/23


1.0.0 - 2017-07-10
==================

This is the initial release of the `vibe-core` package. The source code was derived from the original `:core` sub package of vibe.d and received a complete work over, mostly under the surface, but also in parts of the API. The changes have been made in a way that is usually backwards compatible from the point of view of an application developer. At the same time, vibe.d 0.8.0 contains a number of forward compatibility declarations, so that switching back and forth between the still existing `vibe-d:core` and `vibe-core` is possible without changing the application code.

To use this package, it is currently necessary to put an explicit dependency with a sub configuration directive in the DUB package recipe:
```
// for dub.sdl:
dependency "vibe-d:core" version="~>0.8.0"
subConfiguration "vibe-d:core" "vibe-core"

// for dub.json:
"dependencies": {
	"vibe-d:core": "~>0.8.0"
},
"subConfigurations": {
	"vibe-d:core": "vibe-core"
}
```
During the development of the 0.8.x branch of vibe.d, the default will eventually be changed, so that `vibe-core` is the default instead.


Major changes
-------------

- The high-level event and task scheduling abstraction has been replaced by the low level Proactor abstraction [eventcore][eventcore], which also means that there is no dependency to libevent anymore.
- GC allocated classes have been replaced by reference counted `struct`s, with their storage backed by a compact array together with event loop specific data.
- `@safe` and `nothrow` have been added throughout the code base, `@nogc` in some parts where no user callbacks are involved.
- The task/fiber scheduling logic has been unified, leading to a major improvement in robustness in case of exceptions or other kinds of interruptions.
- The single `Path` type has been replaced by `PosixPath`, `WindowsPath`, `InetPath` and `NativePath`, where the latter is an alias to either `PosixPath` or `WindowsPath`. This greatly improves the robustness of path handling code, since it is no longer possible to blindly mix different path types (especially file system paths and URI paths).
- Streams (`InputStream`, `OutputStream` etc.) can now also be implemented as `struct`s instead of classes. All API functions accept stream types as generic types now, meaning that allocations and virtual function calls can be eliminated in many cases and function inlining can often work across stream boundaries.
- There is a new `IOMode` parameter for read and write operations that enables a direct translation of operating system provided modes ("write as much as possible in one go" or "write only if possible without blocking").

[eventcore]: https://github.com/vibe-d/eventcore
