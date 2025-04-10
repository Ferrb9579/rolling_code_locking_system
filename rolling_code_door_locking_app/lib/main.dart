import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'lock_controller.dart'; // Import the controller
import 'lock_screen.dart'; // Import the screen

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // Needed for plugins
  // Initialize and register the controller globally *before* runApp
  Get.put(LockController());
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Use GetMaterialApp instead of MaterialApp
    return GetMaterialApp(
      title: 'Rolling Code Lock (Classic)',
      theme: ThemeData(
        primarySwatch: Colors.indigo, // Changed theme color
        useMaterial3: true,
        // Optional: Define consistent button styling
        elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15), textStyle: const TextStyle(fontSize: 18))),
        outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(foregroundColor: Colors.red, side: const BorderSide(color: Colors.red))),
        cardTheme: CardTheme(elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
      ),
      home: const LockControlScreen(), // Your main screen
    );
  }
}
