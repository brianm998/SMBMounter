import Foundation

/// JSON-line control protocol spoken over the unix socket (§11). One request,
/// one response, one line each, then the connection closes.
///
/// Request:  {"op":"status"}
///           {"op":"mount","name":"mammoth"}
///           {"op":"unmount","name":"mammoth","force":false}
///           {"op":"reload"}
///           {"op":"probe","name":"mammoth"}
/// Response: {"ok":true, ...} | {"ok":false,"error":"..."}
struct RPCRequest: Codable {
    var op: String
    var name: String?
    var force: Bool?
}

/// Per-mount status snapshot returned by the `status` op.
struct MountStatusDTO: Codable {
    var name: String
    var state: String
    var mountpoint: String
    var server: String
    var share: String
    var sinceEpoch: Double?
    var recoveryCount: Int
    var lastError: String?
    var mountedFrom: String?
}

struct RPCResponse: Codable {
    var ok: Bool
    var error: String?
    var message: String?
    var mounts: [MountStatusDTO]?

    static func failure(_ message: String) -> RPCResponse {
        RPCResponse(ok: false, error: message, message: nil, mounts: nil)
    }
    static func success(_ message: String? = nil) -> RPCResponse {
        RPCResponse(ok: true, error: nil, message: message, mounts: nil)
    }
}

/// Implemented by the daemon; called by the control socket handler. Each method
/// runs to completion (blocking the socket handler) and returns the response.
protocol DaemonControl: AnyObject {
    func controlStatus() -> RPCResponse
    func controlMount(name: String) -> RPCResponse
    func controlUnmount(name: String, force: Bool) -> RPCResponse
    func controlReload() -> RPCResponse
    func controlProbe(name: String) -> RPCResponse
}
