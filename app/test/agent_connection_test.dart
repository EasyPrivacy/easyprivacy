import 'package:easyprivacy/src/api/agent_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('requires HTTPS for a remote server', () {
    expect(
      () => AgentConnection.parse(
        name: 'Home',
        serverUrl: 'http://192.0.2.10:7443',
        token: 'secret',
      ),
      throwsFormatException,
    );
  });

  test('allows localhost HTTP for development', () {
    final connection = AgentConnection.parse(
      name: 'Local',
      serverUrl: 'http://127.0.0.1:7443',
      token: 'secret',
    );

    expect(connection.baseUri, Uri.parse('http://127.0.0.1:7443'));
  });
}
