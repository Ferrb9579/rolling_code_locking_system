// ----- START FILE: rolling_code_door_locking_app/lib/lock_controller.dart -----
import 'dart:async';
import 'dart:convert'; // Required for utf8 encoding/decoding
import 'dart:typed_data'; // Required for Uint8List
// import 'dart:math'; // No longer using dart:math for code generation

// Required for COTP implementation - crypto might still be needed if other crypto functions are used, keeping for now.
// import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Re-adding OTP package for standard HOTP generation
import 'package:otp/otp.dart';
// No longer using flutter_secure_storage for the secret key
// import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Use bluetooth_classic package
import 'package:bluetooth_classic/bluetooth_classic.dart';
import 'package:bluetooth_classic/models/device.dart';

import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';

// --- Configuration ---
const String hc05DeviceName = "HC-05"; // Used to identify the target device in list
const String counterStorageKey = "rollingCodeCounter"; // Re-added
// const String _secureStorageKeySecret = 'shared_secret_key'; // No longer using secure storage for secret
// Standard Serial Port Profile (SPP) UUID
const String sppUUID = "00001101-0000-1000-8000-00805f9b34fb";
// OTP Configuration (must match Arduino)
const int otpDigits = 6; // Number of digits for the code

class LockController extends GetxController {
  // --- Hardcoded Secret Key ---
  // !! IMPORTANT: This key MUST exactly match the `SHARED_SECRET_KEY_STR` content in the Arduino sketch !!
  // The `otp` package uses it as a string, SimpleHOTP needs it as bytes, ensure content matches.
  static const String _hardcodedSharedSecretString = "123456789";

  // --- Secure Storage ---
  // final _secureStorage = const FlutterSecureStorage(); // No longer using secure storage for secret

  // --- Bluetooth Classic Specific (using bluetooth_classic package) ---
  final BluetoothClassic _bluetoothClassic = BluetoothClassic();
  StreamSubscription? _btStatusSubscription;
  StreamSubscription? _btDataSubscription;
  StreamSubscription? _discoverySubscription; // Discovery listener is now persistent
  String _receiveBuffer = "";

  // --- Reactive State Variables ---
  final isScanning = false.obs;
  final isLoading = false.obs;
  final isConnecting = false.obs;
  final isConnected = false.obs;
  final statusMessage = "Initializing...".obs;
  final receivedData = "".obs;
  final availableDevices = RxList<Device>([]);
  final syncCounter = 0.obs; // Re-added rolling code counter
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
    _btStatusSubscription?.cancel();
    _btDataSubscription?.cancel();
    _discoverySubscription?.cancel(); // Cancel persistent discovery subscription
    if (isConnected.value || isConnecting.value) {
      // Check if actually connected/connecting before native disconnect
      try {
        _bluetoothClassic.disconnect(); // Attempt disconnect on close if needed
      } catch (e) {
        print("Error during disconnect on close: $e");
      }
    }
    super.onClose();
  }

  // --- Initialization (Now initializes discovery listener) ---
  Future<void> _init() async {
    isLoading.value = true;
    statusMessage.value = "Loading counter..."; // Re-added
    await _loadCounter(); // Re-added

    // Indicate that the hardcoded key is being used
    print("Using hardcoded shared secret key string: $_hardcodedSharedSecretString");
    // Basic validation of the hardcoded key format during init (optional, good practice)
    if (_hardcodedSharedSecretString.isEmpty) {
      print("CRITICAL ERROR: Hardcoded secret key string is empty!");
      statusMessage.value = "FATAL: Invalid Hardcoded Key";
      isLoading.value = false;
      return;
    }

    statusMessage.value = "Initializing Bluetooth & Permissions...";
    try {
      bool permissionsGranted = await _bluetoothClassic.initPermissions();
      if (!permissionsGranted) {
        statusMessage.value = "Bluetooth Permissions Required!";
        print("Bluetooth permissions not granted.");
        isLoading.value = false;
        Get.snackbar("Permission Required", "Bluetooth permissions are needed.");
        return;
      }
      print("Bluetooth permissions granted.");
      statusMessage.value = "Permissions OK. Setting up listeners...";
      _listenToDeviceStatus();

      // Initialize persistent discovery listener once and pause it
      print("Initializing persistent discovery listener...");
      _discoverySubscription = _bluetoothClassic.onDeviceDiscovered().listen(
        (device) {
          // Only process if scanning is actually active
          if (!isScanning.value) return;
          if (!availableDevices.any((d) => d.address == device.address)) {
            availableDevices.add(device);
            print("Discovered: ${device.name ?? device.address}");
          }
        },
        onError: (e) {
          print("Error in discovery stream: $e");
          if (isScanning.value) {
            // Handle error only if scanning was active
            statusMessage.value = "Scan Error: $e";
            stopScan(); // Attempt to stop scan on error
          }
        },
        onDone: () {
          // Stream closed unexpectedly
          print("Discovery stream closed (onDone).");
          _discoverySubscription = null; // Nullify subscription ref
          if (isScanning.value) {
            statusMessage.value = "Scan ended unexpectedly.";
            stopScan(); // Ensure state is cleaned up
          }
        },
        cancelOnError: false,
      ); // Keep listening after errors

      _discoverySubscription?.pause(); // Start in paused state
      print("Discovery listener initialized and paused.");
      statusMessage.value = "Ready."; // Update status after setup
    } catch (e) {
      statusMessage.value = "Error initializing Bluetooth: $e";
      print("Error initializing Bluetooth: $e");
      _discoverySubscription?.cancel(); // Ensure cleanup on init error
      _discoverySubscription = null;
    } finally {
      isLoading.value = false;
    }
  }

  // --- Counter Persistence (Re-added) ---
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

  // --- Secret Key Persistence (Removed) ---
  // Future<String?> _getSharedSecret() async { ... } // Removed

  // --- Device Discovery (Paired Devices - Unchanged) ---
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

  // --- Device Scanning (Uses pause/resume) ---
  Future<void> startScan() async {
    if (isScanning.value || isLoading.value || isConnecting.value || isConnected.value) return;

    // Check if listener was initialized
    if (_discoverySubscription == null) {
      print("Error: Discovery listener not initialized!");
      statusMessage.value = "Error: Cannot start scan. Restart app?";
      return; // Prevent scan if listener isn't ready
    }

    isScanning.value = true;
    isLoading.value = true; // Keep isLoading true during scan
    statusMessage.value = "Scanning for devices...";
    availableDevices.clear(); // Clear previous results

    try {
      // Ensure scan is stopped natively before starting (belt-and-suspenders)
      await _bluetoothClassic.stopScan();
      print("Ensured native scan is stopped before starting.");

      // Resume the persistent listener
      _discoverySubscription?.resume();
      print("Discovery listener resumed.");

      // Start the native scan
      await _bluetoothClassic.startScan();
      print("Native scan started.");

      // Stop scan automatically after a timeout
      Future.delayed(const Duration(seconds: 15), () {
        // Only stop if still scanning (might have been stopped manually)
        if (isScanning.value) {
          print("Scan timeout reached.");
          stopScan();
        }
      });
    } catch (e) {
      print("Error starting scan: $e");
      statusMessage.value = "Error starting scan: $e";
      // If error occurs during start, ensure we pause the listener and reset state
      _discoverySubscription?.pause();
      isScanning.value = false;
      isLoading.value = false; // Reset isLoading on error
    }
    // isLoading remains true while scanning
  }

  Future<void> stopScan() async {
    // Check if scanning or if listener is potentially active but unpaused
    if (!isScanning.value && (_discoverySubscription == null || _discoverySubscription!.isPaused)) {
      print("Scan is not active or listener is already paused.");
      // Ensure state is consistent
      isScanning.value = false;
      isLoading.value = false;
      return;
    }

    print("Stopping scan...");
    try {
      // Pause the persistent listener
      _discoverySubscription?.pause();
      print("Discovery listener paused.");

      // Stop the native scan
      await _bluetoothClassic.stopScan();
      print("Native scan stopped.");
      // Update status only if scan was actually running
      if (isScanning.value) {
        statusMessage.value = "Scan stopped. Found ${availableDevices.length} devices.";
      }
    } catch (e) {
      print("Error stopping scan: $e");
      statusMessage.value = "Error stopping scan: $e";
    } finally {
      // Ensure state is always reset after attempting to stop
      isScanning.value = false;
      isLoading.value = false; // Reset isLoading when scan stops
      print("Scan state variables reset.");
    }
  }

  // --- Connection (Updated - Simplified Error Handling) ---
  Future<void> connectToDevice(Device device) async {
    if (isConnected.value || isConnecting.value) return;

    // Ensure scanning is stopped before attempting connection
    if (isScanning.value) {
      print("Scan is active, stopping before connecting...");
      await stopScan(); // stopScan now pauses the listener
    }

    isConnecting.value = true;
    statusMessage.value = "Connecting to ${device.name ?? device.address}...";
    connectedDevice.value = device; // Store target device
    availableDevices.clear(); // Clear list while connecting
    try {
      print("Attempting connection to ${device.address} using SPP UUID: $sppUUID");
      // Initiate connection. State changes (connected, error, disconnected)
      // will be handled by the _listenToDeviceStatus listener.
      await _bluetoothClassic.connect(device.address, sppUUID);
      print("Connection initiated to ${device.address}. Waiting for status update via listener.");
      // REMOVED: _listenToData(); - Now called by status listener on Status 2
    } catch (e) {
      // Catch errors during the *initiation* of the connection only.
      // The status listener handles errors *during* an established connection.
      print("Error initiating connection to ${device.address}: $e");
      statusMessage.value = "Error connecting: $e";
      // Don't call _handleDisconnection here, let status listener handle potential status -1 event.
      // Just reset the 'connecting' flag as the attempt failed.
      isConnecting.value = false;
      connectedDevice.value = null; // Clear target device if initiation failed
    }
    // isConnecting will be set to true/false by the status listener based on events
  }

  // --- Listeners Setup (Status Listener now sets up Data Listener) ---
  void _listenToDeviceStatus() {
    _btStatusSubscription?.cancel();
    _btStatusSubscription = _bluetoothClassic.onDeviceStatusChanged().listen((int status) {
      print("Device Status Changed: $status");
      switch (status) {
        case 2: // Connected
          // Ensure scanning is stopped if connection happens during scan
          if (isScanning.value) {
            print("Connected while scanning, stopping scan...");
            stopScan(); // This will pause the discovery listener
          }
          isConnected.value = true;
          isConnecting.value = false;
          statusMessage.value = "Connected to ${connectedDevice.value?.name ?? connectedDevice.value?.address ?? 'device'}";
          print("Device Connected (Status 2). Setting up data listener...");
          // Setup data listener *only* when connection is confirmed
          _listenToData();
          break;
        case 1: // Intermediate Connecting
          // Only set if not already connected (avoids flicker if status 1 comes after 2)
          if (!isConnected.value) {
            isConnecting.value = true;
            statusMessage.value = "Connecting/Authenticating...";
          }
          break;
        case 0: // Disconnected
          print("Device Status Listener received Disconnected (Status 0).");
          _handleDisconnection();
          break;
        case -1: // Error
          print("Device Status Listener received Error (Status -1).");
          _handleDisconnection(errorOccurred: true);
          Get.snackbar("Connection Error", "An error occurred during connection.");
          break;
        default:
          print("Unknown device status code: $status");
          break;
      }
    });
    print("Device status listener set up.");
  }

  // Data listener setup remains mostly the same, but is now called by the status listener
  void _listenToData() {
    _btDataSubscription?.cancel(); // Ensure previous listener is cancelled
    _receiveBuffer = "";
    print("Setting up data listener..."); // Added log
    _btDataSubscription = _bluetoothClassic.onDeviceDataReceived().listen(
      (Uint8List data) {
        _receiveBuffer += utf8.decode(data, allowMalformed: true);
        while (_receiveBuffer.contains('\n')) {
          int newlineIndex = _receiveBuffer.indexOf('\n');
          String line = _receiveBuffer.substring(0, newlineIndex).trim();
          _receiveBuffer = _receiveBuffer.substring(newlineIndex + 1);
          if (line.isNotEmpty) {
            receivedData.value = line;
            print("Received Line: $line");
            // Update status based on expected responses from Arduino
            if (line == "OK") {
              statusMessage.value = "Command Successful!";
            } else if (line == "ERROR:InvalidCode") {
              // Exact match
              statusMessage.value = "Command Failed: Invalid Code Received!";
            } else if (line == "ERROR:InvalidFormat") {
              // Exact match
              statusMessage.value = "Command Error: Invalid Format Sent!";
            } else if (line.startsWith("ERROR:")) {
              // Handle other potential errors
              statusMessage.value = "Command Failed: ${line.split(':').last.trim()}";
            } else {
              statusMessage.value = "Received: $line"; // Display other messages
            }
          }
        }
      },
      onError: (e) {
        print("Error in data stream: $e");
        statusMessage.value = "Data Error: $e";
        _handleDisconnection(errorOccurred: true); // Disconnect on data error
      },
      onDone: () {
        print("Data stream closed.");
        // Handle disconnection if stream closes unexpectedly while connected
        if (isConnected.value || isConnecting.value) {
          // Also handle if it was connecting
          print("Data stream closed while connected/connecting, triggering disconnect logic.");
          _handleDisconnection();
        }
      },
    );
    print("Device data listener setup complete.");
  }

  // --- Disconnection (Triggered by user or status listener/error handling) ---
  Future<void> disconnectDevice() async {
    // Check if we are actually in a state where disconnect makes sense
    if (!isConnected.value && !isConnecting.value) {
      print("Disconnect called but already disconnected/not connecting.");
      // Ensure state is consistent if called unexpectedly
      _handleDisconnection();
      return;
    }

    statusMessage.value = "Disconnecting...";
    print("User initiated disconnect...");
    try {
      await _bluetoothClassic.disconnect();
      print("Native disconnect command sent.");
      // IMPORTANT: Don't call _handleDisconnection here directly.
      // Let the status listener (`_listenToDeviceStatus`) handle the actual
      // state change when it receives the status update (0) from the plugin.
      // This prevents race conditions and double handling.
    } catch (e) {
      print("Error sending native disconnect command: $e");
      statusMessage.value = "Error disconnecting: $e";
      // If the native call itself fails, force a state reset as a fallback.
      _handleDisconnection(errorOccurred: true);
    }
  }

  // --- Helper for Cleaning Up State on Disconnect/Error (Idempotent) ---
  void _handleDisconnection({bool errorOccurred = false}) {
    // **Idempotency Check:** Only run if not already disconnected/idle.
    if (!isConnected.value && !isConnecting.value) {
      print("Already disconnected/idle, skipping redundant state reset.");
      return;
    }

    print("Starting state reset. Error occurred: $errorOccurred");

    if (errorOccurred) {
      statusMessage.value = "Connection Error"; // Set status specifically for UI
    } else {
      // Only show "Disconnected" if it was previously connected/connecting
      statusMessage.value = "Disconnected";
    }

    // Reset state variables
    isConnected.value = false;
    isConnecting.value = false;
    // Don't clear connectedDevice.value here immediately, maybe keep last connected?
    // Or clear it: connectedDevice.value = null; // Decide based on desired UX

    // Cancel data listener **before** clearing state variables might be slightly safer
    _btDataSubscription?.cancel();
    _btDataSubscription = null;
    _receiveBuffer = "";

    print("State reset complete.");
    // Note: Status listener (_btStatusSubscription) is kept active to listen for future connections.
    // Discovery listener (_discoverySubscription) is managed using pause/resume/cancel.
  }

  // --- Standard HOTP Code Generation (Using otp package) ---
  Future<String?> _generateCOTPCode(int counter) async {
    // Using the hardcoded secret key string directly with the otp package
    final String secretKeyString = _hardcodedSharedSecretString;

    try {
      // Use the OTP package to generate standard HOTP code string (HMAC-SHA1)
      String code = OTP.generateHOTPCodeString(
        secretKeyString, // Secret is passed as a string
        counter,
        length: otpDigits, // Use configured number of digits (6)
        algorithm: Algorithm.SHA1, // Explicitly use SHA1 for standard HOTP
      );

      print("Generated HOTP code for counter $counter (using hardcoded key): $code");
      return code;
    } catch (e) {
      print("Error generating HOTP code: $e");
      statusMessage.value = "Error: Code Generation Failed";
      return null;
    }
  }

  // --- Sending Command ---
  Future<void> sendToggleCommand() async {
    if (!isConnected.value) {
      statusMessage.value = "Not connected.";
      print("Cannot send command: Not connected.");
      Get.snackbar("Error", "Not connected to the lock device.");
      return;
    }

    // Prevent sending if already connecting/scanning/loading
    if (isConnecting.value || isScanning.value || isLoading.value) {
      print("Cannot send command: Operation already in progress.");
      Get.snackbar("Busy", "Please wait for the current operation to finish.");
      return;
    }

    int currentCounter = syncCounter.value; // Get current counter value
    statusMessage.value = "Generating HOTP code for C:$currentCounter...";

    // Generate the standard HOTP code for the current counter
    final codeString = await _generateCOTPCode(currentCounter);

    if (codeString == null) {
      // Error message already set by _generateCOTPCode
      Get.snackbar("Error", "Failed to generate secure code.");
      return;
    }
    print("Generated HOTP Code for counter $currentCounter: $codeString");

    // Prepare command: "code\n" (Only the code, followed by newline)
    String commandString = "$codeString\n";

    // Increment and save counter *before* sending
    // Note: If send fails, the counter is still incremented. Arduino needs the window.
    int nextCounter = currentCounter + 1;
    await _saveCounter(nextCounter);

    try {
      statusMessage.value = "Sending HOTP Code: $codeString...";
      // Use write(String) for sending the command string
      await _bluetoothClassic.write(commandString);
      print("Sent string: $commandString");
      statusMessage.value = "Code sent. Waiting for response...";
    } catch (e) {
      print("Error sending command: $e");
      statusMessage.value = "Error sending command: $e";
      _handleDisconnection(errorOccurred: true);
      Get.snackbar("Send Error", "Failed to send command. Connection lost?");
      // Consider counter rollback logic here if needed, though complicates recovery
    }
  }
}
// ----- END FILE: rolling_code_door_locking_app/lib/lock_controller.dart -----