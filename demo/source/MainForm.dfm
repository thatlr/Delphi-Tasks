object fMainForm: TfMainForm
  Left = 458
  Top = 508
  Caption = 'GUI Task Demo'
  ClientHeight = 161
  ClientWidth = 411
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  Menu = TMainMenu
  OldCreateOrder = False
  OnActivate = FormActivate
  OnClose = FormClose
  PixelsPerInch = 96
  TextHeight = 13
  object btCountPrimeNumbers: TButton
    Left = 16
    Top = 44
    Width = 181
    Height = 33
    Caption = 'Count Prime numbers'
    TabOrder = 0
    OnClick = btCountPrimeNumbersClick
  end
  object btOpenMsgBox: TButton
    Left = 216
    Top = 44
    Width = 181
    Height = 33
    Caption = 'Open MessageBox'
    TabOrder = 1
    OnClick = btOpenMsgBoxClick
  end
  object Panel1: TPanel
    Left = 16
    Top = 96
    Width = 377
    Height = 49
    BevelOuter = bvLowered
    DoubleBuffered = True
    ParentBackground = False
    ParentDoubleBuffered = False
    TabOrder = 2
    object lblPrimeResult: TLabel
      Left = 1
      Top = 1
      Width = 375
      Height = 47
      Align = alClient
      AutoSize = False
      Caption = 'lblPrimeResult'
      Color = clBtnFace
      ParentColor = False
      Transparent = False
      WordWrap = True
      ExplicitWidth = 66
      ExplicitHeight = 13
    end
  end
  object Panel2: TPanel
    Left = 16
    Top = 8
    Width = 137
    Height = 18
    BevelOuter = bvLowered
    DoubleBuffered = True
    ParentBackground = False
    ParentDoubleBuffered = False
    TabOrder = 3
    object lblRGB: TLabel
      Left = 1
      Top = 1
      Width = 135
      Height = 16
      Align = alClient
      AutoSize = False
      Caption = 'lblRGB'
      Color = clBtnFace
      ParentColor = False
      Transparent = False
      Layout = tlCenter
      ExplicitLeft = 8
      ExplicitTop = 8
      ExplicitWidth = 30
      ExplicitHeight = 13
    end
  end
  object TMainMenu: TMainMenu
    object TMenu: TMenuItem
      Caption = 'Menu'
      object TMemuItem: TMenuItem
        Caption = 'MenuItem'
      end
    end
  end
end
