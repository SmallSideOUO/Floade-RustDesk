# Floade / RustDesk 低延遲調查與實驗

## 實測資料與界線

2026-10-12，Windows 到 Windows，1080p。使用者回報版本 1.4.9、延遲超過 1 秒、FPS 低於 30；本機已安裝 1.4.9+67。本次實際認證後，主機 `PeerInfo.version` 回報 **1.5.0**，不再以口述版本推測對端。

觀看端安裝版本是 1.4.9+67。重新連線後的本機日誌確認：直連失敗，最後使用 Relay；影片切換為 H.264，D3D11VA 硬體解碼建立成功；要求的 FPS 仍為 30。本機設定存的是 60 FPS。

建立連線花費約 19 秒是連線建立時間，不能當成持續 RTT。原版日誌沒有提供本次新增的逐秒診斷；下列候選量測也不能取代螢幕呈現、輸入到畫面或主機編碼耗時量測。

原始碼基準：RustDesk 1.5.0，commit `fada664df7a294d1d1a9ca3e7cd3637069122f17`；舊版比較基準：1.4.9，commit `6c578292e8ebbbec708b76986ba8c4bc7c509747`。

## 確認的原因與待量測項目

1. `LoginConfigHandler::get_option_message` 會把「公共伺服器且非直連」的自訂 FPS 上限壓到 30。1.4.9 與 1.5.0 都有這個限制。把 TOML 設為 60 不能繞過這段邏輯；本實驗也保留公共中繼上限。
2. 顯示 H.264 不代表整條管線零拷貝；D3D11VA 解碼成功也不能證明遠端使用 GPU 編碼。本機 AMD 顯卡是觀看端資訊，不能用來選擇遠端 NVENC / AMF 參數。
3. 延遲探針與影片共用傳輸串流。品質監視器的 delay 包含共享傳輸路徑排隊、觀看端處理與回傳，不等於純網路 ping，也不等於從輸入到螢幕的完整延遲。
4. 客戶端解碼佇列容量為 120。30 FPS 時這相當於最多約 4 秒的影格數，但容量不是目前實際排隊時間。TCP 重傳、伺服器送出阻塞、遠端編碼和 UI 呈現都可能造成延遲，必須分開量測。
5. FPS 不夠可能是桌面沒有變動、網路控制限速或實際處理不足。靜態桌面的低 FPS 不能單獨判定卡頓；評估時要使用持續捲動或動態畫面。

## 上游已有的改善

[1.5.0 發行紀錄](https://github.com/rustdesk/rustdesk/releases/tag/1.5.0) 包含 [QoS 改善 #16082](https://github.com/rustdesk/rustdesk/pull/16082)：確認持續壅塞、改善恢復、較早取得延遲基準，並針對碼率受控的編碼器優先降低碼率。單純降 FPS，對 CBR 編碼器不一定能減少傳輸位元組。上游有模型模擬測試，但模擬不代表這條實際連線的效能結果。

這些主要改善位於被控端 `src/server/video_qos.rs`。若只更新觀看端、家裡繼續使用 1.4.9，不會讓家裡的伺服器 QoS 自動變成 1.5.0。本次認證回報的主機已是 1.5.0，因此已有這段上游 QoS。

[WebRTC #15684](https://github.com/rustdesk/rustdesk/pull/15684) 增加 ICE / DTLS / SCTP DataChannel 與連線競速。它不是已經改用可過期的 RTP 影片管線；遇到 NAT 仍可能依賴 TURN。不能把「用了 WebRTC」當成低延遲保證。

## 這次新增的實驗

設定環境變數 `FLOADE_RUSTDESK_LOW_LATENCY=1` 才會啟用。未啟用時保留原有畫面回呼與碼率控制。這是可測試候選方案，尚不代表已改善目前連線。

Windows 上，`FLOADE_RUSTDESK_TEST_PROFILE=1` 使用獨立的 `FloadeRustDesk` 設定、日誌與視窗名稱，讓候選程式可以和已安裝 RustDesk 並行。該旗標不會替換原有程式，也不需要關閉原有連線。測試需另外匯入連線設定；不複製本機遠端服務 ID。

### 舊版主機的觀看端碼率回饋

限於主機版本低於 1.5.0、使用自訂品質的連線。連續兩個有效探針顯示共享路徑延遲至少 500 ms，將傳送品質值減半，最低 10。兩個樣本冷卻後才再次調整；連續五個低於或等於 200 ms 的樣本，品質值增加 5，最高恢復到使用者設定。

使用既有 `OptionMessage.custom_image_quality`，不改協定、不寫入使用者品質設定，不解除公共 Relay 的 FPS 限制。品質值是碼率比例輸入，不是量到的 Mbps。先回覆延遲探針，才安排品質訊息，避免控制回饋拖延探針本身。

限制：這是絕對延遲門檻的相容性措施，仍需實際 A/B 驗證。天然高延遲路徑可能降畫質卻沒有改善延遲；其他觀看者共用主機編碼器時也可能受碼率變化影響。新版主機停用此措施，交給上游 QoS。

### 解碼與顯示排隊

保持既有影格解碼及錄影處理；當解碼佇列仍有資料時，略過部分 UI 回呼以加速追上，佇列清空就立即顯示。保留週期呈現，且即使前一次呈現很慢，也至少讓一個影格只解碼、不呈現。

不任意跳過 H.264 / VP9 / AV1 預測影格，不更動關鍵影格、解碼器重設與原本溢位處理。這只減少 UI 呈現成本；RGB 轉換仍在原有解碼流程內，不能解決 TCP 中已有的資料積壓，也不是 GPU 零拷貝重寫。

### 可用程式讀取的診斷

啟用後，既有日誌定期輸出 `floade_perf` JSON，包含取樣時間、共享路徑延遲、UI 回呼 FPS、解碼佇列影格數、codec、要求及套用限制後的 FPS 設定上限、儲存品質與目前傳送品質。沒有延遲樣本時輸出 null。

`presented_fps` 計算送到 UI 的影格回呼；後續 renderer 仍可能略過更新，因此不是螢幕真正呈現的 FPS。`effective_fps_limit` 是套用公共 Relay 限制後的設定上限，主機 QoS 與客戶端自動限速仍可更低；它不是實測輸出 FPS。

亦包含主機回報的目標碼率與整條接收串流的速率；接收速率包含控制及音訊，不能當成純影片的編碼碼率。

測試 profile 即使關閉低延遲修正，仍提供同一份診斷，以便用程式比較 A/B；一般 profile 關閉實驗時不增加此記錄。

另外輸出主機在登入後回報的 `peer_version`、`low_latency_enabled` 與 `automatic_fps_limit`。不以本機已安裝版本或設定檔推測主機版本。

`python scripts/floade-performance.py` 讀取日誌最後 512 KiB，輸出 JSON；可用 `--log` 指定日誌。提供樣本年齡與 `fresh`；歷史樣本不是目前仍連線的證明。目前是只讀診斷介面，還沒有通用的即時設定 RPC。原版 RustDesk 不會輸出這些資料。

測試 profile 的讀取指令是 `python scripts/floade-performance.py --test-profile`；`scripts/floade-start-test.ps1 -DisableLowLatency` 啟動關閉策略的對照組。

啟動器預設使用 H.264 VRAM／texture 呈現，先匯入同機 GPU 快取並開啟候選 LocalConfig 的 `allow-d3d-render`、`use-texture-render`；首次設定保留備份。`-DisableGpuTexture` 可改回 RAM 呈現。切換策略或 GPU 模式前要先關閉候選；啟動器遇到正在執行的候選會拒絕，以免把不同環境旗標的連線送進舊程式。只複製網路、單一已儲存連線與 GPU 能力設定，不複製本機遠端服務 ID。

日誌限流是每個程式的記錄位置共用：多個連線時不保證每個連線都能每五秒取得一筆。這次先驗證單一連線。

## 建置與驗證

- 獨立 checkout 與 `codex/floade-low-latency` 分支；沒有改 Floade-need 的開發中檔案。
- Rust 1.75.0、bridge codegen 1.80.1、cargo-expand 1.0.95 按上游工作流程準備，工具放在 `.floade-tools`，沒有更動全域 PATH。
- vcpkg 基準 `9e593bb18ea69cc5095e012465dcd675a822ed0d`，硬體編碼依賴保留。
- 官方 Windows 1.5.0 前端來源包：201562177 bytes，SHA-256 `d006697cb522e79a25cfad489f7b45de32c778407b2887c4870280bf7a2308c2`，與發行資產 digest 相同。只用同一版本前端搭配候選核心，不能把原版 DLL 冒充修改版。
- `scripts/floade-test-core.ps1`：三個策略測試通過。測試涵蓋持續一秒延遲的品質降低與恢復、單次尖峰不降低、排隊及慢呈現時仍能追上和顯示最新影格。
- 完整 RustDesk 核心與硬體編解碼依賴已編譯，整合執行新增的三個測試：3 passed、0 failed，346 個既有測試未執行。最終 Release 建置、前端啟動、實際認證／影片接收與診斷 JSON 讀取均完成；嚴格 A/B、實際輸入到畫面延遲與所有既有功能回歸尚未完成。
- 最終修改核心 SHA-256：`906f488bc8c915c2330d38b66a187e248143f6e90f4ddca355aa3872b7061c48`。`floade-build.json` 記錄基準 commit、工作目錄有修改，以及五個編譯來源檔案的 digest；已核對來源與 DLL，沒有把基準 commit 當成包含修改的 commit。

首次 Release 核心已完成，343 個原生匯出符號與同版官方核心一致，`--version` 回傳 1.5.0 / exit 0。CLI 啟動後完成登入並收到 H.264 影片，已實際走過前端初始化、認證與媒體介面；其他功能介面沒有逐一執行。

首次獨立 profile 尚未帶入本機 GPU 快取，使用軟體 H.264 解碼。以下是未控制桌面內容、未排除其他觀看者的功能觀察，**不是能證明修改效果的 A/B 基準測試**：

| 條件 | 有效日誌樣本 | 共享路徑 delay p50 / p95 | UI 回呼 FPS 中位數 | 最高解碼佇列 |
| --- | ---: | ---: | ---: | ---: |
| 關閉策略、軟體解碼 | 13 | 80 / 667 ms | 36 | 16 |
| 開啟策略、軟體解碼 | 23 | 73 / 94 ms | 28 | 22 |
| 開啟策略、D3D11VA RAM 解碼 | 34 | 77 / 885 ms | 21 | 37 |
| 開啟策略、H.264 VRAM、品質 70 | 43 | 105 / 774 ms | 37 | 19 |
| 開啟策略、H.264 VRAM、品質 50 | 33 | 162 / 2465 ms | 29 | 38 |
| 恢復品質 70、VRAM、落回公共 Relay | 42 | 409 / 2017 ms | 17 | 8 |

這些連線建立 WebRTC 路徑，RustDesk 回報 `direct=true`、設定 FPS 上限 60；原始碼以實際 ICE candidate pair 判斷 TURN，不是只看到 WebRTC 就當成直連。回呼 FPS 降低可能包含略過過期 UI 更新，也可能是內容與負載變化；不能據此宣稱因果改善。兩次重連遭對端 reset（10054），此前重試可恢復，連線穩定性仍需觀察。

已修正啟動器的 INFO 記錄、日誌路徑偵測、GPU 快取匯入與 texture 設定。日誌確認 AMF / FFmpeg H.264 VRAM decoder 建立成功；VRAM 品質 70 階段後續多數取樣佇列為 0，FPS 中位數 37，但共享路徑延遲最大仍有 1241 ms。品質 50 試驗最大 3126 ms，沒有提供穩定改善的證據，因此恢復品質 70。這些尾端延遲顯示目前**尚未完全解決卡頓**，需要分開檢查主機編碼／送出排隊、傳輸可靠通道與路徑壅塞。

主機實際是 1.5.0，`low_latency_enabled=true` 但 `legacy_bitrate_feedback_enabled=false`，是預期行為：保留主機已有的 QoS；這次沒有驗證舊主機相容回饋的實際網路效果，只完成該策略的三個回歸測試。

目前候選使用品質 70、60 FPS 設定上限、GPU texture 與畫面追趕策略，獨立 profile 可直接測試。JSON 原始觀察資料位於忽略的 `.floade-tools/runtime-observations.json`。來源與候選目錄保留在本 checkout；Floade-need 尚未接入此實驗引擎。

最後重試雖然完成登入與 VRAM 影片接收，路徑又落回公共 Relay，實際 FPS 設定上限回到 30，delay 最大 2777 ms。這確認直連尚不穩定；不能以早先直連階段的好樣本宣稱問題已修好。完成測試後已關閉本次啟動的額外候選程式，避免額外觀看連線持續占用頻寬。

下一個原始碼調查點是主機 `src/server/connection.rs` 的 `rx_video` 分支：影格 ACK 發生在 `stream.send().await` 前，送出等待又和控制訊息接收共用迴圈。先補上編碼耗時、送出等待與 in-flight 位元組量測，才能判斷是否需要延後 ACK 形成背壓、把 reader 與 writer 分離或調整影片／控制通道排程；目前沒有對這些主機路徑作未驗證修改。

現有觀看端診斷只取得共享路徑延遲與本機解碼／回呼資料，沒有主機編碼和傳送耗時，因此尚不能區分 WAN 壅塞與主機送出阻塞。下一階段需要主機端的這些記錄，並查驗直連失敗／reset 的兩端日誌；這是目前未完成的驗證界線。

## 接入 Floade-need 的方向

先驗證遠端引擎，再用 Floade-need 管理啟動、連線及診斷；畫面由原生程式處理。把影像繞經 Electron 截圖、JSON 或每影格 IPC 會增加拷貝與合成成本。

下一階段可以做只允許本機使用者的 named pipe RPC，提供 `session.status`、`session.set_profile`、`session.disconnect`，按連線識別、權限與版本檢查。這次沒有新增網路監聽、遠端設定入口或 Floade 管理中心。

## 實際 A/B 準則

同一對電腦、同一網路、同一 1080p 動態內容，各測原版、候選關閉與候選開啟。記錄 delay p50/p95、實際呈現 FPS、queue、碼率和解碼器資訊。若畫質下降但 delay p95 未改善，就停用碼率相容措施並改查中繼路由 / 上行壅塞。輸入到畫面的延遲需另外量測，不能用共享路徑 delay 代替。

若可讓兩端直連或使用靠近兩端的自架 relay，再測 60 FPS；自架伺服器本身不保證路由更快。若 RustDesk 在相同條件仍顯著落後，可用 Sunshine / Moonlight 的原生桌面串流作為另一個引擎的對照，而不是先做大型傳輸協定重寫。

## 回歸影響範圍

- `src/client.rs`：加入模組；啟用實驗時，解碼完成後的 UI 呈現回呼可能跳過，解碼與錄影照原有順序進行。
- `src/client/io_loop.rs`：啟用實驗時，在舊版主機的探針回覆後安排品質訊息，重連時重設實驗狀態，並輸出診斷；沒有改登入、輸入、檔案傳輸與線上協定格式。
- `src/core_main.rs`：僅在 Windows 測試旗標啟用時，在初始化前選擇獨立 AppName，避免候選 CLI 被送到已安裝的 RustDesk 視窗；原版設定路徑不變。
- `src/client/low_latency.rs`：新增純策略模組與三個測試；`src/client/io_loop/low_latency.rs` 集中處理回饋與診斷。沒有改共用 trait、函式簽名、submodule 或新增 runtime 依賴。

## 技術文件

- [RustDesk 進階設定](https://rustdesk.com/docs/en/self-host/client-configuration/advanced-settings/)：自訂 FPS、品質、硬體解碼、D3D 呈現選項。
- [RustDesk 自架說明](https://rustdesk.com/docs/en/self-host/)：hbbs 註冊 / rendezvous 與 hbbr 中繼。
- [NVIDIA NVENC Programming Guide](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/nvenc-video-encoder-api-prog-guide/index.html)：低延遲模式、VBV、lookahead 與 rate control。
- [Microsoft Desktop Duplication API](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api)：GPU 表面、dirty/move rectangles、游標資訊。
- [WebRTC Peer Connections](https://webrtc.org/getting-started/peer-connections)：ICE / STUN / TURN 與路徑建立。
- [RFC 8836](https://www.rfc-editor.org/rfc/rfc8836.html)：互動影音壅塞控制、排隊延遲與快速反應。
- [RFC 9221](https://www.rfc-editor.org/rfc/rfc9221.html)：QUIC 不可靠 datagram 與可靠 stream 的差別；改傳輸需要重新設計丟棄與解碼相依性。
- [Moonlight FAQ](https://github.com/moonlight-stream/moonlight-docs/wiki/Frequently-Asked-Questions) 與 [Sunshine 設定](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html)：原生桌面串流、網路 / 解碼 / 呈現指標、低延遲編碼設定。
