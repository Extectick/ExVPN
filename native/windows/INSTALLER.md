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

Close ExVPN in all sessions. Maintenance holds its global per-user mutex and
refuses to kill UI processes. Upgrade requires a larger build number and the same
IPC owner. The service's explicit maintenance control 128 disconnects the tunnel
before stopping; ordinary stop/shutdown retains the persistent protection latch.

Before replacement, the installer verifies all owned hashes/ACLs and copies the
previous package to a protected GUID directory under `Program Files/ExVPN Rollback`.
Unknown/changed files, foreign service configuration or a remaining TUN adapter
stop maintenance. If replacement fails after removal, the previous package is
restored when the known files can be safely cleaned. The rollback copy is retained
for diagnosis; failure never triggers blanket firewall/DNS resets.

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
maintenance checks, deletes only unchanged manifest-owned files and the exact
service/product registration, and retains encrypted per-user subscriptions.
Unknown/modified files cause a preflight failure. Installer extraction and cleanup
use fixed file lists and protected staging, never `RMDir /r` on an installation root.

## Windows Sandbox option (not enabled by this work)

The current host inventory has Windows Sandbox/Hyper-V disabled. Enabling Sandbox
is a separate administrator action and may require a reboot; neither is performed
by this package. A future `.wsb` can expose only the installer directory read-only,
disable clipboard/printer/audio/video redirection, and leave networking enabled
inside the disposable guest for explicit tunnel tests. Do not expose `.private`
or the whole repository. Sandbox is suitable for install/uninstall and basic
network tests; it does not replace persistent reboot/sleep and Windows 10/11 VM
coverage. Closing Sandbox discards its guest state.

Sources: [NSIS](https://nsis.sourceforge.io/Download),
[licenses](https://nsis.sourceforge.io/License),
[service control permissions](https://learn.microsoft.com/en-us/windows/win32/api/winsvc/nf-winsvc-controlservice),
[Sandbox configuration](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file).
