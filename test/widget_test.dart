import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openrig_console/main.dart';
import 'package:openrig_console/services/settings_service.dart';

void main() {
  testWidgets('App shell renders with new layout', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.init();

    await tester.pumpWidget(OpenRigConsoleApp(settings: settings));
    // Use pump instead of pumpAndSettle — polling timers never settle.
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('openRig'), findsOneWidget);
    // Tab bar labels
    expect(find.text('Log'), findsOneWidget);
    expect(find.text('Spots'), findsOneWidget);
    expect(find.text('Bandmap'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);
    // Rig panel elements
    expect(find.text('PTT'), findsOneWidget);
    expect(find.text('Add Rig'), findsOneWidget);
    // QSO entry elements
    expect(find.text('Callsign'), findsOneWidget);
    expect(find.text('Log QSO'), findsOneWidget);
    // Stats panel
    expect(find.text('Log Stats'), findsOneWidget);
  });
}
