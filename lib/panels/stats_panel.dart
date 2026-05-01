import 'dart:io';

import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart';

class StatsPanel extends StatefulWidget {
  final String logPath;

  const StatsPanel({super.key, required this.logPath});

  @override
  State<StatsPanel> createState() => StatsPanelState();
}

class StatsPanelState extends State<StatsPanel> {
  int _qsoCount = 0;
  int _dxccCount = 0;
  int _wasCount = 0;
  List<MapEntry<String, int>> _topBands = [];

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final file = File(widget.logPath);
    if (!await file.exists()) return;
    final content = await file.readAsString();
    final records = AdifLog.parse(content);
    if (!mounted) return;

    final bandCounts = qsosByBand(records);
    final sorted = bandCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    setState(() {
      _qsoCount = records.length;
      _dxccCount = countDxcc(records);
      _wasCount = countWas(records);
      _topBands = sorted.take(5).toList();
    });
  }

  void reload() => _loadStats();

  @override
  Widget build(BuildContext context) {
    final maxBandCount =
        _topBands.isNotEmpty ? _topBands.first.value : 1;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Log Stats',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade300,
            ),
          ),
          const Divider(height: 16),
          _StatRow(label: 'QSOs', value: '$_qsoCount'),
          _StatRow(label: 'DXCC', value: '$_dxccCount/340'),
          _StatRow(label: 'WAS', value: '$_wasCount/50'),
          const SizedBox(height: 8),
          Text(
            'Top Bands',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 4),
          if (_topBands.isEmpty)
            Text('--',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600))
          else
            for (final entry in _topBands)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 32,
                      child: Text(
                        entry.key,
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey.shade400,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final fraction = entry.value / maxBandCount;
                          return Container(
                            height: 10,
                            width: constraints.maxWidth * fraction,
                            decoration: BoxDecoration(
                              color: Colors.green.shade700,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${entry.value}',
                      style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: Colors.grey.shade400,
                      ),
                    ),
                  ],
                ),
              ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: _loadStats,
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Refresh', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(label,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
