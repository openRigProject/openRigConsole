import 'dart:async';

import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart' hide ChangeNotifier;
import '../services/connection_service.dart';
import '../services/settings_service.dart';
import '../widgets/rig_settings_dialog.dart';

class DevicesScreen extends StatefulWidget {
  final ConnectionService connectionService;
  final SettingsService settings;

  const DevicesScreen({
    super.key,
    required this.connectionService,
    required this.settings,
  });

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  OpenRigDevice? _selectedDevice;
  StreamSubscription<OpenRigDevice>? _foundSub;
  StreamSubscription<String>? _lostSub;

  ConnectionService get _cs => widget.connectionService;

  @override
  void initState() {
    super.initState();
    _cs.addListener(_onServiceChanged);
    if (_cs.mdnsAvailable) {
      _foundSub = _cs.discovery.onDeviceFound.listen((_) {
        if (mounted) setState(() {});
      });
      _lostSub = _cs.discovery.onDeviceLost.listen((host) {
        if (mounted) {
          if (_selectedDevice?.host == host) _selectedDevice = null;
          setState(() {});
        }
      });
    }
  }

  @override
  void dispose() {
    _foundSub?.cancel();
    _lostSub?.cancel();
    _cs.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _addRig(OpenRigDevice device) async {
    try {
      final label = device.callsign.isNotEmpty
          ? '${device.callsign} (${device.type})'
          : device.name;
      await _cs.addRemoteRig(
        device.host,
        device.rigctldPort ?? 4532,
        label: label,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added ${device.host}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_cs.mdnsAvailable) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off, size: 48, color: Colors.grey.shade600),
            const SizedBox(height: 16),
            Text('Device discovery unavailable',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'mDNS multicast is not available on this system.\n'
              'Use the connection dialog to connect manually.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }

    final devices = _cs.discovery.devices.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    return Row(
      children: [
        // Device list — left
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                child: Row(
                  children: [
                    Text('Devices',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(width: 12),
                    Text(
                      '${devices.length} found',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: devices.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.search,
                                size: 48, color: Colors.grey.shade600),
                            const SizedBox(height: 12),
                            Text('Scanning for devices...',
                                style:
                                    TextStyle(color: Colors.grey.shade500)),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                        itemCount: devices.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final d = devices[i];
                          final isSelected =
                              _selectedDevice?.host == d.host;
                          return _DeviceCard(
                            device: d,
                            isSelected: isSelected,
                            onSelect: () =>
                                setState(() => _selectedDevice = d),
                            onAddRig:
                                d.hasRigctld ? () => _addRig(d) : null,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        const VerticalDivider(thickness: 1, width: 1),
        // Detail panel — right
        Expanded(
          flex: 4,
          child: _selectedDevice == null
              ? Center(
                  child: Text('Select a device to view details',
                      style: TextStyle(color: Colors.grey.shade500)),
                )
              : _DeviceDetailPanel(
                  key: ValueKey(_selectedDevice!.host),
                  device: _selectedDevice!,
                  connectionService: _cs,
                  settings: widget.settings,
                  onAddRig: _selectedDevice!.hasRigctld
                      ? () => _addRig(_selectedDevice!)
                      : null,
                ),
        ),
      ],
    );
  }
}

// -- Device card (left panel) --

class _DeviceCard extends StatelessWidget {
  final OpenRigDevice device;
  final bool isSelected;
  final VoidCallback onSelect;
  final VoidCallback? onAddRig;

  const _DeviceCard({
    required this.device,
    required this.isSelected,
    required this.onSelect,
    this.onAddRig,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: isSelected ? 4 : 1,
      color: isSelected
          ? Colors.green.withAlpha(25)
          : Theme.of(context).cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isSelected ? Colors.green.shade700 : Colors.transparent,
        ),
      ),
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      device.callsign.isNotEmpty
                          ? device.callsign
                          : device.name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                  _TypeBadge(device.type),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                device.host,
                style: TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    color: Colors.grey.shade400),
              ),
              if (device.version.isNotEmpty)
                Text('v${device.version}',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade600)),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (device.hasRigctld) ...[
                    Icon(Icons.radio,
                        size: 14, color: Colors.green.shade400),
                    const SizedBox(width: 4),
                    Text('rigctld :${device.rigctldPort ?? 4532}',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.green.shade400)),
                  ],
                  const Spacer(),
                  if (onAddRig != null)
                    SizedBox(
                      height: 28,
                      child: FilledButton.tonal(
                        onPressed: onAddRig,
                        style: FilledButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                        child: const Text('Add Rig'),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  final String type;
  const _TypeBadge(this.type);

  Color get _color => switch (type) {
        'hotspot' => Colors.orange,
        'rigctl' => Colors.blue,
        'console' => Colors.purple,
        _ => Colors.grey,
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _color.withAlpha(40),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _color.withAlpha(120)),
      ),
      child: Text(type, style: TextStyle(fontSize: 11, color: _color)),
    );
  }
}

// -- Detail panel (right) --

class _DeviceDetailPanel extends StatefulWidget {
  final OpenRigDevice device;
  final ConnectionService connectionService;
  final SettingsService settings;
  final VoidCallback? onAddRig;

  const _DeviceDetailPanel({
    super.key,
    required this.device,
    required this.connectionService,
    required this.settings,
    this.onAddRig,
  });

  @override
  State<_DeviceDetailPanel> createState() => _DeviceDetailPanelState();
}

class _DeviceDetailPanelState extends State<_DeviceDetailPanel> {
  OpenRigApiClient? _api;
  DeviceStatus? _status;
  HotspotConfig? _hotspot;
  NetworkStatus? _network;
  List<WifiNetwork>? _wifiNetworks;
  List<HotspotClient>? _clients;
  bool _loading = true;
  String? _error;

  // Hotspot edit controllers
  final _rfFreqCtl = TextEditingController();
  final _dmrIdCtl = TextEditingController();
  final _dmrServerCtl = TextEditingController();
  final _dmrPasswordCtl = TextEditingController();
  final _colorcodeCtl = TextEditingController();
  final _ysfReflectorCtl = TextEditingController();
  final _ysfDescCtl = TextEditingController();
  bool _dmrEnabled = false;
  bool _ysfEnabled = false;
  bool _ysf2dmrEnabled = false;
  bool _dmr2ysfEnabled = false;
  List<Talkgroup> _talkgroups = [];
  bool _hotspotDirty = false;
  bool _wifiDirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadDevice();
  }

  @override
  void dispose() {
    _api?.dispose();
    _rfFreqCtl.dispose();
    _dmrIdCtl.dispose();
    _dmrServerCtl.dispose();
    _dmrPasswordCtl.dispose();
    _colorcodeCtl.dispose();
    _ysfReflectorCtl.dispose();
    _ysfDescCtl.dispose();
    super.dispose();
  }

  Future<void> _loadDevice() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    _api?.dispose();
    final api = OpenRigApiClient(host: widget.device.host);
    _api = api;

    try {
      final status = await api.getStatus();
      NetworkStatus? network;
      try {
        network = await api.getNetworkStatus();
      } catch (_) {
        // Device may not support this endpoint yet.
      }
      List<WifiNetwork>? wifiNetworks;
      try {
        wifiNetworks = await api.getWifi();
      } catch (_) {
        // Device may not support this endpoint yet.
      }
      HotspotConfig? hotspot;
      List<HotspotClient>? clients;
      if (status.type == 'hotspot') {
        hotspot = await api.getHotspot();
        clients = await api.getClients();
      }
      if (!mounted) return;
      setState(() {
        _status = status;
        _network = network;
        _wifiNetworks = wifiNetworks;
        _wifiDirty = false;
        _hotspot = hotspot;
        _clients = clients;
        _loading = false;
        if (hotspot != null) _populateHotspotFields(hotspot);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _populateHotspotFields(HotspotConfig h) {
    _rfFreqCtl.text =
        h.rfFrequencyMhz > 0 ? h.rfFrequencyMhz.toStringAsFixed(4) : '';
    _dmrEnabled = h.dmr.enabled;
    _dmrIdCtl.text = h.dmr.dmrId > 0 ? h.dmr.dmrId.toString() : '';
    _dmrServerCtl.text = h.dmr.masterServer;
    _dmrPasswordCtl.text = h.dmr.password;
    _colorcodeCtl.text = h.dmr.colorcode.toString();
    _talkgroups = List.of(h.dmr.talkgroups);
    _ysfEnabled = h.ysf.enabled;
    _ysfReflectorCtl.text = h.ysf.reflector;
    _ysfDescCtl.text = h.ysf.description;
    _ysf2dmrEnabled = h.ysf2dmr.enabled;
    _dmr2ysfEnabled = h.dmr2ysf.enabled;
    _hotspotDirty = false;
  }

  Future<void> _saveHotspot() async {
    if (_api == null) return;
    setState(() => _saving = true);
    try {
      final config = HotspotConfig(
        rfFrequencyMhz:
            double.tryParse(_rfFreqCtl.text.trim()) ?? (_hotspot?.rfFrequencyMhz ?? 0.0),
        dmr: DmrConfig(
          enabled: _dmrEnabled,
          colorcode: int.tryParse(_colorcodeCtl.text.trim()) ?? 1,
          masterServer: _dmrServerCtl.text.trim(),
          password: _dmrPasswordCtl.text.trim(),
          talkgroups: _talkgroups,
          dmrId: int.tryParse(_dmrIdCtl.text.trim()) ?? (_hotspot?.dmr.dmrId ?? 0),
        ),
        ysf: YsfConfig(
          enabled: _ysfEnabled,
          reflector: _ysfReflectorCtl.text.trim(),
          description: _ysfDescCtl.text.trim(),
        ),
        ysf2dmr: CrossModeConfig(enabled: _ysf2dmrEnabled),
        dmr2ysf: CrossModeConfig(enabled: _dmr2ysfEnabled),
      );
      await _api!.updateHotspot(config);
      if (mounted) {
        setState(() {
          _hotspotDirty = false;
          _saving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Hotspot config saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    }
  }

  Future<void> _saveWifi() async {
    if (_api == null || _wifiNetworks == null) return;
    try {
      await _api!.updateWifi(_wifiNetworks!);
      if (mounted) {
        setState(() => _wifiDirty = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('WiFi config saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    }
  }

  void _showAddWifiDialog() {
    final ssidCtl = TextEditingController();
    final passwordCtl = TextEditingController();
    final priorityCtl = TextEditingController(text: '10');
    List<ScannedNetwork> scanned = [];
    bool scanning = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> scan() async {
            if (_api == null) return;
            setDialogState(() => scanning = true);
            try {
              final results = await _api!.scanWifi();
              setDialogState(() {
                scanned = results;
                scanning = false;
              });
            } catch (_) {
              setDialogState(() => scanning = false);
            }
          }

          return AlertDialog(
            title: const Text('Add WiFi Network'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('Available networks',
                          style: TextStyle(fontSize: 12)),
                      const Spacer(),
                      if (scanning)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        TextButton.icon(
                          onPressed: scan,
                          icon: const Icon(Icons.refresh, size: 14),
                          label: const Text('Scan',
                              style: TextStyle(fontSize: 12)),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                    ],
                  ),
                  if (scanned.isNotEmpty) ...[
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: scanned
                          .map((n) => ActionChip(
                                label: Text('${n.ssid} (${n.signal}%)',
                                    style: const TextStyle(fontSize: 11)),
                                onPressed: () => ssidCtl.text = n.ssid,
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 8),
                  ],
                  TextField(
                    controller: ssidCtl,
                    decoration: const InputDecoration(
                        labelText: 'SSID', isDense: true),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: passwordCtl,
                    decoration: const InputDecoration(
                        labelText: 'Password', isDense: true),
                    obscureText: true,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: priorityCtl,
                    decoration: const InputDecoration(
                        labelText: 'Priority', isDense: true),
                    keyboardType: TextInputType.number,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final ssid = ssidCtl.text.trim();
                  if (ssid.isEmpty) return;
                  setState(() {
                    _wifiNetworks!.add(WifiNetwork(
                      ssid: ssid,
                      security:
                          passwordCtl.text.isEmpty ? 'OPEN' : 'WPA2',
                      priority:
                          int.tryParse(priorityCtl.text.trim()) ?? 10,
                      password: passwordCtl.text.isEmpty
                          ? null
                          : passwordCtl.text,
                    ));
                    _wifiDirty = true;
                  });
                  Navigator.of(ctx).pop();
                },
                child: const Text('Add'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _reboot() async {
    if (_api == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reboot Device?'),
        content:
            Text('${widget.device.name} will be unreachable for a moment.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reboot'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _api!.reboot();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rebooting…')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reboot failed: $e')),
        );
      }
    }
  }

  Future<void> _refreshClients() async {
    if (_api == null) return;
    try {
      final clients = await _api!.getClients();
      if (mounted) setState(() => _clients = clients);
    } catch (_) {}
  }

  Future<void> _restartService(String name) async {
    if (_api == null) return;
    try {
      await _api!.restartService(name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restarted $name')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restart failed: $e')),
        );
      }
    }
  }

  void _showAddTalkgroup() {
    final idCtl = TextEditingController();
    final slotCtl = TextEditingController(text: '1');
    final nameCtl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Talkgroup'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: idCtl,
                decoration:
                    const InputDecoration(labelText: 'TG ID', isDense: true),
                keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            TextField(
                controller: slotCtl,
                decoration:
                    const InputDecoration(labelText: 'Slot', isDense: true),
                keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            TextField(
                controller: nameCtl,
                decoration:
                    const InputDecoration(labelText: 'Name', isDense: true)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final id = int.tryParse(idCtl.text.trim());
              final slot = int.tryParse(slotCtl.text.trim()) ?? 1;
              if (id == null) return;
              setState(() {
                _talkgroups.add(Talkgroup(
                    id: id, slot: slot, name: nameCtl.text.trim()));
                _hotspotDirty = true;
              });
              Navigator.of(ctx).pop();
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _openRigSettings() {
    final device = widget.device;
    final rigs = widget.connectionService.rigManager.rigs;
    // Find a rig entry matching this device, or create a temporary one
    RigEntry? entry;
    for (final r in rigs) {
      if (r.host == device.host) {
        entry = r;
        break;
      }
    }
    if (entry == null) return;
    showDialog<bool>(
      context: context,
      builder: (_) => RigSettingsDialog(
        rig: entry!,
        connectionService: widget.connectionService,
        settings: widget.settings,
      ),
    );
  }

  String _formatUptime(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: Colors.red.shade300),
              const SizedBox(height: 12),
              Text('Failed to load device',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(
                      color: Colors.grey.shade500, fontSize: 13),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadDevice,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final status = _status!;
    final isHotspot = status.type == 'hotspot';
    final isRigType =
        status.type == 'rigctl' || status.type == 'console';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Expanded(
                child: Text(
                  status.callsign.isNotEmpty
                      ? status.callsign
                      : status.hostname,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              _TypeBadge(status.type),
            ],
          ),
          const SizedBox(height: 16),

          // 1. Status card
          _SectionCard(
            title: 'Status',
            icon: Icons.info_outline,
            children: [
              _InfoRow('Type', status.type),
              _InfoRow('Callsign', status.callsign),
              _InfoRow('Hostname', status.hostname),
              _InfoRow('Version', status.version),
              _InfoRow('Uptime', _formatUptime(status.uptime)),
              if (status.cpuPercent > 0 || status.memTotalMb > 0 || status.diskTotalGb > 0) ...[
                const SizedBox(height: 4),
                _MetricRow('CPU', status.cpuPercent / 100, '${status.cpuPercent.toStringAsFixed(1)}%'),
                if (status.memTotalMb > 0)
                  _MetricRow(
                    'Memory',
                    status.memUsedMb / status.memTotalMb,
                    '${status.memUsedMb} / ${status.memTotalMb} MB',
                  ),
                if (status.diskTotalGb > 0)
                  _InfoRow('Disk', '${status.diskUsedGb.toStringAsFixed(1)} / ${status.diskTotalGb.toStringAsFixed(1)} GB'),
              ],
            ],
          ),
          const SizedBox(height: 16),

          // 2. Network card
          if (_network != null) ...[
            _SectionCard(
              title: 'Network',
              icon: Icons.wifi,
              children: [
                _InfoRow('Mode', _network!.mode),
                if (_network!.ssid.isNotEmpty) _InfoRow('SSID', _network!.ssid),
                if (_network!.ip.isNotEmpty) _InfoRow('IP', _network!.ip),
                if (_network!.networkInterface.isNotEmpty)
                  _InfoRow('Interface', _network!.networkInterface),
                if (_network!.mode == 'wifi' && _network!.signalDbm != 0)
                  _InfoRow('Signal', '${_network!.signalDbm} dBm'),
                _InfoRow('Connected', _network!.connected ? 'Yes' : 'No'),
              ],
            ),
            const SizedBox(height: 16),
          ],

          // 3. WiFi config card
          if (_wifiNetworks != null) ...[
            _SectionCard(
              title: 'WiFi Networks',
              icon: Icons.wifi,
              trailing: _wifiDirty
                  ? FilledButton(
                      onPressed: _saveWifi,
                      child: const Text('Save'),
                    )
                  : null,
              children: [
                if (_wifiNetworks!.isEmpty)
                  Text('No networks configured.',
                      style: TextStyle(color: Colors.grey.shade500)),
                ..._wifiNetworks!.map((net) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.wifi, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(net.ssid,
                                style: const TextStyle(
                                    fontSize: 13, fontFamily: 'monospace')),
                          ),
                          Text('Priority ${net.priority}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade500)),
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: () => setState(() {
                              _wifiNetworks!.remove(net);
                              _wifiDirty = true;
                            }),
                            icon: const Icon(Icons.close, size: 14),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            tooltip: 'Remove network',
                          ),
                        ],
                      ),
                    )),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _showAddWifiDialog,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add Network'),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          // 4. Hotspot card (only for hotspot devices)
          if (isHotspot && _hotspot != null) ...[
            _SectionCard(
              title: 'Hotspot Configuration',
              icon: Icons.cell_tower,
              trailing: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child:
                          CircularProgressIndicator(strokeWidth: 2))
                  : FilledButton(
                      onPressed: _hotspotDirty ? _saveHotspot : null,
                      child: const Text('Save'),
                    ),
              children: [
                // RF Frequency
                TextField(
                  controller: _rfFreqCtl,
                  decoration: const InputDecoration(
                    labelText: 'RF Frequency (MHz)',
                    hintText: '438.8000',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontFamily: 'monospace'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() => _hotspotDirty = true),
                ),
                const SizedBox(height: 12),
                // Mode chips
                Wrap(
                  spacing: 8,
                  children: [
                    FilterChip(
                      label: const Text('DMR'),
                      selected: _dmrEnabled,
                      onSelected: (v) => setState(() {
                        _dmrEnabled = v;
                        if (!v) _dmr2ysfEnabled = false;
                        _hotspotDirty = true;
                      }),
                    ),
                    FilterChip(
                      label: const Text('YSF'),
                      selected: _ysfEnabled,
                      onSelected: (v) => setState(() {
                        _ysfEnabled = v;
                        if (!v) _ysf2dmrEnabled = false;
                        _hotspotDirty = true;
                      }),
                    ),
                    if (_ysfEnabled)
                      FilterChip(
                        label: const Text('YSF\u2192DMR'),
                        selected: _ysf2dmrEnabled,
                        onSelected: (v) => setState(() {
                          _ysf2dmrEnabled = v;
                          _hotspotDirty = true;
                        }),
                      ),
                    if (_dmrEnabled)
                      FilterChip(
                        label: const Text('DMR\u2192YSF'),
                        selected: _dmr2ysfEnabled,
                        onSelected: (v) => setState(() {
                          _dmr2ysfEnabled = v;
                          _hotspotDirty = true;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),

                // DMR section
                if (_dmrEnabled) ...[
                  Text('DMR',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.grey.shade300)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _dmrServerCtl,
                          decoration: const InputDecoration(
                              labelText: 'BrandMeister Server',
                              isDense: true,
                              border: OutlineInputBorder()),
                          style: const TextStyle(fontSize: 13),
                          onChanged: (_) =>
                              setState(() => _hotspotDirty = true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _colorcodeCtl,
                          decoration: const InputDecoration(
                              labelText: 'Color Code',
                              isDense: true,
                              border: OutlineInputBorder()),
                          style: const TextStyle(fontSize: 13),
                          keyboardType: TextInputType.number,
                          onChanged: (_) =>
                              setState(() => _hotspotDirty = true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _dmrPasswordCtl,
                    decoration: const InputDecoration(
                        labelText: 'Password',
                        isDense: true,
                        border: OutlineInputBorder()),
                    style: const TextStyle(fontSize: 13),
                    obscureText: true,
                    onChanged: (_) =>
                        setState(() => _hotspotDirty = true),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _dmrIdCtl,
                    decoration: const InputDecoration(
                        labelText: 'DMR ID',
                        isDense: true,
                        border: OutlineInputBorder(),
                        hintText: '1000000–9999999'),
                    style: const TextStyle(fontSize: 13),
                    keyboardType: TextInputType.number,
                    onChanged: (_) =>
                        setState(() => _hotspotDirty = true),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text('Talkgroups',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade400)),
                      const Spacer(),
                      IconButton(
                        onPressed: _showAddTalkgroup,
                        icon: const Icon(Icons.add, size: 18),
                        tooltip: 'Add talkgroup',
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: _talkgroups.map((tg) {
                      return Chip(
                        label: Text(
                            '${tg.name.isNotEmpty ? tg.name : 'TG'}:${tg.id} (S${tg.slot})',
                            style: const TextStyle(fontSize: 11)),
                        deleteIcon: const Icon(Icons.close, size: 14),
                        onDeleted: () => setState(() {
                          _talkgroups.remove(tg);
                          _hotspotDirty = true;
                        }),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                ],

                // YSF section
                if (_ysfEnabled) ...[
                  Text('YSF',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.grey.shade300)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _ysfReflectorCtl,
                          decoration: const InputDecoration(
                              labelText: 'Reflector',
                              isDense: true,
                              border: OutlineInputBorder()),
                          style: const TextStyle(fontSize: 13),
                          onChanged: (_) =>
                              setState(() => _hotspotDirty = true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _ysfDescCtl,
                          decoration: const InputDecoration(
                              labelText: 'Description',
                              isDense: true,
                              border: OutlineInputBorder()),
                          style: const TextStyle(fontSize: 13),
                          onChanged: (_) =>
                              setState(() => _hotspotDirty = true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
            const SizedBox(height: 16),

            // 3. Connected clients
            _SectionCard(
              title: 'Connected Clients',
              icon: Icons.people,
              trailing: IconButton(
                onPressed: _refreshClients,
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
              ),
              children: [
                if (_clients == null || _clients!.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('No clients heard recently.',
                        style:
                            TextStyle(color: Colors.grey.shade500)),
                  )
                else
                  SizedBox(
                    width: double.infinity,
                    child: DataTable(
                      headingRowHeight: 36,
                      dataRowMinHeight: 32,
                      dataRowMaxHeight: 36,
                      columns: const [
                        DataColumn(label: Text('Callsign')),
                        DataColumn(label: Text('Mode')),
                        DataColumn(label: Text('Duration')),
                      ],
                      rows: _clients!.map((c) {
                        return DataRow(cells: [
                          DataCell(Text(c.callsign,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold))),
                          DataCell(Text(c.mode)),
                          DataCell(Text('${c.duration}s',
                              style: const TextStyle(
                                  fontFamily: 'monospace'))),
                        ]);
                      }).toList(),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          // 4. Rig settings (rigctl / console types)
          if (isRigType && widget.device.hasRigctld) ...[
            _SectionCard(
              title: 'Rig Configuration',
              icon: Icons.radio,
              children: [
                FilledButton.icon(
                  onPressed: _openRigSettings,
                  icon: const Icon(Icons.settings, size: 16),
                  label: const Text('Configure Rig...'),
                ),
                if (widget.onAddRig != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: widget.onAddRig,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add Rig'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
          ],

          // 5. Services card
          _SectionCard(
            title: 'Services',
            icon: Icons.miscellaneous_services,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (widget.device.hasRigctld)
                    _ServiceButton(
                      label: 'rigctld',
                      onRestart: () => _restartService('rigctld'),
                    ),
                  if (isHotspot) ...[
                    _ServiceButton(
                      label: 'mmdvmhost',
                      onRestart: () => _restartService('mmdvmhost'),
                    ),
                    _ServiceButton(
                      label: 'dmrgateway',
                      onRestart: () => _restartService('dmr'),
                    ),
                    _ServiceButton(
                      label: 'ysfgateway',
                      onRestart: () => _restartService('ysf'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              const Divider(),
              const SizedBox(height: 4),
              OutlinedButton.icon(
                onPressed: _reboot,
                icon: const Icon(Icons.power_settings_new,
                    size: 16, color: Colors.orange),
                label: const Text('Reboot Device',
                    style: TextStyle(color: Colors.orange)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.orange),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// -- Shared widgets --

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget? trailing;
  final List<Widget> children;

  const _SectionCard({
    required this.title,
    required this.icon,
    this.trailing,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade900.withAlpha(120),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: Colors.grey.shade400),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade300),
              ),
              const Spacer(),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style:
                    TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final String label;
  final double value; // 0.0–1.0
  final String text;
  const _MetricRow(this.label, this.value, this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: value.clamp(0.0, 1.0)),
                const SizedBox(height: 2),
                Text(text,
                    style: const TextStyle(
                        fontSize: 11, fontFamily: 'monospace')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceButton extends StatelessWidget {
  final String label;
  final VoidCallback onRestart;

  const _ServiceButton({required this.label, required this.onRestart});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onRestart,
      icon: const Icon(Icons.restart_alt, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }
}
