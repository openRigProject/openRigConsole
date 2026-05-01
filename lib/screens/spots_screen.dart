import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart';
import '../services/connection_service.dart';
import '../services/settings_service.dart';

const _bandOptions = [
  'All', '160m', '80m', '60m', '40m', '30m',
  '20m', '17m', '15m', '12m', '10m', '6m', '2m',
];
const _modeOptions = ['All', 'CW', 'SSB', 'Digital'];

enum _SortCol { freq, dx, spotter, time }
enum _SpotSource { cluster, pota }

// ---------------------------------------------------------------------------
// POTA spot model
// ---------------------------------------------------------------------------

class _PotaSpot {
  final String activator;
  final double frequencyKhz; // POTA API returns kHz
  final String mode;
  final String reference;  // e.g. K-1234
  final String parkName;
  final String spotter;
  final String comment;
  final DateTime time;
  final double? latitude;
  final double? longitude;

  const _PotaSpot({
    required this.activator,
    required this.frequencyKhz,
    required this.mode,
    required this.reference,
    required this.parkName,
    required this.spotter,
    required this.comment,
    required this.time,
    this.latitude,
    this.longitude,
  });

  factory _PotaSpot.fromJson(Map<String, dynamic> j) {
    return _PotaSpot(
      activator: (j['activator'] as String? ?? '').toUpperCase(),
      frequencyKhz: double.tryParse(j['frequency']?.toString() ?? '') ?? 0,
      mode: j['mode'] as String? ?? '',
      reference: j['reference'] as String? ?? '',
      parkName: j['parkName'] as String? ?? '',
      spotter: (j['spotter'] as String? ?? '').toUpperCase(),
      comment: j['comments'] as String? ?? '',
      time: DateTime.tryParse(j['spotTime'] as String? ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
      latitude: double.tryParse(j['latitude']?.toString() ?? ''),
      longitude: double.tryParse(j['longitude']?.toString() ?? ''),
    );
  }

  double get frequencyMhz => frequencyKhz / 1000;
}

// ---------------------------------------------------------------------------
// Cluster controller — lets external widgets send spots
// ---------------------------------------------------------------------------

class DxClusterController {
  _SpotsScreenState? _state;
  void _attach(_SpotsScreenState s) => _state = s;
  void _detach() => _state = null;

  bool get isConnected => _state?._clusterConnected == true;

  /// Send a spot to the connected cluster.
  /// Format: DX <freqKhz> <callsign> [comment]
  void sendSpot(String callsign, double freqKhz,
      {String mode = '', String comment = ''}) {
    final cluster = _state?._cluster;
    if (cluster == null) return;
    final parts = [
      'DX',
      freqKhz.toStringAsFixed(1),
      callsign.toUpperCase(),
      if (comment.isNotEmpty) comment else if (mode.isNotEmpty) mode,
    ];
    cluster.send(parts.join(' '));
  }
}

// ---------------------------------------------------------------------------

class SpotsScreen extends StatefulWidget {
  final ConnectionService connectionService;
  final SettingsService settings;
  final ValueChanged<List<DxSpot>>? onSpotsChanged;
  final ValueChanged<DxSpot>? onSpotSelected;
  final DxClusterController? controller;
  /// Called when a POTA spot with known park coordinates is selected,
  /// so the map can jump to the park location directly.
  final void Function(double lat, double lon, String label)? onLocationOverride;

  const SpotsScreen({
    super.key,
    required this.connectionService,
    required this.settings,
    this.onSpotsChanged,
    this.onSpotSelected,
    this.controller,
    this.onLocationOverride,
  });

  @override
  State<SpotsScreen> createState() => _SpotsScreenState();
}

class _SpotsScreenState extends State<SpotsScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  DxClusterClient? _cluster;
  StreamSubscription<DxSpot>? _spotSub;
  StreamSubscription<String>? _rawSub;
  List<DxSpot> _spots = [];
  Timer? _expiryTimer;

  late String _clusterHost;
  late int _clusterPort;
  late String _callsign;
  late int _spotMaxAgeMinutes;
  bool _clusterConnected = false;

  // Source selection
  _SpotSource _source = _SpotSource.cluster;

  // Raw terminal
  bool _showRaw = false;
  final List<String> _rawLines = [];
  final _rawScrollCtl = ScrollController();
  final _cmdCtl = TextEditingController();

  // POTA
  List<_PotaSpot> _potaSpots = [];
  Timer? _potaTimer;

  // Filter state
  String _filterBand = 'All';
  String _filterMode = 'All';
  bool _neededOnly = false;
  bool _newBandOnly = false;
  DuplicateChecker _dupeChecker = DuplicateChecker([]);

  void _notifySpots() {
    widget.onSpotsChanged?.call(List.unmodifiable(_spots));
  }

  // Sort state
  _SortCol _sortCol = _SortCol.time;
  bool _sortAsc = false;

  @override
  void initState() {
    super.initState();
    _clusterHost = widget.settings.clusterHost;
    _clusterPort = widget.settings.clusterPort;
    _spotMaxAgeMinutes = widget.settings.clusterSpotMaxAge;
    _callsign = widget.settings.callsign.isNotEmpty
        ? widget.settings.callsign
        : 'N0CALL';
    widget.controller?._attach(this);
    _buildDupeChecker();
    if (widget.settings.clusterAutoConnect) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _connectCluster());
    }
    _expiryTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) {
        setState(() {
          _spots = expireSpots(_spots, Duration(minutes: _spotMaxAgeMinutes));
        });
        _notifySpots();
      }
    });
  }

  Future<void> _buildDupeChecker() async {
    try {
      final file = File(widget.settings.logPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final records = AdifLog.parse(content);
        if (mounted) setState(() => _dupeChecker = DuplicateChecker(records));
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    widget.controller?._detach();
    _expiryTimer?.cancel();
    _potaTimer?.cancel();
    _spotSub?.cancel();
    _rawSub?.cancel();
    _rawScrollCtl.dispose();
    _cmdCtl.dispose();
    _cluster?.disconnect();
    super.dispose();
  }

  Future<void> _selectSource(_SpotSource src) async {
    if (_source == src) return;
    // Only manage POTA timer — cluster connection is independent of source view.
    if (src == _SpotSource.cluster) {
      _potaTimer?.cancel();
      _potaTimer = null;
    }
    setState(() {
      _source = src;
      _showRaw = false;
    });
    if (src == _SpotSource.pota) {
      await _fetchPota();
      _potaTimer ??= Timer.periodic(
        const Duration(minutes: 2), (_) => _fetchPota());
    }
  }

  Future<void> _fetchPota() async {
    try {
      final client = HttpClient();
      final req = await client.getUrl(
          Uri.parse('https://api.pota.app/spot/activator'));
      req.headers.set('Accept', 'application/json');
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();
      final list = jsonDecode(body) as List<dynamic>;
      final spots = list
          .where((s) => (s['invalid'] ?? 0) != 1)
          .map((s) => _PotaSpot.fromJson(s as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.time.compareTo(a.time));
      if (mounted) setState(() => _potaSpots = spots);
    } catch (_) {}
  }

  Future<void> _connectCluster({String? host, int? port}) async {
    await _disconnectCluster();
    final client = DxClusterClient(
      host: host ?? _clusterHost,
      port: port ?? _clusterPort,
      callsign: _callsign,
    );
    try {
      await client.connect();
      _cluster = client;
      _spotSub = client.spots.listen((spot) {
        if (mounted) {
          setState(() => _spots = mergeSpot(_spots, spot));
          _notifySpots();
        }
      });
      _rawSub = client.rawLines.listen((line) {
        if (!mounted) return;
        setState(() => _rawLines.add(line));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_rawScrollCtl.hasClients) {
            _rawScrollCtl.jumpTo(_rawScrollCtl.position.maxScrollExtent);
          }
        });
      });
      setState(() => _clusterConnected = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cluster connection failed: $e')),
        );
      }
    }
  }

  Future<void> _disconnectCluster() async {
    await _spotSub?.cancel();
    _spotSub = null;
    await _rawSub?.cancel();
    _rawSub = null;
    await _cluster?.disconnect();
    _cluster = null;
    if (mounted) setState(() => _clusterConnected = false);
  }

  void _sendCommand() {
    final cmd = _cmdCtl.text.trim();
    if (cmd.isEmpty || _cluster == null) return;
    _cluster!.send(cmd);
    setState(() => _rawLines.add('> $cmd'));
    _cmdCtl.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_rawScrollCtl.hasClients) {
        _rawScrollCtl.jumpTo(_rawScrollCtl.position.maxScrollExtent);
      }
    });
  }

  void _showSettings() {
    final hostCtl = TextEditingController(text: _clusterHost);
    final portCtl = TextEditingController(text: _clusterPort.toString());
    final callCtl = TextEditingController(text: _callsign);
    final maxAgeCtl = TextEditingController(text: _spotMaxAgeMinutes.toString());
    bool autoConnect = widget.settings.clusterAutoConnect;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('DX Cluster Settings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: hostCtl,
                decoration: const InputDecoration(labelText: 'Host'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: portCtl,
                decoration: const InputDecoration(labelText: 'Port'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: callCtl,
                decoration: const InputDecoration(labelText: 'Callsign'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: maxAgeCtl,
                decoration: const InputDecoration(
                  labelText: 'Spot max age (minutes)',
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-connect on startup',
                    style: TextStyle(fontSize: 13)),
                value: autoConnect,
                onChanged: (v) => setDlgState(() => autoConnect = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final host = hostCtl.text.trim();
                final port = int.tryParse(portCtl.text.trim()) ?? 23;
                final call = callCtl.text.trim().toUpperCase();
                final maxAge = (int.tryParse(maxAgeCtl.text.trim()) ?? 30)
                    .clamp(1, 1440);
                setState(() {
                  _clusterHost = host;
                  _clusterPort = port;
                  _callsign = call;
                  _spotMaxAgeMinutes = maxAge;
                });
                widget.settings.setClusterNode(host, port);
                widget.settings.setCallsign(call);
                widget.settings.setClusterAutoConnect(autoConnect);
                widget.settings.setClusterSpotMaxAge(maxAge);
                Navigator.of(ctx).pop();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _tuneToSpot(DxSpot spot) {
    widget.onSpotSelected?.call(spot);
    if (widget.onSpotSelected == null) {
      final client = widget.connectionService.client;
      if (client == null || !client.isConnected) return;
      client.setFrequency((spot.frequencyKhz * 1000).round());
    }
  }

  void _tuneToPotatSpot(_PotaSpot spot) {
    final synthetic = DxSpot(
      spotter: spot.spotter,
      dxCall: spot.activator,
      frequencyKhz: spot.frequencyKhz,
      comment: spot.mode,
      time: spot.time,
      source: 'pota',
      parkRef: spot.reference.isNotEmpty ? spot.reference : null,
    );
    widget.onSpotSelected?.call(synthetic);
    if (widget.onSpotSelected == null) {
      final client = widget.connectionService.client;
      if (client == null || !client.isConnected) return;
      client.setFrequency((spot.frequencyKhz * 1000).round());
    }
    // Move map to park location if available, bypassing QRZ lookup.
    if (spot.latitude != null && spot.longitude != null) {
      final label = spot.reference.isNotEmpty ? spot.reference : spot.activator;
      widget.onLocationOverride?.call(spot.latitude!, spot.longitude!, label);
    }
  }

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Returns the mode for a spot: explicit from comment if recognizable,
  /// otherwise inferred from the frequency sub-band.
  String _spotMode(DxSpot spot) {
    final upper = spot.comment.toUpperCase();
    for (final m in [
      'FT8', 'FT4', 'JS8', 'PSK31', 'PSK63', 'RTTY', 'WSPR',
      'CW', 'SSB', 'USB', 'LSB', 'AM', 'FM', 'DIGI',
    ]) {
      if (upper.contains(m)) return m;
    }
    final band = bandFromKhz(spot.frequencyKhz);
    return band?.subBandFromMhz(spot.frequencyKhz / 1000.0)?.name ?? '';
  }

  static String _sourceLabel(_SpotSource s) => switch (s) {
        _SpotSource.cluster => 'DX Cluster',
        _SpotSource.pota    => 'POTA Spots',
      };

  Widget _buildPotaTable() {
    if (_potaSpots.isEmpty) {
      return Center(
        child: Text('No POTA spots — tap refresh to load.',
            style: TextStyle(color: Colors.grey.shade500)),
      );
    }
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: SizedBox(
          width: double.infinity,
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(Colors.grey.shade900),
            columns: const [
              DataColumn(label: Text('Freq (MHz)')),
              DataColumn(label: Text('Activator')),
              DataColumn(label: Text('Park Ref')),
              DataColumn(label: Text('Park Name')),
              DataColumn(label: Text('Mode')),
              DataColumn(label: Text('Spotter')),
              DataColumn(label: Text('Time')),
            ],
            rows: _potaSpots.map((s) {
              return DataRow(
                onSelectChanged: (_) => _tuneToPotatSpot(s),
                cells: [
                  DataCell(Text(s.frequencyMhz.toStringAsFixed(3),
                      style: const TextStyle(fontFamily: 'monospace'))),
                  DataCell(Text(s.activator,
                      style: const TextStyle(fontWeight: FontWeight.bold))),
                  DataCell(Text(s.reference,
                      style: TextStyle(color: Colors.green.shade400))),
                  DataCell(Text(s.parkName,
                      overflow: TextOverflow.ellipsis)),
                  DataCell(Text(s.mode)),
                  DataCell(Text(s.spotter)),
                  DataCell(Text(_formatTime(s.time),
                      style: const TextStyle(fontFamily: 'monospace'))),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  bool get _filtersActive =>
      _filterBand != 'All' ||
      _filterMode != 'All' ||
      _neededOnly ||
      _newBandOnly;

  List<DxSpot> get _filteredSorted {
    final filter = ClusterFilter(
      bands: _filterBand != 'All' ? [_filterBand] : [],
      modes: _filterMode != 'All' ? [_filterMode] : [],
      neededOnly: _neededOnly,
      newBandOnly: _newBandOnly,
      dupeChecker: _dupeChecker,
    );
    var list = _spots.where(filter.passes).toList();

    int Function(DxSpot, DxSpot) cmp;
    switch (_sortCol) {
      case _SortCol.freq:
        cmp = (a, b) => a.frequencyKhz.compareTo(b.frequencyKhz);
      case _SortCol.dx:
        cmp = (a, b) => a.dxCall.compareTo(b.dxCall);
      case _SortCol.spotter:
        cmp = (a, b) => a.spotter.compareTo(b.spotter);
      case _SortCol.time:
        cmp = (a, b) => a.time.compareTo(b.time);
    }
    list.sort(_sortAsc ? cmp : (a, b) => cmp(b, a));
    return list;
  }

  void _onSort(_SortCol col) {
    setState(() {
      if (_sortCol == col) {
        _sortAsc = !_sortAsc;
      } else {
        _sortCol = col;
        _sortAsc = col == _SortCol.dx || col == _SortCol.spotter;
      }
    });
  }

  Widget _sortableHeader(String label, _SortCol col) {
    final active = _sortCol == col;
    return InkWell(
      onTap: () => _onSort(col),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          if (active)
            Icon(
              _sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
              size: 14,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final filtered = _filteredSorted;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title bar
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
          child: Row(
            children: [
              Text(
                _source == _SpotSource.pota ? 'POTA Spots' : 'DX Cluster Spots',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(width: 12),
              if (_clusterConnected)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.shade900,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text('Connected',
                      style: TextStyle(
                          color: Colors.green.shade300, fontSize: 12)),
                ),
              const SizedBox(width: 12),
              // Source selector chips
              for (final src in _SpotSource.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(_sourceLabel(src),
                        style: const TextStyle(fontSize: 12)),
                    selected: _source == src,
                    showCheckmark: false,
                    onSelected: (_) => _selectSource(src),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              const Spacer(),
              if (_source == _SpotSource.cluster) ...[
                IconButton(
                  icon: Icon(_showRaw ? Icons.view_list : Icons.terminal),
                  tooltip: _showRaw ? 'Show spots' : 'Show raw stream',
                  onPressed: () => setState(() => _showRaw = !_showRaw),
                ),
                IconButton(
                  icon: const Icon(Icons.settings),
                  tooltip: 'Cluster settings',
                  onPressed: _showSettings,
                ),
                const SizedBox(width: 8),
                _clusterConnected
                    ? OutlinedButton(
                        onPressed: _disconnectCluster,
                        child: const Text('Disconnect'),
                      )
                    : FilledButton(
                        onPressed: () => _connectCluster(),
                        child: const Text('Connect'),
                      ),
              ],
              if (_source == _SpotSource.pota)
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh POTA spots',
                  onPressed: _fetchPota,
                ),
            ],
          ),
        ),

        // ── Raw terminal view ─────────────────────────────────────────────
        if (_showRaw) ...[
          Expanded(
            child: Container(
              color: Colors.black,
              child: _rawLines.isEmpty
                  ? Center(
                      child: Text(
                        _clusterConnected
                            ? 'Waiting for data...'
                            : 'Connect to a cluster to see the raw stream.',
                        style: TextStyle(
                            color: Colors.grey.shade600,
                            fontFamily: 'monospace'),
                      ),
                    )
                  : ListView.builder(
                      controller: _rawScrollCtl,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      itemCount: _rawLines.length,
                      itemBuilder: (_, i) {
                        final line = _rawLines[i];
                        final isCmd = line.startsWith('> ');
                        return Text(
                          line,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: isCmd
                                ? Colors.green.shade400
                                : Colors.grey.shade300,
                          ),
                        );
                      },
                    ),
            ),
          ),
          // Command input
          Container(
            color: Colors.grey.shade900,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Text('> ',
                    style: TextStyle(
                        fontFamily: 'monospace',
                        color: Colors.green.shade400,
                        fontSize: 13)),
                Expanded(
                  child: TextField(
                    controller: _cmdCtl,
                    enabled: _clusterConnected,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: 'sh/dx 20',
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendCommand(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, size: 18),
                  onPressed: _clusterConnected ? _sendCommand : null,
                  tooltip: 'Send',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ],

        // ── Spots table view ──────────────────────────────────────────────
        if (!_showRaw) ...[

        // Filter toolbar
        if (_spots.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Row(
              children: [
                // Band filter
                SizedBox(
                  width: 120,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Band',
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _filterBand,
                        isDense: true,
                        items: _bandOptions
                            .map((b) =>
                                DropdownMenuItem(value: b, child: Text(b)))
                            .toList(),
                        onChanged: (v) => setState(() => _filterBand = v!),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Mode filter
                SizedBox(
                  width: 120,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Mode',
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _filterMode,
                        isDense: true,
                        items: _modeOptions
                            .map((m) =>
                                DropdownMenuItem(value: m, child: Text(m)))
                            .toList(),
                        onChanged: (v) => setState(() => _filterMode = v!),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilterChip(
                  label: const Text('Needed'),
                  selected: _neededOnly,
                  onSelected: (v) => setState(() {
                    _neededOnly = v;
                    if (v) _newBandOnly = false;
                  }),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('New Band'),
                  selected: _newBandOnly,
                  onSelected: (v) => setState(() {
                    _newBandOnly = v;
                    if (v) _neededOnly = false;
                  }),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 16),
                Text(
                  '${filtered.length} of ${_spots.length} spots',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
                if (_filtersActive) ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => setState(() {
                      _filterBand = 'All';
                      _filterMode = 'All';
                      _neededOnly = false;
                      _newBandOnly = false;
                    }),
                    icon: const Icon(Icons.clear, size: 16),
                    label: const Text('Clear'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ],
              ],
            ),
          ),

        // ── POTA table ────────────────────────────────────────────────
        if (_source == _SpotSource.pota)
          Expanded(child: _buildPotaTable()),

        // ── DX cluster table (Cluster + DXSummit) ─────────────────────
        if (_source != _SpotSource.pota)
          Expanded(
            child: _spots.isEmpty
                ? Center(
                    child: Text(
                      _clusterConnected
                          ? 'Waiting for spots...'
                          : 'Connect to a DX Cluster to see spots.',
                      style: TextStyle(color: Colors.grey.shade500),
                    ),
                  )
                : SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: SizedBox(
                        width: double.infinity,
                        child: DataTable(
                          headingRowColor:
                              WidgetStatePropertyAll(Colors.grey.shade900),
                          columns: [
                            DataColumn(label: _sortableHeader('Freq (kHz)', _SortCol.freq)),
                            DataColumn(label: _sortableHeader('DX Call', _SortCol.dx)),
                            const DataColumn(label: Text('Mode')),
                            DataColumn(label: _sortableHeader('Spotter', _SortCol.spotter)),
                            const DataColumn(label: Text('Comment')),
                            DataColumn(label: _sortableHeader('Time', _SortCol.time)),
                          ],
                          rows: filtered.isEmpty
                              ? [
                                  DataRow(cells: [
                                    DataCell(Text('No spots match filters',
                                        style: TextStyle(
                                            color: Colors.grey.shade500,
                                            fontStyle: FontStyle.italic))),
                                    const DataCell(SizedBox.shrink()),
                                    const DataCell(SizedBox.shrink()),
                                    const DataCell(SizedBox.shrink()),
                                    const DataCell(SizedBox.shrink()),
                                    const DataCell(SizedBox.shrink()),
                                  ]),
                                ]
                              : filtered.map((s) {
                                  return DataRow(
                                    onSelectChanged: (_) => _tuneToSpot(s),
                                    cells: [
                                      DataCell(Text(
                                        s.frequencyKhz.toStringAsFixed(1),
                                        style: const TextStyle(fontFamily: 'monospace'),
                                      )),
                                      DataCell(Text(s.dxCall,
                                          style: const TextStyle(fontWeight: FontWeight.bold))),
                                      DataCell(Text(_spotMode(s),
                                          style: const TextStyle(fontSize: 12))),
                                      DataCell(Text(s.spotter)),
                                      DataCell(Text(s.comment)),
                                      DataCell(Text(
                                        _formatTime(s.time),
                                        style: const TextStyle(fontFamily: 'monospace'),
                                      )),
                                    ],
                                  );
                                }).toList(),
                        ),
                      ),
                    ),
                  ),
          ),

        ], // end if (!_showRaw)
      ],
    );
  }
}
