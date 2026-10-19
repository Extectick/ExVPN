// SPDX-License-Identifier: Apache-2.0
// QA only: bounded, process-bound accessibility API; never exports arbitrary UI text.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.IO;
using System.Text;
using Microsoft.Win32.SafeHandles;
using Accessibility;

public static class ExvpnShorebirdMsaa {
    private delegate bool EnumCallback(IntPtr hwnd, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumCallback callback, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumThreadWindows(uint thread, EnumCallback callback, IntPtr state);
    [DllImport("user32.dll",SetLastError=true)] private static extern bool PostMessage(IntPtr hwnd,uint message,UIntPtr wparam,IntPtr lparam);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr hwnd, EnumCallback callback, IntPtr state);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd,StringBuilder text,int length);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hwnd);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern uint GetFinalPathNameByHandle(SafeFileHandle file,StringBuilder path,uint count,uint flags);
    [DllImport("oleacc.dll")] private static extern int AccessibleObjectFromWindow(IntPtr hwnd,uint id,ref Guid iid,[MarshalAs(UnmanagedType.Interface)]out IAccessible root);
    [DllImport("oleacc.dll")] private static extern int AccessibleChildren(IAccessible root,int start,int count,[Out,MarshalAs(UnmanagedType.LPArray,ArraySubType=UnmanagedType.Struct,SizeParamIndex=2)]object[] children,out int actual);
    public sealed class Result { public string Diagnostics; public List<string> Actions=new List<string>(); public int Nodes; }
    private sealed class Node { public IAccessible Parent; public int Id; public int Depth; }
    private static readonly string[] Allowed={"Настройки","Settings","Обезличенная диагностика","Anonymous diagnostics","Версии и обновления","Versions and updates","Проверить обновления","Check for updates","Загрузить патч","Download patch","Проверить","Check","Загрузить","Download","Закрыть","Close","Понятно","OK","Выйти","Exit"};
    private static string ActionName(string name) {
        if(name==null)return null;
        foreach(string label in Allowed) if(name==label || name.StartsWith(label+"\n",StringComparison.Ordinal))return label;
        return null;
    }
    private static string Hash(string path) { using(var sha=SHA256.Create())using(var file=File.OpenRead(path))return BitConverter.ToString(sha.ComputeHash(file)).Replace("-","").ToLowerInvariant(); }
    public static string Fingerprint(string path) {
        using(var file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete)) {
            if(file.Length<=0 || file.Length>512L*1024*1024)throw new InvalidOperationException("qa_continuity_input_invalid");
            var actual=new StringBuilder(32768);uint length=GetFinalPathNameByHandle(file.SafeFileHandle,actual,32768,0);
            if(length==0 || length>=32768)throw new InvalidOperationException("qa_continuity_path_unavailable");
            string resolved=actual.ToString();if(resolved.StartsWith(@"\\?\",StringComparison.Ordinal))resolved=resolved.Substring(4);
            if(!String.Equals(resolved,Path.GetFullPath(path),StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("qa_continuity_path_virtualized");
            using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(file)).Replace("-","").ToLowerInvariant();
        }
    }
    private static IntPtr MainWindow(Process process) {
        var windows=new List<IntPtr>();int count=0;
        EnumCallback callback=delegate(IntPtr window,IntPtr state){
            if(++count>1024)return false;uint owner;GetWindowThreadProcessId(window,out owner);
            if(owner==(uint)process.Id){var text=new StringBuilder(128);GetClassName(window,text,text.Capacity);if(text.ToString()=="EXVPN_RUNNER_WIN32_WINDOW")windows.Add(window);}return true;
        };
        EnumWindows(callback,IntPtr.Zero);GC.KeepAlive(callback);
        if(count>1024 || windows.Count!=1)throw new InvalidOperationException("qa_main_window_missing_or_ambiguous");
        return windows[0];
    }
    private static Process Identity(int pid,long startTicks,string expectedHash) {
        if(expectedHash==null || expectedHash.Length!=64)throw new InvalidOperationException("qa_process_binding_invalid");
        var process=Process.GetProcessById(pid);
        try {if(process.HasExited || process.StartTime.ToUniversalTime().Ticks!=startTicks || process.MainModule.FileName!="C:\\Program Files\\ExVPN\\exvpn.exe" || Hash(process.MainModule.FileName)!=expectedHash)throw new InvalidOperationException("qa_process_identity_changed");return process;}
        catch {process.Dispose();throw;}
    }
    private static IntPtr Popup(IntPtr main,int pid) {
        uint owner;uint thread=GetWindowThreadProcessId(main,out owner);
        if(owner!=(uint)pid || thread==0 || !IsWindow(main))throw new InvalidOperationException("qa_main_window_owner_changed");
        var found=new List<IntPtr>();int count=0;bool invalid=false;
        EnumCallback callback=delegate(IntPtr window,IntPtr state){
            if(++count>64)return false;uint candidateOwner;uint candidateThread=GetWindowThreadProcessId(window,out candidateOwner);
            var text=new StringBuilder(128);GetClassName(window,text,text.Capacity);
            if(text.ToString()=="#32768"){if(candidateOwner!=(uint)pid || candidateThread!=thread || !IsWindow(window)){invalid=true;return false;}found.Add(window);}return true;
        };
        EnumThreadWindows(thread,callback,IntPtr.Zero);GC.KeepAlive(callback);
        if(invalid || count>64 || found.Count>1)throw new InvalidOperationException("qa_popup_ambiguous");return found.Count==0?IntPtr.Zero:found[0];
    }
    public static void OpenExitMenu(int pid,long startTicks,string expectedHash) {
        using(var process=Identity(pid,startTicks,expectedHash)) {
            var main=MainWindow(process);if(Popup(main,pid)!=IntPtr.Zero)throw new InvalidOperationException("qa_popup_preexisting");
            // Real owned tray callback. Never send WM_APP+73, which skips Dart flush.
            if(!PostMessage(main,0x8048,UIntPtr.Zero,new IntPtr(0x1007b)))throw new InvalidOperationException("qa_tray_callback_failed");
        }
    }
    public static Result Run(int pid,long startTicks,string expectedHash,string action) {
        bool invoke=!String.IsNullOrEmpty(action);
        bool exitMenu=action=="Выйти из ExVPN…";
        if(invoke && !exitMenu && Array.IndexOf(Allowed,action)<0)throw new InvalidOperationException("qa_action_refused");
        using(var process=Identity(pid,startTicks,expectedHash)) {
            var main=MainWindow(process);
            uint owner;GetWindowThreadProcessId(main,out owner);if(owner!=(uint)pid || !IsWindow(main))throw new InvalidOperationException("qa_main_window_owner_changed");
            var watch=Stopwatch.StartNew();var windows=new List<IntPtr>();int visited=0;
            EnumCallback callback=delegate(IntPtr child,IntPtr unused){if(++visited>64)return false;var text=new StringBuilder(128);GetClassName(child,text,text.Capacity);GetWindowThreadProcessId(child,out owner);if(text.ToString()=="FLUTTERVIEW" && owner==(uint)pid)windows.Add(child);return true;};
            if(exitMenu){var popup=Popup(main,pid);if(popup==IntPtr.Zero)throw new InvalidOperationException("qa_exit_menu_missing");windows.Add(popup);}
            else {EnumChildWindows(main,callback,IntPtr.Zero);GC.KeepAlive(callback);if(visited>64 || windows.Count!=1)throw new InvalidOperationException("qa_flutter_window_ambiguous");}
            var leases=new List<object>();var matches=new List<Node>();var result=new Result();
            try {
                var iid=new Guid("618736e0-3c3d-11cf-810c-00aa00389b71");IAccessible root;
                if(AccessibleObjectFromWindow(windows[0],0xfffffffcu,ref iid,out root)<0 || root==null)throw new InvalidOperationException("qa_accessibility_not_ready");
                leases.Add(root);var queue=new Queue<Node>();queue.Enqueue(new Node{Parent=root,Id=0,Depth=0});
                while(queue.Count>0) {
                    if(watch.ElapsedMilliseconds>8000 || ++result.Nodes>2048)throw new InvalidOperationException("qa_accessibility_bound");
                    var node=queue.Dequeue();if(node.Depth>64)throw new InvalidOperationException("qa_accessibility_depth");
                    var name=node.Parent.get_accName(node.Id);var role=node.Parent.get_accRole(node.Id);var state=node.Parent.get_accState(node.Id);
                    if(!(role is int)||!(state is int))throw new InvalidOperationException("qa_accessibility_type");
                    if((((int)state)&(1|0x8000|0x10000))==0) {
                        var label=exitMenu && name=="Выйти из ExVPN…" && (int)role==12?name:ActionName(name);
                        if(label!=null && (int)role==(exitMenu?12:43)){result.Actions.Add(label);if(label==action)matches.Add(node);}
                    }
                    string diagnosticText=name;
                    if(diagnosticText==null || !diagnosticText.Contains("\"currentDartPatch\"")) {
                        if((int)role==42)try{diagnosticText=node.Parent.get_accValue(node.Id);}catch(COMException){}
                    }
                    if(diagnosticText!=null && diagnosticText.Length<=8192 && diagnosticText.Contains("\"currentDartPatch\"") && diagnosticText.Contains("\"application\"")) {
                        var candidate=diagnosticText.Trim();
                        if(candidate.StartsWith("{",StringComparison.Ordinal) && candidate.EndsWith("}",StringComparison.Ordinal)){
                            if(result.Diagnostics!=null && result.Diagnostics!=candidate)throw new InvalidOperationException("qa_diagnostics_ambiguous");result.Diagnostics=candidate;
                        }
                    }
                    if(node.Id!=0)continue;
                    var count=node.Parent.accChildCount;if(count<0 || count+queue.Count+result.Nodes>2048)throw new InvalidOperationException("qa_accessibility_count");
                    if(count==0)continue;var items=new object[count];int actual;
                    if(AccessibleChildren(node.Parent,0,count,items,out actual)<0 || actual<0 || actual>count)throw new InvalidOperationException("qa_accessibility_children");
                    for(int i=0;i<actual;i++){var child=items[i] as IAccessible;if(child!=null){leases.Add(child);queue.Enqueue(new Node{Parent=child,Id=0,Depth=node.Depth+1});}else if(items[i] is int && (int)items[i]>0){queue.Enqueue(new Node{Parent=node.Parent,Id=(int)items[i],Depth=node.Depth+1});}else throw new InvalidOperationException("qa_accessibility_variant");}
                }
                if(invoke) {
                    if(matches.Count!=1)throw new InvalidOperationException("qa_action_missing_or_ambiguous");
                    var target=matches[0];var name=target.Parent.get_accName(target.Id);var role=target.Parent.get_accRole(target.Id);var state=target.Parent.get_accState(target.Id);
                    GetWindowThreadProcessId(main,out owner);
                    if(owner!=(uint)pid || !IsWindow(main) || process.HasExited ||
                        (exitMenu?(Popup(main,pid)!=windows[0] || name!="Выйти из ExVPN…"):ActionName(name)!=action) ||
                        !(role is int) || (int)role!=(exitMenu?12:43) || !(state is int) || (((int)state)&(1|0x8000|0x10000))!=0)throw new InvalidOperationException("qa_action_changed");
                    target.Parent.accDoDefaultAction(target.Id);
                }
                return result;
            } finally { for(int i=leases.Count-1;i>=0;i--)if(Marshal.IsComObject(leases[i]))Marshal.ReleaseComObject(leases[i]); }
        }
    }
}
