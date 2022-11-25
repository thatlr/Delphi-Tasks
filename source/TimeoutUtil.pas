unit TimeoutUtil;

{
  Types for efficient handling of timeouts.

  - TTimeoutTime: Represents the expiration time of a timeout.
}


{$include LibOptions.inc}

interface

type
  //===================================================================================================================
  // Represents the expiration time of a timeout. This is *not* a timespan, but a absolute point in time!
  // Time spent in sleep or hibernation counts towards the timeout.
  //
  // This is a very thin wrapper around the API function GetTickCount64, which provides the number of milliseconds
  // since the last Windows system start, regardless of time changes, time zone changes and daylight saving time
  // switches.
  //===================================================================================================================
  TTimeoutTime = record
  strict private
	const
	  FInfinite = uint64(High(int64));		// not cause overflow in the signed subtraction in RemainingMilliSecs (roughly 292m years)
	var
	  FTimeoutTime: uint64;					// time when the timeout expires (in terms of GetTickCount64)

	function RemainingMilliSecs: uint64;
	class function ClampTo32(Value: uint64): uint32; static; {$ifdef CPU64BITS}inline;{$endif}
  public
	constructor FromMilliSecs(Value: uint32);
	constructor FromSecs(Value: uint32);
	class function Elapsed: TTimeoutTime; inline; static;
	class function Infinite: TTimeoutTime; inline; static;
	class function Undefined: TTimeoutTime; static; deprecated 'use "Infinite"';

	function AsSeconds: uint32;
	function AsMilliSecs: uint32;
	function IsElapsed: boolean;
	function IsInfinite: boolean; {$ifdef CPU64BITS}inline;{$endif}
	function IsDefined: boolean; deprecated 'use "not .IsInfinite"';
  end;


{############################################################################}
implementation
{############################################################################}

uses Windows;

{$if not declared(GetTickCount64)}
// since Vista:
function GetTickCount64: uint64; stdcall; external Windows.kernel32 name 'GetTickCount64';
{$ifend}

type
  TInt64Rec = record
	case byte of
	0: (Value: uint64);
	1: (Lo, Hi: uint32);
  end;


{ TTimeoutTime }

 //===================================================================================================================
 // Returns a timeout is already expired.
 //===================================================================================================================
class function TTimeoutTime.Elapsed: TTimeoutTime;
begin
  Result.FTimeoutTime := 0;
end;


 //===================================================================================================================
 // Returns a timeout that never expires.
 //===================================================================================================================
class function TTimeoutTime.Infinite: TTimeoutTime;
begin
  Result.FTimeoutTime := FInfinite;
end;


 //===================================================================================================================
 // Obsolete.
 //===================================================================================================================
class function TTimeoutTime.Undefined: TTimeoutTime;
begin
  Result := TTimeoutTime.Infinite;
end;


 //===================================================================================================================
 // Returns true if the timeout is "Infinite".
 //===================================================================================================================
function TTimeoutTime.IsInfinite: boolean;
begin
  Result := FTimeoutTime = FInfinite;
end;


 //===================================================================================================================
 // Obsolete.
 //===================================================================================================================
function TTimeoutTime.IsDefined: boolean;
begin
  Result := not self.IsInfinite;
end;


 //===================================================================================================================
 // Returns true if the timeout has expired.
 //===================================================================================================================
function TTimeoutTime.IsElapsed: boolean;
begin
  Result := GetTickCount64 >= FTimeoutTime;
end;


 //===================================================================================================================
 // Initializes the timeout with the specified number of milliseconds.
 // The constant System.INFINITE (identical to Windows.INFINITE) is supported.
 // Due to the argument type, the maximum timeout is limited to 49.7 days.
 //===================================================================================================================
constructor TTimeoutTime.FromMilliSecs(Value: uint32);
begin
  if Value = System.INFINITE then
	FTimeoutTime := FInfinite
  else
	FTimeoutTime := GetTickCount64 + Value;
end;


 //===================================================================================================================
 // Initializes the timeout with the specified number of of seconds.
 // The constant System.INFINITE (identical to Windows.INFINITE) is not supported.
 // Due to the argument type, the maximum timeout is limited to 49700 days.
 //===================================================================================================================
constructor TTimeoutTime.FromSecs(Value: uint32);
begin
  FTimeoutTime := GetTickCount64 + Value * uint64(1000);
end;


 //===================================================================================================================
 // Returns the number of milliseconds until the timeout as a 64-bit value.
 //===================================================================================================================
function TTimeoutTime.RemainingMilliSecs: uint64;
var
  res: int64 absolute Result;
begin
  res := int64(FTimeoutTime) - int64(GetTickCount64);
  if res < 0 then res := 0;
end;


 //===================================================================================================================
 // Returns <Value> as uint32, or High(uint32) if <Value> exceeds the uint32 range.
 //===================================================================================================================
class function TTimeoutTime.ClampTo32(Value: uint64): uint32;
begin
  {$if High(Result) <> System.INFINITE} {$message error 'Wrong result type'} {$ifend}

  if TInt64Rec(Value).Hi <> 0 then
	Result := High(Result)
  else
	Result := TInt64Rec(Value).Lo;
end;


 //===================================================================================================================
 // Returns the number of milliseconds until the timeout.
 // The result type limits the maximum time that can be delivered to 49.7 days. For higher values, or if the value
 // in Infinite, System.INFINITE is returned.
 //===================================================================================================================
function TTimeoutTime.AsMilliSecs: uint32;
begin
  Result := self.ClampTo32(self.RemainingMilliSecs);
end;


 //===================================================================================================================
 // Returns the number of seconds until the timeout.
 // The result type limits the maximum time that can be delivered to 49700 days. For higher values, or if the value
 // is Infinite, the highest possible value is returned.
 //===================================================================================================================
function TTimeoutTime.AsSeconds: uint32;
begin
  Result := self.ClampTo32(self.RemainingMilliSecs div 1000);
end;


 //===================================================================================================================
 // Exists only in Debug builds.
 //===================================================================================================================
function UnitTest: boolean;
var
  t: TTimeoutTime;
begin
  t := TTimeoutTime.Infinite;
  Assert(t.IsInfinite);
  Assert(not t.IsElapsed);
  Assert(t.AsMilliSecs = System.INFINITE);
  Assert(t.AsMilliSecs = High(t.AsMilliSecs));
  Assert(t.AsSeconds = High(t.AsSeconds));

  t := TTimeoutTime.FromMilliSecs(System.INFINITE);
  Assert(t.IsInfinite);
  Assert(not t.IsElapsed);
  Assert(t.AsMilliSecs = System.INFINITE);

  t := TTimeoutTime.Elapsed;
  Assert(not t.IsInfinite);
  Assert(t.IsElapsed);
  Assert(t.AsMilliSecs = 0);
  Assert(t.AsSeconds = 0);

  t := TTimeoutTime.FromMilliSecs(0);
  Assert(not t.IsInfinite);
  Assert(t.IsElapsed);
  Assert(t.AsMilliSecs = 0);

  t := TTimeoutTime.FromMilliSecs($FFFFFFFE);
  Assert(not t.IsInfinite);
  Assert(not t.IsElapsed);
  Assert(t.AsMilliSecs <= $FFFFFFFE);

  t := TTimeoutTime.FromSecs(123);
  // can only fail on an extremly slow system, or if halted in the debugger in between:
  Assert(t.AsSeconds in [122, 123]);

  Result := true;
end;


initialization
  Assert(UnitTest);
end.

