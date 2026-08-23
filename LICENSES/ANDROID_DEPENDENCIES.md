# Android dependency notices

The following libraries are packaged into the DawnShell APK through Gradle.
Their resolved versions are fixed by `app/build.gradle` and the transitive
dependency metadata fetched by Gradle.

## Apache License 2.0

The following project families are distributed under the Apache License 2.0.
The full license is in `Apache-2.0.txt`.

- AndroidX libraries, including AppCompat, Activity, Annotation, Arch,
  Collection, Concurrent, ConstraintLayout, Core, CursorAdapter, CustomView,
  DocumentFile, DrawerLayout, DynamicAnimation, Emoji2, Fragment,
  Interpolator, Lifecycle, Loader, LocalBroadcastManager, Print,
  ProfileInstaller, RecyclerView, ResourceInspection, SavedState, Startup,
  Tracing, Transition, VectorDrawable, VersionedParcelable, ViewPager and
  ViewPager2. Copyright The Android Open Source Project.
- Material Components for Android 1.12.0. Copyright Google LLC.
- Kotlin standard library 1.8.22 and kotlinx.coroutines 1.6.4. Copyright
  JetBrains s.r.o. and Kotlin contributors.
- JetBrains annotations 13.0. Copyright JetBrains s.r.o.
- Error Prone annotations 2.15.0 and Guava `listenablefuture` 1.0. Copyright
  Google LLC.

## CC0 1.0 Universal

- EdDSA-Java 0.3.0 (`net.i2p.crypto:eddsa`), by str4d and contributors. The
  complete CC0 legal code is in `CC0-1.0.txt`.

JUnit and its test-only dependencies are not packaged in the APK.
