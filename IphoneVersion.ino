#include <ArduinoBLE.h>
#include <Dynamixel2Arduino.h>
#include <math.h>

// -------------------- BLE CONFIG --------------------
// Must match the UUIDs in your iOS BluetoothManager.swift
const char* BLE_DEVICE_NAME = "Arduino";

const char* SERVICE_UUID =
  "12345678-1234-1234-1234-1234567890AB";

const char* COMMAND_CHARACTERISTIC_UUID =
  "87654321-4321-4321-4321-BA0987654321";

// This service represents the RedefineLighting Arduino controller.
BLEService redefineService(SERVICE_UUID);

// iPhone writes ASCII commands here.
// Example values:
//   G-0.07
//   G4.25
//   H
//   E
//   D
//   L75
BLEStringCharacteristic commandCharacteristic(
  COMMAND_CHARACTERISTIC_UUID,
  BLEWrite,
  32
);

// Buffer for BLE command text in case commands arrive with newline.
String bleCommandBuffer = "";

// -------------------- DYNAMIXEL CONFIG --------------------
#define DXL_SERIAL        Serial1
const int     DXL_DIR_PIN  = 2;
const uint8_t DXL_ID       = 1;
const float   DXL_PROTOCOL = 2.0;

const int32_t HOME_POS      = 2048;
const int32_t POS_MIN       = 0;
const int32_t POS_MAX       = 4095;
const float   ANGLE_MIN_DEG = -10.0f;
const float   ANGLE_MAX_DEG =  10.0f;

using namespace ControlTableItem;
Dynamixel2Arduino dxl(DXL_SERIAL, DXL_DIR_PIN);

// -------------------- LED CONFIG --------------------
// PWM pins for the 6 LEDs — change these if your wiring differs
const int LED_PINS[]  = { 3, 5, 6, 9, 10, 11 };
const int LED_COUNT   = 6;
int       ledBrightness = 0;   // 0–255, starts off

// -------------------- HELPERS --------------------

int32_t degreesToPosition(float deg) {
  float pos_f = HOME_POS + (deg * 4096.0f / 360.0f);
  int32_t pos = (int32_t)lround(pos_f);

  if (pos < POS_MIN) pos = POS_MIN;
  if (pos > POS_MAX) pos = POS_MAX;

  return pos;
}

float positionToDegrees(int32_t pos) {
  return (pos - HOME_POS) * (360.0f / 4096.0f);
}

void setAllLeds(int brightness) {
  ledBrightness = constrain(brightness, 0, 255);

  for (int i = 0; i < LED_COUNT; i++) {
    analogWrite(LED_PINS[i], ledBrightness);
  }
}

// -------------------- COMMAND HANDLER --------------------
// Supported commands, ASCII newline-terminated or single BLE write:
//   G<deg>    — move servo to angle, e.g. G-7.50
//   L<0-100>  — set all LED brightness as a percentage, e.g. L75
//   E         — torque on
//   D         — torque off
//   R         — read present position + angle
//   H         — go to home (0°)

void processCommand(const String &cmdRaw) {
  String cmd = cmdRaw;
  cmd.trim();

  if (cmd.length() == 0) return;

  Serial.print("RX -> ");
  Serial.println(cmd);

  // G<deg> : move servo to angle
  if (cmd.charAt(0) == 'G' || cmd.charAt(0) == 'g') {
    float deg = cmd.substring(1).toFloat();

    if (deg < ANGLE_MIN_DEG) deg = ANGLE_MIN_DEG;
    if (deg > ANGLE_MAX_DEG) deg = ANGLE_MAX_DEG;

    int32_t targetPos = degreesToPosition(deg);
    dxl.setGoalPosition(DXL_ID, targetPos);

    Serial.print("OK:GOTO_DEG=");
    Serial.print(deg, 2);
    Serial.print(",TARGET_POS=");
    Serial.println(targetPos);
    return;
  }

  // L<pct> : set all LED brightness, 0–100%
  if (cmd.charAt(0) == 'L' || cmd.charAt(0) == 'l') {
    int pct = cmd.substring(1).toInt();
    pct = constrain(pct, 0, 100);

    int pwm = (int)((pct / 100.0f) * 255.0f);
    setAllLeds(pwm);

    Serial.print("OK:LED_PCT=");
    Serial.print(pct);
    Serial.print(",PWM=");
    Serial.println(pwm);
    return;
  }

  // E : torque on
  if (cmd.equalsIgnoreCase("E")) {
    dxl.torqueOn(DXL_ID);
    Serial.println("OK:TORQUE_ON");
    return;
  }

  // D : torque off
  if (cmd.equalsIgnoreCase("D")) {
    dxl.torqueOff(DXL_ID);
    Serial.println("OK:TORQUE_OFF");
    return;
  }

  // R : read present position
  if (cmd.equalsIgnoreCase("R")) {
    int32_t pos = dxl.getPresentPosition(DXL_ID);
    float deg = positionToDegrees(pos);

    Serial.print("POS=");
    Serial.print(pos);
    Serial.print(",DEG=");
    Serial.println(deg, 2);
    return;
  }

  // H : go home
  if (cmd.equalsIgnoreCase("H")) {
    dxl.setGoalPosition(DXL_ID, HOME_POS);
    Serial.println("OK:HOME");
    return;
  }

  Serial.println("ERR:UNKNOWN_CMD");
}

// Handles command text received from BLE.
// Your iPhone currently sends one command per write, like "G-0.07\n".
// This function also supports multiple newline-separated commands.
void processBleText(String incoming) {
  if (incoming.length() == 0) return;

  Serial.print("BLE raw -> ");
  Serial.println(incoming);

  bleCommandBuffer += incoming;

  int newlineIndex = bleCommandBuffer.indexOf('\n');

  while (newlineIndex >= 0) {
    String oneCommand = bleCommandBuffer.substring(0, newlineIndex);
    processCommand(oneCommand);

    bleCommandBuffer.remove(0, newlineIndex + 1);
    newlineIndex = bleCommandBuffer.indexOf('\n');
  }

  // If the iPhone/app ever sends a command without a newline,
  // process it directly as long as it looks complete and short.
  if (bleCommandBuffer.length() > 0 && bleCommandBuffer.length() <= 16) {
    char first = bleCommandBuffer.charAt(0);

    if (first == 'G' || first == 'g' ||
        first == 'L' || first == 'l' ||
        bleCommandBuffer.equalsIgnoreCase("E") ||
        bleCommandBuffer.equalsIgnoreCase("D") ||
        bleCommandBuffer.equalsIgnoreCase("R") ||
        bleCommandBuffer.equalsIgnoreCase("H")) {
      processCommand(bleCommandBuffer);
      bleCommandBuffer = "";
    }
  }

  // Safety: prevent buffer growth if malformed BLE data arrives.
  if (bleCommandBuffer.length() > 64) {
    Serial.println("BLE command buffer overflow. Clearing.");
    bleCommandBuffer = "";
  }
}

// -------------------- SETUP --------------------
void setup() {
  Serial.begin(115200);
  while (!Serial) { ; }

  Serial.println("Starting BLE + DYNAMIXEL + LED controller...");

  // Init LED pins and start at 50% brightness
  for (int i = 0; i < LED_COUNT; i++) {
    pinMode(LED_PINS[i], OUTPUT);
    analogWrite(LED_PINS[i], 127);
  }

  // Dynamixel init
  DXL_SERIAL.begin(57600);
  dxl.begin(57600);
  dxl.setPortProtocolVersion(DXL_PROTOCOL);

  dxl.torqueOff(DXL_ID);
  dxl.setOperatingMode(DXL_ID, OP_POSITION);
  dxl.writeControlTableItem(PROFILE_VELOCITY,     DXL_ID, 2);
  dxl.writeControlTableItem(PROFILE_ACCELERATION, DXL_ID, 1);
  dxl.torqueOn(DXL_ID);

  Serial.println("DYNAMIXEL ready.");

  // BLE init
  if (!BLE.begin()) {
    Serial.println("BLE failed to start.");
    while (1) {
      delay(1000);
    }
  }

  BLE.setLocalName(BLE_DEVICE_NAME);
  BLE.setDeviceName(BLE_DEVICE_NAME);

  // This is the important part for narrow scanning later:
  // advertise the same service UUID your iPhone scans for.
  BLE.setAdvertisedService(redefineService);

  redefineService.addCharacteristic(commandCharacteristic);
  BLE.addService(redefineService);

  commandCharacteristic.writeValue("");

  BLE.advertise();

  Serial.println("BLE advertising as Arduino");
  Serial.print("Service UUID: ");
  Serial.println(SERVICE_UUID);
  Serial.print("Command characteristic UUID: ");
  Serial.println(COMMAND_CHARACTERISTIC_UUID);
  Serial.println("READY");
}

// -------------------- LOOP --------------------
void loop() {
  // Keep BLE events moving.
  BLE.poll();

  // Handle commands typed into Serial Monitor over USB.
  if (Serial.available()) {
    String cmd = Serial.readStringUntil('\n');
    processCommand(cmd);
  }

  // Handle commands written by the iPhone over BLE.
  if (commandCharacteristic.written()) {
    String incoming = commandCharacteristic.value();
    processBleText(incoming);
  }
}