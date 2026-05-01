import 'dart:async';

import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart';
import '../services/connection_service.dart';

class _Segment {
  final String label;
  final double startKhz;
  final double endKhz;
  final Color color;

  const _Segment(this.label, this.startKhz, this.endKhz, this.color);
}

class _Band {
  final String name;
  final double startKhz;
  final double endKhz;
  final List<_Segment> segments;

  const _Band(this.name, this.startKhz, this.endKhz, this.segments);

  String get rangeLabel =>
      '${(startKhz / 1000).toStringAsFixed(3)}\u2013${(endKhz / 1000).toStringAsFixed(3)} MHz';
}

const _cwColor = Color(0xFF4A6FA5);
const _digiColor = Color(0xFF6A4C93);
const _ssbColor = Color(0xFF1B998B);

// US band plan segments (approximate)
const _bands = [
  _Band('160m', 1800, 2000, [
    _Segment('CW', 1800, 1840, _cwColor),
    _Segment('Digi', 1840, 1850, _digiColor),
    _Segment('SSB', 1850, 2000, _ssbColor),
  ]),
  _Band('80m', 3500, 4000, [
    _Segment('CW', 3500, 3600, _cwColor),
    _Segment('Digi', 3570, 3600, _digiColor),
    _Segment('SSB', 3600, 4000, _ssbColor),
  ]),
  _Band('60m', 5330.5, 5403.5, [
    _Segment('USB', 5330.5, 5403.5, _ssbColor),
  ]),
  _Band('40m', 7000, 7300, [
    _Segment('CW', 7000, 7125, _cwColor),
    _Segment('Digi', 7070, 7125, _digiColor),
    _Segment('SSB', 7125, 7300, _ssbColor),
  ]),
  _Band('30m', 10100, 10150, [
    _Segment('CW', 10100, 10130, _cwColor),
    _Segment('Digi', 10130, 10150, _digiColor),
  ]),
  _Band('20m', 14000, 14350, [
    _Segment('CW', 14000, 14150, _cwColor),
    _Segment('Digi', 14070, 14100, _digiColor),
    _Segment('SSB', 14150, 14350, _ssbColor),
  ]),
  _Band('17m', 18068, 18168, [
    _Segment('CW', 18068, 18110, _cwColor),
    _Segment('Digi', 18095, 18110, _digiColor),
    _Segment('SSB', 18110, 18168, _ssbColor),
  ]),
  _Band('15m', 21000, 21450, [
    _Segment('CW', 21000, 21200, _cwColor),
    _Segment('Digi', 21070, 21110, _digiColor),
    _Segment('SSB', 21200, 21450, _ssbColor),
  ]),
  _Band('12m', 24890, 24990, [
    _Segment('CW', 24890, 24930, _cwColor),
    _Segment('Digi', 24910, 24930, _digiColor),
    _Segment('SSB', 24930, 24990, _ssbColor),
  ]),
  _Band('10m', 28000, 29700, [
    _Segment('CW', 28000, 28300, _cwColor),
    _Segment('Digi', 28070, 28150, _digiColor),
    _Segment('SSB', 28300, 29700, _ssbColor),
  ]),
];

class BandmapScreen extends StatefulWidget {
  final ConnectionService connectionService;
  final List<DxSpot> spots;

  const BandmapScreen({
    super.key,
    required this.connectionService,
    this.spots = const [],
  });

  @override
  State<BandmapScreen> createState() => _BandmapScreenState();
}

class _BandmapScreenState extends State<BandmapScreen> {
  int _frequencyHz = 0;
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
      if (mounted) setState(() => _frequencyHz = 0);
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
      if (mounted) setState(() => _frequencyHz = freq);
    } catch (_) {}
  }

  void _tuneToFrequency(int hz) {
    final client = _cs.client;
    if (client == null || !client.isConnected) return;
    client.setFrequency(hz);
    setState(() => _frequencyHz = hz);
  }

  @override
  Widget build(BuildContext context) {
    final freqKhz = _frequencyHz / 1000.0;
    final isConnected = _cs.connected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Row(
            children: [
              Text('Bandmap', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(width: 16),
              // Legend
              _LegendChip('CW', _cwColor),
              const SizedBox(width: 8),
              _LegendChip('Digital', _digiColor),
              const SizedBox(width: 8),
              _LegendChip('SSB', _ssbColor),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            itemCount: _bands.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final band = _bands[index];
              final isOnBand =
                  freqKhz >= band.startKhz && freqKhz <= band.endKhz;
              final bandSpots = widget.spots
                  .where((s) =>
                      s.frequencyKhz >= band.startKhz &&
                      s.frequencyKhz <= band.endKhz)
                  .toList();
              return _BandRow(
                band: band,
                currentFreqKhz: isOnBand ? freqKhz : null,
                isConnected: isConnected,
                onTune: isConnected
                    ? (khz) => _tuneToFrequency((khz * 1000).round())
                    : null,
                spots: bandSpots,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _LegendChip extends StatelessWidget {
  final String label;
  final Color color;

  const _LegendChip(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color.withAlpha(180),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
      ],
    );
  }
}

class _BandRow extends StatelessWidget {
  final _Band band;
  final double? currentFreqKhz;
  final bool isConnected;
  final void Function(double khz)? onTune;
  final List<DxSpot> spots;

  const _BandRow({
    required this.band,
    required this.currentFreqKhz,
    required this.isConnected,
    this.onTune,
    this.spots = const [],
  });

  @override
  Widget build(BuildContext context) {
    final isActive = currentFreqKhz != null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isActive
            ? Colors.green.withAlpha(20)
            : Colors.grey.shade900.withAlpha(120),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isActive ? Colors.green.shade700 : Colors.grey.shade800,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                band.name,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isActive ? Colors.green.shade300 : Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                band.rangeLabel,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: Colors.grey.shade500,
                ),
              ),
              if (currentFreqKhz != null) ...[
                const Spacer(),
                Text(
                  '${(currentFreqKhz! / 1000).toStringAsFixed(3)} MHz',
                  style: TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    color: Colors.green.shade300,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final barWidth = constraints.maxWidth;
              return GestureDetector(
                onTapDown: onTune == null
                    ? null
                    : (details) {
                        final fraction =
                            details.localPosition.dx / barWidth;
                        final khz = band.startKhz +
                            fraction * (band.endKhz - band.startKhz);
                        onTune!(khz.clamp(band.startKhz, band.endKhz));
                      },
                child: MouseRegion(
                  cursor: isConnected
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.basic,
                  child: SizedBox(
                    height: 28,
                    width: barWidth,
                    child: CustomPaint(
                      painter: _BandBarPainter(
                        band: band,
                        currentFreqKhz: currentFreqKhz,
                        spots: spots,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _BandBarPainter extends CustomPainter {
  final _Band band;
  final double? currentFreqKhz;
  final List<DxSpot> spots;

  _BandBarPainter({required this.band, this.currentFreqKhz, this.spots = const []});

  @override
  void paint(Canvas canvas, Size size) {
    final span = band.endKhz - band.startKhz;

    // Background
    final bgPaint = Paint()..color = const Color(0xFF1A1A1A);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        const Radius.circular(4),
      ),
      bgPaint,
    );

    // Draw segments
    for (final seg in band.segments) {
      final left = ((seg.startKhz - band.startKhz) / span) * size.width;
      final right = ((seg.endKhz - band.startKhz) / span) * size.width;
      final segPaint = Paint()..color = seg.color.withAlpha(100);
      canvas.drawRect(
        Rect.fromLTRB(left.clamp(0, size.width), 0, right.clamp(0, size.width), size.height),
        segPaint,
      );
    }

    // Segment labels
    final labelStyle = TextStyle(
      fontSize: 9,
      color: Colors.grey.shade500,
    );
    final drawn = <String>{};
    for (final seg in band.segments) {
      if (drawn.contains(seg.label)) continue;
      drawn.add(seg.label);
      final left = ((seg.startKhz - band.startKhz) / span) * size.width;
      final right = ((seg.endKhz - band.startKhz) / span) * size.width;
      final segWidth = right - left;
      if (segWidth > 24) {
        final tp = TextPainter(
          text: TextSpan(text: seg.label, style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        if (tp.width < segWidth - 4) {
          tp.paint(
            canvas,
            Offset(left + (segWidth - tp.width) / 2, (size.height - tp.height) / 2),
          );
        }
      }
    }

    // Rig frequency marker
    if (currentFreqKhz != null) {
      final x = ((currentFreqKhz! - band.startKhz) / span) * size.width;
      final markerPaint = Paint()
        ..color = Colors.green
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      // Vertical line
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), markerPaint);
      // Small triangle at top
      final triPath = Path()
        ..moveTo(x - 4, 0)
        ..lineTo(x + 4, 0)
        ..lineTo(x, 5)
        ..close();
      canvas.drawPath(triPath, Paint()..color = Colors.green);
    }

    // Spot markers
    for (final spot in spots) {
      final x = ((spot.frequencyKhz - band.startKhz) / span) * size.width;
      final spotPaint = Paint()
        ..color = Colors.yellow.withAlpha(180)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(x, size.height - 4), 3, spotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _BandBarPainter old) =>
      old.currentFreqKhz != currentFreqKhz || old.spots.length != spots.length;
}
