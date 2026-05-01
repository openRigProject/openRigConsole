import 'dart:io';

import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart';
import '../services/connection_service.dart';
import '../services/settings_service.dart';

const _baudRates = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200];

/// Dialog for adding rigs (local sidecar, mDNS-discovered, or manual).
class ConnectionDialog extends StatefulWidget {
  final ConnectionService connectionService;
  final SettingsService settings;

  const ConnectionDialog({
    super.key,
    required this.connectionService,
    required this.settings,
  });

  @override
  State<ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<ConnectionDialog> {
  // Manual connection fields
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '4532');
  final _labelController = TextEditingController();

  // Local rig config fields
  late int _localModel;
  late TextEditingController _localSerialPortCtl;
  late int _localBaudRate;
  String _localModelFilter = '';
  bool _showLocalModelPicker = false;
  List<String> _availablePorts = [];

  String? _error;
  bool _busy = false;

  ConnectionService get _cs => widget.connectionService;
  SettingsService get _settings => widget.settings;

  @override
  void initState() {
    super.initState();
    _localModel = _settings.sidecarModel;
    _localBaudRate = _settings.sidecarBaudRate;
    _localSerialPortCtl =
        TextEditingController(text: _settings.sidecarSerialPort);
    _loadAvailablePorts();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _labelController.dispose();
    _localSerialPortCtl.dispose();
    super.dispose();
  }

  Future<void> _loadAvailablePorts() async {
    try {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      final entities = await Directory('/dev').list().toList();
      final ports = entities.map((e) => e.path).where((p) {
        final name = p.split('/').last;
        if (Platform.isMacOS) {
          return name.startsWith('cu.') || name.startsWith('tty.');
        } else {
          return name.startsWith('ttyUSB') ||
              name.startsWith('ttyACM') ||
              name.startsWith('ttyS') ||
              name.startsWith('rfcomm');
        }
      }).toList()
        ..sort();
      if (mounted) setState(() => _availablePorts = ports);
    } catch (_) {}
  }

  Future<void> _launchLocalRig() async {
    setState(() { _busy = true; _error = null; });
    final serialPort = _localSerialPortCtl.text.trim();

    // Build a label from model name + serial port
    HamlibModel? hm;
    for (final m in kCommonHamlibModels) {
      if (m.id == _localModel) { hm = m; break; }
    }
    final modelName = hm != null
        ? '${hm.manufacturer} ${hm.name}'
        : _localModel == 1 ? 'Dummy' : 'Model $_localModel';
    final label = serialPort.isNotEmpty
        ? '$modelName · ${serialPort.split('/').last}'
        : modelName;

    try {
      await _cs.addFfiLocalRig(
        model: _localModel,
        serialPort: serialPort,
        baudRate: _localBaudRate,
        label: label,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addRemoteRig(String host, int port, {String? label}) async {
    setState(() { _busy = true; _error = null; });
    try {
      await _cs.addRemoteRig(host, port, label: label);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addManualRig() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 4532;
    final label = _labelController.text.trim();
    if (host.isEmpty) {
      setState(() => _error = 'Enter a hostname or IP address');
      return;
    }
    await _addRemoteRig(host, port, label: label.isNotEmpty ? label : null);
  }

  HamlibModel? get _selectedModel {
    for (final m in kCommonHamlibModels) {
      if (m.id == _localModel) return m;
    }
    return null;
  }

  List<HamlibModel> get _filteredModels {
    if (_localModelFilter.isEmpty) return kCommonHamlibModels;
    final q = _localModelFilter.toLowerCase();
    return kCommonHamlibModels
        .where((m) =>
            m.manufacturer.toLowerCase().contains(q) ||
            m.name.toLowerCase().contains(q) ||
            m.id.toString().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final mdnsAvailable = _cs.mdnsAvailable;
    final devices = mdnsAvailable
        ? _cs.discovery.devices.values.toList()
        : <OpenRigDevice>[];
    final selectedModel = _selectedModel;

    return AlertDialog(
      title: const Text('Add Rig'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!,
                    style: TextStyle(color: Colors.red.shade300)),
              ),

            // ── Local Rig ──────────────────────────────────────────────────
            Text('Local Rig',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),

            // Model selector
            InkWell(
              onTap: () =>
                  setState(() => _showLocalModelPicker = !_showLocalModelPicker),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade600),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        selectedModel != null
                            ? '${selectedModel.manufacturer} ${selectedModel.name} (${selectedModel.id})'
                            : 'Model ID: $_localModel',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    Icon(
                      _showLocalModelPicker
                          ? Icons.arrow_drop_up
                          : Icons.arrow_drop_down,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),

            if (_showLocalModelPicker) ...[
              const SizedBox(height: 4),
              TextField(
                decoration: const InputDecoration(
                  hintText: 'Search models...',
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18),
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (v) => setState(() => _localModelFilter = v),
              ),
              const SizedBox(height: 4),
              Container(
                height: 160,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade700),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: _filteredModels.length,
                  itemBuilder: (_, i) {
                    final m = _filteredModels[i];
                    final isSelected = m.id == _localModel;
                    return ListTile(
                      dense: true,
                      selected: isSelected,
                      selectedTileColor: Colors.green.withAlpha(30),
                      title: Text('${m.manufacturer} ${m.name}',
                          style: const TextStyle(fontSize: 13)),
                      trailing: Text('${m.id}',
                          style: TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: Colors.grey.shade500)),
                      onTap: () => setState(() {
                        _localModel = m.id;
                        _showLocalModelPicker = false;
                        _localModelFilter = '';
                      }),
                    );
                  },
                ),
              ),
            ],

            // Serial port + baud rate — hidden for Dummy/NET rigctl
            if (_localModel > 2) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _localSerialPortCtl,
                            decoration: const InputDecoration(
                              labelText: 'Serial Port',
                              hintText: '/dev/ttyUSB0',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            style: const TextStyle(
                                fontSize: 13, fontFamily: 'monospace'),
                          ),
                        ),
                        if (_availablePorts.isNotEmpty) ...[
                          const SizedBox(width: 2),
                          PopupMenuButton<String>(
                            tooltip: 'Available ports',
                            icon: const Icon(Icons.expand_more, size: 20),
                            onSelected: (p) =>
                                setState(() => _localSerialPortCtl.text = p),
                            itemBuilder: (_) => _availablePorts
                                .map((p) => PopupMenuItem(
                                      value: p,
                                      child: Text(p.split('/').last,
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontFamily: 'monospace')),
                                    ))
                                .toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Baud Rate',
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        border: OutlineInputBorder(),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: _localBaudRate,
                          isDense: true,
                          isExpanded: true,
                          items: _baudRates
                              .map((v) => DropdownMenuItem(
                                  value: v,
                                  child: Text('$v',
                                      style: const TextStyle(fontSize: 13))))
                              .toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => _localBaudRate = v);
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 8),

            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _busy ? null : _launchLocalRig,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('Add Local Rig'),
              ),
            ),

            const Divider(height: 28),

            // ── Discovered Devices ─────────────────────────────────────────
            if (mdnsAvailable) ...[
              Text('Discovered Devices',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              if (devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('No devices found on the network.',
                      style: TextStyle(color: Colors.grey.shade500)),
                )
              else
                ...devices.map((d) => _DeviceTile(
                      device: d,
                      busy: _busy,
                      onAdd: () {
                        final lbl = d.callsign.isNotEmpty
                            ? '${d.callsign} (${d.type})'
                            : d.name;
                        _addRemoteRig(
                          d.host,
                          d.rigctldPort ?? 4532,
                          label: lbl,
                        );
                      },
                    )),
              const Divider(height: 28),
            ],

            // ── Manual Connection ──────────────────────────────────────────
            Text('Manual Connection',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Label (optional)',
                hintText: 'e.g. IC-7300',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _hostController,
                    decoration: const InputDecoration(
                      labelText: 'Host',
                      hintText: '192.168.1.100',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _portController,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _addManualRig,
                  child: const Text('Add'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        if (_busy)
          const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final OpenRigDevice device;
  final bool busy;
  final VoidCallback onAdd;

  const _DeviceTile({
    required this.device,
    required this.busy,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        device.hasRigctld ? Icons.radio : Icons.devices,
        color: device.hasRigctld ? Colors.green : Colors.grey,
      ),
      title: Text(device.callsign.isNotEmpty
          ? '${device.callsign} (${device.type})'
          : device.name),
      subtitle: Text(device.host),
      trailing: device.hasRigctld
          ? const Icon(Icons.add_circle_outline, size: 20)
          : null,
      enabled: device.hasRigctld && !busy,
      onTap: device.hasRigctld && !busy ? onAdd : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );
  }
}
