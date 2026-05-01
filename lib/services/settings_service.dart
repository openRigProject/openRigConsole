import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists user settings across sessions.
class SettingsService {
  late final SharedPreferences _prefs;

  static const _keyLastHost = 'last_host';
  static const _keyLastPort = 'last_port';
  static const _keyClusterHost = 'cluster_host';
  static const _keyClusterPort = 'cluster_port';
  static const _keyClusterAutoConnect = 'cluster_auto_connect';
  static const _keyClusterSpotMaxAge  = 'cluster_spot_max_age';
  static const _keyCallsign = 'callsign';
  static const _keyLogPath = 'log_path';
  static const _keySidecarPort = 'sidecar_port';
  static const _keySidecarModel = 'sidecar_model';
  static const _keySidecarSerialPort = 'sidecar_serial_port';
  static const _keySidecarBaudRate = 'sidecar_baud_rate';
  static const _keySidecarDataBits = 'sidecar_data_bits';
  static const _keySidecarStopBits = 'sidecar_stop_bits';
  static const _keySidecarParity = 'sidecar_parity';
  static const _keySidecarHandshake = 'sidecar_handshake';
  static const _keyGridSquare = 'grid_square';
  static const _keyQrzApiKey = 'qrz_api_key';
  static const _keyQrzXmlUser = 'qrz_xml_user';
  static const _keyQrzXmlPass = 'qrz_xml_pass';
  static const _keyLayoutTopZone  = 'layout_top_zone';
  static const _keyLayoutMapWidth  = 'layout_map_width';
  static const _keyLayoutStatsWidth = 'layout_stats_width';

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // -- Last connected device --

  String? get lastHost => _prefs.getString(_keyLastHost);
  int get lastPort => _prefs.getInt(_keyLastPort) ?? 4532;

  Future<void> setLastDevice(String host, int port) async {
    await _prefs.setString(_keyLastHost, host);
    await _prefs.setInt(_keyLastPort, port);
  }

  Future<void> clearLastDevice() async {
    await _prefs.remove(_keyLastHost);
    await _prefs.remove(_keyLastPort);
  }

  // -- DX Cluster node --

  String get clusterHost => _prefs.getString(_keyClusterHost) ?? 'dxc.ve7cc.net';
  int get clusterPort => _prefs.getInt(_keyClusterPort) ?? 23;
  bool get clusterAutoConnect => _prefs.getBool(_keyClusterAutoConnect) ?? false;

  Future<void> setClusterNode(String host, int port) async {
    await _prefs.setString(_keyClusterHost, host);
    await _prefs.setInt(_keyClusterPort, port);
  }

  Future<void> setClusterAutoConnect(bool value) async {
    await _prefs.setBool(_keyClusterAutoConnect, value);
  }

  // -- Spot max age (minutes) --

  int get clusterSpotMaxAge => _prefs.getInt(_keyClusterSpotMaxAge) ?? 30;

  Future<void> setClusterSpotMaxAge(int minutes) async {
    await _prefs.setInt(_keyClusterSpotMaxAge, minutes);
  }

  // -- Callsign --

  String get callsign => _prefs.getString(_keyCallsign) ?? '';

  Future<void> setCallsign(String callsign) async {
    await _prefs.setString(_keyCallsign, callsign);
  }

  // -- Grid square --

  String get gridSquare => _prefs.getString(_keyGridSquare) ?? '';

  Future<void> setGridSquare(String grid) async {
    await _prefs.setString(_keyGridSquare, grid);
  }

  // -- QRZ Logbook API key --

  String get qrzApiKey => _prefs.getString(_keyQrzApiKey) ?? '';

  Future<void> setQrzApiKey(String key) async {
    await _prefs.setString(_keyQrzApiKey, key);
  }

  // -- QRZ XML API credentials --

  String get qrzXmlUser => _prefs.getString(_keyQrzXmlUser) ?? '';
  String get qrzXmlPass => _prefs.getString(_keyQrzXmlPass) ?? '';

  Future<void> setQrzXmlCredentials(String user, String pass) async {
    await _prefs.setString(_keyQrzXmlUser, user);
    await _prefs.setString(_keyQrzXmlPass, pass);
  }

  // -- Layout divider positions --

  double get layoutTopZone   => _prefs.getDouble(_keyLayoutTopZone)   ?? 320;
  double get layoutMapWidth  => _prefs.getDouble(_keyLayoutMapWidth)  ?? 220;
  double get layoutStatsWidth => _prefs.getDouble(_keyLayoutStatsWidth) ?? 160;

  Future<void> setLayoutTopZone(double v)   async => _prefs.setDouble(_keyLayoutTopZone, v);
  Future<void> setLayoutMapWidth(double v)  async => _prefs.setDouble(_keyLayoutMapWidth, v);
  Future<void> setLayoutStatsWidth(double v) async => _prefs.setDouble(_keyLayoutStatsWidth, v);

  // -- Log file path --

  String get logPath =>
      _prefs.getString(_keyLogPath) ??
      '${Platform.environment['HOME'] ?? '.'}/openrig.adi';

  Future<void> setLogPath(String path) async {
    await _prefs.setString(_keyLogPath, path);
  }

  // -- Sidecar rigctld port --

  int get sidecarPort => _prefs.getInt(_keySidecarPort) ?? 4532;

  Future<void> setSidecarPort(int port) async {
    await _prefs.setInt(_keySidecarPort, port);
  }

  // -- Sidecar rig config --

  int get sidecarModel => _prefs.getInt(_keySidecarModel) ?? 1;
  String get sidecarSerialPort => _prefs.getString(_keySidecarSerialPort) ?? '';
  int get sidecarBaudRate => _prefs.getInt(_keySidecarBaudRate) ?? 9600;
  int get sidecarDataBits => _prefs.getInt(_keySidecarDataBits) ?? 8;
  int get sidecarStopBits => _prefs.getInt(_keySidecarStopBits) ?? 1;
  String get sidecarParity => _prefs.getString(_keySidecarParity) ?? 'none';
  String get sidecarHandshake => _prefs.getString(_keySidecarHandshake) ?? 'none';

  Future<void> setSidecarRigConfig({
    required int model,
    required String serialPort,
    required int baudRate,
    required int dataBits,
    required int stopBits,
    required String parity,
    required String handshake,
  }) async {
    await _prefs.setInt(_keySidecarModel, model);
    await _prefs.setString(_keySidecarSerialPort, serialPort);
    await _prefs.setInt(_keySidecarBaudRate, baudRate);
    await _prefs.setInt(_keySidecarDataBits, dataBits);
    await _prefs.setInt(_keySidecarStopBits, stopBits);
    await _prefs.setString(_keySidecarParity, parity);
    await _prefs.setString(_keySidecarHandshake, handshake);
  }
}
