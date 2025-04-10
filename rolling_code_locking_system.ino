// ----- START FILE: rolling_code_door_lock/rolling_code_door_lock.ino -----
#include <Servo.h>
#include <SoftwareSerial.h>
// Removed crypto/EEPROM/Base64 includes

// --- Configuration ---
// Bluetooth HC-05 Pins
const int BLUETOOTH_RX_PIN = 10;  // Arduino RX pin connected to HC-05 TX
const int BLUETOOTH_TX_PIN = 11;  // Arduino TX pin connected to HC-05 RX

// Servo Pin
const int SERVO_PIN = 9;          // PWM pin for servo control

// Servo Positions
const int SERVO_LOCKED_POS = 0;   // Angle for locked position
const int SERVO_UNLOCKED_POS = 90; // Angle for unlocked position

// Fixed command expected from the app
const String APP_COMMAND = "TOGGLE";

// Bluetooth Setup
SoftwareSerial hc05(BLUETOOTH_RX_PIN, BLUETOOTH_TX_PIN); // RX, TX
const long BLUETOOTH_BAUD = 9600;                       // Common default for HC-05

// --- Global Variables ---
Servo lockServo;
bool isLocked = true;           // Assume starting state is locked
// Removed syncCounter

// --- Function Prototypes ---
// Removed crypto/EEPROM prototypes
void toggleLock();

// --- Setup ---
void setup() {
  Serial.begin(9600); // For debugging output to Serial Monitor
  Serial.println(F("Arduino Simple BT Lock System Booting...")); // Updated name

  hc05.begin(BLUETOOTH_BAUD);
  Serial.println(F("HC-05 Bluetooth Initialized at 9600 baud."));

  lockServo.attach(SERVO_PIN);
  lockServo.write(SERVO_LOCKED_POS); // Start in locked position
  isLocked = true;
  Serial.println(F("Servo Initialized and Locked."));

  // Removed EEPROM reading
  // Serial.print(F("Initial Sync Counter read from EEPROM: "));
  // Serial.println(syncCounter);

  Serial.println(F("Setup Complete. Waiting for command..."));
}

// --- Main Loop ---
void loop() {
  if (hc05.available() > 0) {
    String incomingString = hc05.readStringUntil('\n');
    incomingString.trim();
    Serial.print(F("Received via Bluetooth: "));
    Serial.println(incomingString);

    // Check if the received string matches the expected command
    if (incomingString.equals(APP_COMMAND)) {
      Serial.println(F("Command Accepted!"));
      toggleLock();           // Perform action
      hc05.println(F("OK"));   // Send confirmation
    } else {
      Serial.print(F("Command Rejected! Expected '"));
      Serial.print(APP_COMMAND);
      Serial.print(F("', Received '"));
      Serial.print(incomingString);
      Serial.println(F("'"));
      hc05.println(F("ERROR:INVALID_CMD")); // Send error back
    }
  }
  // Other non-blocking tasks can go here
}

// Removed calculateHmac, isValidHmac, updateEEPROMCounter, readEEPROMCounter, printHex functions

// --- Servo Control ---
void toggleLock() {
  if (isLocked) {
    lockServo.write(SERVO_UNLOCKED_POS);
    isLocked = false;
    Serial.println(F("Servo Unlocked."));
  } else {
    lockServo.write(SERVO_LOCKED_POS);
    isLocked = true;
    Serial.println(F("Servo Locked."));
  }
  delay(500); // Give servo time to move
}

// Removed EEPROM Functions

// Removed Helper Function printHex
// ----- END FILE: rolling_code_door_lock/rolling_code_door_lock.ino -----