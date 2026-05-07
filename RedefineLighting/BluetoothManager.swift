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

    private var centralManager: CBCentralManager?
    private var arduinoPeripheral: CBPeripheral?
    private var boundingBoxCharacteristic: CBCharacteristic?

    private let serviceUUID = CBUUID(string: "12345678-1234-1234-1234-1234567890AB")
    private let characteristicUUID = CBUUID(string: "87654321-4321-4321-4321-BA0987654321")

    // Store the last center point that actually caused a BLE command.
    private var lastSentCenterX: Double?
    private var lastSentCenterY: Double?

    // Normalized movement thresholds.
    // 0.03 means the detected center must move about 3% of the normalized frame
    // before another command is sent.
    private let xChangeThreshold = 0.03
    private let yChangeThreshold = 0.03

    // Dynamixel command mapping.
    // box.x is normalized from 0 to 1, so the center of the frame is 0.5.
    private let targetCenterX = 0.5

    // This maps normalized x-error to servo degrees.
    // With gain = 20:
    // box.x = 0.0 -> +10 degrees
    // box.x = 0.5 ->   0 degrees
    // box.x = 1.0 -> -10 degrees
    private let angleGain = 20.0

    private let minAngle = -10.0
    private let maxAngle = 10.0

    override init() {
        super.init()

        centralManager = CBCentralManager(
            delegate: self,
            queue: nil
        )
    }

    func sendDynamixelCommandIfNeeded(_ box: NormalizedBox?) {
        guard let box else {
            return
        }

        guard let arduinoPeripheral else {
            return
        }

        guard let boundingBoxCharacteristic else {
            return
        }

        let shouldSend: Bool

        if let lastX = lastSentCenterX,
           let lastY = lastSentCenterY {
            let xChange = abs(box.x - lastX)
            let yChange = abs(box.y - lastY)

            shouldSend = xChange > xChangeThreshold || yChange > yChangeThreshold
        } else {
            // Always send the first valid detection after the characteristic is ready.
            shouldSend = true
        }

        guard shouldSend else {
            return
        }

        // Same idea as the Python code:
        // error = target center - frame center
        // angle command = -error * gain
        let errorX = box.x - targetCenterX
        var angle = -errorX * angleGain

        // Clamp the angle to match the Arduino sketch safety limits.
        if angle < minAngle {
            angle = minAngle
        }

        if angle > maxAngle {
            angle = maxAngle
        }

        // Arduino command format:
        // G<deg>\n
        // Example: G-4.25
        let message = String(format: "G%.2f\n", angle)

        guard let data = message.data(using: .utf8) else {
            return
        }

        arduinoPeripheral.writeValue(
            data,
            for: boundingBoxCharacteristic,
            type: .withResponse
        )

        lastSentCenterX = box.x
        lastSentCenterY = box.y

        bluetoothStatus = "Sent: \(message)"
        print("Sent Dynamixel command: \(message)")
        print("box.x: \(box.x), errorX: \(errorX), angle: \(angle)")
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStatus = "Bluetooth powered on. Scanning for Arduino..."

            // LightBlue on the Mac is advertising the local name "Arduino",
            // but not the custom service UUID, so we scan broadly for this test.
            // For the real Arduino, we can switch this back to [serviceUUID]
            // if the Arduino advertises the service UUID properly.
            central.scanForPeripherals(
                withServices: nil,
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

        // LightBlue may show the peripheral name as the MacBook,
        // while advertising "Arduino" as the local name.
        guard localName == "Arduino" else {
            return
        }

        // Avoid trying to connect repeatedly to the same device.
        if arduinoPeripheral?.identifier == peripheral.identifier {
            return
        }

        bluetoothStatus = "Found Arduino. Connecting..."

        print("Found Arduino")
        print("Peripheral name: \(peripheralName)")
        print("Advertisement local name: \(localName ?? "No local name")")
        print("Peripheral identifier: \(peripheral.identifier)")
        print("RSSI: \(RSSI)")
        print("Advertisement data: \(advertisementData)")

        // Save the peripheral so Core Bluetooth keeps the connection target alive.
        arduinoPeripheral = peripheral

        // This is needed before we can discover services/characteristics.
        arduinoPeripheral?.delegate = self

        // Stop scanning now that we found the device we want.
        central.stopScan()

        // Connect to the LightBlue fake Arduino.
        central.connect(peripheral, options: nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        bluetoothStatus = "Connected. Discovering services..."
        isConnected = true

        print("Connected to Arduino")

        // Look for the custom RedefineLighting service.
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
        boundingBoxCharacteristic = nil
        lastSentCenterX = nil
        lastSentCenterY = nil

        print("Disconnected from Arduino")

        if let error {
            print("Disconnect error: \(error.localizedDescription)")
        }

        // Start scanning again so the app can reconnect if the peripheral comes back.
        central.scanForPeripherals(
            withServices: nil,
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
                boundingBoxCharacteristic = characteristic
                bluetoothStatus = "Ready to send Dynamixel commands"

                print("Bounding box / Dynamixel command characteristic found")
            }
        }
    }
}
