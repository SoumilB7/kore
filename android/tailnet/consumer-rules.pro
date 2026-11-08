# gomobile's runtime and bindings are reached from Go through JNI by name.
-keep class go.** { *; }
-keep class dev.kore.tailnet.bind.** { *; }
-keep class * implements dev.kore.tailnet.bind.tailnet.Sealer { *; }
-keep class * implements dev.kore.tailnet.bind.tailnet.Binder { *; }
