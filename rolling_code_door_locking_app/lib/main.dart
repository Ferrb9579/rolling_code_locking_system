import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'lock_controller.dart'; // Import the controller

// Run this before runApp to initialize GetX and the controller
void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // Needed for plugins and async ops before runApp
  Get.put(LockController()); // Initialize and register the controller globally
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Use GetMaterialApp instead of MaterialApp
    return GetMaterialApp(
      title: 'Rolling Code Lock (GetX)',
      theme: ThemeData(
        primarySwatch: Colors.teal, // Changed theme color for fun
        useMaterial3: true,
      ),
      home: const LockControlScreen(),
    );
  }
}

class LockControlScreen extends StatelessWidget {
  const LockControlScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Find the controller instance managed by GetX
    final LockController lockController = Get.find<LockController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rolling Code Lock Control'),
        actions: [
          // Use Obx to react to isScanning changes
          Obx(
            () => IconButton(
              icon: Icon(lockController.isScanning.value ? Icons.bluetooth_searching : Icons.bluetooth),
              // Disable scan button when connected
              onPressed:
                  lockController.isConnected.value
                      ? null
                      : () {
                        if (lockController.isScanning.value) {
                          lockController.stopScan();
                        } else {
                          lockController.startScan();
                        }
                      },
              tooltip: lockController.isConnected.value ? "Connected" : (lockController.isScanning.value ? "Stop Scan" : "Start Scan"),
            ),
          ),
        ],
      ),
      // Use Obx for the main body that reacts to multiple state changes
      body: Obx(
        () => Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status Display Card
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Status: ${lockController.statusMessage.value}", style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text("Device: ${lockController.connectedDevice.value?.platformName ?? 'None'}"),
                      const SizedBox(height: 4),
                      Text("Next Counter: ${lockController.syncCounter.value}"),
                      if (lockController.receivedData.value.isNotEmpty) ...[const SizedBox(height: 4), Text("Last Response: ${lockController.receivedData.value}")],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Action Button
              ElevatedButton.icon(
                icon: const Icon(Icons.lock_open_outlined), // Or Icons.lock_outline
                label: const Text('Toggle Lock'),
                style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 15), textStyle: const TextStyle(fontSize: 18), backgroundColor: Colors.teal, foregroundColor: Colors.white),
                // Enable button only when connected and ready to send
                onPressed:
                    lockController.isReadyToSend.value
                        ? lockController
                            .sendToggleCommand // Direct method reference
                        : null,
              ),
              const SizedBox(height: 10),

              // Disconnect Button - Shown only when connected
              if (lockController.isConnected.value)
                OutlinedButton(
                  onPressed: lockController.disconnectDevice, // Direct method reference
                  child: const Text('Disconnect'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.red, side: const BorderSide(color: Colors.red)),
                ),
              const Divider(height: 30, thickness: 1),

              // Scan Results (only show if not connected)
              if (!lockController.isConnected.value) ...[Text("Found Devices:", style: Theme.of(context).textTheme.titleSmall), Expanded(child: _buildScanResultList(lockController))],
            ],
          ),
        ),
      ),
    );
  }

  // Helper widget to build the scan result list
  Widget _buildScanResultList(LockController lockController) {
    // Use Obx again here specifically for scan results and scanning state
    return Obx(() {
      if (lockController.isScanning.value && lockController.scanResults.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      } else if (!lockController.isScanning.value && lockController.scanResults.isEmpty) {
        return const Center(child: Text("No devices found. Press scan button."));
      } else {
        return ListView.builder(
          itemCount: lockController.scanResults.length,
          itemBuilder: (context, index) {
            final result = lockController.scanResults[index];
            String deviceName = result.device.platformName.isNotEmpty ? result.device.platformName : (result.advertisementData.advName.isNotEmpty ? result.advertisementData.advName : "Unknown Device");
            bool isHC05 = deviceName.contains(hc05DeviceName); // Simple check

            return ListTile(
              title: Text(deviceName),
              subtitle: Text(result.device.remoteId.toString()),
              leading: isHC05 ? const Icon(Icons.bluetooth_audio, color: Colors.green) : const Icon(Icons.devices), // Different icon
              trailing: Text("RSSI: ${result.rssi}"),
              onTap: () => lockController.connectToDevice(result.device),
              // Enable tap only if not currently connected
              enabled: !lockController.isConnected.value,
            );
          },
        );
      }
    });
  }
}
