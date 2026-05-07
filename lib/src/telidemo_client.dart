import 'dart:async';
import 'package:telegram_universe/telegram_universe.dart';
import 'telidemo_credentials.dart';

/// A wrapper around [TelegramUniverse] to simplify Telegram operations.
final class TeliDemoClient {
  late final TelegramUniverse _tg;
  final TeliDemoCredentials credentials;
  int? _clientId;

  TeliDemoClient(this.credentials) {
    _tg = TelegramUniverse();
  }

  /// Initializes the client.
  Future<void> init({String pathTdlib = ""}) async {
    _tg.ensureInitialized(pathTdlib: pathTdlib);
    await _tg.initialized();
    _clientId = _tg.createClient();
  }

  /// Listens for updates.
  void onUpdate(FutureOr<void> Function(Map data) callback) {
    _tg.on('update', (data) async {
      if (data['@client_id'] == _clientId) {
        await callback(data);
      }
    });
  }

  /// Invokes a TDLib method.
  Future<Map> invoke(Map parameters) async {
    if (_clientId == null) {
      throw StateError('Client not initialized. Call init() first.');
    }
    final params = Map<String, dynamic>.from(parameters);
    params['@client_id'] = _clientId;
    return await _tg.invoke(params);
  }

  /// Gets the current client ID.
  int? get clientId => _clientId;
}
