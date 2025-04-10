import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- Configuration --- (Same as before)
const int sharedSecretKey = 123456789; // !! CHANGE THIS !!
const String hc05DeviceName = "HC-05";
const String counterStorageKey = "rollingCodeCounter";

class LockController extends GetxController {
  // --- Reactive State Variables ---
  final isScanning = false.obs;
  final isConnected = false.obs;
  final isReadyToSend = false.obs; // Flag indicating if write characteristic is found
  final statusMessage = "Disconnected".obs;
  final receivedData = "".obs;
  final scanResults = RxList<ScanResult>([]);
  final syncCounter = 0.obs; // Rolling code counter
  final connectedDevice = Rx<BluetoothDevice?>(null);

  // --- Internal Variables ---
  BluetoothCharacteristic? _writeCharacteristic;
  StreamSubscription<List<int>>? _valueSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<bool>? _isScanningSubscription;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;


  // --- Lifecycle Methods ---
  @override
  void onInit() {
    super.onInit();
    _init();
  }

  @override
  void onClose() {
    print("Disposing LockController...");
    _isScanningSubscription?.cancel();
    _scanResultsSubscription?.cancel();
    _connectionSubscription?.cancel();
    _valueSubscription?.cancel();
    // Only stop scan if it's actually running
    if (isScanning.value) {
       FlutterBluePlus.stopScan();
    }
    // Disconnect if connected
    connectedDevice.value?.disconnect();
    super.onClose();
  }

  // --- Initialization ---
  Future<void> _init() async {
    await _loadCounter();
    _setupBluetoothListeners();
    // Don't auto-scan, let user initiate. Check permissions on first scan attempt.
    statusMessage.value = "Ready. Press Scan.";
  }

  // --- Bluetooth Listeners Setup ---
  void _setupBluetoothListeners() {
    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
      // Filter results - you might want more specific filtering
       scanResults.assignAll(results
           .where((r) => r.device.platformName.isNotEmpty || r.advertisementData.advName.isNotEmpty)
           .toList());
    });

    _isScanningSubscription = FlutterBluePlus.isScanning.listen((scanning) {
      isScanning.value = scanning;
       if (!scanning && statusMessage.value == "Scanning for devices...") {
          statusMessage.value = "Scan finished.";
       }
    });
  }

  // --- Counter Persistence ---
  Future<void> _loadCounter() async {
    final prefs = await SharedPreferences.getInstance();
    syncCounter.value = prefs.getInt(counterStorageKey) ?? 0;
    print("Loaded sync counter: ${syncCounter.value}");
  }

  Future<void> _saveCounter(int newCounter) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(counterStorageKey, newCounter);
    syncCounter.value = newCounter;
    print("Saved sync counter: ${syncCounter.value}");
  }

  // --- Permissions ---
  Future<bool> _checkAndRequestPermissions() async {
    print("Checking permissions...");
    Map<Permission, PermissionStatus> statuses = await [
      Permission.locationWhenInUse,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    if (statuses[Permission.locationWhenInUse]!.isGranted &&
        statuses[Permission.bluetoothScan]!.isGranted &&
        statuses[Permission.bluetoothConnect]!.isGranted) {
      print("Permissions granted.");
      return true;
    } else {
      print("Permissions denied.");
      statusMessage.value = "Bluetooth/Location permissions required.";
      // Optionally show a GetX Snackbar or Dialog
      Get.snackbar(
        "Permission Required",
        "Bluetooth Scanning, Connection, and Location permissions are needed to use the lock.",
        snackPosition: SnackPosition.BOTTOM,
      );
      return false;
    }
  }

  // --- Scanning ---
  Future<void> startScan() async {
     if (isConnected.value || isScanning.value) return; // Don't scan if already connected or scanning

     bool permissionsOk = await _checkAndRequestPermissions();
     if (!permissionsOk) return;

     scanResults.clear(); // Clear previous results
     try {
        statusMessage.value = "Scanning for devices...";
        // Start scanning - adjust timeout as needed
        await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
        // Status will update via the isScanning listener
     } catch (e) {
        print("Error starting scan: $e");
        statusMessage.value = "Error starting scan: $e";
        isScanning.value = false; // Ensure scanning state is reset on error
     }
  }

  Future<void> stopScan() async {
    if (isScanning.value) {
       await FlutterBluePlus.stopScan();
       // Status will update via the isScanning listener
       print("Scan stopped manually.");
    }
  }

  // --- Connection ---
  Future<void> connectToDevice(BluetoothDevice device) async {
    if (isConnected.value) return; // Already connected
    await stopScan(); // Stop scanning before connecting

    statusMessage.value = "Connecting to ${device.platformName}...";
    connectedDevice.value = device; // Optimistically set device

    try {
      _connectionSubscription = device.connectionState.listen((state) async {
         print("Connection state changed: $state");
         isConnected.value = (state == BluetoothConnectionState.connected);
         if (isConnected.value) {
            statusMessage.value = "Connected to ${device.platformName}";
            print(statusMessage.value);
            await _discoverServices(device);
         } else {
            // Handle disconnection
            statusMessage.value = "Disconnected";
            connectedDevice.value = null;
            _writeCharacteristic = null;
            isReadyToSend.value = false;
            _valueSubscription?.cancel(); // Clean up listener
            _connectionSubscription?.cancel(); // Clean up this listener too
            print(statusMessage.value);
         }
      });

      await device.connect(autoConnect: false); // Connect!
      // On successful connection, the listener above handles the state update.

    } catch (e) {
      print("Error connecting to ${device.platformName}: $e");
      statusMessage.value = "Error connecting: $e";
      isConnected.value = false;
      isReadyToSend.value = false;
      connectedDevice.value = null; // Reset device on error
      _connectionSubscription?.cancel(); // Clean up listener on error
    }
  }

  Future<void> disconnectDevice() async {
    await _connectionSubscription?.cancel(); // Cancel state listener first
    _connectionSubscription = null;
    await _valueSubscription?.cancel();
    _valueSubscription = null;
    isReadyToSend.value = false; // No longer ready

    if (connectedDevice.value != null) {
       await connectedDevice.value!.disconnect(); // Trigger disconnection
       print("Disconnect initiated.");
       // The connectionState listener should handle the state updates (isConnected=false, etc.)
    } else {
       print("Already disconnected or no device selected.");
       // Ensure state is consistent if disconnect is called unexpectedly
       isConnected.value = false;
       statusMessage.value = "Disconnected";
       _writeCharacteristic = null;
    }
  }

  // --- Services and Characteristics ---
  Future<void> _discoverServices(BluetoothDevice device) async {
    try {
      statusMessage.value = "Discovering services...";
      List<BluetoothService> services = await device.discoverServices();
      statusMessage.value = "Found ${services.length} services.";
      print(statusMessage.value);

      _writeCharacteristic = null;
      BluetoothCharacteristic? notifyCharacteristic;

      // Find the Serial Port Profile (SPP) characteristics
      for (BluetoothService service in services) {
        print(" Service UUID: ${service.uuid.toString()}");
        for (BluetoothCharacteristic characteristic in service.characteristics) {
          print("  Characteristic UUID: ${characteristic.uuid.toString()}");
          print("   Properties: Write=${characteristic.properties.write}, Read=${characteristic.properties.read}, Notify=${characteristic.properties.notify}");
          if (characteristic.properties.writeWithoutResponse || characteristic.properties.write) { // Prefer writeWithoutResponse for SPP
             print("   Found Writable Characteristic: ${characteristic.uuid}");
             _writeCharacteristic = characteristic;
          }
          if (characteristic.properties.notify) {
             print("   Found Notify Characteristic: ${characteristic.uuid}");
             notifyCharacteristic = characteristic;
          }
        }
      }

      if (_writeCharacteristic != null) {
        statusMessage.value = "Ready to send commands.";
        isReadyToSend.value = true; // Set the ready flag!
        print("Write Characteristic found and stored.");

        if (notifyCharacteristic != null) {
           await _setupNotifications(notifyCharacteristic);
           statusMessage.value += " Listening for responses.";
        } else {
           print("No suitable Notify characteristic found.");
        }
      } else {
        statusMessage.value = "Error: Write characteristic not found!";
        isReadyToSend.value = false; // Not ready
        print(statusMessage.value);
        // Optionally disconnect: await disconnectDevice();
      }
    } catch (e) {
      print("Error discovering services: $e");
      statusMessage.value = "Error discovering services: $e";
      isReadyToSend.value = false; // Not ready on error
    }
  }

  Future<void> _setupNotifications(BluetoothCharacteristic characteristic) async {
     try {
        await characteristic.setNotifyValue(true);
        _valueSubscription = characteristic.lastValueStream.listen((value) {
          receivedData.value = utf8.decode(value); // Decode bytes to string
          print("Received from Arduino: ${receivedData.value}");
          if (receivedData.value.contains("OK")) {
              statusMessage.value = "Command Successful!";
          } else if (receivedData.value.contains("ERROR")) {
              statusMessage.value = "Command Failed: ${receivedData.value.split(':').last}";
              // Consider re-sync logic here if needed
          } else {
             statusMessage.value = "Received: ${receivedData.value}";
          }
        }, onError: (error) {
           print("Notification stream error: $error");
           statusMessage.value = "Notification Error: $error";
           // Maybe attempt to re-setup or handle disconnection
        });
        print("Notifications enabled for ${characteristic.uuid}");
     } catch (e) {
        print("Error setting up notifications: $e");
        statusMessage.value = "Error setting up notifications: $e";
     }
  }

  // --- Rolling Code Logic ---
  int _generateCode(int counter) {
    final random = Random(sharedSecretKey + counter);
    return random.nextInt(900000) + 100000; // 6-digit code
  }

  Future<void> sendToggleCommand() async {
    if (_writeCharacteristic == null || !isConnected.value || !isReadyToSend.value) {
      statusMessage.value = "Not connected or not ready.";
      print("Cannot send command: Not connected or characteristic not found/ready.");
      return;
    }

    // 1. Generate code
    int codeToSend = _generateCode(syncCounter.value);
    print("Generated code for counter ${syncCounter.value}: $codeToSend");

    // 2. Prepare data
    String commandString = "$codeToSend\n";
    List<int> bytesToSend = utf8.encode(commandString);

    // 3. Increment and save counter *before* sending
    int nextCounter = syncCounter.value + 1;
    await _saveCounter(nextCounter); // Saves and updates reactive syncCounter

    // 4. Send data
    try {
      statusMessage.value = "Sending code: $codeToSend...";
      // Use writeWithoutResponse if available and preferred for SPP/HC-05
      await _writeCharacteristic!.write(bytesToSend, withoutResponse: _writeCharacteristic!.properties.writeWithoutResponse);
      print("Sent bytes: $bytesToSend (Code: $codeToSend)");
      statusMessage.value = "Code sent. Waiting for response...";
      // Response handled by notification listener
    } catch (e) {
      print("Error sending command: $e");
      statusMessage.value = "Error sending command: $e";
      // !! Consider robust error handling for de-sync issues !!
    }
  }
}