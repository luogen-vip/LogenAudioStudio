import 'package:flutter/material.dart';

import 'pages/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LogenApp());
}

class LogenApp extends StatelessWidget {
  const LogenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '罗根音频工作室',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF22D3EE),
          brightness: Brightness.dark,
          surface: const Color(0xFF0B1015),
        ),
        scaffoldBackgroundColor: const Color(0xFF080C11),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B1015),
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF121A22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0,
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: Color(0xFF22D3EE),
          thumbColor: Color(0xFF22D3EE),
          overlayColor: Color(0x3322D3EE),
        ),
      ),
      home: const HomePage(),
    );
  }
}
