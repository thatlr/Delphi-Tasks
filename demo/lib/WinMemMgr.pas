unit WinMemMgr;

{
  Replacement for the built-in Memory Manager, as it tends to fragment (at least before D2009 / FastMM).

  Note:

  Releasing memory is much slower under the debugger as without being debugged, as Windows performs additional sanity
  checks which slow down especially HeapFree. If not desirable, the environment variable _NO_DEBUG_HEAP can be set to
  turn this off.


  **************************************************************************************************
  *** This unit must be the first in the uses clause in the Project file (.dpr) (before MemTest) ***
  **************************************************************************************************

  Manifest clause to use the new ("better") segment heap since Windows 10, version 2004 (build 19041):
  https://docs.microsoft.com/en-us/windows/win32/sbscs/application-manifests#heaptype

  <asmv3:application>
	<asmv3:windowsSettings xmlns="http://schemas.microsoft.com/SMI/2020/WindowsSettings">
	  <heapType>SegmentHeap</heapType>
	</asmv3:windowsSettings>
  </asmv3:application>


  As of "C:\Program Files (x86)\Microsoft Visual Studio 10.0\VC\crt\src\malloc.c" (and many older versions), the
  Windows Heap allocator is used by the Microsoft C/C++ runtime for malloc/free. Therefore, it is one of the most
  used implementations. Also, it features "low-fragmentation" as default since Windows Vista.
  By using it also from Delphi, the number of alloctors that use (and therefore fragment) the address space is lower
  than with the delphi-specific default implementation.

  https://docs.microsoft.com/en-us/windows/win32/memory/low-fragmentation-heap
  https://devblogs.microsoft.com/oldnewthing/20130103-00/?p=5653

  >>
  When a program is running under the debugger, some parts of the system behave differently. One example is that the
  Close­Handle function raises an exception (I believe it’s STATUS_INVALID_HANDLE but don’t quote me) if you ask it
  to close a handle that isn’t open. But the one that catches most people is that when run under the debugger, an
  alternate heap is used. This alternate heap has a different memory layout, and it does extra work when allocating
  and freeing memory to help try to catch common heap errors, like filling newly-allocated memory with a known sentinel
  value.
  <<
}


{$undef LIB_DEBUG}

{$include LibOptions.inc}

{$LongStrings off}
{$Optimization on}
{$Overflowchecks off}
{$Rangechecks off}

interface

function HeapValidate: boolean;


{############################################################################}
implementation
{############################################################################}

uses Windows;

type
  // since Delphi XE2, the core MemoryManager functions have a different signature:
  _NativeInt = {$ifdef DelphiXE2} NativeInt {$else} integer {$endif};
  _NativeUInt = {$ifdef DelphiXE2} NativeUInt {$else} cardinal {$endif};

{$if not declared(HEAP_ZERO_MEMORY)}
const
  HEAP_ZERO_MEMORY                = $00000008;
{$ifend}

var
  hHeap: THandle = 0;


 //===================================================================================================================
 // Returns false if the heap contains some structural error.
 // "If the specified heap or memory block is invalid, the return value is zero. On a system set up for debugging, the
 // HeapValidate function then displays debugging messages that describe the part of the heap or memory block that is
 // invalid, and stops at a hard-coded breakpoint so that you can examine the system to determine the source of the
 // invalidity.
 // There is no extended error information for this function; do not call GetLastError."
 //===================================================================================================================
function HeapValidate: boolean;
begin
  Result := Windows.HeapValidate(hHeap, 0, nil);
end;


 //===================================================================================================================
 // Allocates the given number of bytes and returns a pointer to the newly allocated block. The Size parameter passed
 // to the GetMem function will never be zero. If the GetMem function cannot allocate a block of the given size, it
 // should return nil.
 //===================================================================================================================
function HeapGetMem(Size: _NativeInt): Pointer;
begin
  Result := Windows.HeapAlloc(hHeap, 0, Size);
end;


 //===================================================================================================================
 // Deallocates the given block. The pointer parameter passed to the FreeMem function will never be nil. If the
 // FreeMem function successfully deallocates the given block, it should return zero. Otherwise, it should return
 // a non-zero value.
 //===================================================================================================================
function HeapFreeMem(Ptr: Pointer): Integer;
begin
  if Windows.HeapFree(hHeap, 0, Ptr) then
	Result := 0
  else
	Result := 1;
end;


 //===================================================================================================================
 // Reallocates the given block to the given new size. The pointer parameter passed to the ReallocMem function will
 // never be nil, and the Size parameter will never be zero.
 // The ReallocMem function must reallocate the given block to the given new size, possibly moving the block if it
 // cannot be resized in place. Any existing contents of the block must be preserved, but newly allocated space can
 // be uninitialized. The ReallocMem function must return a pointer to the reallocated block, or nil if the block
 // cannot be reallocated.
 //===================================================================================================================
function HeapReallocMem(Ptr: Pointer; Size: _NativeInt): Pointer;
begin
  Result := Windows.HeapRealloc(hHeap, 0, Ptr, Size);
end;


 //===================================================================================================================
 // Allocates a zero-initialized block of memory.
 //===================================================================================================================
function HeapAllocMem(Size: {$ifdef DelphiXE2}_NativeInt{$else}_NativeUInt{$endif}): Pointer;
begin
  Result := Windows.HeapAlloc(hHeap, HEAP_ZERO_MEMORY, Size);
end;


 //===================================================================================================================
 //===================================================================================================================
function Dummy(P: Pointer): Boolean;
begin
  Result := False;
end;


 //===================================================================================================================
 // Replace the existing Memory Manager.
 //===================================================================================================================
procedure Install;

  function NoMemoryAllocated: boolean;
  var
	State: TMemoryManagerState;
  begin
	// no memory must be allocated at this point:
	GetMemoryManagerState(State);
	Result := (State.AllocatedMediumBlockCount = 0) and (State.AllocatedLargeBlockCount = 0);
  end;

const
  MemMgr: TMemoryManagerEx = (
	GetMem: HeapGetMem;
	FreeMem: HeapFreeMem;
	ReallocMem: HeapReallocMem;
	AllocMem: HeapAllocMem;
	RegisterExpectedMemoryLeak: Dummy;
	UnregisterExpectedMemoryLeak: Dummy;
  );
begin
  Assert(NoMemoryAllocated, 'Memory already allocated');

  hHeap := Windows.GetProcessHeap();
  Assert(hHeap <> 0);

  SetMemoryManager(MemMgr);
end;


{$if not declared(SetDllDirectory)}
//WinBase.h:
function SetDllDirectory(lpPathName: PChar): BOOL; stdcall;
  external Windows.kernel32 name {$ifdef UNICODE}'SetDllDirectoryW'{$else}'SetDllDirectoryA'{$endif};
{$ifend}


initialization
  // For a little additional security and performance, remove the current working directory of the process from the
  // search path for DLLs (effective for DLLs that are loaded after this point only).
  // Argument values:
  // - Pathname: Replaces the CWD in the Search Path with <Pathname>
  // - Empty string: Removes the CWD from the Search Path
  // - NULL: Restores the default search order
  SetDllDirectory('');

  Install;
end.
