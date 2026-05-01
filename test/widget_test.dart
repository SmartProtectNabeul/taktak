import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taktak/app_state.dart';
import 'package:taktak/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(SharedPreferences.resetStatic);

  testWidgets('dashboard shell renders after bootstrap without BLE radios', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) {
          final s = AppState(scaffoldMessengerKey: scaffoldMessengerKey);
          Future.microtask(
            () => s.bootstrap(startBleRadiosWhenOffline: false),
          );
          return s;
        },
        child: TakTakApp(scaffoldMessengerKey: scaffoldMessengerKey),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('TakTak'), findsOneWidget);
    expect(find.textContaining('SIGNALLING'), findsOneWidget);
  });
}
