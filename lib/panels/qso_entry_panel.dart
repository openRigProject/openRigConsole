import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/connection_service.dart';
import '../services/settings_service.dart';

// ---------------------------------------------------------------------------
// QSO source — rig VFO or hotspot last-heard station
// ---------------------------------------------------------------------------

sealed class _QsoSource {
  String get id;
  String get label;
}

class _RigSource extends _QsoSource {
  final RigEntry rig;
  _RigSource(this.rig);
  @override String get id => rig.id;
  @override String get label => rig.label;
}

class _HotspotSource extends _QsoSource {
  final OpenRigDevice device;
  _HotspotSource(this.device);
  @override String get id => device.host;
  @override String get label =>
      device.callsign.isNotEmpty ? device.callsign : device.host;
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

class QsoEntryController {
  _QsoEntryPanelState? _state;

  void _attach(_QsoEntryPanelState s) => _state = s;
  void _detach() => _state = null;

  /// Populate the QSO entry panel from a DX cluster spot and trigger a QRZ lookup.
  void loadSpot(DxSpot spot) => _state?._loadSpot(spot);
}

// ---------------------------------------------------------------------------

class QsoEntryPanel extends StatefulWidget {
  final ConnectionService connectionService;
  final SettingsService settings;
  final VoidCallback? onQsoLogged;
  final QsoEntryController? controller;
  final dynamic dxClusterController; // DxClusterController from spots_screen
  final void Function(double lat, double lon, String callsign)? onLocationChanged;

  const QsoEntryPanel({
    super.key,
    required this.connectionService,
    required this.settings,
    this.onQsoLogged,
    this.controller,
    this.dxClusterController,
    this.onLocationChanged,
  });

  @override
  State<QsoEntryPanel> createState() => _QsoEntryPanelState();
}

class _QsoEntryPanelState extends State<QsoEntryPanel> {
  // ── Callsign + contact fields ───────────────────────────────────────────
  final _callCtl     = TextEditingController();
  final _notesCtl    = TextEditingController();

  // ── QSO data fields ─────────────────────────────────────────────────────
  final _rstSentCtl  = TextEditingController(text: '59');
  final _rstRcvdCtl  = TextEditingController(text: '59');
  final _powerCtl    = TextEditingController(text: '5');
  final _gridCtl     = TextEditingController();
  final _locatorCtl  = TextEditingController();
  final _ituCtl      = TextEditingController();
  final _iotaCtl     = TextEditingController();
  final _skccCtl     = TextEditingController();
  final _sotaCtl     = TextEditingController();
  final _potaCtl     = TextEditingController();
  final _qslViaCtl   = TextEditingController();
  final _wwffCtl     = TextEditingController();
  final _dxccCtl     = TextEditingController();
  final _cqCtl       = TextEditingController();
  final _urlCtl      = TextEditingController();
  final _tentenCtl   = TextEditingController();
  final _dxDeCtl     = TextEditingController();

  // ── Time & frequency ────────────────────────────────────────────────────
  DateTime? _timeOn;
  DateTime? _timeOff;
  DateTime _nowUtc = DateTime.now().toUtc();
  Timer? _clockTimer;

  int _frequencyHz = 0;
  String _mode = '';
  Timer? _pollTimer;

  // ── QRZ inline data ─────────────────────────────────────────────────────
  CallsignInfo? _qrzInfo;
  bool _qrzLookingUp = false;
  // True when the current spot has a known POTA location; suppress QRZ map update.
  bool _hasPotaLocation = false;

  // ── POTA park info ───────────────────────────────────────────────────────
  String? _potaParkName;

  // ── Dupe checker ────────────────────────────────────────────────────────
  DuplicateChecker? _dupeChecker;

  // ── Source selection ────────────────────────────────────────────────────
  _QsoSource? _selectedSource;
  OpenRigApiClient? _hotspotApiClient;
  Timer? _hotspotPollTimer;
  StreamSubscription<OpenRigDevice>? _deviceFoundSub;
  StreamSubscription<String>? _deviceLostSub;

  // ── Tab: 0=DX, 1=Contest ─────────────────────────────────────────────
  int _qsoTab = 0;

  ConnectionService get _cs => widget.connectionService;

  // ── Styles ──────────────────────────────────────────────────────────────
  static const _labelStyle = TextStyle(fontSize: 11, color: Color(0xFF9E9E9E));
  static const _valueStyle = TextStyle(fontSize: 11);
  static const _inputStyle = TextStyle(fontSize: 11, fontFamily: 'monospace');

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _cs.addListener(_onConnectionChanged);
    _callCtl.addListener(_onCallsignChanged);
    _buildDupeChecker();

    _clockTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) { if (mounted) setState(() => _nowUtc = DateTime.now().toUtc()); },
    );

    if (_cs.mdnsAvailable) {
      _deviceFoundSub = _cs.discovery.onDeviceFound.listen((_) {
        if (mounted) setState(() => _ensureSourceValid());
      });
      _deviceLostSub = _cs.discovery.onDeviceLost.listen((_) {
        if (mounted) setState(() => _ensureSourceValid());
      });
    }
    _ensureSourceValid();
  }

  @override
  void dispose() {
    widget.controller?._detach();
    _clockTimer?.cancel();
    _pollTimer?.cancel();
    _hotspotPollTimer?.cancel();
    _hotspotApiClient?.dispose();
    _deviceFoundSub?.cancel();
    _deviceLostSub?.cancel();
    _cs.removeListener(_onConnectionChanged);
    for (final c in [
      _callCtl, _notesCtl, _rstSentCtl, _rstRcvdCtl, _powerCtl,
      _gridCtl, _locatorCtl, _ituCtl, _iotaCtl, _skccCtl,
      _sotaCtl, _potaCtl, _qslViaCtl, _wwffCtl, _dxccCtl,
      _cqCtl, _urlCtl, _tentenCtl, _dxDeCtl,
    ]) { c.dispose(); }
    super.dispose();
  }

  // ── Dupe checker ──────────────────────────────────────────────────────

  Future<void> _buildDupeChecker() async {
    try {
      final file = File(widget.settings.logPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final records = AdifLog.parse(content);
        if (mounted) setState(() => _dupeChecker = DuplicateChecker(records));
      } else {
        if (mounted) setState(() => _dupeChecker = DuplicateChecker([]));
      }
    } catch (_) {
      if (mounted) setState(() => _dupeChecker = DuplicateChecker([]));
    }
  }

  void _onCallsignChanged() {
    final call = _callCtl.text.trim();
    // Auto-set timeOn the first time a callsign is typed
    if (call.isNotEmpty && _timeOn == null) {
      _timeOn = DateTime.now().toUtc();
    }
    if (call.isEmpty) {
      _qrzInfo = null;
    }
    setState(() {});
  }

  // ── Connection & source handling ──────────────────────────────────────

  void _onConnectionChanged() {
    setState(() {});
    _ensureSourceValid();
    final source = _selectedSource;
    if (source is _RigSource) {
      if (source.rig.connected) {
        _startPolling();
      } else {
        _pollTimer?.cancel();
        _pollTimer = null;
      }
    }
  }

  List<_QsoSource> _buildSources() {
    final sources = <_QsoSource>[];
    for (final rig in _cs.rigManager.rigs) {
      sources.add(_RigSource(rig));
    }
    if (_cs.mdnsAvailable) {
      for (final device in _cs.discovery.devices.values) {
        if (device.type == 'hotspot' && device.provisioned) {
          sources.add(_HotspotSource(device));
        }
      }
    }
    return sources;
  }

  void _ensureSourceValid() {
    final sources = _buildSources();
    if (_selectedSource == null) {
      if (sources.isNotEmpty) _selectSource(sources.first);
      return;
    }
    final stillValid = sources.any((s) => s.id == _selectedSource!.id);
    if (!stillValid) {
      _selectSource(sources.isNotEmpty ? sources.first : null);
    }
  }

  void _selectSource(_QsoSource? source) {
    _pollTimer?.cancel();
    _pollTimer = null;
    _hotspotPollTimer?.cancel();
    _hotspotPollTimer = null;
    _hotspotApiClient?.dispose();
    _hotspotApiClient = null;

    setState(() {
      _selectedSource = source;
      _frequencyHz = 0;
      _mode = '';
    });

    if (source == null) return;

    if (source is _RigSource && source.rig.connected) {
      _startPolling();
    } else if (source is _HotspotSource) {
      _hotspotApiClient = OpenRigApiClient(
        host: source.device.host,
        port: source.device.port,
      );
      _fetchHotspotFrequency();
      _startHotspotPolling();
    }
  }

  Future<void> _fetchHotspotFrequency() async {
    final client = _hotspotApiClient;
    if (client == null) return;
    try {
      final config = await client.getHotspot();
      if (mounted && config.rfFrequencyMhz > 0) {
        setState(() => _frequencyHz = (config.rfFrequencyMhz * 1e6).round());
      }
    } catch (_) {}
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  bool _polling = false;
  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final source = _selectedSource;
      if (source is! _RigSource) return;
      final client = source.rig.client;
      if (!client.isConnected) return;
      final freq = await client.getFrequency();
      final modeResult = await client.getMode();
      if (mounted) setState(() { _frequencyHz = freq; _mode = modeResult.mode; });
    } catch (_) {
    } finally {
      _polling = false;
    }
  }

  void _startHotspotPolling() {
    _hotspotPollTimer?.cancel();
    _pollHotspot();
    _hotspotPollTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _pollHotspot());
  }

  Future<void> _pollHotspot() async {
    final client = _hotspotApiClient;
    if (client == null) return;
    try {
      final clients = await client.getClients();
      if (!mounted || clients.isEmpty) return;
      final latest = clients.first;
      setState(() {
        _mode = _mapHotspotMode(latest.mode);
        if (_callCtl.text.isEmpty) _callCtl.text = latest.callsign;
      });
    } catch (_) {}
  }

  static String _mapHotspotMode(String mode) => switch (mode.toUpperCase()) {
        'DMR' => 'DMR',
        'YSF' => 'C4FM',
        'P25' => 'P25',
        'NXDN' => 'NXDN',
        _ => mode,
      };

  // ── Spot loading ─────────────────────────────────────────────────────────

  void _loadSpot(DxSpot spot) {
    final hz = (spot.frequencyKhz * 1000).round();
    final mode = _modeFromSpot(spot);
    final client = _cs.client;
    if (client != null && client.isConnected) {
      client.setFrequency(hz);
      if (mode != null) client.setMode(mode);
    }

    _hasPotaLocation = spot.parkRef != null;
    setState(() {
      _callCtl.text = spot.dxCall;
      if (mode != null) _mode = mode;
      _qrzInfo = null;
      _potaParkName = null;
      _qsoTab = 0;
      _timeOn = DateTime.now().toUtc();
      _timeOff = null;
      _gridCtl.clear();
      _cqCtl.clear();
      _ituCtl.clear();
      _iotaCtl.clear();
      _qslViaCtl.clear();
      _urlCtl.clear();
      _dxccCtl.clear();
      if (spot.parkRef != null) {
        _potaCtl.text = spot.parkRef!;
      } else {
        _potaCtl.clear();
      }
    });

    _lookupQrz();
    if (spot.parkRef != null) _lookupPotaPark(spot.parkRef!);
  }

  Future<void> _lookupPotaPark(String ref) async {
    try {
      final client = HttpClient();
      final req = await client.getUrl(
          Uri.parse('https://api.pota.app/park/$ref'));
      req.headers.set('Accept', 'application/json');
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final name = json['name'] as String? ?? '';
      final location = json['locationName'] as String? ?? '';
      final parkName = [name, location].where((s) => s.isNotEmpty).join(', ');
      if (mounted && parkName.isNotEmpty) {
        setState(() => _potaParkName = parkName);
      }
    } catch (_) {}
  }

  /// Detect mode from spot comment, then fall back to band-plan inference.
  static String? _modeFromSpot(DxSpot spot) {
    final comment = spot.comment.toUpperCase();
    // Digital modes: VFO stays in USB on the rig
    for (final m in ['FT8', 'FT4', 'PSK31', 'RTTY', 'JS8', 'WSPR', 'DIGI', 'DATA']) {
      if (comment.contains(m)) return 'USB';
    }
    for (final m in ['CW']) {
      if (comment.contains(m)) return 'CW';
    }
    for (final m in ['FM']) {
      if (comment.contains(m)) return 'FM';
    }
    for (final m in ['AM']) {
      if (comment.contains(m)) return 'AM';
    }
    for (final m in ['USB']) {
      if (comment.contains(m)) return 'USB';
    }
    if (comment.contains('LSB')) { return 'LSB'; }
    if (comment.contains('SSB')) { return 'USB'; }
    return null;
  }

  // ── QRZ ─────────────────────────────────────────────────────────────────

  Future<void> _lookupQrz() async {
    final raw = normalizeCallsign(_callCtl.text);
    if (raw.isEmpty) return;
    final user = widget.settings.qrzXmlUser;
    final pass = widget.settings.qrzXmlPass;
    if (user.isEmpty || pass.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('QRZ XML credentials not set — add in Preferences')),
      );
      return;
    }
    setState(() => _qrzLookingUp = true);
    try {
      final client = QrzXmlClient(username: user, password: pass);
      CallsignInfo? info;
      String? prefixCountryOverride;

      try {
        info = await client.lookupCallsign(raw);
      } on QrzXmlException {
        // If the callsign contains '/', retry with the longer segment
        if (raw.contains('/')) {
          final parts = raw.split('/');
          final longer = parts.reduce(
              (a, b) => a.length >= b.length ? a : b);
          final shorter = parts.firstWhere((p) => p != longer,
              orElse: () => '');
          final shorterIsPrefix = shorter.isNotEmpty &&
              raw.startsWith(shorter);
          try {
            info = await client.lookupCallsign(longer);
            // If shorter part is the prefix, look up DXCC for that prefix
            if (shorterIsPrefix) {
              prefixCountryOverride =
                  lookupDxccOrNull('${shorter}0AA') ??
                  lookupDxccOrNull(shorter);
            }
          } on QrzXmlException {
            rethrow;
          }
        } else {
          rethrow;
        }
      }

      client.dispose();
      if (!mounted) return;
      setState(() {
        _qrzInfo = info;
        if (info!.grid.isNotEmpty) {
          _gridCtl.text = info.grid;
          // Don't move the map when a POTA location override is already in place.
          if (!_hasPotaLocation) {
            final loc = gridToLatLon(info.grid);
            if (loc != null) {
              widget.onLocationChanged?.call(loc.lat, loc.lon, raw);
            }
          }
        }
        if (info.cqZone.isNotEmpty)   _cqCtl.text      = info.cqZone;
        if (info.ituZone.isNotEmpty)  _ituCtl.text     = info.ituZone;
        if (info.iota.isNotEmpty)     _iotaCtl.text    = info.iota;
        if (info.qslMgr.isNotEmpty)   _qslViaCtl.text  = info.qslMgr;
        if (info.url.isNotEmpty)      _urlCtl.text     = info.url;
        // Country override wins if operating under a foreign prefix
        if (prefixCountryOverride != null) {
          _dxccCtl.text = prefixCountryOverride;
        } else if (info.dxcc.isNotEmpty) {
          _dxccCtl.text = info.dxcc;
        }
      });
    } on QrzXmlException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('QRZ: ${e.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _qrzLookingUp = false);
    }
  }

  Future<void> _openQrzPage(String callsign) async {
    final uri = Uri.parse('https://www.qrz.com/db/${callsign.toUpperCase()}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  // ── QSO actions ──────────────────────────────────────────────────────────

  void _clear() {
    setState(() {
      _callCtl.clear();
      _rstSentCtl.text = '59';
      _rstRcvdCtl.text = '59';
      _notesCtl.clear();
      _powerCtl.text = '5';
      _gridCtl.clear();
      _locatorCtl.clear();
      _ituCtl.clear();
      _iotaCtl.clear();
      _skccCtl.clear();
      _sotaCtl.clear();
      _potaCtl.clear();
      _qslViaCtl.clear();
      _wwffCtl.clear();
      _dxccCtl.clear();
      _cqCtl.clear();
      _urlCtl.clear();
      _tentenCtl.clear();
      _dxDeCtl.clear();
      _timeOn = null;
      _timeOff = null;
      _qrzInfo = null;
    });
  }

  Future<void> _logQso() async {
    final call = normalizeCallsign(_callCtl.text);
    if (call.isEmpty) return;
    if (!isValidCallsign(call)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid callsign')),
      );
      return;
    }

    final freqMhz = _frequencyHz / 1e6;
    final record = QsoRecord(
      call: call,
      band: _freqToBand(freqMhz),
      mode: _mode.isNotEmpty ? _mode : 'SSB',
      freqMhz: freqMhz,
      timeOn: _timeOn ?? DateTime.now().toUtc(),
      timeOff: _timeOff,
      rstSent: _rstSentCtl.text.trim(),
      rstRcvd: _rstRcvdCtl.text.trim(),
      name: _qrzInfo?.fullName.isNotEmpty == true ? _qrzInfo!.fullName : null,
      comment: _notesCtl.text.trim().isNotEmpty ? _notesCtl.text.trim() : null,
      sotaRef: _sotaCtl.text.trim().isEmpty ? null : _sotaCtl.text.trim(),
      potaRef: _potaCtl.text.trim().isEmpty ? null : _potaCtl.text.trim(),
      extra: {
        if (_qrzInfo?.city.isNotEmpty == true) 'QTH': _qrzInfo!.city,
        if (_qrzInfo?.state.isNotEmpty == true) 'STATE': _qrzInfo!.state,
        if (_qrzInfo?.country.isNotEmpty == true) 'COUNTRY': _qrzInfo!.country,
      },
    );

    await AdifLog.appendRecord(widget.settings.logPath, record);
    _dupeChecker?.addQso(record);
    widget.onQsoLogged?.call();

    final key = widget.settings.qrzApiKey;
    if (key.isNotEmpty) {
      try {
        final client = QrzLogbookClient(apiKey: key);
        await client.insertQso(record);
        client.dispose();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Logged to QRZ')),
          );
        }
      } on QrzException catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('QRZ upload failed: ${e.message}')),
          );
        }
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Logged $call'), duration: const Duration(seconds: 2)),
      );
      _clear();
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _freqToBand(double mhz) {
    if (mhz >= 1.8 && mhz < 2.0) return '160m';
    if (mhz >= 3.5 && mhz < 4.0) return '80m';
    if (mhz >= 5.3 && mhz < 5.5) return '60m';
    if (mhz >= 7.0 && mhz < 7.3) return '40m';
    if (mhz >= 10.1 && mhz < 10.15) return '30m';
    if (mhz >= 14.0 && mhz < 14.35) return '20m';
    if (mhz >= 18.068 && mhz < 18.168) return '17m';
    if (mhz >= 21.0 && mhz < 21.45) return '15m';
    if (mhz >= 24.89 && mhz < 24.99) return '12m';
    if (mhz >= 28.0 && mhz < 29.7) return '10m';
    if (mhz >= 50.0 && mhz < 54.0) return '6m';
    if (mhz >= 144.0 && mhz < 148.0) return '2m';
    return '';
  }

  String _formatDateTimeUtc(DateTime dt) {
    final d = '${dt.year}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
    final t = '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
    return '$d $t';
  }

  String _formatFreq(int hz) {
    if (hz == 0) return '0.000.00';
    final mhz = hz ~/ 1000000;
    final khz = (hz % 1000000) ~/ 1000;
    final sub = (hz % 1000) ~/ 10;
    return '$mhz.${khz.toString().padLeft(3, '0')}.${sub.toString().padLeft(2, '0')}';
  }

  // ── Dupe status ───────────────────────────────────────────────────────────

  // Returns (label, color) for the dupe indicator
  (String, Color)? _dupeInfo() {
    final call = _callCtl.text.trim().toUpperCase();
    if (call.isEmpty || _dupeChecker == null) return null;
    final band = _freqToBand(_frequencyHz / 1e6);
    final mode = _mode.isNotEmpty ? _mode : 'SSB';
    if (_dupeChecker!.isWorkedOnBandMode(call, band, mode)) {
      return ('DUPE', Colors.red.shade400);
    }
    if (_dupeChecker!.isWorkedOnBand(call, band)) {
      return ('B+M', Colors.amber.shade400);
    }
    if (_dupeChecker!.isWorked(call)) {
      return ('B+', Colors.grey.shade400);
    }
    return null;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final sources = _buildSources();
    final band = _freqToBand(_frequencyHz / 1e6);
    final timeDisplay = _formatDateTimeUtc(_timeOn ?? _nowUtc);
    final dupe = _dupeInfo();

    return Column(
      children: [
        // ── DX | Contest tab + source selector ──────────────────────────
        Container(
          height: 30,
          color: Colors.grey.shade900,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              _TabButton('DX',      selected: _qsoTab == 0, onTap: () => setState(() => _qsoTab = 0)),
              const SizedBox(width: 2),
              _TabButton('Contest', selected: _qsoTab == 1, onTap: () => setState(() => _qsoTab = 1)),
              const Spacer(),
              // Source selector
              if (sources.isNotEmpty)
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedSource?.id,
                    isDense: true,
                    style: const TextStyle(fontSize: 11),
                    items: [
                      for (final s in sources)
                        DropdownMenuItem(
                          value: s.id,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                s is _RigSource ? Icons.radio : Icons.router,
                                size: 11,
                                color: s is _RigSource
                                    ? (s.rig.connected ? Colors.green.shade400 : Colors.grey)
                                    : Colors.blue.shade300,
                              ),
                              const SizedBox(width: 4),
                              Text(s.label, style: const TextStyle(fontSize: 11)),
                            ],
                          ),
                        ),
                    ],
                    onChanged: (id) {
                      if (id == null) return;
                      for (final s in sources) {
                        if (s.id == id) { _selectSource(s); return; }
                      }
                    },
                  ),
                ),
            ],
          ),
        ),

        // ── Main two-column body ─────────────────────────────────────────
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── LEFT: contact info panel ──────────────────────────────
              Flexible(
                fit: FlexFit.loose,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: _buildContactPanel(dupe),
                ),
              ),
              Container(width: 1, color: Colors.grey.shade800),

              // ── RIGHT: QSO data panel ─────────────────────────────────
              Expanded(
                child: _qsoTab == 0
                    ? _buildDxPanel(timeDisplay, band, dupe)
                    : _buildContestPanel(timeDisplay, band),
              ),
            ],
          ),
        ),

        // ── Bottom action bar ────────────────────────────────────────────
        Container(
          height: 32,
          color: Colors.grey.shade900,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 90,
                child: FilledButton(
                  onPressed: _logQso,
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.zero,
                    textStyle: const TextStyle(fontSize: 12),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Log QSO'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _clear,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: const TextStyle(fontSize: 12),
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Clear'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () {
                  final call = _callCtl.text.trim();
                  if (call.isEmpty) return;
                  final freqKhz = _frequencyHz / 1000.0;
                  widget.dxClusterController?.sendSpot(
                    call, freqKhz, mode: _mode);
                },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: const TextStyle(fontSize: 12),
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Send Spot'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Left contact panel ────────────────────────────────────────────────────

  Widget _buildContactPanel((String, Color)? dupe) {
    final info = _qrzInfo;
    final callText = _callCtl.text.trim();
    final dxcc = info != null ? lookupDxccOrNull(callText.toUpperCase()) : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          // Call row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            child: Row(
              children: [
                const SizedBox(
                  width: 52,
                  child: Text('Call', textAlign: TextAlign.right, style: _labelStyle),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SizedBox(
                    height: 22,
                    child: TextField(
                      controller: _callCtl,
                      textCapitalization: TextCapitalization.characters,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _lookupQrz(),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        letterSpacing: 1,
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                _qrzLookingUp
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 1.5))
                    : GestureDetector(
                        onTap: callText.isNotEmpty ? _lookupQrz : null,
                        child: Icon(
                          Icons.manage_search,
                          size: 16,
                          color: callText.isNotEmpty
                              ? Colors.grey.shade400
                              : Colors.grey.shade700,
                        ),
                      ),
              ],
            ),
          ),
          // QRZ link + dupe status
          if (callText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 66, right: 8, bottom: 2),
              child: Row(
                children: [
                  if (dupe != null)
                    Text(dupe.$1,
                        style: TextStyle(
                            fontSize: 10,
                            color: dupe.$2,
                            fontWeight: FontWeight.bold)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => _openQrzPage(callText),
                    child: Text('QRZ ↗',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.blue.shade400,
                          decoration: TextDecoration.underline,
                          decorationColor: Colors.blue.shade400,
                        )),
                  ),
                ],
              ),
            ),
          // QRZ photo or country flag
          if (info != null) ...[
            const SizedBox(height: 4),
            _buildContactImage(info),
            const SizedBox(height: 4),
          ] else
            const SizedBox(height: 2),
          _contactRow('Name',    info?.fullName ?? ''),
          _contactRow('Street',  info?.address ?? ''),
          _contactRow('City',    info?.city ?? ''),
          _contactRow('County',  info?.county ?? ''),
          _contactRow('State',   info?.state ?? ''),
          _contactRow('Country', info?.country ?? ''),
          _contactRow('Grid',    info?.grid ?? ''),
          _contactRow('Class',   info?.licenseClass ?? ''),
          _contactRow('Email',   info?.email ?? ''),
          if (info?.qslMgr.isNotEmpty == true)
            _contactRow('QSL Mgr', info!.qslMgr),
          if (dxcc != null) _contactRow('DXCC', dxcc),
          const SizedBox(height: 4),
          _contactRow('Notes', '', editable: true, controller: _notesCtl),
        ],
      ),
    );
  }

  Widget _contactRow(String label, String value,
      {bool editable = false, TextEditingController? controller}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 52,
            child: Text(label,
                textAlign: TextAlign.right, style: _labelStyle),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: editable && controller != null
                ? SizedBox(
                    height: 20,
                    child: TextField(
                      controller: controller,
                      style: _inputStyle,
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  )
                : Text(value, style: _valueStyle, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  // ── DX panel (right) ─────────────────────────────────────────────────────

  Widget _buildDxPanel(String timeDisplay, String band, (String, Color)? dupe) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Timing ────────────────────────────────────────────────────
          _dxRow2(
            l1: 'Time On',
            c1: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(timeDisplay,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace')),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => setState(() => _timeOn = DateTime.now().toUtc()),
                  child: Text('!',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: dupe != null ? dupe.$2 : Colors.grey.shade600,
                      )),
                ),
              ],
            ),
            l2: 'Time Off',
            c2: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _formatDateTimeUtc(_timeOff ?? _nowUtc),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: _timeOff != null ? null : Colors.grey.shade600,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  height: 18,
                  child: TextButton(
                    onPressed: () =>
                        setState(() => _timeOff = DateTime.now().toUtc()),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 10),
                    ),
                    child: const Text('Now'),
                  ),
                ),
              ],
            ),
          ),
          // ── Frequency / Mode ──────────────────────────────────────────
          _dxRow2(
            l1: 'MHz',
            c1: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(_formatFreq(_frequencyHz),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace')),
                ),
                const SizedBox(width: 8),
                Text(band.isNotEmpty ? band : '—',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.amber.shade400)),
              ],
            ),
            l2: 'Mode',
            c2: Text(_mode.isNotEmpty ? _mode : '--',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace')),
          ),
          _sectionDivider(),
          // ── Signal ────────────────────────────────────────────────────
          _dxInlineRow([
            _inlineField('RST S', _compactField(_rstSentCtl, width: 44)),
            _inlineField('RST R', _compactField(_rstRcvdCtl, width: 44)),
            _inlineField('Power', _compactField(_powerCtl, width: 42)),
          ]),
          _sectionDivider(),
          // ── Location ──────────────────────────────────────────────────
          _dxRow2(
            l1: 'Grid',    c1: _expandField(_gridCtl,    caps: true, width: 68),
            l2: 'Locator', c2: _expandField(_locatorCtl, caps: true, width: 68),
          ),
          _dxRow2(
            l1: 'CQ Zone', c1: _expandField(_cqCtl,  width: 36),
            l2: 'ITU',     c2: _expandField(_ituCtl, width: 36),
          ),
          _dxRow2(
            l1: 'IOTA',    c1: _expandField(_iotaCtl, caps: true, width: 62),
            l2: 'DXCC',    c2: _expandField(_dxccCtl, width: 110),
          ),
          _sectionDivider(),
          // ── Awards / References ───────────────────────────────────────
          _dxRow2(
            l1: 'SOTA',  c1: _expandField(_sotaCtl, caps: true, width: 90),
            l2: 'POTA',  c2: _expandField(_potaCtl, caps: true, width: 72),
          ),
          if (_potaParkName != null)
            Padding(
              padding: const EdgeInsets.only(top: 1, bottom: 2),
              child: Row(
                children: [
                  const SizedBox(width: 56 + 4 + 90 + 16), // align under POTA column
                  Flexible(
                    child: Text(
                      _potaParkName!,
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.green.shade400,
                        fontStyle: FontStyle.italic,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          _dxRow2(
            l1: 'WWFF',  c1: _expandField(_wwffCtl, caps: true, width: 80),
            l2: 'SKCC',  c2: _expandField(_skccCtl, width: 58),
          ),
          _sectionDivider(),
          // ── Exchange / Info ───────────────────────────────────────────
          _dxRow2(
            l1: 'QSL Via', c1: _expandField(_qslViaCtl, width: 80),
            l2: '10/10',   c2: _expandField(_tentenCtl, width: 52),
          ),
          _dxRow2(
            l1: 'URL',   c1: _expandField(_urlCtl, width: 130),
            l2: 'DX de', c2: _expandField(_dxDeCtl, caps: true, width: 72),
          ),
        ],
      ),
    );
  }

  // ── Contest panel (placeholder) ───────────────────────────────────────────

  Widget _buildContestPanel(String timeDisplay, String band) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _qsoRow([
            _qsoLabel('Time On'),
            Text(timeDisplay,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold,
                    fontFamily: 'monospace')),
          ]),
          _qsoRow([
            _qsoLabel('MHz'),
            Text(_formatFreq(_frequencyHz),
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold,
                    fontFamily: 'monospace')),
            const SizedBox(width: 8),
            Text(band.isNotEmpty ? band : '—',
                style: TextStyle(fontSize: 12, color: Colors.amber.shade400)),
            const SizedBox(width: 16),
            _qsoLabel('Mode'),
            Text(_mode.isNotEmpty ? _mode : '--',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ]),
          _qsoRow([
            _qsoLabel('RSTS'),
            _compactField(_rstSentCtl, width: 52),
            const SizedBox(width: 8),
            _qsoLabel('RSTR'),
            _compactField(_rstRcvdCtl, width: 52),
          ]),
          const SizedBox(height: 8),
          Text('Contest exchange fields coming soon.',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  // ── Row / field helpers ──────────────────────────────────────────────────

  static const _kLabelW = 52.0;

  /// Two-column row: [label | content] pairs side-by-side, content is fixed-size.
  Widget _dxRow2({
    required String l1,
    required Widget c1,
    String? l2,
    Widget? c2,
  }) {
    Widget col(String label, Widget content) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: _kLabelW,
              child: Text(label,
                  textAlign: TextAlign.right, style: _labelStyle),
            ),
            const SizedBox(width: 4),
            Flexible(child: content),
          ],
        );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Wrap(
        spacing: 16,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          col(l1, c1),
          if (l2 != null && c2 != null) col(l2, c2),
        ],
      ),
    );
  }

  /// Inline row — wraps if narrow.
  Widget _dxInlineRow(List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 2,
        children: children,
      ),
    );
  }

  /// A label + field pair for use in [_dxInlineRow].
  Widget _inlineField(String label, Widget field) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label, style: _labelStyle),
        const SizedBox(width: 4),
        field,
      ],
    );
  }

  Widget _sectionDivider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Divider(height: 1, color: Colors.grey.shade800),
      );

  /// Fixed-width field for use inside [_dxRow2].
  Widget _expandField(TextEditingController ctl,
      {bool caps = false, double width = 90}) =>
      _compactField(ctl, width: width, caps: caps);

  // For contest panel rows (still uses old-style Wrap)
  Widget _qsoRow(List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 0,
        runSpacing: 2,
        children: children,
      ),
    );
  }

  Widget _qsoLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Text(text, style: _labelStyle),
    );
  }

  Widget _compactField(
    TextEditingController ctl, {
    double width = 64,
    bool caps = false,
  }) {
    return SizedBox(
      width: width,
      height: 20,
      child: TextField(
        controller: ctl,
        style: _inputStyle,
        textCapitalization:
            caps ? TextCapitalization.characters : TextCapitalization.none,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          border: OutlineInputBorder(),
        ),
      ),
    );
  }

  // ── Contact image / flag ──────────────────────────────────────────────────

  Widget _buildContactImage(CallsignInfo info) {
    final imageUrl = info.imageUrl;
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.network(
            imageUrl,
            height: 100,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _flagWidget(info.country),
          ),
        ),
      );
    }
    return _flagWidget(info.country);
  }

  Widget _flagWidget(String country) {
    final flag = _countryFlag(country);
    if (flag == null) return const SizedBox.shrink();
    return Center(
      child: Text(flag, style: const TextStyle(fontSize: 40)),
    );
  }

  static String? _countryFlag(String country) {
    const iso = {
      'United States': 'US', 'Canada': 'CA', 'Japan': 'JP',
      'Germany': 'DE', 'United Kingdom': 'GB', 'England': 'GB',
      'Scotland': 'GB', 'Wales': 'GB', 'Northern Ireland': 'GB',
      'Australia': 'AU', 'France': 'FR', 'Italy': 'IT',
      'Spain': 'ES', 'Russia': 'RU', 'Brazil': 'BR',
      'Mexico': 'MX', 'China': 'CN', 'South Korea': 'KR',
      'Korea': 'KR', 'India': 'IN', 'Netherlands': 'NL',
      'Belgium': 'BE', 'Switzerland': 'CH', 'Austria': 'AT',
      'Sweden': 'SE', 'Norway': 'NO', 'Finland': 'FI',
      'Denmark': 'DK', 'Poland': 'PL', 'Czech Republic': 'CZ',
      'Hungary': 'HU', 'Romania': 'RO', 'Bulgaria': 'BG',
      'Portugal': 'PT', 'Greece': 'GR', 'Turkey': 'TR',
      'Israel': 'IL', 'Argentina': 'AR', 'Chile': 'CL',
      'Colombia': 'CO', 'Venezuela': 'VE', 'New Zealand': 'NZ',
      'South Africa': 'ZA', 'Indonesia': 'ID', 'Philippines': 'PH',
      'Thailand': 'TH', 'Malaysia': 'MY', 'Singapore': 'SG',
      'Taiwan': 'TW', 'Hong Kong': 'HK', 'Ukraine': 'UA',
      'Croatia': 'HR', 'Slovenia': 'SI', 'Serbia': 'RS',
      'Slovakia': 'SK', 'Lithuania': 'LT', 'Latvia': 'LV',
      'Estonia': 'EE', 'Iceland': 'IS', 'Ireland': 'IE',
      'Luxembourg': 'LU', 'Malta': 'MT', 'Cyprus': 'CY',
      'Belarus': 'BY', 'Moldova': 'MD', 'Georgia': 'GE',
      'Armenia': 'AM', 'Azerbaijan': 'AZ', 'Kazakhstan': 'KZ',
      'Uzbekistan': 'UZ', 'Pakistan': 'PK', 'Bangladesh': 'BD',
      'Sri Lanka': 'LK', 'Nepal': 'NP', 'Vietnam': 'VN',
      'Egypt': 'EG', 'Morocco': 'MA', 'Tunisia': 'TN',
      'Nigeria': 'NG', 'Kenya': 'KE', 'Tanzania': 'TZ',
      'Ghana': 'GH', 'Peru': 'PE', 'Ecuador': 'EC',
      'Bolivia': 'BO', 'Uruguay': 'UY', 'Paraguay': 'PY',
      'Cuba': 'CU', 'Dominican Republic': 'DO', 'Puerto Rico': 'PR',
      'Jamaica': 'JM', 'Panama': 'PA', 'Costa Rica': 'CR',
      'Guatemala': 'GT', 'Honduras': 'HN', 'El Salvador': 'SV',
      'Nicaragua': 'NI', 'Saudi Arabia': 'SA', 'Jordan': 'JO',
      'Iraq': 'IQ', 'Iran': 'IR', 'Kuwait': 'KW',
      'Bahrain': 'BH', 'Qatar': 'QA', 'Oman': 'OM',
      'United Arab Emirates': 'AE', 'Yemen': 'YE', 'Lebanon': 'LB',
      'Syria': 'SY', 'Libya': 'LY', 'Algeria': 'DZ',
      'Senegal': 'SN', 'Cameroon': 'CM', 'Ethiopia': 'ET',
    };
    final code = iso[country];
    if (code == null || code.length != 2) return null;
    final a = String.fromCharCode(code.codeUnitAt(0) - 65 + 0x1F1E6);
    final b = String.fromCharCode(code.codeUnitAt(1) - 65 + 0x1F1E6);
    return '$a$b';
  }
}

// ---------------------------------------------------------------------------
// Tab button widget
// ---------------------------------------------------------------------------

class _TabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TabButton(this.label, {required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? Colors.grey.shade700 : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? Colors.white : Colors.grey.shade500,
          ),
        ),
      ),
    );
  }
}
