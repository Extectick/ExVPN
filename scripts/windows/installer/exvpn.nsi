Unicode true
Target x86-unicode
ManifestDPIAware true
ManifestLongPathAware true
RequestExecutionLevel admin
SetCompressor /SOLID lzma
Name "ExVPN development"
OutFile "${OUTPUT_FILE}"
InstallDir "$PROGRAMFILES64\ExVPN"
Icon "${ICON_FILE}"
UninstallIcon "${ICON_FILE}"
VIProductVersion "${PRODUCT_VERSION}"
VIAddVersionKey "ProductName" "ExVPN development"
VIAddVersionKey "FileDescription" "ExVPN controlled Windows test installer"
VIAddVersionKey "FileVersion" "${DISPLAY_VERSION}"
VIAddVersionKey "LegalCopyright" "ExVPN contributors; Apache-2.0"
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!include "WinVer.nsh"
!include "FileFunc.nsh"
!include "nsDialogs.nsh"
!include "${GENERATED_INCLUDE}"
Var Stage
Var OwnerSid
Var NetworkArg
Var NetworkCheckbox
Var AppUpdateArg
Var MaintenanceAction
Var Parameters

!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TEXT "Development package for a controlled Windows test machine. VPN/WFP acceptance is incomplete. Close ExVPN in every session before installation or upgrade.$\r$\n$\r$\nThe installer prepares protected files, a LocalSystem service and a recovery copy. It does not launch the desktop UI with administrator privileges."
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${LICENSE_FILE}"
!insertmacro MUI_PAGE_LICENSE "${RUNTIME_TERMS_FILE}"
Page custom OptionsPage OptionsLeave
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "ExVPN requires Windows x64." /SD IDOK
    Abort
  ${EndIf}
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_ICONSTOP "ExVPN requires Windows 10 or newer." /SD IDOK
    Abort
  ${EndIf}
  SetRegView 64
  SetShellVarContext all
  StrCpy $OwnerSid "AUTO"
  StrCpy $NetworkArg ""
  StrCpy $AppUpdateArg ""
  ${GetParameters} $Parameters
  ${GetOptions} $Parameters "/OWNER_SID=" $0
  ${IfNot} ${Errors}
    StrCpy $OwnerSid $0
  ${EndIf}
  ${GetOptions} $Parameters "/NETWORK_TESTING=" $0
  ${If} $0 == "1"
    StrCpy $NetworkArg "-EnableNetworkTesting"
  ${EndIf}
  ${GetOptions} $Parameters "/APP_UPDATE=" $0
  ${IfNot} ${Errors}
    ${If} $0 != "1"
      Abort "Invalid application update mode."
    ${EndIf}
    StrCpy $AppUpdateArg "-RequireDisconnected"
  ${EndIf}
  ; No untrusted command-line characters may reach the PowerShell argument.
  ${If} $OwnerSid != "AUTO"
    StrLen $1 $OwnerSid
    ${If} $1 > 100
      Abort "Invalid owner SID."
    ${EndIf}
    StrCpy $2 0
    sid_loop:
      StrCpy $3 $OwnerSid 1 $2
      StrCmp $3 "" sid_done
      StrCmp $3 "S" sid_next
      StrCmp $3 "-" sid_next
      StrCmp $3 "0" sid_next
      StrCmp $3 "1" sid_next
      StrCmp $3 "2" sid_next
      StrCmp $3 "3" sid_next
      StrCmp $3 "4" sid_next
      StrCmp $3 "5" sid_next
      StrCmp $3 "6" sid_next
      StrCmp $3 "7" sid_next
      StrCmp $3 "8" sid_next
      StrCmp $3 "9" sid_next
      Abort "Invalid owner SID."
    sid_next:
      IntOp $2 $2 + 1
      Goto sid_loop
    sid_done:
  ${EndIf}
FunctionEnd

Function OptionsPage
  nsDialogs::Create 1018
  Pop $0
  ${NSD_CreateLabel} 0 0 100% 42u "The desktop account is detected from Explorer in this session. For a different account use /OWNER_SID=S-1-5-21-... . All product paths are fixed under Program Files."
  Pop $0
  ${NSD_CreateCheckbox} 0 55u 100% 25u "Allow VPN network testing on this controlled machine"
  Pop $NetworkCheckbox
  ${If} $NetworkArg != ""
    ${NSD_Check} $NetworkCheckbox
  ${EndIf}
  ${NSD_CreateLabel} 0 90u 100% 45u "Default: service/IPC only. Enabling testing permits a later Connect action to change routes, DNS and WFP. Use an isolated VM with a snapshot and local recovery access."
  Pop $0
  nsDialogs::Show
FunctionEnd
Function OptionsLeave
  ${NSD_GetState} $NetworkCheckbox $0
  StrCpy $NetworkArg ""
  ${If} $0 == ${BST_CHECKED}
    StrCpy $NetworkArg "-EnableNetworkTesting"
  ${EndIf}
FunctionEnd

!macro DefineProtectedStage PREFIX
Function ${PREFIX}CreateProtectedStage
  ; Ensure newly extracted files have an Administrators owner, not an ordinary
  ; account able to replace its DACL. Fail before extraction on unusual tokens.
  System::Call 'advapi32::OpenProcessToken(p -1, i 8, *p .r0) i.r1'
  StrCmp $1 0 stage_error
  System::Alloc 512
  Pop $2
  System::Call 'advapi32::GetTokenInformation(p r0, i 4, p r2, i 512, *i .r3) i.r1'
  System::Call 'kernel32::CloseHandle(p r0)'
  StrCmp $1 0 stage_token_error
  System::Call '*$2(p .r4)'
  System::Call 'advapi32::ConvertStringSidToSidW(w "S-1-5-32-544", *p .r5) i.r1'
  StrCmp $1 0 stage_token_error
  System::Call 'advapi32::EqualSid(p r4, p r5) i.r1'
  System::Call 'kernel32::LocalFree(p r5)'
  System::Free $2
  StrCmp $1 0 stage_error
  System::Alloc 16
  Pop $0
  System::Call 'ole32::CoCreateGuid(p r0) i.r1'
  StrCmp $1 0 +2
    Goto stage_guid_error
  System::Call 'ole32::StringFromGUID2(p r0, w .r2, i 40) i.r1'
  System::Free $0
  StrCmp $1 0 stage_error
  StrCpy $Stage "$PROGRAMFILES64\ExVPN Setup $2"
  System::Call 'kernel32::CreateDirectoryW(w "$Stage", p 0) i.r1'
  StrCmp $1 0 stage_error
  System::Call 'advapi32::ConvertStringSecurityDescriptorToSecurityDescriptorW(w "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", i 1, *p .r0, p 0) i.r1'
  StrCmp $1 0 stage_error
  System::Call 'advapi32::SetFileSecurityW(w "$Stage", i 0x80000007, p r0) i.r1'
  System::Call 'kernel32::LocalFree(p r0)'
  StrCmp $1 0 stage_error
  Return
  stage_guid_error:
    System::Free $0
    Goto stage_error
  stage_token_error:
    System::Free $2
  stage_error:
    Abort "Cannot create secure installer staging. No package was installed."
FunctionEnd
!macroend
!insertmacro DefineProtectedStage ""
!insertmacro DefineProtectedStage "un."

Section "ExVPN" SEC_MAIN
  Call CreateProtectedStage
  !insertmacro ExtractPayload
  WriteUninstaller "$Stage\Uninstall.exe"
  nsExec::ExecToLog '"$WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$Stage\control\package.ps1" -Action Install -PayloadRoot "$Stage" -OwnerSid "$OwnerSid" $NetworkArg $AppUpdateArg'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "Installation failed (code $0). Protected staging remains at:$\r$\n$Stage$\r$\nDo not reset global firewall or DNS settings. Use the controlled recovery instructions." /SD IDOK
    SetErrorLevel 1
    Abort
  ${EndIf}
  SetOutPath "$PROGRAMFILES64"
  !insertmacro RemoveStaging
SectionEnd

Function un.onInit
  SetRegView 64
  SetShellVarContext all
  StrCpy $MaintenanceAction "Uninstall"
  ${GetParameters} $Parameters
  ${GetOptions} $Parameters "/RECOVER=" $0
  ${If} $0 == "1"
    StrCpy $MaintenanceAction "Recover"
  ${EndIf}
  ${GetOptions} $Parameters "/ROLLBACK=" $0
  ${If} $0 == "1"
    StrCpy $MaintenanceAction "Rollback"
  ${EndIf}
FunctionEnd
Section "Uninstall"
  Call un.CreateProtectedStage
  !insertmacro ExtractMaintenance
  nsExec::ExecToLog '"$WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$Stage\control\package.ps1" -Action $MaintenanceAction'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "Maintenance failed (code $0). Existing files/recovery data are retained. Inspect the controlled recovery instructions." /SD IDOK
    SetErrorLevel 1
    Abort
  ${EndIf}
  SetOutPath "$PROGRAMFILES64"
  Delete "$Stage\control\package.ps1"
  Delete "$Stage\control\package-common.ps1"
  RMDir "$Stage\control"
  RMDir "$Stage"
SectionEnd
