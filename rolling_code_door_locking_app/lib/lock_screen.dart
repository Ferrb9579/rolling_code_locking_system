// ----- START FILE: rolling_code_door_locking_app/lib/lock_screen.dart -----
import 'package:flutter/material.dart';
// Import the Device model from the new package
import 'package:bluetooth_classic/models/device.dart';
import 'package:get/get.dart';
import 'lock_controller.dart'; // Import the controller

class LockControlScreen extends StatelessWidget {
  const LockControlScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final LockController lockController = Get.find<LockController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('COTP Lock (Classic)'), // Updated title
        actions: [
          // Refresh / Load Paired Devices Button
          Obx(
            () => IconButton(
              icon: (lockController.isLoading.value && !lockController.isScanning.value && !lockController.isConnecting.value) ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.refresh),
              onPressed:
                  (lockController.isLoading.value || lockController.isConnecting.value || lockController.isConnected.value || lockController.isScanning.value)
                      ? null // Disable if busy
                      : lockController.getPairedDevices,
              tooltip: lockController.isConnected.value ? "Connected" : (lockController.isLoading.value || lockController.isConnecting.value || lockController.isScanning.value ? "Busy..." : "Load Paired Devices"),
            ),
          ),
          // Scan Button
          Obx(
            () => IconButton(
              icon:
                  lockController.isScanning.value
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) // Show progress only when scanning
                      : const Icon(Icons.bluetooth_searching),
              onPressed:
                  (lockController.isScanning.value || lockController.isLoading.value || lockController.isConnecting.value || lockController.isConnected.value)
                      ? null // Disable if busy
                      : lockController.startScan,
              tooltip: lockController.isScanning.value ? "Scanning..." : (lockController.isLoading.value || lockController.isConnecting.value || lockController.isConnected.value ? "Busy..." : "Scan for Devices"),
            ),
          ),
          // Stop Scan Button - Conditionally Visible
          Obx(() {
            if (lockController.isScanning.value) {
              return IconButton(
                icon: const Icon(Icons.stop_circle_outlined), // Stop Icon
                onPressed: lockController.stopScan, // Call stopScan method
                tooltip: 'Stop Scan',
              );
            } else {
              return const SizedBox.shrink(); // Render nothing when not scanning
            }
          }),
        ],
      ),
      body: Obx(
        () => Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status Display Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Simplified busy indicator - shows if any operation is in progress
                      if (lockController.isLoading.value || lockController.isConnecting.value || lockController.isScanning.value) Padding(padding: const EdgeInsets.only(bottom: 8.0), child: Row(children: [const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 8), Text(lockController.isConnecting.value ? "Connecting..." : (lockController.isScanning.value ? "Scanning..." : "Loading..."))])),
                      Text("Status: ${lockController.statusMessage.value}", style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text("Device: ${lockController.connectedDevice.value?.name ?? lockController.connectedDevice.value?.address ?? 'None'}"),
                      // Re-added Counter Display
                      const SizedBox(height: 4),
                      Text("Next Counter: ${lockController.syncCounter.value}"),
                      // Show last response only if not connected (avoids flicker during connection)
                      if (lockController.receivedData.value.isNotEmpty && !lockController.isConnected.value) ...[const SizedBox(height: 4), const Divider(), Text("Last Response: ${lockController.receivedData.value}")],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Action Button
              ElevatedButton.icon(
                icon: const Icon(Icons.lock_open_outlined),
                label: const Text('Toggle Lock'),
                // Disable if not connected OR if any operation is busy
                onPressed: (lockController.isConnected.value && !lockController.isLoading.value && !lockController.isConnecting.value && !lockController.isScanning.value) ? lockController.sendToggleCommand : null,
              ),
              const SizedBox(height: 10),

              // Disconnect Button
              if (lockController.isConnected.value || lockController.isConnecting.value)
                OutlinedButton(
                  // Disable if busy (e.g., during connection attempt)
                  onPressed: (lockController.isLoading.value || lockController.isScanning.value) ? null : lockController.disconnectDevice,
                  child: const Text('Disconnect'),
                ),

              // Device List Area
              if (!lockController.isConnected.value && !lockController.isConnecting.value) ...[
                const Divider(height: 30, thickness: 1),
                Text(lockController.isScanning.value ? "Scanning Results:" : "Paired Devices:", style: Theme.of(context).textTheme.titleSmall),
                Expanded(child: _buildDeviceList(lockController, context)),
              ] else if (lockController.isConnecting.value) ...[
                const Expanded(child: Center(child: Text("Connecting... Please Wait"))),
              ] else if (lockController.isConnected.value) ...[
                // Optionally show something here when connected, or just empty space
                const Spacer(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // Helper widget to build the device list (Unchanged logic, but reflects controller state changes)
  Widget _buildDeviceList(LockController lockController, BuildContext context) {
    return Obx(() {
      // Show loading indicator only if loading paired devices specifically
      if (lockController.isLoading.value && !lockController.isScanning.value && lockController.availableDevices.isEmpty) {
        return const Center(child: Text("Loading paired devices..."));
      }
      // Show scanning indicator only when scanning and no devices found yet
      else if (lockController.isScanning.value && lockController.availableDevices.isEmpty) {
        return const Center(child: Text("Scanning..."));
      }
      // Show message if not loading/scanning and list is empty
      else if (!lockController.isLoading.value && !lockController.isScanning.value && lockController.availableDevices.isEmpty) {
        return Center(child: Padding(padding: const EdgeInsets.all(16.0), child: Text("No devices found.\nLoad paired devices (refresh icon) or scan (search icon).\nEnsure '${lockController.targetDeviceName}' is paired in Bluetooth settings.", textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]))));
      }
      // Show the list
      else {
        return ListView.builder(
          itemCount: lockController.availableDevices.length,
          itemBuilder: (context, index) {
            final Device device = lockController.availableDevices[index];
            String deviceName = device.name ?? "Unknown Device";
            bool isTargetDevice = deviceName.contains(lockController.targetDeviceName);
            // Check against stored connected device *address* for robustness
            bool isCurrentlyConnected = device.address == lockController.connectedDevice.value?.address;

            return ListTile(
              title: Text(deviceName),
              subtitle: Text(device.address),
              leading: Icon(
                isCurrentlyConnected ? Icons.bluetooth_connected : (isTargetDevice ? Icons.memory : Icons.bluetooth), // Icon logic remains
                color: isCurrentlyConnected ? Colors.blue : (isTargetDevice ? Theme.of(context).primaryColor : null), // Color logic remains
              ),
              trailing: isCurrentlyConnected ? const Icon(Icons.check_circle, color: Colors.green) : null, // Trailing checkmark remains
              // Disable tap if any operation is busy
              onTap: (lockController.isLoading.value || lockController.isScanning.value || lockController.isConnecting.value || lockController.isConnected.value) ? null : () => lockController.connectToDevice(device),
              enabled: !(lockController.isLoading.value || lockController.isScanning.value || lockController.isConnecting.value || lockController.isConnected.value), // Explicitly enable/disable
            );
          },
        );
      }
    });
  }
}
// ----- END FILE: rolling_code_door_locking_app/lib/lock_screen.dart -----