import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../consts.dart';
import '../models/state_model.dart';
import '../models/model.dart';
import '../models/platform_model.dart';
import 'connection_status.dart';

String miniPreviewText(String zh, String en) {
  final language = bind.mainGetLocalOption(key: 'lang');
  return (language.isEmpty ? Platform.localeName : language)
          .toLowerCase()
          .startsWith('zh')
      ? zh
      : en;
}

final floadeMiniPreview = FloadeMiniPreview();

class FloadeMiniPreview {
  static const channel = MethodChannel('floade/mini_preview');
  final enabled = false.obs;
  final collapsed = false.obs;
  bool _busy = false;
  bool _showTabBar = true;
  bool _fullscreen = false;

  bool get automatic =>
      bind.getLocalFlutterOption(k: 'floade-mini-on-minimize') == 'Y';

  Future<void> setAutomatic(bool value) => bind.setLocalFlutterOption(
      k: 'floade-mini-on-minimize', v: value ? 'Y' : 'N');

  Future<void> enter(FFI ffi) async {
    if (_busy || enabled.value) return;
    _busy = true;
    try {
      ffi.inputModel.exitRelativeMouseModeWithKeyRelease();
      ffi.inputModel.enterOrLeave(false);
      bind.hostStopSystemKeyPropagate(stopped: true);
      _showTabBar = stateGlobal.showTabBar.value;
      _fullscreen = stateGlobal.fullscreen.value;
      enabled.value = true;
      if (_fullscreen) {
        await WindowController.fromWindowId(stateGlobal.windowId)
            .setFullscreen(false);
        stateGlobal.setFullscreen(false, procWnd: false);
      }
      stateGlobal.showTabBar.value = false;
      dynamic bounds;
      try {
        bounds =
            jsonDecode(bind.getLocalFlutterOption(k: 'floade-mini-bounds'));
      } catch (_) {}
      final rect = ffi.ffiModel.rect;
      await channel.invokeMethod<void>('enter', {
        'ratio': rect != null && rect.height > 0
            ? rect.width / rect.height
            : 16.0 / 9.0,
        if (bounds is List &&
            bounds.length == 4 &&
            bounds.every((v) => v is int))
          'bounds': bounds,
      });
    } catch (_) {
      enabled.value = false;
      stateGlobal.showTabBar.value = _showTabBar;
      if (_fullscreen) {
        await WindowController.fromWindowId(stateGlobal.windowId)
            .setFullscreen(true);
        stateGlobal.setFullscreen(true, procWnd: false);
      }
      rethrow;
    } finally {
      _busy = false;
    }
  }

  Future<void> restore() async {
    if (_busy || !enabled.value) return;
    _busy = true;
    try {
      final bounds = await channel.invokeListMethod<int>('bounds');
      if (bounds != null) {
        await bind.setLocalFlutterOption(
            k: 'floade-mini-bounds', v: jsonEncode(bounds));
      }
      await channel.invokeMethod<void>('restore');
      collapsed.value = false;
      enabled.value = false;
      stateGlobal.showTabBar.value = _showTabBar;
      if (_fullscreen) {
        await WindowController.fromWindowId(stateGlobal.windowId)
            .setFullscreen(true);
        stateGlobal.setFullscreen(true, procWnd: false);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> collapse() async {
    if (_busy || !enabled.value) return;
    _busy = true;
    try {
      collapsed.value = await channel.invokeMethod<bool>('collapse') == true;
    } finally {
      _busy = false;
    }
  }

  Map<String, dynamic> get status =>
      {'enabled': enabled.value, 'collapsed': collapsed.value};
}

Future<void> miniPreviewAction(
    BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(miniPreviewText('無法切換小窗，請再試一次。',
              'Could not switch preview mode. Please try again.'))));
    }
  }
}

class MiniPreviewButton extends StatelessWidget {
  const MiniPreviewButton({super.key, required this.onEnter});
  final Future<void> Function() onEnter;

  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
            icon: const Icon(Icons.picture_in_picture_alt, size: 18),
            tooltip: miniPreviewText('遠端小窗（唯讀）', 'Mini preview (view only)'),
            onPressed: () => miniPreviewAction(context, onEnter)),
        PopupMenuButton<bool>(
            padding: EdgeInsets.zero,
            tooltip: miniPreviewText('小窗設定', 'Preview settings'),
            icon: const Icon(Icons.arrow_drop_down, size: 16),
            onSelected: (value) => floadeMiniPreview.setAutomatic(value),
            itemBuilder: (_) => [
                  CheckedPopupMenuItem<bool>(
                      value: !floadeMiniPreview.automatic,
                      checked: floadeMiniPreview.automatic,
                      child: Text(miniPreviewText(
                          '最小化時轉成小窗', 'Preview when minimized')))
                ]),
      ]);
}

class MiniPreview extends StatefulWidget {
  const MiniPreview({super.key, required this.ffi});
  final FFI ffi;

  @override
  State<MiniPreview> createState() => _MiniPreviewState();
}

class _MiniPreviewState extends State<MiniPreview> {
  Timer? _timer;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ffi = widget.ffi;
    final status = floadeConnectionStatus(ffi.id, [ffi.id]);
    final state = status['state'];
    final connected = state == 'connected' && status['video'] == true;
    final needsAction = state == 'user-action';
    final message = connected
        ? miniPreviewText('唯讀預覽', 'View only')
        : needsAction
            ? miniPreviewText('請展開完成授權', 'Expand to authenticate')
            : miniPreviewText('連線中／等待畫面', 'Connecting / waiting for video');
    final alias = bind.mainGetPeerOptionSync(id: ffi.id, key: 'alias');
    return Material(
        color: const Color(0xff101114),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Obx(() => Column(children: [
                SizedBox(
                    height: 28,
                    child: Row(children: [
                      Expanded(
                          child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanStart: (_) => WindowController.fromWindowId(
                                      stateGlobal.windowId)
                                  .startDragging(),
                              onDoubleTap: () => miniPreviewAction(
                                  context, floadeMiniPreview.restore),
                              onTap: floadeMiniPreview.collapsed.value
                                  ? () => miniPreviewAction(
                                      context, floadeMiniPreview.collapse)
                                  : null,
                              child: Row(children: [
                                const SizedBox(width: 8),
                                Icon(Icons.circle,
                                    size: 6,
                                    color: connected
                                        ? const Color(0xffa7d4ba)
                                        : Colors.amber),
                                const SizedBox(width: 6),
                                Expanded(
                                    child: Text(alias.isEmpty ? ffi.id : alias,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.white70))),
                              ]))),
                      if (_hover ||
                          floadeMiniPreview.collapsed.value ||
                          needsAction) ...[
                        _button(
                            Icons.open_in_full,
                            miniPreviewText('還原遠端視窗', 'Restore remote window'),
                            floadeMiniPreview.restore),
                        _button(
                            floadeMiniPreview.collapsed.value
                                ? Icons.expand_more
                                : Icons.remove,
                            miniPreviewText('展開／收起預覽（保持連線）',
                                'Expand / collapse preview (stay connected)'),
                            floadeMiniPreview.collapse),
                      ],
                    ])),
                if (!floadeMiniPreview.collapsed.value)
                  Expanded(
                      child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onDoubleTap: () => miniPreviewAction(
                              context, floadeMiniPreview.restore),
                          child: Stack(fit: StackFit.expand, children: [
                            IgnorePointer(
                                child: ExcludeFocus(
                                    child: _MiniPreviewImage(ffi: ffi))),
                            if (!connected)
                              const ColoredBox(color: Color(0x99000000)),
                            if (_hover || !connected)
                              Align(
                                  alignment: connected
                                      ? Alignment.bottomCenter
                                      : Alignment.center,
                                  child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      color: const Color(0xbb101114),
                                      child: Text(message,
                                          style: const TextStyle(
                                              fontSize: 10,
                                              color: Colors.white70)))),
                          ]))),
              ])),
        ));
  }

  Widget _button(
          IconData icon, String tooltip, Future<void> Function() action) =>
      IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          tooltip: tooltip,
          icon: Icon(icon, size: 14, color: Colors.white70),
          onPressed: () => miniPreviewAction(context, action));
}

class _MiniPreviewImage extends StatelessWidget {
  const _MiniPreviewImage({required this.ffi});
  final FFI ffi;

  @override
  Widget build(BuildContext context) {
    final image = Provider.of<ImageModel>(context);
    final peer = ffi.ffiModel;
    if (!image.useTextureRender && !peer.pi.forceTextureRender) {
      return RawImage(
          image: image.image,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.low);
    }
    final rect = peer.rect;
    if (rect == null || rect.width <= 0 || rect.height <= 0) {
      return const SizedBox();
    }
    final displays = peer.pi.getCurDisplays();
    return FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
            width: rect.width,
            height: rect.height,
            child: Stack(children: [
              for (var i = 0; i < displays.length; i++)
                Positioned(
                    left: displays[i].x - rect.left,
                    top: displays[i].y - rect.top,
                    width: displays[i].width /
                        (peer.isPeerLinux ? displays[i].scale : 1),
                    height: displays[i].height /
                        (peer.isPeerLinux ? displays[i].scale : 1),
                    child: Obx(() => Texture(
                        textureId: ffi.textureModel
                            .getTextureId(
                                peer.pi.currentDisplay == kAllDisplayValue
                                    ? i
                                    : peer.pi.currentDisplay)
                            .value,
                        filterQuality: FilterQuality.low))),
            ])));
  }
}
