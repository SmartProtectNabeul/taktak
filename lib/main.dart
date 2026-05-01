import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'screens/dashboard_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WebRTC.initialize(options: {});

  final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  runApp(
    ChangeNotifierProvider(
      lazy: false,
      create: (_) {
        final state = AppState(scaffoldMessengerKey: scaffoldMessengerKey);
        Future.microtask(() => state.bootstrap());
        return state;
      },
      child: TakTakApp(scaffoldMessengerKey: scaffoldMessengerKey),
    ),
  );
}

class TakTakApp extends StatelessWidget {
  const TakTakApp({super.key, required this.scaffoldMessengerKey});

  final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      title: 'TakTak',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0C10),
        primaryColor: const Color(0xFF66FCF1),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF66FCF1),
          secondary: Color(0xFF45A29E),
          surface: Color(0xFF1F2833),
        ),
        fontFamily: 'Inter',
      ),
      home: const DashboardScreen(),
    );
  }
}
