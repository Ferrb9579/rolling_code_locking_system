import 'dart:async';
import 'dart:convert'; // Required for utf8 encoding/decoding
import 'dart:typed_data'; // Required for Uint8List

// Removed crypto, secure_storage, shared_preferences imports

// Use bluetooth_classic package
import 'package:bluetooth_classic/bluetooth_classic.dart';
import 'package:bluetooth_classic/models/device.dart';

import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart'; // Keep for potential future use
// Removed SharedPreferences import

// --- Configuration ---
const String hc05DeviceName = "HC-05"; // Used to identify the target device in list
// Removed counter and secret key constants
// Standard Serial Port Profile (SPP) UUID
const String sppUUID = "00001101-0000-1000-8000-00805f9b34fb";
// Fixed command to send
const String toggleCommand = "TOGGLE";

class LockController extends GetxController {
  // Removed Secure Storage instance

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
  final statusMessage = "Initializing...".obs;
  final receivedData = "".obs; // Last complete message received
  final availableDevices = RxList<Device>([]);
  // Removed syncCounter
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
    if (isConnected.value) {
      _bluetoothClassic.disconnect();
    }
    super.onClose();
  }

  // --- Initialization ---
  Future<void> _init() async {
    isLoading.value = true;
    // Removed counter loading
    // Removed secret key check

    statusMessage.value = "Initializing Bluetooth & Permissions...";
    try {
      bool permissionsGranted = await _bluetoothClassic.initPermissions();
      if (!permissionsGranted) {
        statusMessage.value = "Bluetooth Permissions Required!";
        print("Bluetooth permissions not granted.");
        isLoading.value = false;
        Get.snackbar("Permission Required", "Bluetooth permissions are needed to operate the lock.");
        return;
      }
      print("Bluetooth permissions granted.");
      statusMessage.value = "Permissions OK. Ready.";
      _listenToDeviceStatus();
    } catch (e) {
      statusMessage.value = "Error initializing Bluetooth: $e";
      print("Error initializing Bluetooth: $e");
    } finally {
      isLoading.value = false;
    }
  }

  // Removed Counter Persistence methods (_loadCounter, _saveCounter)
  // Removed Secret Key Persistence method (_getSharedSecret)

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

  // --- Device Scanning ---
  Future<void> startScan() async {
      if (isScanning.value || isLoading.value || isConnecting.value || isConnected.value) return;
      isScanning.value = true;
      isLoading.value = true;
      statusMessage.value = "Scanning for devices...";
      availableDevices.clear();
      try {
          await _bluetoothClassic.stopScan();
          _bluetoothClassic.onDeviceDiscovered().listen((device) {
              if (!availableDevices.any((d) => d.address == device.address)) {
                  availableDevices.add(device);
              }
          });
          await _bluetoothClassic.startScan();
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
          isLoading.value = false;
      }
  }

  // --- Connection ---
  Future<void> connectToDevice(Device device) async {
    if (isConnected.value || isConnecting.value) return;
    isConnecting.value = true;
    statusMessage.value = "Connecting to ${device.name ?? device.address}...";
    connectedDevice.value = device;
    availableDevices.clear();
    try {
      print("Attempting connection to ${device.address} using SPP UUID: $sppUUID");
      await _bluetoothClassic.connect(device.address, sppUUID);
      print("Connection initiated to ${device.address}. Waiting for status update.");
      _listenToData();
    } catch (e) {
      print("Error initiating connection to ${device.address}: $e");
      statusMessage.value = "Error connecting: $e";
      _handleDisconnection(errorOccurred: true);
      isConnecting.value = false;
    }
  }

  // --- Listeners Setup ---
  void _listenToDeviceStatus() {
    _btStatusSubscription?.cancel();
    _btStatusSubscription = _bluetoothClassic.onDeviceStatusChanged().listen((int status) {
      print("Device Status Changed: $status");
      switch (status) {
        case 2: // Connected
          isConnected.value = true;
          isConnecting.value = false;
          if (connectedDevice.value != null) {
             statusMessage.value = "Connected to ${connectedDevice.value?.name ?? connectedDevice.value?.address}";
          } else {
             statusMessage.value = "Connected";
          }
          print("Device Connected (Status 2).");
          break;
        case 1: // Intermediate Connecting/Authenticating state?
          if (!isConnected.value) {
             isConnecting.value = true;
             statusMessage.value = "Connecting/Authenticating...";
          } else {
             print("Received intermediate status 1 while already connected. Ignoring.");
          }
          break;
        case 0: // Disconnected
           print("Device Disconnected (Status 0).");
          _handleDisconnection();
          break;
        case -1: // Error
          print("Device Error occurred (Status -1).");
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
    _btDataSubscription?.cancel();
    _receiveBuffer = "";
    _btDataSubscription = _bluetoothClassic.onDeviceDataReceived().listen((Uint8List data) {
      _receiveBuffer += utf8.decode(data, allowMalformed: true);
      while (_receiveBuffer.contains('\n')) {
        int newlineIndex = _receiveBuffer.indexOf('\n');
        String line = _receiveBuffer.substring(0, newlineIndex).trim();
        _receiveBuffer = _receiveBuffer.substring(newlineIndex + 1);
        if (line.isNotEmpty) {
          receivedData.value = line;
          print("Received Line: $line");
          // Simplified status update based on simple OK/ERROR
          if (line.contains("OK")) {
            statusMessage.value = "Command Successful!";
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
      _handleDisconnection();
      return;
    }
    statusMessage.value = "Disconnecting...";
    try {
      await _bluetoothClassic.disconnect();
      print("Disconnect command sent.");
    } catch (e) {
      print("Error sending disconnect command: $e");
      statusMessage.value = "Error disconnecting: $e";
       _handleDisconnection(errorOccurred: true);
    }
  }

  // --- Helper for Cleaning Up State on Disconnect/Error ---
  void _handleDisconnection({bool errorOccurred = false}) {
    if (errorOccurred) {
        statusMessage.value = "Connection Error";
    } else if (isConnected.value || isConnecting.value) {
        statusMessage.value = "Disconnected";
    }
    isConnected.value = false;
    isConnecting.value = false;
    if (connectedDevice.value != null) {
       connectedDevice.value = null;
    }
    _btDataSubscription?.cancel();
    _btDataSubscription = null;
    _receiveBuffer = "";
    print("State reset after disconnection/error.");
  }

  // Removed Rolling Code Logic (_generateHmacCode)

  // --- Sending Command ---
  Future<void> sendToggleCommand() async {
    if (!isConnected.value) {
      statusMessage.value = "Not connected.";
      print("Cannot send command: Not connected.");
      Get.snackbar("Error", "Not connected to the lock device.");
      return;
    }

    // Prepare the fixed command string with newline termination
    String commandString = "$toggleCommand\n";

    try {
      statusMessage.value = "Sending command...";
      // Use write(String) for sending the command string
      await _bluetoothClassic.write(commandString);
      print("Sent string: $commandString");
      statusMessage.value = "Command sent. Waiting for response...";
    } catch (e) {
      print("Error sending command: $e");
      statusMessage.value = "Error sending command: $e";
      _handleDisconnection(errorOccurred: true);
      Get.snackbar("Send Error", "Failed to send command. Connection lost?");
    }
  }
}