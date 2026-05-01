import 'dart:async';

import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart';
import '../services/connection_service.dart';
import '../services/settings_service.dart';
import '../widgets/connection_dialog.dart';
import '../widgets/rig_settings_dialog.dart';

class RigPanel extends StatefulWidget {
  final ConnectionService connectionService;
  final SettingsService settings;

  const RigPanel({
    super.key,
    required this.connectionService,
    required this.settings,
  });

  @override
  State<RigPanel> createState() => _RigPanelState();
}

class _RigPanelState extends State<RigPanel> {
  static const _modes = ['USB', 'LSB', 'CW', 'FM', 'AM'];
  static const _vfos  = ['VFOA', 'VFOB'];

  int _frequencyHz = 0;
  String _mode = '';
  String _vfo  = '';
  bool _pttActive = false;
  Timer? _pollTimer;
  bool _polling = false;

  ConnectionService get _cs => widget.connectionService;
  RigManager get _rm => _cs.rigManager;

  @override
  void initState() {
    super.initState();
    _cs.addListener(_onChanged);
    if (_cs.connected) _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _cs.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (_cs.connected) {
      _startPolling();
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
      if (mounted) {
        setState(() {
          _frequencyHz = 0;
          _mode = '';
          _vfo = '';
          _pttActive = false;
        });
      }
    }
    if (mounted) setState(() {});
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final client = _cs.client;
      if (client == null || !client.isConnected) return;
      final freq = await client.getFrequency();
      final modeResult = await client.getMode();
      final ptt = await client.getPtt();
      final vfo = await client.getVfo();
      if (mounted) {
        setState(() {
          _frequencyHz = freq;
          _mode = modeResult.mode;
          _pttActive = ptt;
          _vfo = vfo;
        });
      }
    } catch (_) {
    } finally {
      _polling = false;
    }
  }

  Future<void> _setVfo(String vfo) async {
    final client = _cs.client;
    if (client == null) return;
    try {
      await client.setVfo(vfo);
      setState(() => _vfo = vfo);
    } catch (_) {}
  }

  Future<void> _setMode(String mode) async {
    final client = _cs.client;
    if (client == null) return;
    try {
      await client.setMode(mode);
      setState(() => _mode = mode);
    } catch (_) {}
  }

  Future<void> _togglePtt() async {
    final client = _cs.client;
    if (client == null) return;
    final newState = !_pttActive;
    try {
      await client.setPtt(newState);
      setState(() => _pttActive = newState);
    } catch (_) {}
  }

  String _formatFrequency(int hz) {
    if (hz == 0) return '-.---.---';
    final whole = (hz ~/ 1000000).toString();
    final khz = ((hz % 1000000) ~/ 1000).toString().padLeft(3, '0');
    final sub = (hz % 1000).toString().padLeft(3, '0');
    return '$whole.$khz.$sub';
  }

  void _showAddRigDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => ConnectionDialog(
        connectionService: _cs,
        settings: widget.settings,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rigs = _rm.rigs;
    final activeRig = _rm.activeRig;
    final isConnected = _cs.connected;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Rig selector row
          Row(
            children: [
              if (rigs.isNotEmpty)
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: activeRig?.id,
                      isExpanded: true,
                      isDense: true,
                      hint: const Text('Select rig',
                          style: TextStyle(fontSize: 12)),
                      items: rigs.map((rig) {
                        return DropdownMenuItem<String>(
                          value: rig.id,
                          child: Row(
                            children: [
                              Icon(Icons.circle,
                                  size: 8,
                                  color: rig.connected
                                      ? Colors.green
                                      : Colors.red),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(rig.label,
                                    style: const TextStyle(fontSize: 12),
                                    overflow: TextOverflow.ellipsis),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (id) {
                        if (id != null) _rm.setActiveRig(id);
                      },
                    ),
                  ),
                ),
              if (rigs.isEmpty) const Spacer(),
              IconButton(
                onPressed: _showAddRigDialog,
                icon: Icon(Icons.add,
                    size: 16, color: Colors.grey.shade400),
                visualDensity: VisualDensity.compact,
                tooltip: 'Add rig',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                    minWidth: 28, minHeight: 28),
              ),
              if (activeRig != null) ...[
                IconButton(
                  onPressed: () => _showRigSettings(activeRig),
                  icon: Icon(Icons.settings,
                      size: 16, color: Colors.grey.shade400),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Rig settings',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                      minWidth: 28, minHeight: 28),
                ),
                IconButton(
                  onPressed: () => _showRigContextMenu(activeRig),
                  icon: Icon(Icons.more_vert,
                      size: 16, color: Colors.grey.shade400),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'More',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                      minWidth: 28, minHeight: 28),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),

          // Frequency display
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade700),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _formatFrequency(_frequencyHz),
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w300,
                  fontFamily: 'monospace',
                  color: isConnected
                      ? Colors.green.shade400
                      : Colors.grey.shade600,
                  letterSpacing: 2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text('MHz',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
          const SizedBox(height: 8),

          // VFO + Mode dropdowns
          Row(
            children: [
              Expanded(
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'VFO',
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _vfos.contains(_vfo) ? _vfo : null,
                      hint: const Text('—', style: TextStyle(fontSize: 12)),
                      isDense: true,
                      style: const TextStyle(fontSize: 12),
                      items: _vfos
                          .map((v) => DropdownMenuItem(
                                value: v,
                                child: Text(v == 'VFOA' ? 'VFO A' : 'VFO B'),
                              ))
                          .toList(),
                      onChanged: isConnected
                          ? (v) { if (v != null) _setVfo(v); }
                          : null,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Mode',
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _modes.contains(_mode) ? _mode : null,
                      hint: const Text('—', style: TextStyle(fontSize: 12)),
                      isDense: true,
                      style: const TextStyle(fontSize: 12),
                      items: _modes
                          .map((m) => DropdownMenuItem(
                                value: m,
                                child: Text(m),
                              ))
                          .toList(),
                      onChanged: isConnected
                          ? (m) { if (m != null) _setMode(m); }
                          : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // PTT button
          SizedBox(
            width: 64,
            height: 64,
            child: ElevatedButton(
              onPressed: isConnected ? _togglePtt : null,
              style: ElevatedButton.styleFrom(
                shape: const CircleBorder(),
                backgroundColor:
                    _pttActive ? Colors.red : Colors.grey.shade800,
                foregroundColor: Colors.white,
                padding: EdgeInsets.zero,
                side: BorderSide(
                  color: _pttActive
                      ? Colors.red.shade300
                      : Colors.grey.shade600,
                  width: 2,
                ),
              ),
              child: Text(
                'PTT',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: _pttActive ? Colors.white : Colors.grey.shade400,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  void _showRigSettings(RigEntry rig) {
    showDialog<bool>(
      context: context,
      builder: (_) => RigSettingsDialog(
        rig: rig,
        connectionService: _cs,
        settings: widget.settings,
      ),
    );
  }

  void _showRigContextMenu(RigEntry rig) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.radio),
              title: Text(rig.label),
              subtitle: Text(rig.id),
            ),
            const Divider(height: 1),
            if (!rig.connected)
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('Reconnect'),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  try {
                    await _rm.connectRig(rig.id);
                  } catch (_) {}
                },
              ),
            if (rig.connected)
              ListTile(
                leading: const Icon(Icons.link_off),
                title: const Text('Disconnect'),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  try {
                    await _rm.disconnectRig(rig.id);
                  } catch (_) {}
                },
              ),
            ListTile(
              leading: Icon(Icons.delete, color: Colors.red.shade300),
              title: Text('Remove', style: TextStyle(color: Colors.red.shade300)),
              onTap: () {
                Navigator.of(ctx).pop();
                _cs.removeRig(rig.id);
              },
            ),
          ],
        ),
      ),
    );
  }
}
