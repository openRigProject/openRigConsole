import 'dart:async';

import 'package:flutter/material.dart';

/// Displays the HamQSL solar conditions image, refreshing every 2 hours.
class SolarImagePanel extends StatefulWidget {
  const SolarImagePanel({super.key});

  @override
  State<SolarImagePanel> createState() => _SolarImagePanelState();
}

class _SolarImagePanelState extends State<SolarImagePanel> {
  static const _baseUrl = 'https://www.hamqsl.com/solar101pic.php';

  late String _url;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _url = _buildUrl();
    _timer = Timer.periodic(const Duration(hours: 2), (_) {
      setState(() => _url = _buildUrl());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _buildUrl() => '$_baseUrl?t=${DateTime.now().millisecondsSinceEpoch}';

  @override
  Widget build(BuildContext context) {
    return Image.network(
      _url,
      fit: BoxFit.fitWidth,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      loadingBuilder: (_, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return const SizedBox(
          height: 60,
          child: Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      },
    );
  }
}
