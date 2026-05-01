import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:openrig_core/openrig_core.dart' hide ChangeNotifier;
import 'settings_service.dart';

/// Holds state for one managed rigctld sidecar process.
class _SidecarEntry {
  Process process;
  bool managed;
  int restartDelaySec;
  final String binaryPath;
  final List<String> args;
  final String rigLabel;

  _SidecarEntry({
    required this.process,
    required this.binaryPath,
    required this.args,
    required this.rigLabel,
  })  : managed = true,
        restartDelaySec = 1;
}

/// Manages rig connections via RigManager, mDNS discovery, and local
/// rigctld sidecar processes.
///
/// Multiple local sidecars are supported simultaneously, each on a
/// different TCP port. Each sidecar is monitored and restarted
/// automatically on unexpected exit with exponential back-off.
class ConnectionService extends ChangeNotifier {
  final SettingsService settings;
  final OpenRigDiscovery discovery = OpenRigDiscovery();
  final RigManager rigManager = RigManager();

  /// Active sidecar processes keyed by their TCP port.
  final Map<int, _SidecarEntry> _sidecars = {};

  /// Ports that have been explicitly removed by the user; suppresses
  /// auto-restart even if the process crashed before the removal.
  final Set<int> _removedPorts = {};

  /// Persistent log buffers per sidecar port (survive restarts).
  final Map<int, List<String>> _sidecarLogs = {};

  /// Broadcast streams for live log tailing per sidecar port.
  final Map<int, StreamController<String>> _sidecarLogStreams = {};

  bool _disposed = false;
  bool _mdnsAvailable = true;
  String? _sidecarBinaryCache;

  ConnectionService({required this.settings}) {
    rigManager.addListener(_onRigManagerChanged);
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  RigClient? get client => rigManager.activeRig?.client;

  bool get connected =>
      rigManager.activeRig != null && rigManager.activeRig!.connected;

  bool get sidecarRunning => _sidecars.isNotEmpty;

  String get statusLabel {
    final active = rigManager.activeRig;
    if (active == null) return 'No rigs';
    if (!active.connected) return 'Disconnected';
    return active.label;
  }

  bool get mdnsAvailable => _mdnsAvailable;

  /// Ports of currently running local sidecars.
  List<int> get sidecarPorts => List.unmodifiable(_sidecars.keys);

  /// Buffered log lines for the sidecar on [port] (last 1000 lines).
  List<String> getSidecarLog(int port) =>
      List.unmodifiable(_sidecarLogs[port] ?? const []);

  /// Broadcast stream of new log lines for the sidecar on [port].
  Stream<String>? getSidecarLogStream(int port) =>
      _sidecarLogStreams[port]?.stream;

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

  /// Re-connect to the last used device.
  Future<void> autoConnect() async {
    final host = settings.lastHost;
    if (host == null) return;

    if (host == 'local') {
      try {
        await addFfiLocalRig();
      } catch (_) {}
      return;
    }

    if (host == 'localhost') {
      try {
        await addLocalRig(tcpPort: settings.lastPort);
      } catch (_) {}
      return;
    }

    try {
      await addRemoteRig(host, settings.lastPort);
    } catch (_) {}
  }

  /// Add a remote rig to the manager.
  Future<RigEntry> addRemoteRig(String host, int port, {String? label}) async {
    final entry = await rigManager.addRig(
      host: host,
      port: port,
      label: label ?? '$host:$port',
    );
    await settings.setLastDevice(host, port);
    return entry;
  }

  /// Add a local rig via direct FFI (libhamlib) — no subprocess needed.
  Future<RigEntry> addFfiLocalRig({
    int? model,
    String? serialPort,
    int? baudRate,
    int? dataBits,
    int? stopBits,
    String? parity,
    String? handshake,
    String? label,
  }) async {
    final m = model ?? settings.sidecarModel;
    final entry = await rigManager.addLocalRig(
      hamlibModel: m,
      serialPort: serialPort ?? settings.sidecarSerialPort,
      baudRate: baudRate ?? settings.sidecarBaudRate,
      dataBits: dataBits ?? settings.sidecarDataBits,
      stopBits: stopBits ?? settings.sidecarStopBits,
      parity: parity ?? settings.sidecarParity,
      handshake: handshake ?? settings.sidecarHandshake,
      label: label,
    );
    await settings.setLastDevice('local', 0);
    return entry;
  }

  /// Launch a local rigctld sidecar and add it as a rig.
  ///
  /// All parameters are optional and fall back to [settings] values.
  /// Pass [tcpPort] to run a second sidecar on a different port.
  Future<RigEntry> addLocalRig({
    int? model,
    String? serialPort,
    int? baudRate,
    int? dataBits,
    int? stopBits,
    String? parity,
    String? handshake,
    int? tcpPort,
    String? label,
  }) async {
    final port = tcpPort ?? settings.sidecarPort;
    _removedPorts.remove(port);
    final m = model ?? settings.sidecarModel;
    final binaryPath = await _resolveSidecarBinaryPath();
    final args = _buildSidecarArgs(
      port: port,
      model: m,
      serialPort: serialPort ?? settings.sidecarSerialPort,
      baudRate: baudRate ?? settings.sidecarBaudRate,
      dataBits: dataBits ?? settings.sidecarDataBits,
      stopBits: stopBits ?? settings.sidecarStopBits,
      parity: parity ?? settings.sidecarParity,
      handshake: handshake ?? settings.sidecarHandshake,
    );
    final rigLabel = label ?? (m == 1 ? 'Local (Dummy)' : 'Local (model $m)');

    final process = await Process.start(binaryPath, args);
    final sidecar = _SidecarEntry(
      process: process,
      binaryPath: binaryPath,
      args: args,
      rigLabel: rigLabel,
    );
    _sidecars[port] = sidecar;
    _subscribeProcessLogs(process, port);

    // Give rigctld a moment to bind its port before connecting.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    RigEntry rigEntry;
    try {
      rigEntry = await rigManager.addRig(
        host: 'localhost',
        port: port,
        label: rigLabel,
      );
    } catch (e) {
      process.kill();
      _sidecars.remove(port);
      rethrow;
    }

    await settings.setLastDevice('localhost', port);
    _watchSidecar(process, port, sidecar);
    return rigEntry;
  }

  /// Restart the sidecar on [port] picking up current settings values.
  /// Pass [label] to override the rig's display name after restart.
  Future<void> restartLocalSidecar(int port, {String? label}) async {
    final existing = _sidecars.remove(port);
    if (existing != null) {
      existing.managed = false;
      existing.process.kill();
    }
    try { rigManager.removeRig('localhost:$port'); } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // Always re-read from settings so any config changes take effect.
    await addLocalRig(tcpPort: port, label: label);
  }

  /// Stop the sidecar on [port] and remove its rig entry.
  void stopLocalSidecar(int port) {
    _stopSidecar(port);
    try { rigManager.removeRig('localhost:$port'); } catch (_) {}
  }

  /// Remove a rig by id. Stops the sidecar if it was a local rig.
  void removeRig(String id) {
    if (id.startsWith('localhost:')) {
      final port = int.tryParse(id.split(':').last);
      if (port != null) {
        _removedPorts.add(port);
        _stopSidecar(port);
      }
    }
    rigManager.removeRig(id);
  }

  /// Disconnect all rigs and stop all sidecars.
  Future<void> disconnect() async {
    for (final port in _sidecars.keys.toList()) {
      _stopSidecar(port);
    }
    for (final rig in List.of(rigManager.rigs)) {
      rigManager.removeRig(rig.id);
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final port in _sidecars.keys.toList()) {
      _stopSidecar(port);
    }
    rigManager.removeListener(_onRigManagerChanged);
    rigManager.dispose();
    try { discovery.stop(); } catch (_) {}
    for (final ctl in _sidecarLogStreams.values) {
      ctl.close();
    }
    super.dispose();
  }

  // ── Sidecar lifecycle ──────────────────────────────────────────────────────

  void _stopSidecar(int port) {
    final entry = _sidecars.remove(port);
    if (entry == null) return;
    entry.managed = false;
    entry.process.kill();
  }

  void _watchSidecar(Process process, int port, _SidecarEntry entry) {
    process.exitCode.then((code) {
      if (_disposed || !entry.managed) return;
      // Ignore if a newer sidecar has already replaced this one.
      final current = _sidecars[port];
      if (current != null && current.process != process) return;

      _sidecars.remove(port);
      debugPrint('rigctld (port $port) exited (code $code) — '
          'restarting in ${entry.restartDelaySec}s');

      try { rigManager.removeRig('localhost:$port'); } catch (_) {}
      notifyListeners();

      _scheduleRestart(port, entry);
    });
  }

  void _scheduleRestart(int port, _SidecarEntry entry) {
    if (_disposed || !entry.managed || _removedPorts.contains(port)) return;
    if (_sidecars.containsKey(port)) return; // already restarted manually

    final delay = Duration(seconds: entry.restartDelaySec);
    entry.restartDelaySec = (entry.restartDelaySec * 2).clamp(1, 30);

    Future.delayed(delay, () async {
      if (_disposed || !entry.managed || _removedPorts.contains(port)) return;
      if (_sidecars.containsKey(port)) return;

      try {
        final process = await Process.start(entry.binaryPath, entry.args);
        final newSidecar = _SidecarEntry(
          process: process,
          binaryPath: entry.binaryPath,
          args: entry.args,
          rigLabel: entry.rigLabel,
        );
        _sidecars[port] = newSidecar;
        _subscribeProcessLogs(process, port);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        try {
          await rigManager.addRig(
              host: 'localhost', port: port, label: entry.rigLabel);
        } catch (_) {
          process.kill();
          _sidecars.remove(port);
          _scheduleRestart(port, entry);
          return;
        }
        _watchSidecar(process, port, newSidecar);
      } catch (_) {
        _scheduleRestart(port, entry);
      }
    });
  }

  // ── Log capture ────────────────────────────────────────────────────────────

  void _subscribeProcessLogs(Process process, int port) {
    _sidecarLogs.putIfAbsent(port, () => []);
    _sidecarLogStreams.putIfAbsent(
        port, () => StreamController<String>.broadcast());

    final buf = _sidecarLogs[port]!;
    final ctl = _sidecarLogStreams[port]!;

    void addLine(String line) {
      if (line.isEmpty) return;
      buf.add(line);
      if (buf.length > 1000) buf.removeAt(0);
      if (!ctl.isClosed) ctl.add(line);
    }

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(addLine);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(addLine);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _onRigManagerChanged() {
    if (!_disposed) notifyListeners();
  }

  List<String> _buildSidecarArgs({
    required int port,
    required int model,
    required String serialPort,
    required int baudRate,
    required int dataBits,
    required int stopBits,
    required String parity,
    required String handshake,
  }) {
    final args = [
      '-m', model.toString(),
      '--port', port.toString(),
    ];
    // Dummy rig (model 1) and NET rigctl (model 2) have no serial port.
    if (model > 2) {
      if (serialPort.isNotEmpty) args.addAll(['-r', serialPort]);
      if (baudRate != 9600) args.addAll(['-s', baudRate.toString()]);
      if (dataBits != 8) args.addAll(['--set-conf', 'data_bits=$dataBits']);
      if (stopBits != 1) args.addAll(['--set-conf', 'stop_bits=$stopBits']);
      if (parity != 'none') {
        final v = parity[0].toUpperCase() + parity.substring(1);
        args.addAll(['--set-conf', 'serial_parity=$v']);
      }
      if (handshake != 'none') {
        final v = handshake[0].toUpperCase() + handshake.substring(1);
        args.addAll(['--set-conf', 'serial_handshake=$v']);
      }
    }
    return args;
  }

  /// Returns a path to the rigctld binary that is guaranteed to be executable.
  ///
  /// On macOS, `open`-launched apps inherit CWD=/ so relative asset paths
  /// fail. We extract the binary from Flutter's asset bundle into a temp
  /// file on first call and cache the result for subsequent restarts.
  Future<String> _resolveSidecarBinaryPath() async {
    if (_sidecarBinaryCache != null) return _sidecarBinaryCache!;

    if (Platform.isMacOS) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = '$exeDir/rigctld';
      if (File(bundled).existsSync()) {
        _sidecarBinaryCache = bundled;
        return bundled;
      }

      const assetKey = 'assets/rigctld/macos/rigctld';
      final tmpPath = '${Directory.systemTemp.path}/openrig_rigctld';
      final data = await rootBundle.load(assetKey);
      final tmpFile = File(tmpPath);
      await tmpFile.writeAsBytes(data.buffer.asUint8List(), flush: true);
      await Process.run('chmod', ['+x', tmpPath]);
      _sidecarBinaryCache = tmpPath;
      return tmpPath;
    }

    if (Platform.isLinux) {
      _sidecarBinaryCache = 'assets/rigctld/linux/rigctld';
      return _sidecarBinaryCache!;
    }
    if (Platform.isWindows) {
      _sidecarBinaryCache = 'assets/rigctld/windows/rigctld.exe';
      return _sidecarBinaryCache!;
    }
    throw UnsupportedError('Unsupported platform for rigctld sidecar');
  }
}
