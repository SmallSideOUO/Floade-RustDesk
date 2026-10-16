import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/floade/connection_status.dart';

void main() {
  test('direct authentication is distinct from receiving a desktop image', () {
    floadeConnectionStart('session-a', '123456789');
    floadeConnectionEvent('session-a', {'name': 'connection_ready', 'direct': 'true'});
    expect(floadeConnectionStatus('123456789', ['123456789'])['state'], 'authenticating');
    floadeConnectionEvent('session-a', {'name': 'peer_info'});
    expect(floadeConnectionStatus('123456789', ['123456789'])['video'], false);
    floadeConnectionVideo('session-a');
    expect(floadeConnectionStatus('123456789', ['123456789'])['video'], true);
    expect(floadeConnectionStatus('123456789', [])['state'], 'closed');
  });

  test('password and permission errors require user action; network errors can switch', () {
    for (final event in [
      {'name': 'msgbox', 'type': 're-input-password', 'text': 'sensitive-value'},
      {'name': 'msgbox', 'type': 'error', 'text': 'Permission denied'},
    ]) {
      floadeConnectionStart('session-b', '987654321');
      floadeConnectionEvent('session-b', event);
      final status = floadeConnectionStatus('987654321', ['987654321']);
      expect(status['state'], 'user-action');
      expect(status.toString().contains('sensitive-value'), false);
    }
    floadeConnectionEvent('session-b', {'name': 'msgbox', 'type': 'error', 'title': 'Connection Error', 'text': 'Failed to connect'});
    expect(floadeConnectionStatus('987654321', ['987654321'])['state'], 'network-error');
    floadeConnectionEvent('session-b', {'name': 'msgbox', 'type': 'error', 'text': 'Failed to resolve (os error 11001)'});
    expect(floadeConnectionStatus('987654321', ['987654321'])['state'], 'network-unavailable');
  });

  test('a new session cannot inherit a previous successful image or late errors', () {
    floadeConnectionStart('old', '123456789');
    floadeConnectionVideo('old');
    floadeConnectionStart('new', '123456789');
    floadeConnectionEvent('old', {'name': 'msgbox', 'type': 'error'});
    expect(floadeConnectionStatus('123456789', ['123456789'])['state'], 'connecting');
    expect(floadeConnectionStatus('123456789', ['123456789'])['video'], false);
  });
}
