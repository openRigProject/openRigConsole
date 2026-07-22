import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:openrig_core/openrig_core.dart' hide ChangeNotifier;
import 'settings_service.dart';

/// Manages mDNS discovery of openRig devices on the local network.
class ConnectionService extends ChangeNotifier {
  final SettingsService settings;
  final OpenRigDiscovery discovery = OpenRigDiscovery();

  bool _mdnsAvailable = true;

  ConnectionService({required this.settings});

  bool get mdnsAvailable => _mdnsAvailable;

  /// Start mDNS discovery. Degrades gracefully if multicast is blocked.
  Future<void> startDiscovery() async {
    try {
      await discovery.start();
    } on SocketException catch (e) {
      debugPrint('mDNS discovery unavailable: $e');
      _mdnsAvailable = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    try { discovery.stop(); } catch (_) {}
    super.dispose();
  }
}
