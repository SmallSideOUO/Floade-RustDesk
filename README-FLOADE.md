# Floade Remote engine

This is an independent AGPL-3.0 modification of RustDesk 1.5.0 (upstream fada664df7a294d1d1a9ca3e7cd3637069122f17). The Flutter remote windows and connection manager remain native; Floade-need supplies the landing page, manual preferences and local named-pipe API. The managed frontend starts hidden with --floade-managed. The executable must be named FloadeRemote.exe to select its independent native identity/profile. No RustDesk host identity is copied.

## Rebuild on Windows x64

Install Visual Studio 2022 Desktop development with C++, Git, Python, and Flutter 3.24.5. Clone this repository with --recurse-submodules. Apply .github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff to that Flutter checkout, as in upstream CI. Do not upgrade Flutter or the FFI bridge independently.

The supplied scripts use isolated tooling under .floade-tools: rustup (Rust 1.75.0 and rustfmt), cargo, flutter, llvm, and vcpkg. Set RUSTUP_HOME and CARGO_HOME to those directories when bootstrapping Rust. Create the current user's .frd-cargo directory junction targeting this checkout's .floade-tools/cargo to keep dependency paths short on Windows. Install cargo-expand 1.0.95 and flutter_rust_bridge_codegen 1.80.1 with --locked and --features uuid for the latter. The original upstream bridge workflow documents generator dependencies.

Use vcpkg commit 9e593bb18ea69cc5095e012465dcd675a822ed0d with the committed vcpkg.json/vcpkg-configuration.json and x64-windows-static triplet. Install the default dependencies plus hwcodec and av1 features (FFmpeg 7.1.1, libvpx, AOM, Opus, libyuv and JPEG dependencies). scripts/floade-build.ps1 validates required headers. Supply LLVM libclang 15: this build used the libclang 15.0.6.1 Python wheel extracted under .floade-tools/llvm. The UI build script creates the bin/libclang.dll layout needed by Dart ffigen without changing the Windows registry.

Clone Flutter tag 3.24.5 into .floade-tools/flutter, run flutter precache --windows, then flutter pub get in flutter/. If developer-mode symlinks are unavailable, precreate directory junctions under flutter/windows/flutter/ephemeral/.plugin_symlinks for the paths in .flutter-plugins-dependencies and rerun pub get. This requires no administrator privileges. Use the committed pubspec.lock.

Use scripts/floade-prepare-engine.ps1 before building Flutter. It verifies the SHA-256-pinned RustDesk Flutter engine release and installs both flutter_windows.dll and its matching gen_snapshot.exe into the isolated SDK. scripts/floade-engine.json records the artifact digest and engine source revision bc374ca81eae3f77329ebf7bc98efadfde10018e (https://github.com/rustdesk/engine). Replacing only the DLL creates an incompatible AOT snapshot. The application, native library, plugins and Flutter AOT snapshot are rebuilt together with this paired engine and generator. If changing an existing SDK, move its flutter/.dart_tool/flutter_build cache aside before rebuilding.

Run scripts/floade-build-ui.ps1. It generates both Rust and Dart bridge files, builds the native library with flutter,hwcodec,vram, builds Flutter with FLOADE_REMOTE=true, and stages a checksummed runtime under floade-artifacts/branded-windows-x64. scripts/floade-test-core.ps1 runs the three presentation/feedback regressions; flutter analyze --no-pub lib/floade/control.dart checks the local control implementation. Native test runs use cargo test --locked --lib --features flutter,hwcodec,vram client::low_latency.

Copy the staged runtime into Floade-need/vendor/remote/windows-x64 before packaging that application. Include the exact source revision, license, runtime manifest and these build instructions in the corresponding release. The native per-launch control token stays only in the current user's profile and must never be included in release assets.

## Changed paths and limits

Client decode/presentation and statistics changes are opt-in with FLOADE_RUSTDESK_LOW_LATENCY=1; decoding order and media recording are retained. core_main selects a separate profile by executable name and accepts the managed-start flag. flutter_ffi adds a validated peer-display preference operation. Flutter main starts the loopback capability bridge and hides the main page; the native tabbar/theme/resource files provide Floade branding. One legacy debug statement was redacted because it exposed connection arguments. Original paths remain when the feature is disabled or the executable has its original name.

The per-user engine can receive connections on the signed-in desktop. Windows login-screen/UAC access requires native service installation and administrator privileges. P2P may fall back to relay. Diagnostic delay is a shared-channel measurement, not mouse-to-display latency, and the FPS metric counts presentation submissions. See FLOADE-PERFORMANCE.md for the earlier test baseline and its limits.

Floade initializes its device ID once with the upstream random-ID operation and persists a local marker. A separate profile alone is insufficient: upstream MAC-derived IDs can otherwise collide with an existing RustDesk on the same host. Later restarts preserve the initialized ID and existing password/key material.

The stager also collects the pinned Flutter engine notices, vcpkg copyright files and cached Rust dependency licenses into THIRD-PARTY-NATIVE-NOTICES.txt; Flutter's generated asset notices remain included. These text files are part of the checksummed runtime.

Floade control exposes the native TCP/UDP/WebRTC punch options without modifying the wire protocol. API disconnect clears native tabs and hides their window for reuse, rather than destroying a Flutter sub-engine. Credential-bearing method arguments are excluded from desktop tab diagnostics.

## Incoming full access

The managed local control exposes `accessGet` and `accessSet`, implemented in `flutter/lib/floade/access.dart`. This opts into the existing full access mode with an incoming ID allowlist; password authentication remains mandatory. IDs are self-reported and are a filter, not cryptographic device identity. An enabled empty list uses a nonmatching sentinel to deny all; disabling restores the previous native mode/filter. Changes apply to new incoming sessions. Existing Rust authentication, permission checks and Windows system-service installer paths are unchanged.

Floade-need invokes the upstream native silent installer (printer=0) to create the independent `FloadeRemote` LocalSystem service in Program Files. Administrator/UAC/login-screen support requires actual Windows consent and service readiness; requesting installation alone does not establish either.

## Windows relative mouse (Floade 0.1.29)

Floade Windows sessions use foreground-only WM_INPUT counts, batched every 8 ms, instead of Flutter logical cursor positions. This preserves physical mouse counts across DPI scaling and removes cursor-warp events from the movement stream. The cursor is confined while enabled and released on toggle, focus loss, window movement or destruction. A lost capture exits relative mode. Ordinary pointer, keyboard and button delivery remains available outside this opt-in mode.

Regression surface: `relative_mouse_model.dart` selects and cleans up the Floade Windows input path; `input_model.dart` blocks absolute canvas refresh/edge movement during that mode; `flutter_window.cpp` registers the plugin for main and remote subwindows; runner CMake includes the new implementation. New logic lives in `floade_raw_mouse.dart` and `floade_raw_mouse.cpp`. Other platforms and non-Floade builds retain their prior input path. No Rust, protocol, dependencies, authentication or incoming permission changes.

Validation: raw-count delivery and lost-capture tests, existing shortcut tests, Flutter analysis and Windows release build. Physical mouse sensitivity in a real remote game still requires end-to-end verification.

## Windows floating preview

Floade desktop sessions provide a view-only, always-on-top mini preview in both the tab bar and the remote toolbar. The same session and decoded GPU texture/image remain active. The preview can be dragged, resized proportionally, collapsed to a label, and restored by double-clicking; closing it collapses it without disconnecting. Preview geometry and the optional minimize-to-preview preference are stored separately from normal window geometry. Authentication/network state remains visible and the full window remains available for prompts. Static images are not treated as connection failures. Streaming FPS/quality are preserved rather than changing a peer's global preferences for a local preview.

Regression surface: `remote_page.dart` releases input focus and selects the preview body only in Floade Windows sessions; `remote_tab_page.dart` supplies the entry button, opt-in minimize listener, local-control commands and cleanup; `remote_toolbar.dart` supplies an optional fullscreen entry button; `tabbar_widget.dart` skips normal-geometry writes during preview. `control.dart` advertises/routes preview commands for existing active windows. `flutter_window.cpp` and runner `CMakeLists.txt` register/build the new Windows preview plugin. Implementation lives in `floade/mini_preview.dart` and `floade_mini_preview.cpp/.h`. Other platforms and non-Floade builds retain their normal session UI. No Rust, wire protocol, dependencies or incoming permissions changed.
