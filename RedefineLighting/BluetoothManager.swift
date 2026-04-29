//
//  BluetoothManager.swift
//  RedefineLighting
//
//  Created by Joshua Marino on 4/28/26.
//

import Foundation
import CoreBluetooth

final class BluetoothManager: NSObject, ObservableObject {
    let objectWillChange: ObservableObjectPublisher
    
