unit StdLib;

{
  Collection of various utility types and helper functions, for any type of application (GUI, command-line, service),
  therefore without any VCL dependency.

  This is a very small subset of content of the original unit.
}

{$include LibOptions.inc}
{$ScopedEnums on}

interface

uses Windows, SysUtils;

const
  // char constants:
  LF = #10;
  CR = #13;
  ESC = #27;
  // Windows end-of-line constant:
  CrLf = #13#10;


type
  // Exception for Windows API errors (instead of SysUtils.EOSError, for better error messages and better usability):
  EOSSysError = class(SysUtils.EOSError)
  public
	constructor Create(Error: DWORD);
	constructor CreateWithMsg(Error: DWORD; const Msg: string); overload;
	constructor CreateWithCtx(Error: DWORD; const Ctx: string); overload;
	constructor CreateWithCtxFmt(Error: DWORD; const Ctx: string; const Args: array of const);

	class function CreateWithMsg(const Msg: string): EOSSysError; overload;
	class function CreateWithCtx(const Ctx: string): EOSSysError; overload;

	class function ErrorMsg(ErrorCode: DWORD; LanguageID: LANGID = 0): string; static;
  end;


  // Hosts methods to update the global format settings when the regional settings of this user session are changed.
  TDummy = class
  public
	class procedure UpdateFormatSettings; static;
	class procedure OnSettingChange(Sender: TObject; Flag: Integer; const Section: string; var Result: Longint);
  end;


  // Order of day-month-year in a timestamp string:
  TDateOrder = (MDY, DMY, YMD);


var
  {$ifndef D2010}
  FormatSettings: TFormatSettings;	// D2009: missing from SysUtils
  {$endif}
  DateOrder: TDateOrder;			// is kept synchronous with <FormatSettings> or SysUtils.FormatSettings

//
// Replacements for SysUtils routines (to use EOSSysError):
//

procedure Win32Check(RetVal: BOOL); overload;
procedure Win32Check(RetVal: BOOL; const Ctx: string); overload;


//
// Replacements for SysUtils FreeAndNil ("inline" gives too much code, can be miscompiled bei D2009 due to improper
// usage of the "var" argument):
//

{$ifdef Delphi104}
procedure FreeObj(const [ref] ObjVar: TObject);
{$else}
procedure FreeObj(var Obj {: TObject});
{$endif}


{############################################################################}
implementation
{############################################################################}


{ TDummy }

 //===================================================================================================================
 // During initialization of a GUI application, use this method as global event handler, as shown here
 //   TApplicationEvents.Create(Application).OnSettingChange := StdLib.TDummy.OnSettingChange;
 //===================================================================================================================
class procedure TDummy.OnSettingChange(Sender: TObject; Flag: Integer; const Section: string; var Result: Longint);
begin
  if Section = 'intl' then self.UpdateFormatSettings;
end;


 //===================================================================================================================
 // Updates the FormatSettings and DateOrder variables. Must be called when the regional settings of the user session have changed.
 //===================================================================================================================
class procedure TDummy.UpdateFormatSettings;
var
  buffer: array [0..1] of char;
begin
  {$ifndef D2010}
  // update global settings:
  SysUtils.GetLocaleFormatSettings(Windows.GetThreadLocale, StdLib.FormatSettings);
  StdLib.FormatSettings.TwoDigitYearCenturyWindow := SysUtils.TwoDigitYearCenturyWindow;
  {$endif}

  // returns '0', '1' or '2':
  Windows.GetLocaleInfo(LOCALE_USER_DEFAULT, LOCALE_IDATE, buffer, System.Length(buffer));

  case buffer[0] of
  //'0': DateOrder := TDateOrder.MDY;
  '1': DateOrder := TDateOrder.DMY;
  '2': DateOrder := TDateOrder.YMD;
  else DateOrder := TDateOrder.MDY;
  end;
end;


{ EOSSysError }

 //===================================================================================================================
 // Creates the exception objects with the given error code.
 // It generates a better error text then SysUtils.EOSError.
 //===================================================================================================================
constructor EOSSysError.Create(Error: DWORD);
begin
  inherited Create(self.ErrorMsg(Error, 0));
  self.ErrorCode := Error;
end;


 //===================================================================================================================
 // Creates the exception objects with the current Windows error code and the given messsage.
 // For special cases in which <Msg> should be used instead of the original Windows message.
 // To be able get correct GetLastError results, this is *not* a constructor!
 //===================================================================================================================
class function EOSSysError.CreateWithMsg(const Msg: string): EOSSysError;
begin
  Result := self.CreateWithMsg(Windows.GetLastError, Msg);
end;


 //===================================================================================================================
 // Creates the exception objects with the given Windows error code and the given messsage.
 // For special cases in which <Msg> should be used instead of the original Windows message.
 //===================================================================================================================
constructor EOSSysError.CreateWithMsg(Error: DWORD; const Msg: string);
begin
  inherited Create(Msg);
  self.ErrorCode := Error;
end;


 //===================================================================================================================
 // Creates the exception objects with the current Windows error code, and places <Ctx> in front of the error message.
 // To be able get correct GetLastError results, this is *not* a constructor!
 //===================================================================================================================
class function EOSSysError.CreateWithCtx(const Ctx: string): EOSSysError;
begin
  Result := self.CreateWithCtx(Windows.GetLastError, Ctx);
end;


 //===================================================================================================================
 // Creates the exception objects with the given Windows error code, and places <Ctx> in front of the error message.
 //===================================================================================================================
constructor EOSSysError.CreateWithCtx(Error: DWORD; const Ctx: string);
begin
  self.Create(Error);
  self.Message := Ctx + ': ' + self.Message;
end;


 //===================================================================================================================
 // Creates the exception objects with the given Windows error code, and places Format(<Ctx>, <Args>) in front of the
 // error message.
 //===================================================================================================================
constructor EOSSysError.CreateWithCtxFmt(Error: DWORD; const Ctx: string; const Args: array of const);
begin
  self.Create(Error);
  self.Message := Format(Ctx, Args) + ': ' + self.Message;
end;


 //===================================================================================================================
 // Returns the system error message in the language <LanguageID> for the given Windows error code.
 // SysUtils.SysErrorMessage () uses buffers that are too small and then returns an empty string, for example, for error
 // 0x8004D02A (431 chars) or 0x80310092 (495 chars).
 //
 // LanguageID: If zero, then the GUI language of the calling thread is used, otherwise the specified language. For
 // example, the value can be MAKELANGID(LANG_ENGLISH, SUBLANG_ENGLISH_US).
 //===================================================================================================================
class function EOSSysError.ErrorMsg(ErrorCode: DWORD; LanguageID: LANGID = 0): string;

  // replace line breaks by a single space:
  function _ReplaceCrLf(Buffer: PChar; Len: DWORD): DWORD;
  var
	idx: DWORD;
	c: char;
  begin
	idx := 0;
	Result := 0;
	while idx < Len do begin
	  c := Buffer[idx];
	  inc(idx);
	  if c = CR then continue;
	  if c = LF then c := ' ';
	  Buffer[Result] := c;
	  inc(Result);
	end;
  end;

var
  Buffer: array [0..1023] of char;
  Len: DWORD;
  NumStr: string;
begin
  repeat
	Len := Windows.FormatMessage(
	  FORMAT_MESSAGE_FROM_SYSTEM or FORMAT_MESSAGE_IGNORE_INSERTS or FORMAT_MESSAGE_ARGUMENT_ARRAY,
	  nil, ErrorCode, LanguageID, Buffer, System.Length(Buffer), nil
	);
	if (Len <> 0) or (LanguageID = 0) then break;
	// try again with LanguageID = 0:
	LanguageID := 0;
  until false;

  if Len = 0 then begin
	Result := 'Unknown error';
  end
  else begin

	// remove white-space and '.' from the end:
	while (Len > 0) and CharInSet(Buffer[Len - 1], [#0..#32, '.']) do Dec(Len);

	System.SetString(Result, Buffer, _ReplaceCrLf(Buffer, Len));
  end;

  if int32(ErrorCode) < 0 then
	// HRESULT value:
	NumStr := '0x%.8x'
  else
	NumStr := '%u';

  Result := Result + ' (Windows Error ' + Format(NumStr, [ErrorCode]) + ')';
end;


 //===================================================================================================================
 // If <RetVal> is false, then an EOSSysError exception with the current Windows error is raised.
 //===================================================================================================================
procedure Win32Check(RetVal: BOOL);
begin
  if not RetVal then raise EOSSysError.Create(Windows.GetLastError);
end;


 //===================================================================================================================
 // If <RetVal> is false, then an EOSSysError exception with the current Windows error is raised, that has <Ctx> in
 // front of the error message.
 //===================================================================================================================
procedure Win32Check(RetVal: BOOL; const Ctx: string);
begin
  if not RetVal then raise EOSSysError.CreateWithCtx(Windows.GetLastError, Ctx);
end;


 //===================================================================================================================
 // Sets <ObjVar> to nil and releases the referenced object *thereafter*.
 // Advantages compared to calling .Free directly:
 // - After the call, the passed variable or the passed field no longer points to memory that has already been released.
 // - The call can safely be used in a destructor, even if the field was never assigned a value due to an exception in
 //   the constructor.
 //
 // Like FreeAndNil(), but the original FreeAndNil is (a) defined inline, which generates too much code and (b) when
 // inlined in another inlined procedure, generates incorrect code (compiler bug, but also questionable code trick to
 // access the 'var' parameter).
 //===================================================================================================================
{$ifdef Delphi104}
procedure FreeObj(const [ref] ObjVar: TObject);
var
  tmp: TObject;
begin
  if ObjVar <> nil then begin
	tmp := ObjVar;
	PPointer(@ObjVar)^ := nil;
	tmp.Destroy;
  end;
end;
{$else}
procedure FreeObj(var Obj {: TObject});
var
  ObjVar: TObject absolute Obj;
  tmp: TObject;
begin
  if ObjVar <> nil then begin
	tmp := ObjVar;
	ObjVar := nil;
	tmp.Destroy;
  end;
end;
{$endif}


initialization
  TDummy.UpdateFormatSettings;
end.
