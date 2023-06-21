unit MemTest;

{
  This unit can be integrated into programs to verify correct memory management. From the point of view of the program,
  only the speed is adversely affected and more memory is used. If the application attempts to call FreeMem or
  ReallocMem with an invalid pointer, an error is written to the console window (if any) or to a trace file, and the
  process terminates without the call returning.

  The complete functionality is controlled by the precompiler symbol MEMTEST_ACTIVE:
  - MEMTEST_ACTIVE is undefined (Release builds): Memory allocations are not intercepted in any way.
  - MEMTEST_ACTIVE is defined (Debug builds): Leak and corruption detection is activated.

  The unit must appear in the .dpr file as the first unit in the uses clause (or directly after WinMemMgr or any other
  memory manager replacement, if that is used).


  * Delphi memory allocations:

  Each allocated memory block is transparently expanded by a test area at the top and bottom. In addition, before each
  release and after each allocation, the respective memory area is filled with $FE bytes, to prevent application code
  from relying on already-free'd memory. Also, all allocated memory blocks are kept in a doubly-linked list, in order
  to detect all attempts on releasing invalid memory (garbage pointers or already free'd pointers).


  * COM memory allocations:

  Memory allocations made be the COM runtime are monitored via a singleton object implementing IMallocSpy
  (https://docs.microsoft.com/en-us/windows/win32/api/objidl/nn-objidl-imallocspy). The allocation is instrumented as
  for Delphi memory.
  As some COM memory is allocated by some Windows components and not release before ExitProcess unloads the respective
  DLLs, automatic memory leak detection is not possible.

  Note, that COM memory is used for WideString instances!


  In D2009, TReader.ReadPropValue() contains
	tkUString:
	  SetUnicodeStrProp(Instance, PropInfo, ReadWideString);
  which wrongly forces WideStrings to be created (using COM memory!), only to be converted to UnicodeStrings immediately
  thereafter. Which happens when .dfm files are loaded.
}

{$include LibOptions.inc}

{$ifdef MEMTEST_DEBUG}
  {$DebugInfo on}
  {$OverflowChecks on}
  {$RangeChecks on}
{$else}
  {$DebugInfo off}
  {$OverflowChecks off}
  {$RangeChecks off}
{$endif}


{$LongStrings off}		// <=== !!!!!!!!

{$warn SYMBOL_PLATFORM off}

interface

// - Do not use any other units!
// - Do not use long strings!
// - Do not use "try"!

type
  // since Delphi XE2, the core MemoryManager functions have a different signature:
  _NativeInt = {$ifdef DelphiXE2} NativeInt {$else} integer {$endif};
  _NativeUInt = {$ifdef DelphiXE2} NativeUInt {$else} cardinal {$endif};

  TMyMemStat = record
	Title: PAnsiChar;

	ExpectedMemInbalance: _NativeUInt;		// Memory that is expected to be not released at the end of the program
	AllocMemSize: _NativeUInt;				// currently allocated bytes (without the added overhead)
	AllocMemBlocks: _NativeUInt;			// currently allocated blocks
	MaxAllocMemSize: _NativeUInt;			// previous maximum value of AllocMemSize

	AllocBreakAddr: pointer;				// triggers debug-break if this address is returned by GetMem or Realloc
	FreeBreakAddr: pointer;					// triggers debug-break stop if this address is passed to Free or Realloc

	AllocBreakSize: _NativeUInt;			// triggers debug-break stop when this memory size is returned by GetMem or Realloc
	FreeBreakSize: _NativeUInt;				// triggers debug-break stop when this memory size is passed to Free or Realloc
  end;

var
  // Data on Delphi memory allocation:
  DelphiMemStats: TMyMemStat = (
	Title: '*** Delphi Memory:';
	AllocBreakSize: High(_NativeUInt);
	FreeBreakSize: High(_NativeUInt);
  );

  // Data on memory allocation via Windows COM functions:
  ComMemStats: TMyMemStat = (
	Title: '*** COM Memory:';
	AllocBreakSize: High(_NativeUInt);
	FreeBreakSize: High(_NativeUInt);
  );

  // as to whether a debug-break should be triggered in the event of alloc errors (e.g. out of memory) in GetMem or
  // ReallocMem:
  MyBreakOnAllocationError: boolean;


procedure DumpAllocatedBlocks(const Filename: string; WithHexDump: boolean = true);
function IsMemoryValid: boolean;


{############################################################################}
implementation
{############################################################################}

{$ifdef MEMTEST_ACTIVE}

uses Windows, WinSlimLock;

//==================================================================================================================================
//== Functions for outputting trace information
//==================================================================================================================================

const
  CrLf = #13#10;
  MyAllocFillByte = $FE;	// freshly allocated memory is filled with this value
  MyFreeFillByte = $FD;		// released memory is overwritten with this value

  FILE_APPEND_DATA = $0004;	// Flag for CreateFile(): If the only bit in the DesiredAccess parameter, then writing is
							// always done at the current end-of-file

  NativeIntHexDigits = sizeof(_NativeInt) * 2;

type
  THexStr = string[NativeIntHexDigits];		// use ShortString (without dynamic memory)


 //===================================================================================================================
 // Returns hex char for <b> (0..15).
 //===================================================================================================================
function Digit(b: byte): AnsiChar;
begin
  if b < 10 then Result := AnsiChar(Byte('0') + b)
  else Result := AnsiChar(Byte('a') - 10 + b)
end;


 //===================================================================================================================
 // Returns hex string with 4 or 8 digits.
 //===================================================================================================================
function NUIntToHex(v: _NativeUInt): THexStr;
var
  i: integer;
begin
  System.SetLength(Result, NativeIntHexDigits);
  for i := NativeIntHexDigits downto 1 do begin
	Result[i] := Digit(v and $0F);
	v := v shr 4;
  end;
end;


 //===================================================================================================================
 // Returns hex string with 4 or 8 digits.
 //===================================================================================================================
function PtrToHex(p: pointer): THexStr; inline;
begin
  Result := NUIntToHex(_NativeUInt(p));
end;


 //===================================================================================================================
 // Returns decimal string.
 //===================================================================================================================
function NUIntToStr(v: _NativeUInt): ShortString;
const
  Digits = 20;
var
  i: integer;
begin
  System.SetLength(Result, Digits);
  i := Digits;
  while i >= 1 do begin
	Result[i] := Digit(v mod 10);
	dec(i);
	v := v div 10;
	if v = 0 then break;
  end;
  Result := System.Copy(Result, i + 1, 255);
end;


 //===================================================================================================================
 // Returns concatination of all elements of <Strs>. The result is always null-terminated after the last character
 // (=> Result is limited to 254 characters).
 //===================================================================================================================
procedure ShortConcat(var Result: ShortString; const Strs: array of ShortString);
var
  i: integer;
  j: integer;
  Dst: PAnsiChar;
begin
  Dst := @Result[1];

  for i := System.Low(Strs) to System.High(Strs) do begin
	for j := 1 to System.Length(Strs[i]) do begin
	  if Dst >= @Result[255] then break;
	  Dst^ := Strs[i][j];
	  inc(Dst);
	end;
  end;

  Dst^ := #0;

  System.SetLength(Result, Dst - @Result[1]);
end;


 //===================================================================================================================
 // Writes all of <Strs> in one write operation to <hFile>.
 //===================================================================================================================
procedure WriteStrToFile(hFile: THandle; const Strs: array of ShortString);
var
  Buf: ShortString;
  BytesWritten: DWORD;
begin
  ShortConcat(Buf, Strs);
  Windows.WriteFile(hFile, Buf[1], System.Length(Buf), BytesWritten, nil);
end;


 //===================================================================================================================
 // Writes <bufsize> bytes from <buf> as lines with the format
 //   "  00000010 03 92 05 00 94 29 14 00 4C 00 52 00 34 00 38 00  .....)..L.R.4.8."
 // to <hFile>:
 // The hex address in the output begins with the value <offset>.
 // bufsize = 0 does not write anything.
 //===================================================================================================================
procedure WriteHexDump(hFile: THandle; buf: pointer; bufsize: _NativeUInt);
const
  LLen = 16;	// bytes per dump line
var
  offset: _NativeUInt;
  hidx: integer;
  sidx: integer;
  p: PByte;
  b: byte;
  OffsetStr: THexStr;
  HexStr: string[LLen * 3];
  Str: string[LLen];
begin
  p := buf;
  offset := _NativeUInt(buf);

  System.SetLength(HexStr, LLen * 3);
  System.SetLength(Str, LLen);

  hidx := 0;
  sidx := 0;
  while bufsize > 0 do begin
	if sidx = 0 then begin
	  OffsetStr := NUIntToHex(offset);
	  FillChar(Str[1], sizeof(Str) - sizeof(Str[0]), ' ');
	  FillChar(HexStr[1], sizeof(HexStr) - sizeof(HexStr[0]), ' ');
	end;
	b := p^;

	HexStr[hidx + 1] := Digit(b shr 4);
	HexStr[hidx + 2] := Digit(b and $0F);

	inc(hidx, 3);
	inc(sidx);

	if (b < 32) or (b > 126) then
	  Str[sidx] := '.'
	else
	  Str[sidx] := AnsiChar(b);

	if sidx >= LLen then begin
	  WriteStrToFile(hFile, ['  ', OffsetStr, ' ', HexStr, ' ', Str, CrLf]);
	  hidx := 0;
	  sidx := 0;
	end;
	inc(p);
	dec(bufsize);
	inc(offset);
  end;

  if sidx > 0 then begin
	WriteStrToFile(hFile, ['  ', OffsetStr, ' ', HexStr, ' ', Str, CrLf]);
  end;
end;


 //===================================================================================================================
 //== Replacement functions for GetMem/FreeMem with added consistency checks and book-keeping
 //===================================================================================================================

type
  // is placed in front of each allocated block (always aligned):
  PPreRec = ^TPreRec;
  TPreRec = record
	Next, Prev: PPreRec;		// allocated blocks form a doubly linked lists
	Size: _NativeUInt;			// Size of the allocated memory block
	Key: _NativeUInt;			// special value (PreMemKey) to detect memory corruption
  end;

  // is placed after each allocated block (possibly not aligned!):
  PPostRec = ^TPostRec;
  TPostRec = record
	Key: _NativeUInt;			// special value (PostMemKey) to detect memory corruption
	Size: _NativeUInt;			// Size of the allocated memory block
  end;

  TBlockList= record
  {strict} private
	FList: TPreRec;				// Root block for a list of all currently allocated memory blocks
	FLock: TSlimRWLock;			// Lock during list manipulations and checks of the chaining, must be zero-initialized
	FStats: ^TMyMemStat;
  public
	function Enqueue(Block: PPreRec; Size: _NativeUInt): pointer;
	function Dequeue(Payload: pointer): PPreRec;

	function IsValidList: boolean;
	procedure DumpList(Filename: PChar; DoLock, CheckForDelphiClasses, WithHexDump: boolean);
	procedure CheckMemoryLeak(IsDelphiMem: boolean);
	procedure MemErr(p: PPreRec);
	class function IsValidBlock(P: PPreRec): boolean; static;
  end;

const
  PreMemKey  = {$ifdef CPU64BITS} _NativeUInt($FEFEFEFEFEFEFEFE) {$else} _NativeUInt($FEFEFEFE) {$endif};
  PostMemKey = {$ifdef CPU64BITS} _NativeUInt($EFEFEFEFEFEFEFEF) {$else} _NativeUInt($EFEFEFEF) {$endif};
  RootKey    = {$ifdef CPU64BITS} _NativeUInt($AA5555AAAA5555AA) {$else} _NativeUInt($AA5555AA) {$endif};


var
  PrevExitProcessProc: procedure;	// original process-exit callback
  OldMgr: TMemoryManagerEx;			// original Memory Manager, to which the operations are forwarded

  DelphiMem: TBlockList = (
	FList: (
	  Next: @DelphiMem.FList;
	  Prev: @DelphiMem.FList;
	  Size: 0;
	  Key:  RootKey;
	);
	//FLock: nil;
	FStats: @DelphiMemStats;
  );

  ComMem: TBlockList = (
	FList: (
	  Next: @ComMem.FList;
	  Prev: @ComMem.FList;
	  Size: 0;
	  Key:  RootKey;
	);
	//FLock: nil;
	FStats: @ComMemStats;
  );

  function IsDebuggerPresent: BOOL; stdcall; external Windows.kernel32 name 'IsDebuggerPresent';


 //===================================================================================================================
 // Cause a break into the debugger. Does nothing when not debugged.
 //===================================================================================================================
procedure MyDebugBreak;
begin
  // In the past, DebugBreak got ignored when not being debugged. Now it terminates the process.
  if IsDebuggerPresent then Windows.DebugBreak;
end;


 //===================================================================================================================
 // Outputs the texts in <Strs> on stderr and in the Windows debug output, and triggers a debugger break.
 //===================================================================================================================
procedure SignalError(const Strs: array of ShortString);
var
  h: THandle;
  Buf: ShortString;
begin
  ShortConcat(Buf, Strs);

  // for GUI processes, the handle is normally NULL, i.e. invalid:
  h := Windows.GetStdHandle(STD_ERROR_HANDLE);
  if h <> 0 then begin
	WriteStrToFile(h, [Buf, CrLf]);
  end;

  // posts the message to the EventLog window of the Delphi IDE (or any other debugger):
  Windows.OutputDebugStringA(@Buf[1]);
  MyDebugBreak;
end;


 //===================================================================================================================
 // Implements GetMem und AllocMem: Returns a new memory block of the application-requested size <Size>.
 //===================================================================================================================
function MyGetMemImpl(Size: _NativeUInt; FillByte: byte): Pointer;
var
  PP: PPreRec;
begin
  PP := OldMgr.GetMem(Size + sizeof(TPreRec) + sizeof(TPostRec));

  if PP = nil then begin
	if MyBreakOnAllocationError then
	  MyDebugBreak;
	exit(nil);
  end;

  // enqueue the block:
  Result := DelphiMem.Enqueue( PP, Size );

  // fill the newly allocated memory:
  FillChar(Result^, Size, FillByte);
end;


 //===================================================================================================================
 // Implements System.GetMem: Returns a uninitialized memory block.
 //===================================================================================================================
function MyGetMem(Size: _NativeInt): Pointer;
begin
  // Delphi always passes positive values:
  Assert(Size > 0);

  Result := MyGetMemImpl(_NativeUInt(Size), MyAllocFillByte);
end;


 //===================================================================================================================
 // Implements System.AllocMem: Returns a zero-initialized memory block.
 //===================================================================================================================
function MyAllocMem(Size: {$ifdef DelphiXE2}_NativeInt{$else}_NativeUInt{$endif}): Pointer;
begin
  // Delphi always passes positive values:
  Assert(Size > 0);

  Result := MyGetMemImpl(_NativeUInt(Size), 0);
end;


 //===================================================================================================================
 // Implements System.FreeMem: Release the memory block.
 //===================================================================================================================
function MyFreeMem(P: Pointer): Integer;
var
  PP: PPreRec;
begin
  // Delphi never passes nil:
  Assert(P <> nil);

  PP := DelphiMem.Dequeue( P );

  // overwrite the released memory, including the old TPreRec and TPostRec data, to detect access to released memory
  // and prevent double-freeing the same block
  FillChar(PP^, PP^.Size + sizeof(TPreRec) + sizeof(TPostRec), MyFreeFillByte);

  Result := OldMgr.FreeMem(PP);
end;


 //===================================================================================================================
 // Implements System.ReallocMem: Enlarges or reduces the memory block to the given size, whereby new memory is not
 // initialized.
 //===================================================================================================================
function MyReallocMem(P: Pointer; _Size: _NativeInt): Pointer;
var
  NewSize: _NativeUInt absolute _Size;
  OldSize: _NativeUInt;
  NewPP: PPreRec;
  OldPP: PPreRec;
begin
  // Delphi never passes nil and always passes positive values:
  // (means: ReallocMem() from zero to non-zero size is done as GetMem(), and ReallocMem() from non-zero to zero size
  // is done as FreeMem().)
  Assert((P <> nil) and (_Size > 0));

  OldPP := DelphiMem.Dequeue( P );

  OldSize := OldPP^.Size;

  if NewSize < OldSize then begin
	// overwrite the released memory, including the old TPostRec data:
	FillChar((PByte(OldPP) + sizeof(TPreRec) + NewSize)^, (OldSize - NewSize) + sizeof(TPostRec), MyFreeFillByte);
  end;

  NewPP := OldMgr.ReallocMem(OldPP, NewSize + sizeof(TPreRec) + sizeof(TPostRec));

  if NewPP = nil then begin
	// not relocated due to some error => enqueue the orginal block:
	DelphiMem.Enqueue( OldPP, OldSize );
	if MyBreakOnAllocationError then
	  MyDebugBreak;
	exit(nil);
  end;

  // enqueue the relocated block:
  Result := DelphiMem.Enqueue( NewPP, NewSize );

  if NewSize > OldSize then begin
	// fill the newly allocated memory:
	FillChar((PByte(Result) + OldSize)^, NewSize - OldSize, MyAllocFillByte);
  end;
end;


 //===================================================================================================================
 //===================================================================================================================
function MyRegisterExpectedMemoryLeak(P: Pointer): Boolean;
begin
  Result := false;
end;


 //===================================================================================================================
 //===================================================================================================================
function MyUnregisterExpectedMemoryLeak(P: Pointer): Boolean;
begin
  Result := false;
end;


{ TBlockList }

 //===================================================================================================================
 // Returns true, is P refers to a block that (a) was allocated by this memory manager and (b) is not already released.
 //===================================================================================================================
class function TBlockList.IsValidBlock(P: PPreRec): boolean;
begin
  Assert(P <> nil);

  Result := (P^.Key = PreMemKey)
   and (P^.Prev <> nil) and (P^.Prev^.Next = P)
   and (P^.Next <> nil) and (P^.Next^.Prev = P)
   and (PPostRec(PByte(P) + sizeof(TPreRec) + P^.Size)^.Key = PostMemKey)
   and (PPostRec(PByte(P) + sizeof(TPreRec) + P^.Size)^.Size = P^.Size);
end;


 //===================================================================================================================
 // Chain <Block> to FList. Update statistics. Return pointer to the payload area of <Block>:
 //===================================================================================================================
function TBlockList.Enqueue(Block: PPreRec; Size: _NativeUInt): pointer;
begin
  Block^.Key := PreMemKey;
  Block^.Size := Size;

  PPostRec(PByte(Block) + sizeof(TPreRec) + Size)^.Key := PostMemKey;
  PPostRec(PByte(Block) + sizeof(TPreRec) + Size)^.Size := Size;

  FLock.AcquireExclusive;

	Block^.Prev := @FList;
	Block^.Next := FList.Next;

	FList.Next^.Prev := Block;
	FList.Next := Block;

	inc(FStats.AllocMemSize, Size);
	if FStats.AllocMemSize > FStats.MaxAllocMemSize then FStats.MaxAllocMemSize := FStats.AllocMemSize;
	inc(FStats.AllocMemBlocks);

  FLock.ReleaseExclusive;

  Result := PByte(Block) + sizeof(TPreRec);

  if (Result = FStats.AllocBreakAddr) or (Size = FStats.AllocBreakSize) then
	MyDebugBreak;
end;


 //===================================================================================================================
 // Unchain <Payload>. Update statistics. Return pointer to the TPreRect data.
 // If the block is invalid, a message is issued, trace file output is generated and the process is killed.
 //===================================================================================================================
function TBlockList.Dequeue(Payload: pointer): PPreRec;
begin
  Result := PPreRec(PByte(Payload) - sizeof(TPreRec));

  if (Payload = FStats.FreeBreakAddr) or (Result^.Size = FStats.FreeBreakSize) then
	MyDebugBreak;

  FLock.AcquireExclusive;

	// IsValidBlock tests the Prev and Next pointers, which could be modified in parallel by other threads.
	// => the check must be done within the lock

	if not self.IsValidBlock(Result) then begin
	  self.MemErr(Result);
	  Windows.TerminateProcess(Windows.GetCurrentProcess, 1);
	end;

	dec(FStats.AllocMemSize, Result^.Size);
	dec(FStats.AllocMemBlocks);

	Result^.Next^.Prev := Result^.Prev;
	Result^.Prev^.Next := Result^.Next;

  FLock.ReleaseExclusive;
end;


 //===================================================================================================================
 // Checks all currently allocated blocks for integrity. If an inconsistency is found, a message is issued, trace file
 // output is generated and false is returned.
 //===================================================================================================================
function TBlockList.IsValidList: boolean;
var
  p: PPreRec;
begin
  FLock.AcquireShared;

	p := FList.Next;
	while p <> @FList do begin

	  if not self.IsValidBlock(p) then begin
		self.MemErr(p);
		FLock.ReleaseShared;
		exit(false);
	  end;

	  p := p^.Next;
	end;

  FLock.ReleaseShared;

  Result := true;
end;


 //===================================================================================================================
 // Appends a dump of all allocated memory blocks to the given file.
 // CheckForDelphiClasses: When set, the function try to classify the block
 // - "UnicodeString"
 // - "AnsiString"
 // - Delphi class: "<ClassName>"
 // - other: "-"
 //===================================================================================================================
procedure TBlockList.DumpList(Filename: PChar; DoLock, CheckForDelphiClasses, WithHexDump: boolean);
type
  // from System.pas
  PStrRec = ^TStrRec;
  TStrRec = packed record
	{$ifdef CPU64BITS}
	_Padding: Integer; // Make 16 byte align for payload..
	{$endif}
	codePage: Word;
	elemSize: Word;
	refCnt: Integer;
	length: Integer;
  end;
var
  MinDataAddr, MaxDataAddr: PByte;

  procedure _QueryDataSegmentSize;
  var
	Info: TMemoryBasicInformation;
  begin
	Windows.VirtualQuery(pointer(System.TObject), Info, sizeof(Info));
	MinDataAddr := Info.AllocationBase;
	MaxDataAddr := MinDataAddr + Info.RegionSize;
  end;

  function _CanReadData(Addr: PByte; Size: uint32): boolean;
  begin
	Result := (Addr >= MinDataAddr) and (Addr + Size <= MaxDataAddr);
  end;

  function _TryGetClassName(Block: pointer; BlockSize: _NativeUInt; var ClassName: ShortString): boolean;
  var
	VMT: PByte;
	InstanceSize: integer;
	tmp: PByte;
  begin
	// to be an object instance, the block must at least contain the VMT pointer:
	if BlockSize < sizeof(pointer) then exit(false);

	// first field in an object is the VMT pointer:
	VMT := PPointer(Block)^;

	// try to read the vmtSelfPtr field in the VMT:
	tmp := VMT + vmtSelfPtr;
	if not _CanReadData(tmp, sizeof(pointer)) then exit(false);
	tmp := PPointer(tmp)^;
	if tmp <> VMT then exit(false);

	// try to read the vmtInstanceSize field in the VMT:
	tmp := VMT + vmtInstanceSize;
	if not _CanReadData(tmp, sizeof(InstanceSize)) then exit(false);
	InstanceSize := PInteger(tmp)^;
	if _NativeUInt(InstanceSize) <> BlockSize then exit(false);

	// try to read the vmtClassName field in the VMT:
	tmp := VMT + vmtClassName;
	if not _CanReadData(tmp, sizeof(pointer)) then exit(false);
	tmp := PPointer(tmp)^;
	// try to read the ClassName field itself:
	if not _CanReadData(tmp, 2) or (tmp[0] = 0) or (tmp[1] <= 32) or (tmp[1] >= 126) or not _CanReadData(tmp, 1 + tmp^) then exit(false);
	ClassName := PShortString(tmp)^;
	Result := true;
  end;

  // see comment in System.pas: the length with the zero-terminator is made even, for whatever reason:
  function _RoundUp(Size: integer): integer; inline;
  begin
	Result := (size + 1) and not 1;
  end;

  function _IsUnicodeString(Block: pointer; BlockSize: _NativeUint): boolean;
  begin
	Result := (BlockSize >= sizeof(TStrRec))
	 and (PStrRec(Block)^.elemSize = sizeof(WideChar))
	 and (PStrRec(Block)^.codePage = System.DefaultUnicodeCodePage)
	 and (_NativeInt(BlockSize) = sizeof(TStrRec) + (PStrRec(Block)^.length + 1) * sizeof(WideChar));
  end;

  function _IsAnsiString(Block: pointer; BlockSize: _NativeUint): boolean;
  begin
	Result := (BlockSize >= sizeof(TStrRec))
	 and (PStrRec(Block)^.elemSize = sizeof(AnsiChar))
	 and (PStrRec(Block)^.codePage <> System.DefaultUnicodeCodePage)
	 and (_NativeInt(BlockSize) = sizeof(TStrRec) + _RoundUp(PStrRec(Block)^.length + 1) * sizeof(AnsiChar));
  end;

const
  MaxDumpSize = _NativeUInt(4 * 1024);
var
  p: PPreRec;
  q: PByte;
  hFile: THandle;
  ClassName: ShortString;
begin
  _QueryDataSegmentSize;

  hFile := Windows.CreateFile(Filename, FILE_APPEND_DATA, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_ALWAYS, 0, 0);
  if hFile = INVALID_HANDLE_VALUE then exit;

  WriteStrToFile(hFile, [FStats.Title, ' ', NUIntToStr(FStats.AllocMemSize), ' byte in ', NUIntToStr(FStats.AllocMemBlocks) , ' blocks', CrLf + CrLf]);

  if DoLock then FLock.AcquireShared;

	p := FList.Next;
	while p <> @FList do begin
	  q := PByte(p) + sizeof(TPreRec);

	  ClassName := '-';
	  if CheckForDelphiClasses then begin
		if not _TryGetClassName(q, p^.Size, ClassName) then
		  if _IsUnicodeString(q, p^.Size) then ClassName := 'UnicodeString'
		  else if _IsAnsiString(q, p^.Size) then ClassName := 'AnsiString';
	  end;

	  WriteStrToFile(hFile, ['Addr: ', PtrToHex(q), '  Size: ', NUIntToStr(p^.Size), '  Type: ', ClassName, CrLf]);

	  if WithHexDump then begin
		if p^.Size <= MaxDumpSize then begin
		  // dump whole block:
		  WriteHexDump(hFile, q, p^.Size);
		end
		else begin
		  // dump only beginning and end of block:
		  WriteHexDump(hFile, q, MaxDumpSize div 2);
		  WriteStrToFile(hFile, ['           .................' + CrLf]);
		  WriteHexDump(hFile, q + p^.Size - MaxDumpSize div 2, MaxDumpSize div 2);
		end;
		WriteStrToFile(hFile, [CrLf]);
	  end;

	  p := p^.Next;
	end;

  if DoLock then FLock.ReleaseShared;

  Windows.CloseHandle(hFile);
end;


 //===================================================================================================================
 // Dumps the given memory block to a file "memdump_corrupt_block.txt".
 // Needs to run in the lock, otherwise the dumped memory blocks may be inconsistent.
 //===================================================================================================================
procedure TBlockList.MemErr(p: PPreRec);
var
  hFile: THandle;
  size: _NativeUInt;
  q: PPostRec;
begin
  SignalError([FStats.Title, ' Memory corruption detected: p=$', PtrToHex(p)]);
  MyDebugBreak;

  hFile := Windows.CreateFile('memdump_corrupt_block.txt', FILE_APPEND_DATA, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_ALWAYS, 0, 0);
  if hFile <> INVALID_HANDLE_VALUE then begin

	size := p^.Size + sizeof(TPreRec) + sizeof(TPostRec);
	q := PPostRec(PByte(p) + sizeof(TPreRec) + p^.Size);

	WriteStrToFile(hFile, [
	  'Addr=', PtrToHex(p), '  Size=', NUIntToStr(size),
	  '  PreKey=$', NUIntToHex(p.Key), '  PostKey=$', NUIntToHex(q.Key),
	  '  PreSize=', NUIntToStr(p.Size), '  PostSize=', NUIntToStr(q.Size),
	  '  Prev=', PtrToHex(p.Prev), '  Next=', PtrToHex(p.Next),
	  '  Prev^.Next=', PtrToHex(p.Prev^.Next), '  Next^.Prev=', PtrToHex(p.Next^.Prev),
	  CrLf
	]);

	WriteHexDump(hFile, p, size);

	Windows.CloseHandle(hFile);
  end;
end;


 //===================================================================================================================
 // Note: COM supports allocations of zero byte by CoTaskMemAlloc / IMalloc::Alloc.
 //===================================================================================================================
procedure TBlockList.CheckMemoryLeak(IsDelphiMem: boolean);
begin
  if (FStats.AllocMemSize > FStats.ExpectedMemInbalance) or (FStats.ExpectedMemInbalance = 0) and (FStats.AllocMemBlocks <> 0) then begin
	SignalError([FStats.Title, ' Memory still allocated: ', NUIntToStr(FStats.AllocMemSize), ' byte in ', NUIntToStr(FStats.AllocMemBlocks) , ' blocks']);
	self.DumpList('memdump_allocated_blocks.txt', false, IsDelphiMem, true);
  end
  else if FStats.AllocMemSize < FStats.ExpectedMemInbalance then begin
	SignalError([FStats.Title, ' Memory imbalance detected: ', NUIntToStr(FStats.AllocMemSize), ' <> ', NUIntToStr(FStats.ExpectedMemInbalance)]);
  end;
end;


 //===================================================================================================================
 // Checks all currently allocated blocks in the Delphi and the COM heap for integrity. If an inconsistency is found,
 // a message is issued, trace file output is generated and false is returned.
 // This temporarly blocks all other threads on doing heap operations.
 //===================================================================================================================
function IsMemoryValid: boolean;
begin
  Result := DelphiMem.IsValidList and ComMem.IsValidList;
end;


 //===================================================================================================================
 // Appends a dump of all allocated memory blocks to the given file.
 // This temporarly blocks all other threads on doing heap operations.
 //===================================================================================================================
procedure DumpAllocatedBlocks(const Filename: string; WithHexDump: boolean);
begin
  DelphiMem.DumpList(PChar(Filename), true, true, WithHexDump);
end;


//
// from ActiveX.pas, to not depend on this unit (and thus on others), which is important for the unit initialization sequence:
//

type
  SIZE_T = ULONG_PTR;

  IMallocSpy = interface(IUnknown)
	['{0000001D-0000-0000-C000-000000000046}']
	function PreAlloc(cbRequest: SIZE_T): SIZE_T; stdcall;
	function PostAlloc(pActual: Pointer): Pointer; stdcall;
	function PreFree(pRequest: Pointer; fSpyed: BOOL): Pointer; stdcall;
	procedure PostFree(fSpyed: BOOL); stdcall;
	function PreRealloc(pRequest: Pointer; cbRequest: SIZE_T;
	  out ppNewRequest: Pointer; fSpyed: BOOL): SIZE_T; stdcall;
	function PostRealloc(pActual: Pointer; fSpyed: BOOL): Pointer; stdcall;
	function PreGetSize(pRequest: Pointer; fSpyed: BOOL): Pointer; stdcall;
	function PostGetSize(pActual: SIZE_T; fSpyed: BOOL): SIZE_T; stdcall;
	function PreDidAlloc(pRequest: Pointer; fSpyed: BOOL): Pointer; stdcall;
	function PostDidAlloc(pRequest: Pointer; fSpyed: BOOL; fActual: Integer): Integer; stdcall;
	procedure PreHeapMinimize; stdcall;
	procedure PostHeapMinimize; stdcall;
  end;

  IInitializeSpy = interface(IUnknown)
	['{00000034-0000-0000-C000-000000000046}']
	function PreInitialize(dwCoInit: DWORD; dwCurThreadAptRefs: DWORD): HRESULT; stdcall;
	function PostInitialize(hrCoInit: HRESULT; dwCoInit: DWORD; dwNewThreadAptRefs: DWORD): HRESULT; stdcall;
	function PreUninitialize(dwCurThreadAptRefs: DWORD): HRESULT; stdcall;
	function PostUninitialize(dwNewThreadAptRefs: DWORD): HRESULT; stdcall;
  end;

const
  ole32 = 'ole32.dll';
  oleaut32 = 'oleaut32.dll';

function IsEqualGUID(const guid1, guid2: TGUID): Boolean; stdcall; external ole32 name 'IsEqualGUID';
function CoRegisterMallocSpy(mallocSpy: IMallocSpy): HResult; stdcall; external ole32 name 'CoRegisterMallocSpy';
function CoRevokeMallocSpy: HResult stdcall; external ole32 name 'CoRevokeMallocSpy';
procedure SetOaNoCache; cdecl; external oleaut32 name 'SetOaNoCache';
function CoRegisterInitializeSpy(pSpy: IInitializeSpy; out puliCookie: ULARGE_INTEGER): HRESULT; stdcall; external ole32 name 'CoRegisterInitializeSpy';
function CoRevokeInitializeSpy(uliCookie: ULARGE_INTEGER): HRESULT; stdcall; external ole32 name 'CoRevokeInitializeSpy';

type
  // structure to implement IMallocSpy as a singleton object:
  TComAllocSpy = record
  strict private
	var
	  FVMT: pointer;

	function QueryInterface(const IID: TGUID; out Obj: pointer): HResult; stdcall;
	function AddRef: Integer; stdcall;
	function Release: Integer; stdcall;
	function PreAlloc(cbRequest: SIZE_T): SIZE_T; stdcall;
	function PostAlloc(pActual: Pointer): Pointer; stdcall;
	function PreFree(pRequest: Pointer; fSpyed: BOOL): Pointer; stdcall;
	procedure PostFree(fSpyed: BOOL); stdcall;
	function PreRealloc(pRequest: Pointer; NewSize: SIZE_T; out ppNewRequest: Pointer; fSpyed: BOOL): SIZE_T; stdcall;
	function PostRealloc(pActual: Pointer; fSpyed: BOOL): Pointer; stdcall;
	function PreGetSize(pRequest: Pointer; fSpyed: BOOL): Pointer; stdcall;
	function PostGetSize(cbActual: SIZE_T; fSpyed: BOOL): SIZE_T; stdcall;
	function PreDidAlloc(pRequest: Pointer; fSpyed: BOOL): Pointer; stdcall;
	function PostDidAlloc(pRequest: Pointer; fSpyed: BOOL; fActual: Integer): Integer; stdcall;
	procedure NoopHeapMinimize; stdcall;
  public
	class procedure Init; static; inline;
	class procedure Fini; static; inline;
  end;

threadvar
  gRequestedSize: _NativeUInt;


{ TComAllocSpy }

// All allocations and releases are still performed by the original COM allocator.
//
// IMalloc.Alloc(0) returns a non-nil pointer
// IMalloc.Realloc(nil, x) calls IMalloc.Alloc(x) for *all* values of x
// IMalloc.Realloc(non-nil, 0) calls IMalloc.Free()

 //===================================================================================================================
 //===================================================================================================================
function TComAllocSpy.QueryInterface(const IID: TGUID; out Obj: pointer): HResult;
begin
  if IsEqualGUID(IID, IMallocSpy) then begin
	Obj := @self;
	Result := S_OK;
  end
  else begin
	Obj := nil;
	Result := E_NOINTERFACE;
  end;
end;


 //===================================================================================================================
 // Not called because we don't use it in QueryInterface.
 //===================================================================================================================
function TComAllocSpy.AddRef: Integer;
begin
  Result := 1;
end;


 //===================================================================================================================
 // This is called during CoRevokeMallocSpy or (when there are outstanding "spyed" allocations) after the last
 // allocation is released. Maybe called *during* ExitProcess.
 //===================================================================================================================
function TComAllocSpy.Release: Integer;
begin
  Assert(ComMem.FStats.AllocMemBlocks = 0);
  Result := 0;
end;


 //===================================================================================================================
 // PreAlloc can force memory allocation failure by returning 0. In this case, IMallocSpy::PostAlloc is not called.
 // However, when the actual allocation encounters a real memory failure and returns NULL, PostAlloc is called.
 // Result = byte count to be passed to underlying allocator
 //===================================================================================================================
function TComAllocSpy.PreAlloc(cbRequest: SIZE_T): SIZE_T;
begin
  gRequestedSize := cbRequest;

  Result := cbRequest + sizeof(TPreRec) + sizeof(TPostRec);
end;

 // Result = pointer to be returned by IMalloc::Alloc
function TComAllocSpy.PostAlloc(pActual: Pointer): Pointer;
begin
  Result := pActual;

  // nil only occurs if COM could not allocate memory (out-of-memory):
  if Result <> nil then begin
	Result := ComMem.Enqueue(Result, gRequestedSize);
	// fill the newly allocated memory:
	FillChar(Result^, gRequestedSize, MyAllocFillByte);
  end
  else if MyBreakOnAllocationError then begin
	MyDebugBreak;
  end;
end;


 //===================================================================================================================
 // Result = pointer to be passed to underlying allocator
 //===================================================================================================================
function TComAllocSpy.PreFree(pRequest: Pointer; fSpyed: BOOL): Pointer;
begin
  Result := pRequest;
  if fSpyed and (Result <> nil) then begin
	Result := ComMem.Dequeue(Result);
	// overwrite the released memory, including the old TPreRec and TPostRec data, to detect access to released memory
	// and prevent double-freeing the same block
	FillChar(Result^, PPreRec(Result)^.Size + sizeof(TPreRec) + sizeof(TPostRec), MyFreeFillByte);
  end;
end;

procedure TComAllocSpy.PostFree(fSpyed: BOOL);
begin
end;


 //===================================================================================================================
 // ppNewRequest = pointer to be passed to underlying allocator
 // Result = byte count to be passed to underlying allocator
 //===================================================================================================================
function TComAllocSpy.PreRealloc(pRequest: Pointer; NewSize: SIZE_T; out ppNewRequest: Pointer; fSpyed: BOOL): SIZE_T;
var
  OldSize: _NativeUInt;
begin
  if not fSpyed then begin
	ppNewRequest := pRequest;
	exit(NewSize);
  end;

  gRequestedSize := NewSize;

  if pRequest <> nil then begin

	pRequest := ComMem.Dequeue(pRequest);
	OldSize := PPreRec(pRequest)^.Size;

	if NewSize < OldSize then begin
	  // overwrite the released memory, including the old TPostRec data:
	  FillChar((PByte(pRequest) + sizeof(TPreRec) + NewSize)^, (OldSize - NewSize) + sizeof(TPostRec), MyFreeFillByte);
	end;
  end;

  ppNewRequest := pRequest;
  Result := NewSize + sizeof(TPreRec) + sizeof(TPostRec);
end;

 // Result = pointer to be returned by IMalloc::Relloc
function TComAllocSpy.PostRealloc(pActual: Pointer; fSpyed: BOOL): Pointer;
var
  NewSize: _NativeUInt;
  OldSize: _NativeUInt;
begin
  Result := pActual;

  if fSpyed then begin

	// nil only occurs if COM could not allocate memory (out-of-memory):
	if Result <> nil then begin
	  OldSize := PPreRec(Result)^.Size;
	  NewSize := gRequestedSize;

	  Result := ComMem.Enqueue(Result, NewSize);

	  if NewSize > OldSize then begin
		// fill the newly allocated memory:
		FillChar((PByte(Result) + OldSize)^, NewSize - OldSize, MyAllocFillByte);
	  end;
	end
	else if MyBreakOnAllocationError then begin
	  MyDebugBreak;
	end;

  end;
end;


 //===================================================================================================================
 // Result = pointer to be passed to underlying allocator
 //===================================================================================================================
function TComAllocSpy.PreGetSize(pRequest: Pointer; fSpyed: BOOL): Pointer;
begin
  Result := pRequest;
  if fSpyed then Result := PByte(Result) - sizeof(TPreRec);
end;

 // Result = byte count to be returned by IMalloc::GetSize
function TComAllocSpy.PostGetSize(cbActual: SIZE_T; fSpyed: BOOL): SIZE_T;
begin
  Result := cbActual;
  if fSpyed then Result := Result - sizeof(TPreRec) - sizeof(TPostRec);
end;


 //===================================================================================================================
 // Result = pointer to be passed to underlying allocator
 //===================================================================================================================
function TComAllocSpy.PreDidAlloc(pRequest: Pointer; fSpyed: BOOL): Pointer;
begin
  Result := pRequest;
  if fSpyed then Result := PByte(Result) - sizeof(TPreRec);
end;

 // Result = value to be returned by IMalloc::DidAlloc (-1, 0, +1)
function TComAllocSpy.PostDidAlloc(pRequest: Pointer; fSpyed: BOOL; fActual: Integer): Integer;
begin
  Result := fActual;
end;


 //===================================================================================================================
 // do nothing
 //===================================================================================================================
procedure TComAllocSpy.NoopHeapMinimize;
begin
end;


 //===================================================================================================================
 // install COM memory monitoring:
 //===================================================================================================================
class procedure TComAllocSpy.Init;
const
  VMT: array [0..14] of Pointer =
  (
	@TComAllocSpy.QueryInterface,
	@TComAllocSpy.AddRef,
	@TComAllocSpy.Release,
	@TComAllocSpy.PreAlloc,
	@TComAllocSpy.PostAlloc,
	@TComAllocSpy.PreFree,
	@TComAllocSpy.PostFree,
	@TComAllocSpy.PreRealloc,
	@TComAllocSpy.PostRealloc,
	@TComAllocSpy.PreGetSize,
	@TComAllocSpy.PostGetSize,
	@TComAllocSpy.PreDidAlloc,
	@TComAllocSpy.PostDidAlloc,
	@TComAllocSpy.NoopHeapMinimize,		// IMallocSpy.PreHeapMinimize
	@TComAllocSpy.NoopHeapMinimize		// IMallocSpy.PostHeapMinimize
  );

  // static singleton COM object:
  Obj: TComAllocSpy = (FVMT: @VMT);
begin
  // install COM memory monitoring:
  CoRegisterMallocSpy(IMallocSpy(@Obj));

  // turn off the BSTR cache in oleaut32.dll (runs slower, but makes allocations deterministic):
  // https://devblogs.microsoft.com/oldnewthing/20150107-00/?p=43203
  SetOaNoCache;
end;


 //===================================================================================================================
 // revoke COM memory monitoring:
 //===================================================================================================================
class procedure TComAllocSpy.Fini;
begin
  // CoRevokeMallocSpy() returns E_ACCESSDENIED when there are outstanding allocations (not yet freed) made while this
  // spy was active.
  // Sadly, this is normal as combase.dll does not release some memory until it is unloaded during ExitProcess (which
  // then finally calls Spy_Release).
  CoRevokeMallocSpy;
end;


 //===================================================================================================================
 //===================================================================================================================
procedure Install;

  function NoMemoryAllocated: boolean;
  var
	State: TMemoryManagerState;
  begin
	// no memory must be allocated at this point:
	System.GetMemoryManagerState(State);
	Result := (State.AllocatedMediumBlockCount = 0) and (State.AllocatedLargeBlockCount = 0);
  end;

const
  MemMgr: TMemoryManagerEx = (
	GetMem: MyGetMem;
	FreeMem: MyFreeMem;
	ReallocMem:	MyReallocMem;
	AllocMem: MyAllocMem;
	RegisterExpectedMemoryLeak: MyRegisterExpectedMemoryLeak;
	UnregisterExpectedMemoryLeak: MyUnregisterExpectedMemoryLeak;
  );
begin
  Assert(NoMemoryAllocated, 'Memory already allocated');

  // replace the existing memory manager:
  GetMemoryManager(OldMgr);
  SetMemoryManager(MemMgr);

  // install COM memory monitoring:
  TComAllocSpy.Init;
end;


 //===================================================================================================================
 //===================================================================================================================
procedure CheckMemoryStatus;
begin
  // report Delphi memory leaks:
  DelphiMem.CheckMemoryLeak(true);

  // revoke COM memory monitoring
  TComAllocSpy.Fini;

  // call the previous exit procedure:
  if Assigned(PrevExitProcessProc) then PrevExitProcessProc();

  // the usage of IMAllocSpy triggers a bug in combase.dll when some DLLs are unloaded during ExitProcess
  // => skip any further DLL unloading:
  Windows.TerminateProcess(Windows.GetCurrentProcess, System.ExitCode);
end;


initialization
  Install;

  // Bug in Delphi XE2 and up: FreeMem(PreferredLanguagesOverride) in the finalization section of System.pas runs
  // after the finalization of every unit => CheckMemoryStatus can only run thereafter
  PrevExitProcessProc := System.ExitProcessProc;
  System.ExitProcessProc := CheckMemoryStatus;

{$else} // MEMTEST_ACTIVE


 //===================================================================================================================
 // Dummy functions to be used if MEMTEST_ACTIVE is not set.
 //===================================================================================================================

function IsMemoryValid: boolean;
begin
  Result := true;
end;

procedure DumpAllocatedBlocks(const Filename: string; WithHexDump: boolean = true);
begin
  // nothing
end;


{$endif} // MEMTEST_ACTIVE

end.
