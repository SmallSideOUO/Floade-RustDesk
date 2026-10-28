# Independent video and control connections

FloadeRemote desktop sessions negotiate a second direct WebRTC peer connection for video. Mouse, keyboard, permissions, clipboard, audio and session control keep the authenticated primary connection. Video and display-switch messages retain their order on the independent connection. A dedicated worker sends video; a full video queue prevents dequeueing more video without awaiting a media write on the control loop.

Both endpoints must run this version. The host advertises `Features.split_video` only when the Floade profile is enabled and the primary transport is peer-authenticated. The client starts negotiation only after a successful desktop login. SDP answers, offers and trickled ICE candidates travel inside that authenticated primary connection. Its authenticated SDP binds the secondary DTLS certificate to the same peer. The secondary connection carries only video and display-switch messages, never login, keyboard, mouse or permission messages. File, terminal, camera and port-forward session scopes cannot negotiate it. TURN/relay is not used.

The host pauses legacy video before sending a Ready barrier on the ordered control connection. The client consumes all preceding legacy video, then acknowledges Ready. Only after both sides are connected and the barrier is acknowledged does the host enqueue independent video. This preserves predictive-frame order across the switch. Setup has a 15-second deadline; failure before activation resumes the legacy route. Failure after activation closes the session explicitly instead of silently splicing two video streams. Session disposal closes the secondary peer connection and aborts its reader/writer.

There are at most four queued outgoing messages plus the current write, and eight pending receive events. Predictive frames are not arbitrarily dropped; the original capture/decoder feedback remains active. Each video message is limited to 16 MiB. A stalled write has a five-second deadline. The two paths share the physical network and still compete for bandwidth; their WebRTC/SCTP queues and congestion states are independent. This implementation retains reliable video transport and the existing native capture, codecs and renderer; it does not implement RTP media tracks or promise a particular physical display FPS. Audio currently remains on the primary connection.

`floade_perf` reports `video_transport: "independent-p2p"` only after activation, otherwise `"shared"`, plus `video_channel_pending_events` (received video/signaling events waiting for the session loop). Existing `shared_path_delay_ms` now describes the control path when split; it is neither secondary video delay nor input-to-display latency. `presented_fps` counts UI submissions. Set `FLOADE_RUSTDESK_SPLIT_VIDEO=0` to retain the old path in FloadeRemote; other executable profiles retain the old path by default. Older peers retain their existing wire behavior.

Validation: `cargo check --locked --lib --features flutter,hwcodec,vram`; `cargo test --locked --lib --features flutter,hwcodec,vram split_video -- --test-threads=1`. The tests exchange real encrypted WebRTC video with fragmented predictive frames and display changes, exercise independent control delivery with a full producer queue, and verify secondary close/payload rejection. They establish transport behavior on loopback, not WAN quality or input-to-display latency. Real-device acceptance requires both endpoints updated and fresh metrics showing `independent-p2p`, stable moving video, button/key releases, service readiness and preserved profiles.

## Existing paths changed

| File | Necessary effect |
| --- | --- |
| `libs/base/protos/message.proto` | Adds a backwards-compatible capability and authenticated signaling envelope. Existing message fields keep their numbers. |
| `src/lib.rs` | Registers the separate feature module. No shared dependency or submodule changes. |
| `src/server/connection.rs` | Advertises support, dispatches post-login signals, and routes video queue entries to the worker after the switch barrier. Existing authorization and permission dispatch still handles input. |
| `src/client/io_loop.rs` | Starts negotiation after supported authenticated desktop login, selects video events beside primary messages, and disposes the worker at session exit. |
| `src/client/io_loop/low_latency.rs` | Exposes the negotiated path and queue occupancy for verification. |

New transport/state logic is in `src/split_video.rs`; client/server event hooks are in their respective `split_video.rs` child modules. Existing capture/codec/presentation, credentials, saved preferences, service installation, Flutter input and non-desktop session behavior are not rewritten.
