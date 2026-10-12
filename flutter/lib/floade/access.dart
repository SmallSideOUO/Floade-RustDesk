import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../models/platform_model.dart';

Future<Map<String, dynamic>> floadeAccess(Map<String, dynamic>? update) async {
  final file = File('${Platform.environment['APPDATA']}/FloadeRemote/access.json');
  final state = await file.exists()
      ? Map<String, dynamic>.from(jsonDecode(await file.readAsString()))
      : <String, dynamic>{'enabled': false, 'devices': <dynamic>[]};
  if (update != null) {
    if (update['enabled'] == false && state['enabled'] != true) return floadeAccess(null);
    final devices = List<Map<String, dynamic>>.from(
        (update['devices'] as List).map((d) => Map<String, dynamic>.from(d)));
    if (devices.length > 50 || devices.any((d) =>
        d['deviceId'] is! String || !RegExp(r'^\d{6,16}$').hasMatch(d['deviceId']) ||
        d['alias'] is! String || (d['alias'] as String).length > 80) ||
        update['enabled'] is! bool) throw const FormatException('Invalid access policy');
    if (update['enabled'] == true && state['enabled'] != true) {
      state['previousMode'] = await bind.mainGetOption(key: 'access-mode');
      state['previousWhitelist'] = await bind.mainGetOption(key: 'id-whitelist');
    }
    state['enabled'] = update['enabled'];
    state['devices'] = devices;
    if (devices.isEmpty) {
      final random = Random.secure();
      state['denyId'] = 'floade-denied-${base64Url.encode(List.generate(32, (_) => random.nextInt(256)))}';
    }
    // An empty enabled list must deny all, rather than mean unrestricted access.
    await bind.mainSetOption(key: 'id-whitelist', value: state['enabled'] == true
        ? (devices.isEmpty ? state['denyId'] as String : devices.map((d) => d['deviceId']).join(','))
        : (state['previousWhitelist'] as String? ?? ''));
    await bind.mainSetOption(key: 'access-mode', value: state['enabled'] == true
        ? 'full' : (state['previousMode'] as String? ?? ''));
    await bind.mainSetOption(key: 'approve-mode', value: 'password');
    await file.parent.create(recursive: true);
    await File('${file.path}.tmp').writeAsString(jsonEncode(state));
    await File('${file.path}.tmp').rename(file.path);
  }
  final mode = await bind.mainGetOption(key: 'access-mode');
  final whitelist = await bind.mainGetOption(key: 'id-whitelist');
  final devices = List<dynamic>.from(state['devices']);
  final expected = devices.isEmpty ? state['denyId'] as String? ?? ''
      : devices.map((d) => d['deviceId']).join(',');
  return {'enabled': state['enabled'], 'devices': devices,
    'effective': state['enabled'] == true && mode == 'full' && whitelist == expected,
    'passwordRequired': await bind.mainGetOption(key: 'approve-mode') == 'password',
    'scope': 'incoming connections on this host; excluded IDs are denied',
    'identity': 'RustDesk self-reported ID filter plus password authentication; not cryptographic device identity',
    'appliesTo': 'new incoming sessions'};
}
