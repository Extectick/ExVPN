# JNI resolves these names and callback signatures directly.
-keep class ru.exvpn.exvpn.NativeCore { *; }
-keepclassmembers class ru.exvpn.exvpn.ExVpnService {
    public boolean protectSocket(int);
    public int connectionOwner(int, java.lang.String, int, java.lang.String, int);
}
