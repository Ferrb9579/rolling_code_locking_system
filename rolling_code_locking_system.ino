#include <Servo.h>
#include <SoftwareSerial.h>
#include <EEPROM.h>  // To store the sync counter persistently

// --- Configuration ---
// Bluetooth HC-05 Pins
const int BLUETOOTH_RX_PIN = 10;  // Arduino RX pin connected to HC-05 TX
const int BLUETOOTH_TX_PIN = 11;  // Arduino TX pin connected to HC-05 RX

// Servo Pin
const int SERVO_PIN = 9;  // PWM pin for servo control

// Servo Positions
const int SERVO_LOCKED_POS = 0;     // Angle for locked position
const int SERVO_UNLOCKED_POS = 90;  // Angle for unlocked position

// Rolling Code Configuration
const unsigned long SHARED_SECRET_KEY = 123456789;  // !! CHANGE THIS !! Keep this EXACTLY the same in the Flutter app.
                                                    // !! IMPORTANT: Hardcoding secrets is NOT secure for production !!
const int EEPROM_COUNTER_ADDR = 0;                  // EEPROM address to store the counter (uses 4 bytes for unsigned long)
const int SYNC_WINDOW_SIZE = 10;                     // How many codes ahead to check (allows for missed messages)

// Bluetooth Setup
SoftwareSerial hc05(BLUETOOTH_RX_PIN, BLUETOOTH_TX_PIN);  // RX, TX
const long BLUETOOTH_BAUD = 9600;                         // Common default for HC-05, check your module's config

// --- Global Variables ---
Servo lockServo;
bool isLocked = true;           // Assume starting state is locked
unsigned long syncCounter = 0;  // Synchronization counter

// --- Function Prototypes ---
unsigned long generateCode(unsigned long counter);
bool isValidCode(unsigned long receivedCode);
void toggleLock();
void updateEEPROMCounter();
void readEEPROMCounter();

// --- Setup ---
void setup() {
  Serial.begin(9600);  // For debugging output to Serial Monitor
  Serial.println("Arduino Rolling Code Lock System Booting...");

  hc05.begin(BLUETOOTH_BAUD);
  Serial.println("HC-05 Bluetooth Initialized at 9600 baud.");

  lockServo.attach(SERVO_PIN);
  lockServo.write(SERVO_LOCKED_POS);  // Start in locked position
  isLocked = true;
  Serial.println("Servo Initialized and Locked.");

  // Read the last saved counter from EEPROM
  readEEPROMCounter();
  Serial.print("Initial Sync Counter read from EEPROM: ");
  Serial.println(syncCounter);

  Serial.println("Setup Complete. Waiting for commands...");
}

// --- Main Loop ---
void loop() {
  // Check if data is available from HC-05
  if (hc05.available() > 0) {
    String incomingString = hc05.readStringUntil('\n');  // Read command until newline
    incomingString.trim();                               // Remove any leading/trailing whitespace

    Serial.print("Received via Bluetooth: ");
    Serial.println(incomingString);

    // Attempt to parse the string as a number (the rolling code)
    // Use strtoul for unsigned long parsing
    char *endptr;
    unsigned long receivedCode = strtoul(incomingString.c_str(), &endptr, 10);

    // Check if parsing was successful (endptr should point to the null terminator)
    if (*endptr == '\0' && incomingString.length() > 0) {
      Serial.print("Parsed Code: ");
      Serial.println(receivedCode);

      // Validate the received rolling code
      if (isValidCode(receivedCode)) {
        Serial.println("Code Accepted!");
        toggleLock();           // Perform the lock/unlock action
        updateEEPROMCounter();  // Save the new counter state
        hc05.println("OK");     // Send confirmation back
      } else {
        Serial.println("Code Rejected!");
        hc05.println("ERROR:InvalidCode");  // Send error back
      }
    } else {
      Serial.print("Failed to parse code: ");
      Serial.println(incomingString);
      hc05.println("ERROR:InvalidFormat");
    }
  }

  // Other non-blocking tasks can go here if needed
}

// --- Rolling Code Functions ---

// Generates a predictable code based on the counter and secret key
// This is a *simple* example, not cryptographically secure.
unsigned long generateCode(unsigned long counter) {
  // Use a pseudo-random generator seeded with the key and counter
  randomSeed(SHARED_SECRET_KEY + counter);
  return random(100000, 999999);  // Generate a 6-digit code (adjust range as needed)
}

// Checks if the received code is valid (matches expected or is within the sync window)
bool isValidCode(unsigned long receivedCode) {
  Serial.print("Current Counter: ");
  Serial.println(syncCounter);

  // 1. Check the very next expected code
  unsigned long nextExpectedCode = generateCode(syncCounter);
  Serial.print("Expecting Code (counter ");
  Serial.print(syncCounter);
  Serial.print("): ");
  Serial.println(nextExpectedCode);
  if (receivedCode == nextExpectedCode) {
    syncCounter++;  // Increment counter for the next use
    Serial.println("Code matches next expected.");
    return true;
  }

  // 2. Check codes within the synchronization window (allows for missed commands)
  Serial.print("Code didn't match next. Checking window (size ");
  Serial.print(SYNC_WINDOW_SIZE);
  Serial.println(")...");
  for (int i = 1; i <= SYNC_WINDOW_SIZE; i++) {
    unsigned long windowCode = generateCode(syncCounter + i);
    Serial.print("  Checking Code (counter ");
    Serial.print(syncCounter + i);
    Serial.print("): ");
    Serial.println(windowCode);
    hc05.println(windowCode);
    if (receivedCode == windowCode) {
      Serial.print("Code matched in window at offset +");
      Serial.println(i);
      // Re-synchronize: Update counter to the matched position + 1 for next use
      syncCounter = syncCounter + i + 1;
      Serial.print("Re-synced counter to: ");
      Serial.println(syncCounter);
      return true;
    }
  }

  // 3. If code wasn't the next expected or within the window, it's invalid
  Serial.println("Code not found in expected sequence or sync window.");
  return false;
}

// --- Servo Control ---
void toggleLock() {
  if (isLocked) {
    lockServo.write(SERVO_UNLOCKED_POS);
    isLocked = false;
    Serial.println("Servo Unlocked.");
  } else {
    lockServo.write(SERVO_LOCKED_POS);
    isLocked = true;
    Serial.println("Servo Locked.");
  }
  delay(500);  // Give servo time to move
}

// --- EEPROM Functions ---
void updateEEPROMCounter() {
  // EEPROM.put() writes the given variable (handles different data types)
  // It's generally better than repeated EEPROM.write() as it checks if the value needs changing, reducing wear.
  EEPROM.put(EEPROM_COUNTER_ADDR, syncCounter);
  Serial.print("Sync Counter ");
  Serial.print(syncCounter);
  Serial.println(" saved to EEPROM.");

  // On ESP32/ESP8266 you would need EEPROM.commit() here. Not needed for standard Arduino AVR.
}

void readEEPROMCounter() {
  // EEPROM.get() reads the variable back
  EEPROM.get(EEPROM_COUNTER_ADDR, syncCounter);
  // Basic sanity check - EEPROM is often 0xFFFFFFFF when new/erased
  if (syncCounter == 0xFFFFFFFF) {
    syncCounter = 0;  // Start fresh if EEPROM seems uninitialized
    Serial.println("EEPROM seemed uninitialized, starting counter at 0.");
    updateEEPROMCounter();  // Save the initial 0 value
  }
}