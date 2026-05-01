import 'dart:io';

import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart' hide ChangeNotifier;
import '../services/connection_service.dart';
import '../services/settings_service.dart';

const _baudRates = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200];
const _dataBitsOptions = [7, 8];
const _stopBitsOptions = [1, 2];
const _parityOptions = ['none', 'even', 'odd'];
const _handshakeOptions = ['none', 'hardware', 'software'];

class RigSettingsDialog extends StatefulWidget {
  final RigEntry rig;
  final ConnectionService connectionService;
  final SettingsService settings;

  const RigSettingsDialog({
    super.key,
    required this.rig,
    required this.connectionService,
    required this.settings,
  });

  @override
  State<RigSettingsDialog> createState() => _RigSettingsDialogState();
}

class _RigSettingsDialogState extends State<RigSettingsDialog> {
  late TextEditingController _labelCtl;
  late TextEditingController _hostCtl;
  late TextEditingController _portCtl;
  late int _modelId;
  late TextEditingController _serialPortCtl;
  late int _baudRate;
  late int _dataBits;
  late int _stopBits;
  late String _parity;
  late String _handshake;
  String _modelFilter = '';
  bool _showModelPicker = false;
  bool _busy = false;
  String? _error;
  List<String> _availablePorts = [];

  bool get _isLocal =>
      widget.rig.connectionType == RigConnectionType.local ||
      widget.rig.host == 'localhost';

  /// Dummy (1) and NET rigctl (2) don't use a serial port.
  bool get _isSerialModel => _modelId > 2;

  @override
  void initState() {
    super.initState();
    _labelCtl = TextEditingController(text: widget.rig.label);
    _hostCtl = TextEditingController(text: widget.rig.host);
    _portCtl = TextEditingController(text: widget.rig.port.toString());
    if (widget.rig.connectionType == RigConnectionType.local) {
      // FFI local rig — read config from the client itself.
      final ffi = widget.rig.client as HamlibFfiClient;
      _modelId = ffi.hamlibModel;
      _serialPortCtl = TextEditingController(text: ffi.serialPort);
      _baudRate = ffi.baudRate;
      _dataBits = ffi.dataBits;
      _stopBits = ffi.stopBits;
      _parity = ffi.parity;
      _handshake = ffi.handshake;
    } else if (_isLocal) {
      // Sidecar local rig — read from settings.
      _modelId = widget.settings.sidecarModel;
      _serialPortCtl =
          TextEditingController(text: widget.settings.sidecarSerialPort);
      _baudRate = widget.settings.sidecarBaudRate;
      _dataBits = widget.settings.sidecarDataBits;
      _stopBits = widget.settings.sidecarStopBits;
      _parity = widget.settings.sidecarParity;
      _handshake = widget.settings.sidecarHandshake;
    } else {
      _modelId = 1;
      _serialPortCtl = TextEditingController();
      _baudRate = 9600;
      _dataBits = 8;
      _stopBits = 1;
      _parity = 'none';
      _handshake = 'none';
      _loadRemoteConfig();
    }
    _loadAvailablePorts();
  }

  @override
  void dispose() {
    _labelCtl.dispose();
    _hostCtl.dispose();
    _portCtl.dispose();
    _serialPortCtl.dispose();
    super.dispose();
  }

  Future<void> _loadAvailablePorts() async {
    try {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      final dir = Directory('/dev');
      final entities = await dir.list().toList();
      final ports = entities
          .map((e) => e.path)
          .where((p) {
            final name = p.split('/').last;
            if (Platform.isMacOS) {
              return name.startsWith('cu.') || name.startsWith('tty.');
            } else {
              return name.startsWith('ttyUSB') ||
                  name.startsWith('ttyACM') ||
                  name.startsWith('ttyS') ||
                  name.startsWith('rfcomm');
            }
          })
          .toList()
        ..sort();
      if (mounted) setState(() => _availablePorts = ports);
    } catch (_) {}
  }

  Future<void> _loadRemoteConfig() async {
    try {
      final api = OpenRigApiClient(host: widget.rig.host);
      final config = await api.getRigConfig();
      api.dispose();
      if (config.rigs.isNotEmpty && mounted) {
        final r = config.rigs.first;
        setState(() {
          _modelId = r.hamlibModelId;
          _serialPortCtl.text = r.port;
          _baudRate = r.baud;
          _dataBits = r.dataBits;
          _stopBits = r.stopBits;
          _parity = r.parity;
          _handshake = r.handshake;
        });
      }
    } catch (_) {
      // Remote config not available — use defaults.
    }
  }

  HamlibModel? get _selectedModel {
    for (final m in kCommonHamlibModels) {
      if (m.id == _modelId) return m;
    }
    return null;
  }

  List<HamlibModel> get _filteredModels {
    if (_modelFilter.isEmpty) return kCommonHamlibModels;
    final q = _modelFilter.toLowerCase();
    return kCommonHamlibModels
        .where((m) =>
            m.manufacturer.toLowerCase().contains(q) ||
            m.name.toLowerCase().contains(q) ||
            m.id.toString().contains(q))
        .toList();
  }

  String _modelDisplayName(HamlibModel m) => '${m.manufacturer} ${m.name}';

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final newLabel = _labelCtl.text.trim();
      final newPort = int.tryParse(_portCtl.text.trim()) ?? widget.rig.port;
      final newHost = _isLocal ? widget.rig.host : _hostCtl.text.trim();
      final hostOrPortChanged =
          newHost != widget.rig.host || newPort != widget.rig.port;

      // Only rename in-place if we're keeping the same connection target.
      if (newLabel.isNotEmpty && !hostOrPortChanged) {
        widget.connectionService.rigManager.renameRig(widget.rig.id, newLabel);
      }

      if (_isLocal) {
        await widget.settings.setSidecarRigConfig(
          model: _modelId,
          serialPort: _serialPortCtl.text.trim(),
          baudRate: _baudRate,
          dataBits: _dataBits,
          stopBits: _stopBits,
          parity: _parity,
          handshake: _handshake,
        );
        if (widget.rig.connectionType == RigConnectionType.local) {
          // FFI local rig — remove and re-add with new settings.
          widget.connectionService.removeRig(widget.rig.id);
          await widget.connectionService.addFfiLocalRig(
            model: _modelId,
            serialPort: _serialPortCtl.text.trim(),
            baudRate: _baudRate,
            dataBits: _dataBits,
            stopBits: _stopBits,
            parity: _parity,
            handshake: _handshake,
            label: newLabel.isNotEmpty ? newLabel : null,
          );
        } else if (hostOrPortChanged) {
          // Sidecar: port changed — stop old sidecar and start fresh.
          widget.connectionService.removeRig(widget.rig.id);
          await widget.connectionService.addLocalRig(
            tcpPort: newPort,
            label: newLabel.isNotEmpty ? newLabel : null,
          );
        } else {
          await widget.connectionService.restartLocalSidecar(
            widget.rig.port,
            label: newLabel.isNotEmpty ? newLabel : null,
          );
        }
      } else {
        if (hostOrPortChanged) {
          // Remove old entry and add a new one at the updated address.
          widget.connectionService.removeRig(widget.rig.id);
          await widget.connectionService.addRemoteRig(
            newHost,
            newPort,
            label: newLabel.isNotEmpty ? newLabel : null,
          );
        } else {
          // Same address — push config via API and reconnect.
          try {
            final api = OpenRigApiClient(host: widget.rig.host);
            final entry = ApiRigEntry(
              enabled: true,
              hamlibModelId: _modelId,
              port: _serialPortCtl.text.trim(),
              baud: _baudRate,
              dataBits: _dataBits,
              stopBits: _stopBits,
              parity: _parity,
              handshake: _handshake,
            );
            await api.updateRigConfig(RigConfig(rigs: [entry]));
            api.dispose();
          } catch (_) {
            // API may not be available on older firmware.
          }
          final rm = widget.connectionService.rigManager;
          try {
            await rm.disconnectRig(widget.rig.id);
          } catch (_) {}
          await Future<void>.delayed(const Duration(milliseconds: 500));
          try {
            await rm.connectRig(widget.rig.id);
          } catch (_) {}
        }
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedModel = _selectedModel;

    return AlertDialog(
      title: Text('Rig Settings: ${widget.rig.label}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
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

              // Label
              TextField(
                controller: _labelCtl,
                decoration: const InputDecoration(
                  labelText: 'Label',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),

              // TCP port (sidecar rigs) / Host + Port (remote rigs)
              // FFI local rigs need neither.
              if (widget.rig.connectionType == RigConnectionType.local) ...[
                // No host/port fields for FFI local rigs.
              ] else if (_isLocal) ...[
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _portCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'TCP Port',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(height: 16),
              ] else ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _hostCtl,
                        decoration: const InputDecoration(
                          labelText: 'Host',
                          hintText: '192.168.1.100',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: _portCtl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Port',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],

              // Model selector
              Text('Hamlib Model',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              InkWell(
                onTap: () =>
                    setState(() => _showModelPicker = !_showModelPicker),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade600),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          selectedModel != null
                              ? '${_modelDisplayName(selectedModel)} (${selectedModel.id})'
                              : 'Model ID: $_modelId',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                      Icon(
                        _showModelPicker
                            ? Icons.arrow_drop_up
                            : Icons.arrow_drop_down,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),

              // Model picker (expandable)
              if (_showModelPicker) ...[
                const SizedBox(height: 4),
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search models...',
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (v) => setState(() => _modelFilter = v),
                ),
                const SizedBox(height: 4),
                Container(
                  height: 180,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade700),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    itemCount: _filteredModels.length,
                    itemBuilder: (_, i) {
                      final m = _filteredModels[i];
                      final isSelected = m.id == _modelId;
                      return ListTile(
                        dense: true,
                        selected: isSelected,
                        selectedTileColor: Colors.green.withAlpha(30),
                        title: Text(_modelDisplayName(m),
                            style: const TextStyle(fontSize: 13)),
                        trailing: Text('${m.id}',
                            style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: Colors.grey.shade500)),
                        onTap: () => setState(() {
                          _modelId = m.id;
                          _showModelPicker = false;
                          _modelFilter = '';
                        }),
                      );
                    },
                  ),
                ),
              ],
              if (_isSerialModel) ...[
                const SizedBox(height: 16),

                // Serial port (combo: type or pick from available)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _serialPortCtl,
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
                      const SizedBox(width: 4),
                      PopupMenuButton<String>(
                        tooltip: 'Available ports',
                        icon: const Icon(Icons.expand_more),
                        onSelected: (port) =>
                            setState(() => _serialPortCtl.text = port),
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
                const SizedBox(height: 12),

                // Baud rate
                _dropdownRow<int>(
                  label: 'Baud Rate',
                  value: _baudRate,
                  items: _baudRates,
                  onChanged: (v) => setState(() => _baudRate = v!),
                  itemLabel: (v) => v.toString(),
                ),
                const SizedBox(height: 12),

                // Data bits + Stop bits
                Row(
                  children: [
                    Expanded(
                      child: _dropdownRow<int>(
                        label: 'Data Bits',
                        value: _dataBits,
                        items: _dataBitsOptions,
                        onChanged: (v) => setState(() => _dataBits = v!),
                        itemLabel: (v) => v.toString(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _dropdownRow<int>(
                        label: 'Stop Bits',
                        value: _stopBits,
                        items: _stopBitsOptions,
                        onChanged: (v) => setState(() => _stopBits = v!),
                        itemLabel: (v) => v.toString(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Parity + Handshake
                Row(
                  children: [
                    Expanded(
                      child: _dropdownRow<String>(
                        label: 'Parity',
                        value: _parity,
                        items: _parityOptions,
                        onChanged: (v) => setState(() => _parity = v!),
                        itemLabel: (v) =>
                            v[0].toUpperCase() + v.substring(1),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _dropdownRow<String>(
                        label: 'Handshake',
                        value: _handshake,
                        items: _handshakeOptions,
                        onChanged: (v) => setState(() => _handshake = v!),
                        itemLabel: (v) =>
                            v[0].toUpperCase() + v.substring(1),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (_busy)
          const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _dropdownRow<T>({
    required String label,
    required T value,
    required List<T> items,
    required ValueChanged<T?> onChanged,
    required String Function(T) itemLabel,
  }) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: const OutlineInputBorder(),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: true,
          items: items
              .map((v) => DropdownMenuItem(
                  value: v,
                  child: Text(itemLabel(v),
                      style: const TextStyle(fontSize: 13))))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}
