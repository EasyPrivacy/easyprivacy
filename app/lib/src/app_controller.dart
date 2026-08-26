import 'package:flutter/foundation.dart';

import 'api/agent_client.dart';
import 'models/agent_status.dart';

enum ConnectionPhase { disconnected, connecting, connected, failed }

class AppController extends ChangeNotifier {
  AppController({AgentClient? client}) : _client = client ?? AgentClient();

  final AgentClient _client;
  ConnectionPhase _phase = ConnectionPhase.disconnected;
  AgentConnection? _connection;
  AgentStatus? _status;
  String? _errorMessage;
  bool _isDemo = false;

  ConnectionPhase get phase => _phase;
  AgentConnection? get connection => _connection;
  AgentStatus? get status => _status;
  String? get errorMessage => _errorMessage;
  bool get isDemo => _isDemo;
  bool get isConnected =>
      _phase == ConnectionPhase.connected && _status != null;

  Future<bool> connect({
    required String name,
    required String serverUrl,
    required String token,
  }) async {
    _phase = ConnectionPhase.connecting;
    _errorMessage = null;
    _isDemo = false;
    notifyListeners();

    try {
      final connection = AgentConnection.parse(
        name: name,
        serverUrl: serverUrl,
        token: token,
      );
      final status = await _client.fetchStatus(connection);
      _connection = connection;
      _status = status;
      _phase = ConnectionPhase.connected;
      notifyListeners();
      return true;
    } on FormatException catch (error) {
      _fail(error.message);
    } on AgentException catch (error) {
      _fail(error.message);
    } catch (_) {
      _fail(
        'EasyPrivacy could not reach that server. Check the address and try again.',
      );
    }
    return false;
  }

  void openDemo() {
    _connection = AgentConnection(
      name: 'Demo home',
      baseUri: Uri.parse('https://demo.invalid'),
      token: 'demo',
    );
    _status = demoAgentStatus;
    _phase = ConnectionPhase.connected;
    _errorMessage = null;
    _isDemo = true;
    notifyListeners();
  }

  Future<void> refresh() async {
    final connection = _connection;
    if (connection == null || _isDemo) {
      return;
    }
    try {
      _status = await _client.fetchStatus(connection);
      _phase = ConnectionPhase.connected;
      _errorMessage = null;
    } on AgentException catch (error) {
      _errorMessage = error.message;
    } catch (_) {
      _errorMessage = 'The server could not be refreshed.';
    }
    notifyListeners();
  }

  void disconnect() {
    _connection = null;
    _status = null;
    _errorMessage = null;
    _isDemo = false;
    _phase = ConnectionPhase.disconnected;
    notifyListeners();
  }

  void _fail(String message) {
    _connection = null;
    _status = null;
    _phase = ConnectionPhase.failed;
    _errorMessage = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
