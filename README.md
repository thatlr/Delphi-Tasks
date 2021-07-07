# Delphi-Tasks
 Small and simple: Thread Pools with Tasks

I needed some better constructs than what was available in Delphi 2009, to be more productive with one of my major programs (this runs as a critical service 7x24, with hundreds of threads, but also short-living parallel activities to manage timeouts and some monitoring).
I felt that I needed somthing better than Delphi's TThread class, that is, a better way of handling threads by a built-in and safe way to start tasks, wait for completion of tasks, as also to cancel a task.
As for keeping the implementation as small and fast as possible, this is relying on pre-existing Windows constructs all the way (Slim RW Locks, Condition Variables, Events).

## Available objects (see Tasks.pas):

* ITask: Reference to an action passed to a thread pool for asynchronous execution.

* ICancel: Reference to an object that serves as an cancellation flag.

* TThreadPool: Implements a configurable thread pool and provides a default thread pool. You can create any number of thread pools.

* TGuiThread: Allows any thread to inject calls into the GUI thread.


## Implemention concept:

The heart of each thread pool is a thread-safe queue for task objects. The application adds tasks to the queue. Threads are created automatically to drain the queue. Idle threads terminate after a configurable timeout. There are parameters to control the three main aspects of this model: Maximum number of threads, Maximum idle time per thread, Maximum number of tasks waiting to be served.

To enable non-GUI threads to delegate calls to the GUI thread, a Windows messaage hook is used. This has the advantage that the processing is not blocked by non-Delphi modal message loops, neither by the standard Windows message box nor by moving or resizing a window.

There is *no* heuristic to "tune" the thread pool(s): It is up to the application to perform "correct" threading for its use-case. If your tasks are CPU-bound, then put them all in a specfic thread pool, sized to run only as much threads in parallel as desired. If your tasks are I/O-bound (like print spooling or network communication, for example), just use the default thread pool.

Also note that Windows only schedules threads within a single, static group of CPU cores, assigned to the process at process startup. (https://docs.microsoft.com/en-us/windows/win32/procthread/processor-groups)

## Notes:

As always with methods that are used as callbacks (in this case: as task methods), you have to pay attention to the details of unit finalization in Delphi.
For example, if you have a task that is performing a method from Unit B, and then code in the finalization section of Unit A is stopping that task, it is very possible
that the finalization of unit B was carried out before the task reacts to the cancellation and finally ends.
If this task assigns values to managed global variables (or "class variables") in unit B, these values (most commonly: strings) may never be cleaned up,
since the cleanup of B's global variables is part of the unit finalization, which may have already been completed.
Such errors lead to mysterious memory leaks.

Tested with:
- Delphi 2009
- Delphi 10.1.2 Berlin: 32bit and 64bit

## Open issues:

Some sensible demo code.
