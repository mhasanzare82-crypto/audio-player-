// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AudioPlayerApp());
}

class AudioPlayerApp extends StatefulWidget {
  const AudioPlayerApp({super.key});

  @override
  State<AudioPlayerApp> createState() => _AudioPlayerAppState();
}

class _AudioPlayerAppState extends State<AudioPlayerApp> {
  bool _isDark = true;
  String _selectedTheme = 'teal';

  static const Map<String, Color> _themeSeeds = {
    'teal': Color(0xFF16A6A0),
    'blue': Color(0xFF2878D0),
    'purple': Color(0xFF8764D8),
    'green': Color(0xFF39865A),
    'amber': Color(0xFFD28A22),
    'rose': Color(0xFFC65D78),
    'slate': Color(0xFF718096),
  };

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _isDark = prefs.getBool('is_dark_theme') ?? true;
      _selectedTheme = _themeSeeds.containsKey(
        prefs.getString('selected_theme_v1'),
      )
          ? prefs.getString('selected_theme_v1')!
          : 'teal';
    });
  }

  Future<void> _toggleTheme() async {
    final next = !_isDark;
    setState(() => _isDark = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_dark_theme', next);
  }

  Future<void> _selectTheme(String themeId) async {
    if (!_themeSeeds.containsKey(themeId)) return;
    setState(() => _selectedTheme = themeId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_theme_v1', themeId);
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _themeSeeds[_selectedTheme]!,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? Color.alphaBlend(
              const Color(0xFF101820).withValues(alpha: 0.88),
              scheme.surface,
            )
          : scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: brightness == Brightness.dark
            ? scheme.surface
            : scheme.surface,
        centerTitle: true,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: brightness == Brightness.dark
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'پلیر صوتی',
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: _isDark ? ThemeMode.dark : ThemeMode.light,
      home: HomeScreen(
        isDark: _isDark,
        themeId: _selectedTheme,
        onToggleTheme: _toggleTheme,
        onSelectTheme: _selectTheme,
      ),
    );
  }
}
