import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:openrig_core/openrig_core.dart';

import 'panels/qso_entry_panel.dart';
import 'panels/map_panel.dart';
import 'panels/solar_image_panel.dart';
import 'panels/stats_panel.dart';
import 'screens/spots_screen.dart' show SpotsScreen, DxClusterController;
import 'screens/devices_screen.dart';
import 'screens/log_screen.dart';
import 'services/connection_service.dart';
import 'services/settings_service.dart';
import 'widgets/preferences_dialog.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService();
  await settings.init();
  runApp(OpenRigConsoleApp(settings: settings));
}

class OpenRigConsoleApp extends StatelessWidget {
  final SettingsService settings;

  const OpenRigConsoleApp({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'openRig Console',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.green,
        useMaterial3: true,
      ),
      home: AppShell(settings: settings),
    );
  }
}

class AppShell extends StatefulWidget {
  final SettingsService settings;

  const AppShell({super.key, required this.settings});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with SingleTickerProviderStateMixin {
  late final ConnectionService _connectionService;
  late final TabController _tabController;
  final GlobalKey<StatsPanelState> _statsKey = GlobalKey<StatsPanelState>();
  final _qsoController = QsoEntryController();
  final _clusterController = DxClusterController();
  final _mapLocation = ValueNotifier<MapLocation?>(null);
  late double _topZoneHeight;
  static const double _topZoneMin = 160;
  static const double _topZoneMax = 600;

  late double _mapWidth;
  static const double _mapMin = 120;
  static const double _mapMax = 400;

  late double _statsWidth;
  static const double _statsMin = 100;
  static const double _statsMax = 320;

  SettingsService get _settings => widget.settings;

  @override
  void initState() {
    super.initState();
    _topZoneHeight = _settings.layoutTopZone;
    _mapWidth      = _settings.layoutMapWidth;
    _statsWidth    = _settings.layoutStatsWidth;
    _connectionService = ConnectionService(settings: _settings);
    _connectionService.addListener(_onConnectionChanged);
    _connectionService.startDiscovery();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _mapLocation.dispose();
    _connectionService.removeListener(_onConnectionChanged);
    _connectionService.dispose();
    super.dispose();
  }

  void _onConnectionChanged() {
    if (mounted) setState(() {});
  }

  Widget _dragDivider({required void Function(double dx) onDelta}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => setState(() => onDelta(d.delta.dx)),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: Container(
          width: 6,
          color: Colors.grey.shade800,
          child: Center(
            child: Container(
              width: 3,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.grey.shade600,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showPreferences() {
    showDialog<bool>(
      context: context,
      builder: (_) => PreferencesDialog(settings: _settings),
    ).then((saved) {
      if (saved == true && mounted) setState(() {});
    });
  }

  void _onQsoLogged() {
    _statsKey.currentState?.reload();
  }

  void _onSpotSelected(DxSpot spot) {
    _qsoController.loadSpot(spot);
  }

  @override
  Widget build(BuildContext context) {
    // Clamp top zone to available height so saved values don't overflow small windows.
    // Reserve ~280px for title bar (36), drag divider (6), tab bar (48), and min tab content (190).
    final maxTop = (MediaQuery.sizeOf(context).height - 280).clamp(_topZoneMin, _topZoneMax);
    final effectiveTopZone = _topZoneHeight.clamp(_topZoneMin, maxTop);

    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          label: 'openRig',
          menus: [
            PlatformMenuItem(
              label: 'Preferences...',
              shortcut: const SingleActivator(
                  LogicalKeyboardKey.comma, meta: true),
              onSelected: _showPreferences,
            ),
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(
                label: 'Quit openRig',
                shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyQ, meta: true),
                onSelected: () => exit(0),
              ),
            ]),
          ],
        ),
      ],
      child: Scaffold(
      body: Column(
        children: [
          // Title bar
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: Colors.grey.shade900,
            child: Row(
              children: [
                Text(
                  'openRig',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.green.shade400,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: _showPreferences,
                  tooltip: 'Preferences',
                  icon: const Icon(Icons.settings, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),

          // Top zone: QSO Entry | Map | Stats
          SizedBox(
            height: effectiveTopZone,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // QSO Entry — left (flexible)
                Expanded(
                  child: QsoEntryPanel(
                    connectionService: _connectionService,
                    settings: _settings,
                    onQsoLogged: _onQsoLogged,
                    controller: _qsoController,
                    dxClusterController: _clusterController,
                    onLocationChanged: (lat, lon, call) {
                      _mapLocation.value = MapLocation(
                          lat: lat, lon: lon, callsign: call);
                    },
                  ),
                ),

                // Draggable divider before Map
                _dragDivider(onDelta: (dx) {
                  setState(() {
                    _mapWidth = (_mapWidth - dx).clamp(_mapMin, _mapMax);
                  });
                  _settings.setLayoutMapWidth(_mapWidth);
                }),

                // Map panel with solar image above
                SizedBox(
                  width: _mapWidth,
                  child: Column(
                    children: [
                      const SolarImagePanel(),
                      Expanded(child: MapPanel(location: _mapLocation)),
                    ],
                  ),
                ),

                // Draggable divider before Stats
                _dragDivider(onDelta: (dx) {
                  setState(() {
                    _mapWidth = (_mapWidth + dx).clamp(_mapMin, _mapMax);
                    _statsWidth = (_statsWidth - dx).clamp(_statsMin, _statsMax);
                  });
                  _settings.setLayoutMapWidth(_mapWidth);
                  _settings.setLayoutStatsWidth(_statsWidth);
                }),

                // Stats — right
                SizedBox(
                  width: _statsWidth,
                  child: StatsPanel(
                    key: _statsKey,
                    logPath: _settings.logPath,
                  ),
                ),
              ],
            ),
          ),

          // Draggable divider
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (details) {
              setState(() {
                _topZoneHeight = (_topZoneHeight + details.delta.dy)
                    .clamp(_topZoneMin, maxTop);
              });
              _settings.setLayoutTopZone(_topZoneHeight);
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpDown,
              child: Container(
                height: 6,
                color: Colors.grey.shade800,
                child: Center(
                  child: Container(
                    width: 40,
                    height: 3,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade600,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Tab bar
          Container(
            color: Colors.grey.shade900,
            child: TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'Log'),
                Tab(text: 'Spots'),
                Tab(text: 'Devices'),
              ],
            ),
          ),

          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                LogScreen(logPath: _settings.logPath, settings: _settings),
                SpotsScreen(
                  settings: _settings,
                  onSpotSelected: _onSpotSelected,
                  controller: _clusterController,
                  onLocationOverride: (lat, lon, label) {
                    _mapLocation.value =
                        MapLocation(lat: lat, lon: lon, callsign: label);
                  },
                ),
                DevicesScreen(
                  connectionService: _connectionService,
                  settings: _settings,
                  qsoController: _qsoController,
                  tabController: _tabController,
                ),
              ],
            ),
          ),
        ],
      ),
      ), // Scaffold
    ); // PlatformMenuBar
  }
}
