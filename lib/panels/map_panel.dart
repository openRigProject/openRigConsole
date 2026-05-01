import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class MapLocation {
  final double lat;
  final double lon;
  final String callsign;
  const MapLocation(
      {required this.lat, required this.lon, required this.callsign});
}

/// Shows an OpenStreetMap view centered on the station being looked up.
class MapPanel extends StatefulWidget {
  final ValueNotifier<MapLocation?> location;

  const MapPanel({super.key, required this.location});

  @override
  State<MapPanel> createState() => _MapPanelState();
}

class _MapPanelState extends State<MapPanel>
    with SingleTickerProviderStateMixin {
  final _mapController = MapController();
  late final AnimationController _animController;
  Animation<double>? _latAnim;
  Animation<double>? _lonAnim;

  // Tracks the current map center for animation start point.
  LatLng? _currentCenter;
  // Separate state for marker + label so FlutterMap isn't rebuilt from scratch.
  LatLng? _markerPos;
  String _markerLabel = '';
  // Zoom range for current fly-to animation.
  double _animStartZoom = 6.0;
  double _animEndZoom = 6.0;
  double _animMinZoom = 6.0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..addListener(_onAnimTick);
    widget.location.addListener(_onLocationChanged);
  }

  @override
  void dispose() {
    _animController.dispose();
    widget.location.removeListener(_onLocationChanged);
    _mapController.dispose();
    super.dispose();
  }

  void _onAnimTick() {
    if (_latAnim == null || _lonAnim == null) return;
    final t = _animController.value; // 0→1

    // Zoom arcs parabolically: starts at _animStartZoom, dips to _animMinZoom
    // at t=0.5, then recovers to _animEndZoom.
    final zoomDip = (_animStartZoom - _animMinZoom) * math.sin(math.pi * t);
    final zoom = _animStartZoom - zoomDip +
        (_animEndZoom - _animStartZoom) * t;

    final pos = LatLng(_latAnim!.value, _lonAnim!.value);
    _currentCenter = pos;
    try {
      _mapController.move(pos, zoom);
    } catch (_) {
      // Controller not yet attached (first frame); ignore.
    }
  }

  void _onLocationChanged() {
    final loc = widget.location.value;
    if (loc == null) return;

    final target = LatLng(loc.lat, loc.lon);
    setState(() {
      _markerPos = target;
      _markerLabel = loc.callsign;
    });

    final from = _currentCenter;
    if (from == null) {
      // First location — FlutterMap will use initialCenter; no animation needed.
      _currentCenter = target;
      return;
    }

    // Distance in km determines how far to zoom out and how long to animate.
    final distKm = const Distance().as(LengthUnit.Kilometer, from, target);

    double minZoom;
    Duration duration;
    if (distKm > 8000) {
      minZoom = 2.5;
      duration = const Duration(milliseconds: 2800);
    } else if (distKm > 4000) {
      minZoom = 3.0;
      duration = const Duration(milliseconds: 2400);
    } else if (distKm > 2000) {
      minZoom = 3.5;
      duration = const Duration(milliseconds: 2000);
    } else if (distKm > 800) {
      minZoom = 4.0;
      duration = const Duration(milliseconds: 1500);
    } else if (distKm > 200) {
      minZoom = 4.5;
      duration = const Duration(milliseconds: 1000);
    } else {
      minZoom = 5.5;
      duration = const Duration(milliseconds: 700);
    }

    double currentZoom;
    try {
      currentZoom = _mapController.camera.zoom;
    } catch (_) {
      currentZoom = 6.0;
    }

    _animStartZoom = currentZoom;
    _animEndZoom = 6.0;
    _animMinZoom = minZoom;
    _animController.duration = duration;

    _latAnim = Tween<double>(begin: from.latitude, end: target.latitude)
        .animate(CurvedAnimation(parent: _animController, curve: Curves.easeInOut));
    _lonAnim = Tween<double>(begin: from.longitude, end: target.longitude)
        .animate(CurvedAnimation(parent: _animController, curve: Curves.easeInOut));
    _animController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (_markerPos == null) {
      return Container(
        color: const Color(0xFF1a1a1a),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_outlined, size: 32, color: Colors.grey.shade700),
              const SizedBox(height: 8),
              Text(
                'Look up a callsign\nto see their location',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _markerPos!,
            initialZoom: 6,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.openrig.console',
            ),
            MarkerLayer(
              markers: [
                Marker(
                  point: _markerPos!,
                  width: 32,
                  height: 32,
                  child: const Icon(Icons.location_on,
                      color: Colors.red, size: 32),
                ),
              ],
            ),
          ],
        ),
        // Callsign overlay
        Positioned(
          top: 6,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(160),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _markerLabel,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
