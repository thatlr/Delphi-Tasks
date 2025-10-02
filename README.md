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


## Implementation concept:

The heart of each thread pool is a thread-safe queue for task objects. The application adds tasks to the queue. Threads are created automatically to drain the queue. Idle threads terminate after a configurable timeout. There are parameters to control the three main aspects of this model:
- Maximum number of threads allowd to be started by the specific thread pool
- Maximum idle time per thread
- Maximum number of tasks waiting to be served

To enable non-GUI threads to delegate calls to the GUI thread, a Windows messaage hook is used. This has the advantage that the processing is not blocked by non-Delphi modal message loops, neither by the standard Windows message box nor by moving or resizing a window.

There is *no* heuristic to "tune" the thread pool(s): It is up to the application to perform "correct" threading for its use-case. If your tasks are CPU-bound, then put them all in a specfic thread pool, sized to run only as much threads in parallel as desired. If your tasks are I/O-bound (like print spooling or network communication, for example), just use the default thread pool.

Also note that Windows only schedules threads within a single, static group of CPU cores, assigned to the process at process startup. (https://docs.microsoft.com/en-us/windows/win32/procthread/processor-groups)

## Notes:

### Shutdown behavior

When TThreadPool.Destroy is invoked, the teardown is done as follows:

First, the thread pool is immediately locked against queuing of new tasks. This is crucial because tasks already
executing within the pool might attempt to enqueue follow-up tasks. While TThreadPool.Queue() calls will still
succeed, any task created is immediately terminated with the status TTaskStatus.Discarded.

Second, Destroy() waits —without timeout— for all tasks associated with the thread pool to finish. This includes
both queued and currently executing tasks. Importantly, it does not cancel any tasks; it simply blocks until all are done.

Third, as there are now no outstanding tasks and no active threads, the actual destruction is executed. 

Important Considerations:

The application must ensure that all outstanding tasks will complete in a timely manner. Typically, this involves
sending cancellation signals and designing the task functions to respond to them appropriately.

Shared variables holding a TThreadPool reference must not be set to nil too soon. As noted above, tasks may rely on such a
shared variable to enqueue additional work to the same thread pool. In such case, FreeAndNil() cannot be used because it sets
the variable to nil *before* calling Destroy(), potentially breaking the tasks that still depend on it.

(In general, instead of FreaAndNil you should use an alternative procedure which first calls destroy and then set the variable
to nil, as this is also more correct in other scenarios.)

### Unit finalization

As always with methods that are used as callbacks (in this case: as task methods), you have to pay attention to the details of unit finalization in Delphi.
For example, if you have a task that is performing a method from Unit B, and then code in the finalization section of Unit A is stopping that task, it is very possible
that the finalization of unit B was carried out before the task reacts to the cancellation and finally ends.

If this task assigns values to managed global variables (or "class variables") in unit B, these values (most commonly: strings) may never be cleaned up,
since the cleanup of B's global variables is part of the unit finalization, which may have already been completed.
Such errors lead to mysterious memory leaks.

### Thread-Safety: General considerations

The main concept to write thread-safe code is "ownership": In general, accessing variables or accessing properties or calling methods of Delphi objects not owned by the current thread is not safe (when not explicitly documented otherwise).

At all times, you must make sure that a thread (a) only interacts with data (variables, objects, ...) that this thread is owning exclusively; or (b) uses serialization to access data shared between multiple threads. This serialization must be done by using explicit locks, like critical sections or reader-writer locks.
Of course, there is no need for serialization when the variable is guaranteed to be stable at all times other threads may read it.

Reads and writes of variables with a size greater than 32 bit in a 32 bit process (respective 64 bit in a 64 bit process) are not atomic and therefore need also locks. (Otherwise, a mix of the old and the new bytes may be read if the value is written by another thread at the very same time.)

Shared access to variables of reference-counted Delphi types (strings, interfaces, dynamic arrays) must be serialized with locks, even thought the ref-counting itself *is* thread-safe and multiple threads can safely use references to the very same string, interfaced object or dynamic array. This also applies to variables of type Variant/OleVariant, as such a variable can contain ref-counted values, or even custom Variant types.

### Thread-Safety: Delphi RTL

Many stand-alone functions and procedures in the Delphi Runtime Library are thread-safe, as they do not access global variables. But as this not described in the documentation, it is always better to check the RTL source code to verify this assumption.

Some functions do read global variables, but it depends on the application, if this is a problem or not. For example, SysUtils.Format() without the explicit FormatSettings parameter uses the global variable SysUtils.FormatSettings. If the global regional settings never change, or if changes of this settings are not influencing the background processing, then this is not a problem. But to play it safe, the best aproach in this example is to always pass an explicit TFormatSettings variable with the expected content to functions that accept such argument.

### Thread-Safety: Delphi VCL

As the VCL is not thread-safe, tasks must not access VCL components directly, not even properties or methods of the global variables Application, Screen, Clipboard or Printer.

All reads and writes of VCL properties, as also calls of VCL methods must be done inside a procedure that is passed to TGuiThread.Perform(). Perform() then posts a special message to the GUI thread and waits for its processing. When the GUI thread some time later retrieves this message from its message queue, it will execute the procedure passed to Perform(). After the GUI thread has finished executing the procedure (normally or per exception), it wakes up the task waiting inside Perform(). This mechanism enables tasks to safely interact with all the VCL objects and therefore to update the GUI.

### Interaction of tasks with the GUI

Please read: Code vs. UI modality: https://devblogs.microsoft.com/oldnewthing/tag/modality (especially part 2 & 4)

When TGuiThread.Perform() is called to execute an action on the GUI thread, that action could display modal dialogs. A (code) modal dialog naturally executes a message loop that is supposed to terminate when the dialog is closed. Such a message loop allows all kinds of window messages to be dispatched, including messages for the modal dialog's parent window or for other non-modal dialogs that the appliation may display.

To avoid reentrancy problems, a modal dialog must disable *all* other dialogs. Otherwise the application might run code for already destroyed GUI objects (see the explanation in the Old New Thing posts).

However, this must *always* be taken into account when displaying a modal dialog, not just in the context of tasks.

## Open issues:

Some sensible demo code.

## Tested with:

- Delphi 2009
- Delphi XE
- Delphi 10.1.2 Berlin: 32bit and 64bit
- Delphi 12.1 Athens: 32bit and 64bit
