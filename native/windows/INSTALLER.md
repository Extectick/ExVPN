# Controlled Windows installer and recovery

Development package, not a stable signed VPN release. E1/E5 system acceptance
remains open. The installer is built offline from pinned local inputs; compilation
does not install a service or change host networking.

## Build

Build the release Flutter UI, Go service and pinned Wintun first. Then run
`scripts/windows/build-installer.ps1 -Offline` from PowerShell 7. The output is a
fresh `artifacts/windows/package-*` directory containing the reviewable payload,
file hashes, generated fixed NSIS file list, artifact hash and unsigned installer.
The full notices bundle, matching source archive and module inventory are included.

NSIS 3.13 comes from the official SourceForge release; URL/archive/compiler hashes
are in `scripts/windows/nsis.lock.json`. The installed license copy preserves
zlib/libpng, bzip2 and CPL/LZMA notices. No third-party NSIS plugins are added.
Three pinned Microsoft C++ runtime DLLs are copied app-locally from the installed
release VS toolset after hash, version, Microsoft Authenticode and PE-import checks.
Their separate license and redistribution notice are included. No global C++
runtime installation is performed. See `scripts/windows/msvc-runtime.lock.json`.

## Installation on a controlled test machine

1. Use a disposable Windows 10/11 x64 VM, snapshot and local console access.
   Copy the installer into the VM. Do not run network testing on the working host.
2. Run the installer through the ordinary Windows UAC prompt. It detects the
   intended UI user's SID from Explorer in the same session. For another account,
   launch with `/OWNER_SID=S-1-5-21-...`. It never silently binds IPC to an alternate
   administrator account used only for UAC.
3. Network testing is off by default. The service starts for IPC, but connect
   returns `system_testing_required`. Enable the explicit checkbox (or
   `/NETWORK_TESTING=1`) only in the prepared VM.
4. Launch ExVPN from Start as the ordinary desktop user. Setup never launches the
   UI elevated. Add only private/local test profiles; screenshots and logs must
   exclude credentials and provider URLs.

Fixed protected locations: `Program Files/ExVPN` (UI), `ExVPN Service` (LocalSystem
service), and `ExVPN Installer` (manifest, maintenance scripts and notices).
Administrators/SYSTEM own and write files; ordinary users have read/execute only.
An explicit service ACL reserves start/stop/custom maintenance for administrators.
The named pipe additionally binds the expected user SID and exact protected UI path.

## Upgrade and rollback

Close ExVPN in all sessions. Before reading installed state, maintenance acquires
the machine-wide `Global\ExVPN.PackageMaintenance.v1` mutex with SYSTEM/Admin-only
owner/ACL validation. Existing user-owned or unexpected-ACL objects fail closed;
contention returns immediately. The global per-user UI mutex remains held too,
and maintenance refuses to kill UI processes. Upgrade requires a larger build number and the same
IPC owner. The service's explicit maintenance control 128 disconnects the tunnel
before stopping; ordinary stop/shutdown retains the persistent protection latch.

Before replacement, the installer verifies all owned hashes/ACLs and copies the
previous package to a protected GUID directory under `Program Files/ExVPN Rollback`.
Unknown/changed files, foreign service configuration or a remaining TUN adapter
stop maintenance. The in-memory transaction phase changes before the first service/file
removal. If removal fails partway, recovery verifies every survivor across all
trees and restores missing old files without overwriting an unchanged locked DLL.
If writing the replacement fails, only verified replacement files are cleaned
before restoring the previous package. Explicit rollback uses the same flow and
first preserves the currently installed version as a separate protected backup.

An unknown/modified survivor or locked replacement file stops automatic recovery.
The error explicitly says `automatic recovery is INCOMPLETE` and identifies the
protected previous package; it never claims that restoration succeeded. Preserve
the remaining files, protected staging and rollback snapshot for inspection. In
the disposable test machine, restore the VM snapshot or perform separately
reviewed recovery after identifying the file owner/lock; do not delete unknown
files, force-unlock processes, or reset global firewall/DNS settings.

An explicit previous-version rollback uses the installed uninstaller with
`/ROLLBACK=1`. This restores binaries and service configuration, not private
subscription data or an automatically connected session. Rollback snapshots are
retained by uninstall; archive/remove them only after a separate reviewed cleanup.

## Recovery and uninstall

The installed `ExVPN Installer/Uninstall.exe /RECOVER=1` runs administrator
maintenance, stops/disconnects the owned service, then removes only ExVPN WFP keys.
The service remains stopped. If an abandoned `ExVPN-Tunnel` adapter remains, the
script refuses to infer ownership from its name: restore the VM snapshot or
perform separately reviewed adapter recovery. Do not reset unrelated routes/DNS.

Normal uninstall uses Apps & Features or `Uninstall.exe`. It performs the same
maintenance checks and creates a verified protected backup before deleting the
service or any installed file. It deletes only unchanged manifest-owned files
and the exact service/product registration, and retains encrypted per-user
subscriptions. Partial deletion or registration failure restores missing known
files and the owned service from the backup; an unchanged locked DLL is retained.
Unknown/modified survivors stop recovery with an explicit `INCOMPLETE` result.
The backup is retained after successful uninstall too.
Unknown/modified files cause a preflight failure. Installer extraction and cleanup
use fixed file lists and protected staging, never `RMDir /r` on an installation root.

## Windows Sandbox bundle (prepared, not executed)

Run `scripts/windows/prepare-sandbox.ps1 -InstallerDirectory <package directory>`.
This writes a fresh `artifacts/windows/sandbox-*` bundle without launching Sandbox.
Its `.wsb` maps only four public package files plus their checksums read-only and a
separate empty `qa-output` folder writable. Clipboard, audio/video and printer
redirection are disabled. The repository and `.private` are never shared. The
standard Sandbox virtual network is enabled; ExVPN network testing stays off.

Opening this `.wsb` runs the guest QA script automatically. It verifies the exact
`WDAGUtilityAccount`, expected guest path, forbidden host identity and input hashes
before any elevation or installation. The guest tests silent install, protected
file hashes/ACLs, LocalSystem SCM identity, explicit recovery, service restart,
uninstall, and unchanged guest route/DNS fingerprints. Results go to
`qa-output/result.json`; treat all guest output as untrusted data, never executable
host instructions. A failed run leaves guest state for inspection and never resets
the host firewall, routes or DNS. Prepare a new bundle for each run.

The script deliberately reports UI/IPC, TUN/WFP/crash coverage, version-pair upgrade
and rollback, reboot/sleep and Windows 10 as untested. Those require subsequent
controlled scenarios, not an installer-compilation checkbox. Enablement of the
Sandbox optional feature and any host reboot are separate operations; this bundle
does neither. Closing Sandbox discards its guest state.

## Local build evidence (2026-10-16)

Pinned NSIS 3.13 compiled the unsigned installer offline; all expanded compiler,
stub and built-in plugin files were checked against the pinned archive. Manifest
tests reject traversal, duplicate targets, foreign rollback paths and cleanup of
unknown/changed files. Windows PowerShell 5.1 parsed the scripts and inspected the
complete payload without elevated/system actions. Flutter Windows release and
Go service builds passed. Thirteen package transaction tests run with real temporary
files and Windows file-sharing locks, with SCM/ACL/registration mocked: partial
old removal after service deletion, unknown/modified survivors, partial new copy,
locked replacement, failed explicit rollback, successful upgrade and successful
explicit rollback, partial uninstall with a locked second DLL, unknown/modified
uninstall survivors, successful uninstall and registration-removal failure.
Windows/Checks CI runs the suite through Windows PowerShell 5.1. These prove local
recovery behavior, not installed SCM/ACL
acceptance. The real release window displays the approved squirrel
in its title bar. Fresh Sandbox installation, exact service ACL readback,
recovery/restart and uninstall now pass with network testing disabled. Guest
route/DNS fingerprints are unchanged. The first live run exposed a sign-extended
WFP DWORD status; it is now normalized before comparing FWP_E_* values. SCM also
expands GENERIC_ALL into concrete service rights, which are now validated rather
than matching SDDL text. Extra principals and interactive control rights fail.
See `docs/evidence/windows-sandbox-installer-smoke.json`. Upgrade, rollback and
removal after an active VPN remain open in E5-004. No installer or service was
run on the host. Source: [b2f4e42](https://github.com/Extectick/ExVPN/commit/b2f4e427075af5f5592904f0f6fdbdc82755af54).
Mock multi-instance checks cover different IPC owners contending for the same
maintenance lock, nonblocking busy behavior and hijacked-owner/ACL refusal.
The installed single-instance elevated mutex/ACL path passed in Sandbox;
concurrent elevated instances and power-loss recovery still require guest tests.
The transaction phase is not a durable power-loss journal.

Sources: [NSIS](https://nsis.sourceforge.io/Download),
[licenses](https://nsis.sourceforge.io/License),
[service control permissions](https://learn.microsoft.com/en-us/windows/win32/api/winsvc/nf-winsvc-controlservice),
[Sandbox configuration](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file).
