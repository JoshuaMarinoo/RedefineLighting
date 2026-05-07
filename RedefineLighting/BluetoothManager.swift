//
//  BluetoothManager.swift
//  RedefineLighting
//

import Foundation
import CoreBluetooth
import Combine

final class BluetoothManager: NSObject, ObservableObject {
    @Published var bluetoothStatus: String = "Not started"
    @Published var isConnected: Bool = false

    // This controls whether the iPhone sends new G<angle> movement commands.
    // When false, the motor should hold its last position because Arduino torque stays ON.
    @Published var servoCommandsEnabled: Bool = true

    private var centralManager: CBCentralManager?
    private var arduinoPeripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?

    private let serviceUUID = CBUUID(string: "12345678-1234-1234-1234-1234567890AB")
    private let characteristicUUID = CBUUID(string: "87654321-4321-4321-4321-BA0987654321")

    private var lastSentCenterX: Double?
    private var lastSentCenterY: Double?

    private let xChangeThreshold = 0.03
    private let yChangeThreshold = 0.03

    private let targetCenterX = 0.5
    private let angleGain = 20.0

    private let minAngle = -10.0
    private let maxAngle = 10.0

    private var lastSentAngle: Double?
    private var smoothedAngle: Double?
    private let smoothingAlpha = 0.25
    private let angleSendThreshold = 0.5
    private let minimumSendInterval: TimeInterval = 0.10
    private var lastSendTime: Date?

    private let ledBrightnessLevels = [0, 25, 50, 75, 100]
    private var ledBrightnessIndex = 2

    override init() {
        super.init()

        centralManager = CBCentralManager(
            delegate: self,
            queue: nil
        )
    }

    func sendDynamixelCommandIfNeeded(_ box: NormalizedBox?) {
        // This is what stops/resumes motor movement.
        // If false, no new G<angle> commands are sent to the Arduino.
        guard servoCommandsEnabled else {
            return
        }

        guard let box else {
            return
        }

        guard let arduinoPeripheral else {
            return
        }

        guard let commandCharacteristic else {
            return
        }

        let shouldConsiderSending: Bool

        if let lastX = lastSentCenterX,
           let lastY = lastSentCenterY {
            let xChange = abs(box.x - lastX)
            let yChange = abs(box.y - lastY)

            shouldConsiderSending = xChange > xChangeThreshold || yChange > yChangeThreshold
        } else {
            shouldConsiderSending = true
        }

        guard shouldConsiderSending else {
            return
        }

        let errorX = box.x - targetCenterX
        var rawAngle = errorX * angleGain

        if rawAngle < minAngle {
            rawAngle = minAngle
        }

        if rawAngle > maxAngle {
            rawAngle = maxAngle
        }

        let filteredAngle: Double

        if let previousSmoothedAngle = smoothedAngle {
            filteredAngle = smoothingAlpha * rawAngle + (1.0 - smoothingAlpha) * previousSmoothedAngle
        } else {
            filteredAngle = rawAngle
        }

        smoothedAngle = filteredAngle

        let now = Date()

        if let lastSendTime,
           now.timeIntervalSince(lastSendTime) < minimumSendInterval {
            return
        }

        if let lastSentAngle,
           abs(filteredAngle - lastSentAngle) < angleSendThreshold {
            return
        }

        let message = String(format: "G%.2f\n", filteredAngle)

        guard let data = message.data(using: .utf8) else {
            return
        }

        arduinoPeripheral.writeValue(
            data,
            for: commandCharacteristic,
            type: .withResponse
        )

        lastSentCenterX = box.x
        lastSentCenterY = box.y
        lastSentAngle = filteredAngle
        lastSendTime = now

        bluetoothStatus = "Sent: \(message)"
        print("Sent Dynamixel command: \(message)")
        print("box.x: \(box.x), errorX: \(errorX), rawAngle: \(rawAngle), filteredAngle: \(filteredAngle)")
    }

    @discardableResult
    func sendCommand(_ command: String) -> Bool {
        guard let arduinoPeripheral else {
            bluetoothStatus = "No Arduino connected"
            return false
        }

        guard let commandCharacteristic else {
            bluetoothStatus = "No command characteristic"
            return false
        }

        let message = command.hasSuffix("\n") ? command : command + "\n"

        guard let data = message.data(using: .utf8) else {
            bluetoothStatus = "Could not encode command"
            return false
        }

        arduinoPeripheral.writeValue(
            data,
            for: commandCharacteristic,
            type: .withResponse
        )

        bluetoothStatus = "Sent: \(message)"
        print("Sent command:", message)

        return true
    }

    // Thumbs-up gesture calls this.
    // It only pauses/resumes new movement commands.
    // It does NOT send D/E, so the Dynamixel should keep holding its current position.
    func toggleServoCommands() {
        servoCommandsEnabled.toggle()

        if servoCommandsEnabled {
            bluetoothStatus = "Motor movement resumed"
            print("Motor movement resumed: sending G commands again")
        } else {
            bluetoothStatus = "Motor movement paused"
            print("Motor movement paused: holding current position")
        }
    }

    // Open-palm gesture calls this.
    // This still sends L<percent> to the Arduino to change LED brightness.
    func cycleLedBrightness() {
        ledBrightnessIndex = (ledBrightnessIndex + 1) % ledBrightnessLevels.count

        let brightness = ledBrightnessLevels[ledBrightnessIndex]

        if sendCommand("L\(brightness)") {
            bluetoothStatus = "LED brightness: \(brightness)%"
        }
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStatus = "Bluetooth powered on. Scanning for Arduino..."

            central.scanForPeripherals(
                withServices: [serviceUUID],
                options: nil
            )

        case .poweredOff:
            bluetoothStatus = "Bluetooth is powered off"
            isConnected = false

        case .unauthorized:
            bluetoothStatus = "Bluetooth permission denied"
            isConnected = false

        case .unsupported:
            bluetoothStatus = "Bluetooth not supported"
            isConnected = false

        case .resetting:
            bluetoothStatus = "Bluetooth resetting"
            isConnected = false

        case .unknown:
            bluetoothStatus = "Bluetooth state unknown"
            isConnected = false

        @unknown default:
            bluetoothStatus = "Unknown Bluetooth state"
            isConnected = false
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        let peripheralName = peripheral.name ?? "Unnamed device"
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String

        print("Found BLE peripheral with matching service")
        print("Peripheral name: \(peripheralName)")
        print("Advertisement local name: \(localName ?? "No local name")")
        print("Peripheral identifier: \(peripheral.identifier)")
        print("RSSI: \(RSSI)")
        print("Advertisement data: \(advertisementData)")

        if arduinoPeripheral?.identifier == peripheral.identifier {
            return
        }

        bluetoothStatus = "Found Arduino. Connecting..."

        arduinoPeripheral = peripheral
        arduinoPeripheral?.delegate = self

        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        bluetoothStatus = "Connected. Discovering services..."
        isConnected = true

        print("Connected to Arduino")

        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        bluetoothStatus = "Failed to connect to Arduino"
        isConnected = false

        print("Failed to connect to Arduino")

        if let error {
            print("Connection error: \(error.localizedDescription)")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        bluetoothStatus = "Disconnected from Arduino"
        isConnected = false

        arduinoPeripheral = nil
        commandCharacteristic = nil

        lastSentCenterX = nil
        lastSentCenterY = nil
        lastSentAngle = nil
        smoothedAngle = nil
        lastSendTime = nil

        print("Disconnected from Arduino")

        if let error {
            print("Disconnect error: \(error.localizedDescription)")
        }

        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: nil
        )
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        if let error {
            bluetoothStatus = "Service discovery failed"
            print("Service discovery failed: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else {
            bluetoothStatus = "No services found"
            print("No services found")
            return
        }

        for service in services {
            print("Discovered service: \(service.uuid.uuidString)")

            if service.uuid == serviceUUID {
                bluetoothStatus = "Service found. Discovering characteristic..."

                peripheral.discoverCharacteristics(
                    [characteristicUUID],
                    for: service
                )
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            bluetoothStatus = "Characteristic discovery failed"
            print("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else {
            bluetoothStatus = "No characteristics found"
            print("No characteristics found")
            return
        }

        for characteristic in characteristics {
            print("Discovered characteristic: \(characteristic.uuid.uuidString)")
            print("Properties: \(characteristic.properties)")

            if characteristic.uuid == characteristicUUID {
                commandCharacteristic = characteristic
                bluetoothStatus = "Ready to send Dynamixel commands"

                print("Dynamixel command characteristic found")
            }
        }
    }
}
