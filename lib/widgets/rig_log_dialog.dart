import 'dart:async';

import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart';

import '../services/connection_service.dart';

/// Terminal-style log viewer for a single rigctld sidecar process.
class _RigLogTab extends StatefulWidget {
  final ConnectionService connectionService;
  final RigEntry rig;

  const _RigLogTab({required this.connectionService, required this.rig});

  @override
  State<_RigLogTab> createState() => _RigLogTabState();
}

class _RigLogTabState extends State<_RigLogTab> {
  final _scrollCtl = ScrollController();
  late List<String> _lines;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    if (widget.rig.host == 'localhost') {
      _lines = List.from(
          widget.connectionService.getSidecarLog(widget.rig.port));
      _sub = widget.connectionService
          .getSidecarLogStream(widget.rig.port)
          ?.listen((line) {
        if (mounted) {
          setState(() => _lines.add(line));
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollCtl.hasClients) {
              _scrollCtl.animateTo(
                _scrollCtl.position.maxScrollExtent,
                duration: const Duration(milliseconds: 100),
                curve: Curves.easeOut,
              );
            }
          });
        }
      });
      // Scroll to bottom after initial render.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtl.hasClients) {
          _scrollCtl.jumpTo(_scrollCtl.position.maxScrollExtent);
        }
      });
    } else {
      _lines = [];
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.rig.host != 'localhost') {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_outlined, size: 48, color: Colors.grey.shade600),
            const SizedBox(height: 12),
            Text(
              'Remote rig — ${widget.rig.host}:${widget.rig.port}',
              style: TextStyle(color: Colors.grey.shade400),
            ),
            const SizedBox(height: 4),
            Text(
              'No local rigctld process. Logs are not available for remote rigs.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }

    if (_lines.isEmpty) {
      return Center(
        child: Text(
          'No output yet — rigctld may still be starting.',
          style: TextStyle(color: Colors.grey.shade500),
        ),
      );
    }

    return Container(
      color: Colors.black,
      child: ListView.builder(
        controller: _scrollCtl,
        padding: const EdgeInsets.all(12),
        itemCount: _lines.length,
        itemBuilder: (_, i) {
          final line = _lines[i];
          // Highlight error/warning lines in amber.
          final isError = line.toLowerCase().contains('error') ||
              line.toLowerCase().contains('warning') ||
              line.toLowerCase().contains('failed');
          return Text(
            line,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: isError ? Colors.amber.shade300 : Colors.grey.shade300,
            ),
          );
        },
      ),
    );
  }
}

/// Dialog showing rigctld stdout/stderr for each configured rig.
class RigLogDialog extends StatefulWidget {
  final ConnectionService connectionService;

  const RigLogDialog({super.key, required this.connectionService});

  static void show(BuildContext context, ConnectionService cs) {
    showDialog(
      context: context,
      builder: (_) => RigLogDialog(connectionService: cs),
    );
  }

  @override
  State<RigLogDialog> createState() => _RigLogDialogState();
}

class _RigLogDialogState extends State<RigLogDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<RigEntry> get _rigs =>
      widget.connectionService.rigManager.rigs;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
        length: _rigs.isEmpty ? 1 : _rigs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 720,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Title bar
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              color: Colors.grey.shade900,
              child: Row(
                children: [
                  const Icon(Icons.terminal, size: 18),
                  const SizedBox(width: 8),
                  const Text('Rig Diagnostics',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            if (_rigs.isEmpty)
              const Expanded(
                child: Center(child: Text('No rigs configured.')),
              )
            else ...[
              // Tab bar (only shown when more than one rig)
              if (_rigs.length > 1)
                Container(
                  color: Colors.grey.shade900,
                  child: TabBar(
                    controller: _tabController,
                    tabs: _rigs
                        .map((r) => Tab(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    r.host == 'localhost'
                                        ? Icons.computer
                                        : Icons.wifi,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(r.label,
                                      style:
                                          const TextStyle(fontSize: 12)),
                                ],
                              ),
                            ))
                        .toList(),
                  ),
                ),

              // Single rig header when only one rig
              if (_rigs.length == 1)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  color: Colors.grey.shade800,
                  child: Row(
                    children: [
                      Icon(
                        _rigs.first.host == 'localhost'
                            ? Icons.computer
                            : Icons.wifi,
                        size: 14,
                        color: Colors.grey.shade400,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _rigs.first.label,
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade400),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _rigs.first.connected
                              ? Colors.green.shade900
                              : Colors.red.shade900,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _rigs.first.connected
                              ? 'Connected'
                              : 'Disconnected',
                          style: TextStyle(
                            fontSize: 11,
                            color: _rigs.first.connected
                                ? Colors.green.shade300
                                : Colors.red.shade300,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // Log content
              Expanded(
                child: _rigs.length == 1
                    ? _RigLogTab(
                        connectionService: widget.connectionService,
                        rig: _rigs.first,
                      )
                    : TabBarView(
                        controller: _tabController,
                        children: _rigs
                            .map((r) => _RigLogTab(
                                  connectionService:
                                      widget.connectionService,
                                  rig: r,
                                ))
                            .toList(),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
