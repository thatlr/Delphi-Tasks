unit CorrectLocale;

{
  This unit must be listed in the uses list of the dpr file before SysUtils so that SysUtils always uses the correct
  value for the initialization of the NLS settings via GetThreadLocale() under Windows 7.

  A bug in Windows 7 can lead to conflicting values for "LocaleName" and "Locale" in
  HKEY_CURRENT_USER\Control Panel\International (http://blogs.msdn.com/b/michkap/archive/2010/03/19/9980203.aspx). 
}

{$include LibOptions.inc}

interface


{############################################################################}
implementation
{############################################################################}

uses Windows;

initialization
  // The initialization of the regional variables in D6/D2009/D2011 may provide American values for Windows 7 despite
  // other regional settings being active:
  // (a) GetThreadLocale in SysUtils.InitSysLocale returns 1033 (USA), despite other regional settings.
  // (b) TFormatSettings.Create() contains IsValidLocale(), which strangely returns false for LOCALE_USER_DEFAULT
  //     if SetThreadLocale() was not called beforehand.
  // Both calls do not have to be used at all, since the constant LOCALE_USER_DEFAULT could be used directly for LCID.

  Windows.SetThreadLocale(LOCALE_USER_DEFAULT);
end.
