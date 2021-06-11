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
  //
  // This is a very thin wrapper around the API function GetTickCount64, which provides the number of milliseconds
  // since the last Windows system start, regardless of time changes, time zone changes and daylight saving time
  // switches.
  //===================================================================================================================
  TTimeoutTime = record
  strict private
	FTimeoutTime: uint64;		// Time at which the timeout expires (in terms of GetTickCount64)
	function RemainingMilliSecs: uint64;
  public
	constructor FromMilliSecs(Value: uint32);
	constructor FromSecs(Value: uint32);
	function AsSeconds: uint32;
	function AsMilliSecs: uint32; inline;
	function IsElapsed: boolean;

  strict private
	class var FZero: TTimeoutTime;
  public
	class property Zero: TTimeoutTime read FZero;
  end;


{############################################################################}
implementation
{############################################################################}

uses Windows;

{$if not declared(GetTickCount64)}
// since Vista:
function GetTickCount64: uint64; stdcall; external Windows.kernel32 name 'GetTickCount64';
{$ifend}


{ TTimeoutTime }

 //===================================================================================================================
 // Initializes the timeout with the specified number of milliseconds.
 // The constant INFINITE is not supported.
 // Due to the argument type, the maximum timeout is limited to 49.7 days.
 //===================================================================================================================
constructor TTimeoutTime.FromMilliSecs(Value: uint32);
begin
  FTimeoutTime :=  GetTickCount64 + Value;
end;


 //===================================================================================================================
 // Initializes the timeout with the specified number of of seconds.
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
 // Returns the number of milliseconds until the timeout.
 // The result type limits the maximum time that can be delivered to 49.7 days.
 // There is a 32-bit wrap-around for higher values.
 //===================================================================================================================
function TTimeoutTime.AsMilliSecs: uint32;
begin
  Result := self.RemainingMilliSecs;
end;


 //===================================================================================================================
 // Returns the number of seconds until the timeout.
 // The result type limits the maximum time that can be delivered to 49700 days.
 // There is a 32-bit wrap-around for higher values.
 //===================================================================================================================
function TTimeoutTime.AsSeconds: uint32;
begin
  Result := self.RemainingMilliSecs div 1000;
end;


 //===================================================================================================================
 // Returns true if the timeout has expired.
 //===================================================================================================================
function TTimeoutTime.IsElapsed: boolean;
begin
  Result := GetTickCount64 >= FTimeoutTime;
end;

end.

