import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:window_manager/window_manager.dart';
import '../common.dart';
import '../models/platform_model.dart';
import '../utils/multi_window_manager.dart';
import 'access.dart';

// Only the local Floade process knows this per-launch capability token.
Future<void> startFloadeControl() async {
  var delay = 1;
  while (true) {
    try { await _runFloadeControl(); } catch (_) {
      // No command arguments or capability token may enter diagnostics.
      print('Floade control unavailable; retrying in ${delay}s.');
    }
    await Future.delayed(Duration(seconds: delay));
    delay = min(delay * 2, 30);
  }
}

Future<void> _runFloadeControl() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  try {
  final random = Random.secure();
  final token = base64Url.encode(List.generate(32, (_) => random.nextInt(256)));
  final directory = Directory('${Platform.environment['APPDATA']}/FloadeRemote');
  await directory.create(recursive: true);
  final endpoint = File('${directory.path}/control.json');
  final temporaryEndpoint = File('${endpoint.path}.tmp');
  await temporaryEndpoint.writeAsString(jsonEncode({'port': server.port, 'token': token, 'pid': pid, 'schema': 1}), flush: true);
  await temporaryEndpoint.rename(endpoint.path);
  await for (final request in server) {
    request.response.headers.contentType = ContentType.json;
    try {
      if (request.method != 'POST' || request.uri.path != '/command' ||
          request.headers.value('x-floade-token') != token ||
          request.headers.value('origin') != null) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.write(jsonEncode({'ok': false, 'error': {'code': 'FORBIDDEN', 'message': 'Local capability required.'}}));
      } else {
        final bytes = <int>[];
        await for (final chunk in request.timeout(const Duration(seconds: 10))) {
          bytes.addAll(chunk);
          if (bytes.length > 65536) throw const FormatException('Request too large');
        }
        final command = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final result = await _dispatch(command['method'] as String, Map<String, dynamic>.from(command['params'] ?? {})).timeout(const Duration(seconds: 12));
        request.response.write(jsonEncode({'ok': true, 'result': result}));
      }
    } catch (_) {
      // Never echo arguments: connect and password commands contain secrets.
      request.response.write(jsonEncode({'ok': false, 'error': {'code': 'ENGINE_REQUEST_FAILED', 'message': 'Remote engine could not complete this command.'}}));
    }
    await request.response.close();
  }
  } finally { await server.close(force: true); }
}

Future<dynamic> _dispatch(String method, Map<String, dynamic> p) async {
  switch (method) {
    case 'accessGet':
      return floadeAccess(null);
    case 'accessSet':
      return floadeAccess(p);
    case 'status':
      return {'pid': pid, 'deviceId': await bind.mainGetMyId(),
        'connection': jsonDecode(await bind.mainGetConnectStatus()),
        'autoConnectStatus': true, 'backgroundOnly': true, 'miniPreview': Platform.isWindows, 'engineVersion': '1.5.0', 'directOnly': Platform.resolvedExecutable.split(Platform.pathSeparator).last.toLowerCase() == 'floaderemote.exe',
        'windows': rustDeskWinManager.getActiveWindows().where((id) => id > 0).toList(),
        'installedService': bind.mainIsInstalled()};
    case 'apply':
      final settings = Map<String, dynamic>.from(p['settings']);
      const options = {'acceptConnections': 'stop-service', 'keyboard': 'enable-keyboard',
        'clipboard': 'enable-clipboard', 'fileTransfer': 'enable-file-transfer',
        'hardwareCodec': 'enable-hwcodec', 'server': 'custom-rendezvous-server',
        'relayServer': 'relay-server', 'serverKey': 'key',
        'approval': 'approve-mode', 'verification': 'verification-method'};
      for (final entry in options.entries) {
        if (!settings.containsKey(entry.key)) continue;
        final value = settings[entry.key];
        final encoded = value is bool ? (entry.key == 'acceptConnections' ? (value ? '' : 'Y') : (value ? 'Y' : 'N')) : value.toString();
        // An unchanged stop-service write reinstalls the Windows system service.
        if (entry.value == 'stop-service' &&
            await bind.mainGetOption(key: entry.value) == encoded) continue;
        await bind.mainSetOption(key: entry.value, value: encoded);
      }
      if (settings.containsKey('gpu')) {
        final value = settings['gpu'] == true ? 'Y' : 'N';
        await bind.mainSetLocalOption(key: 'allow-d3d-render', value: value);
        await bind.mainSetLocalOption(key: 'use-texture-render', value: value);
      }
      for (final entry in {'tcpPunch': 'enable-tcp-punch',
        'udpPunch': 'enable-udp-punch', 'webrtc': 'enable-webrtc'}.entries) {
        if (settings.containsKey(entry.key)) {
          await bind.mainSetLocalOption(key: entry.value,
            value: settings[entry.key] == true ? 'Y' : 'N');
        }
      }
      if (settings.containsKey('relativeMouseShortcut')) {
        await bind.mainSetLocalOption(key: 'floade-relative-mouse-shortcut',
            value: settings['relativeMouseShortcut'].toString());
      }
      for (final entry in {'fps': 'custom-fps', 'quality': 'custom_image_quality', 'codec': 'codec-preference'}.entries) {
        if (settings.containsKey(entry.key)) await bind.mainSetUserDefaultOption(key: entry.value, value: settings[entry.key].toString());
      }
      await bind.mainSetUserDefaultOption(key: 'image_quality', value: 'custom');
      if (settings['acceptConnections'] == false) {
        await gFFI.serverModel.stopService();
      } else if (settings['acceptConnections'] == true) {
        await gFFI.serverModel.startService();
      }
      return {'applied': true, 'displayChangesApplyTo': 'new connections'};
    case 'password':
      final password = p['password'] as String;
      if (password.isNotEmpty && password.length < 8) throw const FormatException('Password too short');
      if (!await bind.mainSetPermanentPasswordWithResult(password: password)) throw StateError('Password not saved');
      return {'saved': true};
    case 'temporaryPassword':
      return {'password': await bind.mainGetTemporaryPassword()};
    case 'connect':
      final id = p['deviceId'] as String;
      if (!RegExp(r'^\d{6,16}$').hasMatch(id)) throw const FormatException('Invalid ID');
      final s = Map<String, dynamic>.from(p['settings'] ?? {});
      if (!await bind.floadeSetPeerDisplay(id: id, quality: s['quality'] ?? 70, fps: s['fps'] ?? 60, codec: s['codec'] ?? 'h264', forceRelay: s['forceRelay'] == true)) throw const FormatException('Invalid display settings');
      for (final entry in {'fps': 'custom-fps', 'codec': 'codec-preference'}.entries) {
        if (s.containsKey(entry.key)) await bind.mainSetPeerOption(id: id, key: entry.value, value: s[entry.key].toString());
      }
      final password = p['password'] as String?;
      final relay = s['forceRelay'] == true;
      if (p['mode'] == 'files') {
        final window = await rustDeskWinManager.newFileTransfer(id, password: password, forceRelay: relay);
        return {'windowId': window.windowId, 'state': 'connecting'};
      }
      final window = await rustDeskWinManager.newRemoteDesktop(id, password: password, forceRelay: relay);
      return {'windowId': window.windowId, 'state': 'connecting'};
    case 'sessionStatus':
      final id = p['windowId'] as int;
      if (!rustDeskWinManager.getActiveWindows().contains(id)) return {'state': 'closed'};
      return await DesktopMultiWindow.invokeMethod(id, 'floade_connection_status', p['deviceId']).timeout(const Duration(seconds: 3));
    case 'miniPreview':
      final id = p['windowId'] as int;
      final action = p['action'] ?? 'open';
      if (!Platform.isWindows || !['open', 'restore', 'collapse', 'status'].contains(action) ||
          !rustDeskWinManager.getActiveWindows().contains(id)) throw const FormatException('Invalid preview window or action');
      return await DesktopMultiWindow.invokeMethod(id, 'floade_mini_preview', action).timeout(const Duration(seconds: 3));
    case 'disconnect':
      final id = p['windowId'] as int;
      if (!(await rustDeskWinManager.getAllSubWindowIds()).contains(id)) throw StateError('Window absent');
      await rustDeskWinManager.closeFloadeWindow(id);
      return {'disconnected': true};
    case 'forget':
      final id = p['deviceId'] as String;
      if (!RegExp(r'^\d{6,16}$').hasMatch(id)) throw const FormatException('Invalid ID');
      await bind.mainForgetPassword(id: id);
      return {'forgotten': true};
    case 'advanced':
      await windowManager.show();
      await windowManager.focus();
      return {'opened': true};
    case 'shutdown':
      await rustDeskWinManager.closeAllSubWindows();
      Future.delayed(const Duration(milliseconds: 300), () => exit(0));
      return {'stopping': true};
    default:
      throw const FormatException('Unknown command');
  }
}
