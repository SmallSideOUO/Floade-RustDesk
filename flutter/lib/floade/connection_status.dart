// Per-window observations only; never retain message text or credentials.
const _enabled = bool.fromEnvironment('FLOADE_REMOTE');
final _sessions = <String, Map<String, dynamic>>{};

void floadeConnectionStart(String session, String peer) {
  if (!_enabled) return;
  _sessions.removeWhere((_, value) => value['peer'] == peer);
  _sessions[session] = {'peer': peer, 'state': 'connecting', 'video': false};
}

void floadeConnectionEvent(String session, Map<String, dynamic> event) {
  if (!_enabled) return;
  final status = _sessions[session];
  if (status == null) return;
  if (event['name'] == 'connection_ready') {
    status['direct'] = event['direct'] == 'true';
    status['state'] = 'authenticating';
  } else if (event['name'] == 'peer_info') {
    status['state'] = 'connected';
  } else if (event['name'] == 'msgbox') {
    final type = event['type']?.toString() ?? '';
    final title = event['title']?.toString() ?? '';
    final text = event['text']?.toString() ?? '';
    if (RegExp('password|2fa|login|wait-remote-accept|wait-uac|on-uac').hasMatch(type) ||
        RegExp('password|denied|not allowed|not in.*whitelist|whitelist|allowlist|permission|2fa|two.factor', caseSensitive: false).hasMatch('$title $text')) {
      status['state'] = 'user-action';
    } else if (type.contains('error') || type.startsWith('restarting') || title == 'Connection Error') {
      status['state'] = RegExp('11001|failed to resolve|network is unreachable|10051', caseSensitive: false).hasMatch(text) ? 'network-unavailable' : 'network-error';
      status['video'] = false;
    }
  }
}

void floadeConnectionVideo(String session) {
  if (!_enabled) return;
  final status = _sessions[session];
  if (status != null) {
    status['video'] = true;
    status['state'] = 'connected';
  }
}

Map<String, dynamic> floadeConnectionStatus(String peer, Iterable<String> activePeers) {
  if (!activePeers.contains(peer)) return {'state': 'closed'};
  for (final status in _sessions.values) {
    if (status['peer'] == peer) return Map<String, dynamic>.from(status);
  }
  return {'state': 'connecting'};
}
