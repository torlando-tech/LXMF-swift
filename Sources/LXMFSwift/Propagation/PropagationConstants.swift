// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  PropagationConstants.swift
//  LXMFSwift
//
//  Constants for LXMF propagation node operations.
//
//  Reference: LXMF/LXMRouter.py propagation constants
//

import Foundation

/// Constants for propagation node operations.
public enum PropagationConstants {

    // MARK: - Link Request Paths

    /// Path for 3-step sync protocol (LIST/WANT/ACK).
    public static let SYNC_PATH = "/get"

    /// Path for sending messages to a propagation node.
    public static let OFFER_PATH = "/offer"

    // MARK: - Destination Aspect

    /// Destination aspect for propagation nodes.
    /// Full destination name: "lxmf.propagation"
    public static let PROPAGATION_ASPECT = "propagation"

    // MARK: - Timeouts

    /// Overall sync operation timeout in seconds.
    public static let SYNC_TIMEOUT: TimeInterval = 120

    /// Link establishment timeout for propagation links.
    public static let LINK_TIMEOUT: TimeInterval = 30

    // MARK: - Transfer Limits

    /// Default maximum messages per transfer (in KB). Matches Python's DELIVERY_LIMIT.
    public static let DEFAULT_PER_TRANSFER_LIMIT = 1000

    /// Default maximum messages per sync request if not announced.
    public static let DEFAULT_PER_SYNC_LIMIT = 20
}
