import 'dart:async';
import 'dart:convert'; // Required for utf8, base64Encode
import 'dart:typed_data'; // Required for Uint8List, Endian, ByteData
import 'package:crypto/crypto.dart'; // Required for Hmac, sha256
import 'package:flutter_secure_storage/flutter_secure_storage.dart'; // Required for secure storage

// Updated import to use the bluetooth_classic package
import 'package:bluetooth_classic/bluetooth_classic.dart';
// Import the Device model specifically if needed, or use package prefix
import 'package:bluetooth_classic/models/device.dart';
// Removed incorrect import for DeviceStatus
// import 'package:bluetooth_classic/models/device_status.dart';

import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart'; // Keep for potential future use
import 'package:shared_preferences/shared_preferences.dart';

// --- Configuration ---
const String hc05DeviceName = "HC-05"; // Used to identify the target device in list
const String counterStorageKey = "rollingCodeCounter";
const String _secureStorageKeySecret = 'shared_secret_key'; // Key for flutter_secure_storage
// Standard Serial Port Profile (SPP) UUID
const String sppUUID = "00001101-0000-1000-8000-00805f9b34fb";

class LockController extends GetxController {
  // --- Secure Storage ---
  final _secureStorage = const FlutterSecureStorage();

  // --- Bluetooth Classic Specific (using bluetooth_classic package) ---
  final BluetoothClassic _bluetoothClassic = BluetoothClassic();
  StreamSubscription? _btStatusSubscription; // For connection status changes
  StreamSubscription? _btDataSubscription; // For incoming data
  String _receiveBuffer = ""; // Buffer for incoming data chunks

  // --- Reactive State Variables ---
  final isScanning = false.obs; // Specific state for scanning
  final isLoading = false.obs; // General loading state (permissions, device list)
  final isConnecting = false.obs; // Specific state for connection attempt
  final isConnected = false.obs;
  // isReadyToSend is implicitly true when isConnected is true with this package
  final statusMessage = "Initializing...".obs;
  final receivedData = "".obs; // Last complete message received
  // Use Device from bluetooth_classic package
  final availableDevices = RxList<Device>([]);
  final syncCounter = 0.obs; // Rolling code counter
  // Use Device from bluetooth_classic package
  final connectedDevice = Rx<Device?>(null);

  // --- Expose constant for UI ---
  String get targetDeviceName => hc05DeviceName;

  // --- Lifecycle Methods ---
  @override
  void onInit() {
    super.onInit();
    _init();
  }

  @override
  void onClose() {
    print("Disposing LockController...");
    // Cancel stream subscriptions
    _btStatusSubscription?.cancel();
    _btDataSubscription?.cancel();
    // Disconnect if connected
    if (isConnected.value) {
      _bluetoothClassic.disconnect();
    }
    super.onClose();
  }

  // --- Initialization ---
  Future<void> _init() async {
    isLoading.value = true;
    statusMessage.value = "Loading counter...";
    await _loadCounter();

    // Check if secret key exists
    final secret = await _getSharedSecret();
    if (secret == null || secret.isEmpty) {
      print("WARNING: Shared secret key is not set in secure storage!");
      statusMessage.value = "Setup Required: Secret Key Missing";
      // Potentially guide user to setup
    } else {
      print("Secure shared secret key found.");
    }

    statusMessage.value = "Initializing Bluetooth & Permissions...";
    try {
      // Request permissions using the bluetooth_classic package's method
      bool permissionsGranted = await _bluetoothClassic.initPermissions();
      if (!permissionsGranted) {
        statusMessage.value = "Bluetooth Permissions Required!";
        print("Bluetooth permissions not granted.");
        isLoading.value = false;
        Get.snackbar("Permission Required", "Bluetooth permissions are needed to operate the lock.");
        return; // Stop initialization if permissions fail
      }
      print("Bluetooth permissions granted.");
      statusMessage.value = "Permissions OK. Ready.";

      // Start listening to device status changes immediately
      _listenToDeviceStatus();
    } catch (e) {
      statusMessage.value = "Error initializing Bluetooth: $e";
      print("Error initializing Bluetooth: $e");
    } finally {
      isLoading.value = false;
    }
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
    syncCounter.value = newCounter; // Update reactive variable
    print("Saved sync counter: ${syncCounter.value}");
  }

  // --- Secret Key Persistence ---
  Future<String?> _getSharedSecret() async {
    try {
      return await _secureStorage.read(key: _secureStorageKeySecret);
    } catch (e) {
      print("Error reading secret key from secure storage: $e");
      return null;
    }
  }

  // --- Device Discovery (Paired Devices) ---
  Future<void> getPairedDevices() async {
    if (isLoading.value || isConnecting.value || isConnected.value || isScanning.value) return;

    isLoading.value = true;
    statusMessage.value = "Loading paired devices...";
    availableDevices.clear();

    try {
      List<Device> devices = await _bluetoothClassic.getPairedDevices();
      if (devices.isNotEmpty) {
        availableDevices.assignAll(devices);
        statusMessage.value = "Found ${devices.length} paired devices.";
      } else {
        statusMessage.value = "No paired devices found. Pair '$targetDeviceName' in settings.";
      }
    } catch (e) {
      print("Error getting paired devices: $e");
      statusMessage.value = "Error getting devices: $e";
      Get.snackbar("Error", "Could not get paired devices: $e");
    } finally {
      isLoading.value = false;
    }
  }

  // --- Device Scanning (Placeholder/Optional) ---
  Future<void> startScan() async {
    if (isScanning.value || isLoading.value || isConnecting.value || isConnected.value) return;

    isScanning.value = true;
    isLoading.value = true; // Use general loading indicator
    statusMessage.value = "Scanning for devices...";
    availableDevices.clear(); // Clear list before scanning

    try {
      // Stop previous scan if any
      await _bluetoothClassic.stopScan();
      // Start listening for discovered devices
      _bluetoothClassic.onDeviceDiscovered().listen((device) {
        // Add device if not already in the list (based on address)
        if (!availableDevices.any((d) => d.address == device.address)) {
          availableDevices.add(device);
        }
      });
      await _bluetoothClassic.startScan();

      // Stop scan after a timeout (e.g., 15 seconds)
      Future.delayed(const Duration(seconds: 15), stopScan);
    } catch (e) {
      print("Error starting scan: $e");
      statusMessage.value = "Error starting scan: $e";
      isScanning.value = false;
      isLoading.value = false;
    }
  }

  Future<void> stopScan() async {
    if (!isScanning.value) return;
    try {
      await _bluetoothClassic.stopScan();
      print("Scan stopped.");
      statusMessage.value = "Scan finished. Found ${availableDevices.length} devices.";
    } catch (e) {
      print("Error stopping scan: $e");
      statusMessage.value = "Error stopping scan: $e";
    } finally {
      isScanning.value = false;
      isLoading.value = false; // Stop general loading indicator
    }
  }

  // --- Connection ---
  // Use Device from bluetooth_classic
  Future<void> connectToDevice(Device device) async {
    if (isConnected.value || isConnecting.value) return;

    isConnecting.value = true;
    statusMessage.value = "Connecting to ${device.name ?? device.address}...";
    connectedDevice.value = device; // Optimistically set device
    availableDevices.clear(); // Hide the list while connecting

    try {
      print("Attempting connection to ${device.address} using SPP UUID: $sppUUID");
      // Connect using address and SPP UUID
      await _bluetoothClassic.connect(device.address, sppUUID);
      // Status is managed by the _listenToDeviceStatus handler
      // No need to set isConnected here, it's handled by the stream.
      print("Connection initiated to ${device.address}. Waiting for status update.");
      _listenToData(); // Start listening for data *after* initiating connection
    } catch (e) {
      print("Error initiating connection to ${device.address}: $e");
      statusMessage.value = "Error connecting: $e";
      _handleDisconnection(errorOccurred: true); // Reset state
      isConnecting.value = false; // Ensure connecting state is reset on error
    }
  }

  // --- Listeners Setup ---
  void _listenToDeviceStatus() {
    _btStatusSubscription?.cancel(); // Cancel previous listener if any
    // The stream emits integer status codes
    _btStatusSubscription = _bluetoothClassic.onDeviceStatusChanged().listen((int status) {
      print("Device Status Changed: $status");
      // Use integer constants for status check (assuming 0=Disc, 1=Conn, 2=Connecting, -1=Error)
      switch (status) {
        case 1: // Connected
          isConnected.value = true;
          isConnecting.value = false;
          if (connectedDevice.value != null) {
            statusMessage.value = "Connected to ${connectedDevice.value?.name ?? connectedDevice.value?.address}";
          } else {
            statusMessage.value = "Connected"; // Fallback
          }
          print("Device Connected.");
          break;
        case 2: // Connecting
          isConnected.value = false;
          isConnecting.value = true;
          statusMessage.value = "Connecting...";
          break;
        case 0: // Disconnected
          print("Device Disconnected (status stream).");
          _handleDisconnection();
          break;
        case -1: // Error
          print("Device Error occurred (status stream).");
          _handleDisconnection(errorOccurred: true);
          Get.snackbar("Connection Error", "An error occurred with the Bluetooth connection.");
          break;
        default:
          print("Unknown device status code: $status");
          break;
      }
    });
    print("Device status listener set up.");
  }

  void _listenToData() {
    _btDataSubscription?.cancel(); // Cancel previous data listener
    _receiveBuffer = ""; // Clear buffer before starting listener
    _btDataSubscription = _bluetoothClassic.onDeviceDataReceived().listen((Uint8List data) {
      // Append incoming data to buffer
      _receiveBuffer += utf8.decode(data, allowMalformed: true);
      // Process buffer line by line (assuming newline termination)
      while (_receiveBuffer.contains('\n')) {
        int newlineIndex = _receiveBuffer.indexOf('\n');
        String line = _receiveBuffer.substring(0, newlineIndex).trim(); // Get line and trim whitespace
        _receiveBuffer = _receiveBuffer.substring(newlineIndex + 1); // Remove processed line from buffer

        if (line.isNotEmpty) {
          receivedData.value = line; // Update reactive variable with the complete line
          print("Received Line: $line");
          // Update status based on response (assuming Arduino sends OK/ERROR)
          if (line.contains("OK")) {
            statusMessage.value = "Command Successful!";
          } else if (line.contains("ERROR:HMAC")) {
            statusMessage.value = "Command Failed: Invalid Code!";
          } else if (line.contains("ERROR:COUNTER")) {
            statusMessage.value = "Command Failed: Counter desync?";
          } else if (line.contains("ERROR")) {
            statusMessage.value = "Command Failed: ${line.split(':').last.trim()}";
          } else {
            statusMessage.value = "Received: $line";
          }
        }
      }
    });
    print("Device data listener set up.");
  }

  // --- Disconnection ---
  Future<void> disconnectDevice() async {
    if (!isConnected.value && !isConnecting.value) {
      print("Already disconnected or not connecting.");
      _handleDisconnection(); // Ensure state is clean
      return;
    }
    statusMessage.value = "Disconnecting...";
    try {
      await _bluetoothClassic.disconnect();
      print("Disconnect command sent.");
      // State update is handled by the _listenToDeviceStatus listener
    } catch (e) {
      print("Error sending disconnect command: $e");
      statusMessage.value = "Error disconnecting: $e";
      _handleDisconnection(errorOccurred: true); // Force state reset on error
    }
  }

  // --- Helper for Cleaning Up State on Disconnect/Error ---
  void _handleDisconnection({bool errorOccurred = false}) {
    // Update status message appropriately
    if (errorOccurred) {
      statusMessage.value = "Connection Error";
    } else if (isConnected.value || isConnecting.value) {
      // Only update if we were previously connected/connecting
      statusMessage.value = "Disconnected";
    }

    // Reset connection states
    isConnected.value = false;
    isConnecting.value = false;

    // Clear connected device info
    if (connectedDevice.value != null) {
      connectedDevice.value = null; // Clear the specific connected device reference
    }

    // Stop listening to data
    _btDataSubscription?.cancel();
    _btDataSubscription = null;
    _receiveBuffer = ""; // Clear buffer

    // Note: _btStatusSubscription should remain active to listen for future connections/errors

    print("State reset after disconnection/error.");
  }

  // --- Rolling Code Logic (HMAC-SHA256 - Unchanged) ---
  Future<String?> _generateHmacCode(int counter) async {
    final secretKeyString = await _getSharedSecret();
    if (secretKeyString == null || secretKeyString.isEmpty) {
      print("Error: Secret key not found or is empty in secure storage.");
      statusMessage.value = "Error: Secret Key Missing!";
      return null;
    }

    try {
      final keyBytes = utf8.encode(secretKeyString);
      final counterBytes = Uint8List(8)..buffer.asByteData().setInt64(0, counter, Endian.big);
      final hmacSha256 = Hmac(sha256, keyBytes);
      final digest = hmacSha256.convert(counterBytes);
      const int truncationLength = 8;
      if (digest.bytes.length < truncationLength) {
        print("Error: HMAC digest too short for truncation.");
        statusMessage.value = "Error: HMAC Generation Failed";
        return null;
      }
      final truncatedBytes = Uint8List.fromList(digest.bytes.sublist(0, truncationLength));
      return base64Encode(truncatedBytes);
    } catch (e) {
      print("Error during HMAC generation: $e");
      statusMessage.value = "Error: Code Generation Failed";
      return null;
    }
  }

  // --- Sending Command ---
  Future<void> sendToggleCommand() async {
    // Check connection status directly from reactive variable
    if (!isConnected.value) {
      statusMessage.value = "Not connected.";
      print("Cannot send command: Not connected.");
      Get.snackbar("Error", "Not connected to the lock device.");
      return;
    }

    int currentCounter = syncCounter.value;
    statusMessage.value = "Generating code for C:$currentCounter...";
    final hmacBase64 = await _generateHmacCode(currentCounter);

    if (hmacBase64 == null) {
      Get.snackbar("Error", "Failed to generate secure code. Check secret key setup.");
      return;
    }
    print("Generated HMAC for counter $currentCounter: $hmacBase64");

    int nextCounter = currentCounter + 1;
    await _saveCounter(nextCounter); // Save and update counter *before* sending

    String commandString = "$currentCounter:$hmacBase64\n";
    // Uint8List bytesToSend = Uint8List.fromList(utf8.encode(commandString)); // Not needed for write(String)

    try {
      statusMessage.value = "Sending C:$currentCounter H:$hmacBase64...";
      // Use write(String) for sending the command string
      await _bluetoothClassic.write(commandString);
      print("Sent string: $commandString");
      statusMessage.value = "Code sent. Waiting for response...";
    } catch (e) {
      print("Error sending command: $e");
      statusMessage.value = "Error sending command: $e";
      _handleDisconnection(errorOccurred: true); // Assume connection lost on write error
      Get.snackbar("Send Error", "Failed to send command. Connection lost?");
      // Consider counter rollback logic here if needed
    }
  }
}
