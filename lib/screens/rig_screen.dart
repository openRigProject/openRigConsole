import 'dart:async';

import 'package:flutter/material.dart';
import '../services/connection_service.dart';

class RigScreen extends StatefulWidget {
  final ConnectionService connectionService;

  const RigScreen({super.key, required this.connectionService});

  @override
  State<RigScreen> createState() => _RigScreenState();
}

class _RigScreenState extends State<RigScreen> {
  static const _modes = ['USB', 'LSB', 'CW', 'FM', 'AM'];

  int _frequencyHz = 0;
  String _mode = '';
  bool _pttActive = false;
  Timer? _pollTimer;

  ConnectionService get _cs => widget.connectionService;

  @override
  void initState() {
    super.initState();
    _cs.addListener(_onConnectionChanged);
    if (_cs.connected) _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _cs.removeListener(_onConnectionChanged);
    super.dispose();
  }

  void _onConnectionChanged() {
    if (_cs.connected) {
      _startPolling();
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
      if (mounted) {
        setState(() {
          _frequencyHz = 0;
          _mode = '';
          _pttActive = false;
        });
      }
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  Future<void> _poll() async {
    final client = _cs.client;
    if (client == null || !client.isConnected) return;
    try {
      final freq = await client.getFrequency();
      final modeResult = await client.getMode();
      final ptt = await client.getPtt();
      if (mounted) {
        setState(() {
          _frequencyHz = freq;
          _mode = modeResult.mode;
          _pttActive = ptt;
        });
      }
    } catch (_) {
      // Connection may have dropped; ignore until next poll or reconnect.
    }
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

  @override
  Widget build(BuildContext context) {
    final isConnected = _cs.connected;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isConnected)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange.shade900.withAlpha(80),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade700),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
                  SizedBox(width: 8),
                  Text('Not connected', style: TextStyle(color: Colors.orange)),
                ],
              ),
            ),
          if (!isConnected) const SizedBox(height: 32),

          // Frequency display
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade700),
              ),
              child: Text(
                _formatFrequency(_frequencyHz),
                style: TextStyle(
                  fontSize: 56,
                  fontWeight: FontWeight.w300,
                  fontFamily: 'monospace',
                  color: isConnected ? Colors.green.shade400 : Colors.grey.shade600,
                  letterSpacing: 4,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text('MHz', style: TextStyle(color: Colors.grey)),
          ),
          const SizedBox(height: 32),

          // Mode selector
          Center(
            child: SegmentedButton<String>(
              segments: _modes
                  .map((m) => ButtonSegment<String>(value: m, label: Text(m)))
                  .toList(),
              selected: {_mode.isNotEmpty && _modes.contains(_mode) ? _mode : _modes.first},
              onSelectionChanged: isConnected
                  ? (selected) => _setMode(selected.first)
                  : null,
            ),
          ),
          const SizedBox(height: 32),

          // PTT button
          Center(
            child: SizedBox(
              width: 120,
              height: 120,
              child: ElevatedButton(
                onPressed: isConnected ? _togglePtt : null,
                style: ElevatedButton.styleFrom(
                  shape: const CircleBorder(),
                  backgroundColor: _pttActive ? Colors.red : Colors.grey.shade800,
                  foregroundColor: Colors.white,
                  side: BorderSide(
                    color: _pttActive ? Colors.red.shade300 : Colors.grey.shade600,
                    width: 2,
                  ),
                ),
                child: Text(
                  'PTT',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: _pttActive ? Colors.white : Colors.grey.shade400,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
