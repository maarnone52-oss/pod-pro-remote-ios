import Foundation
import CoreMIDI

/// Collega la pagina al MIDI di iOS (interfacce USB e Bluetooth).
/// Le porte sono identificate dal loro ID univoco CoreMIDI, passato alla pagina come testo.
final class MIDIBridge {
    /// Eventi per la pagina: ["type": "ports", ...] oppure ["type": "msg", "id": ..., "data": [...]]
    var onEvent: (([String: Any]) -> Void)?

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var started = false
    private var connectedSources: [MIDIEndpointRef] = []
    private var parsers: [Int32: MessageParser] = [:]   // usato solo dal thread di lettura MIDI
    private let parserLock = NSLock()

    func start() {
        if started { refresh(); return }
        started = true

        MIDIClientCreateWithBlock("POD Pro Remote" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        MIDIOutputPortCreate(client, "Uscita" as CFString, &outPort)
        MIDIInputPortCreateWithBlock(client, "Ingresso" as CFString, &inPort) { [weak self] list, srcRefCon in
            guard let self = self else { return }
            let uid = Int32(truncatingIfNeeded: Int(bitPattern: srcRefCon))
            self.handle(list, from: uid)
        }
        refresh()
    }

    /// Riconnette tutte le sorgenti e comunica l'elenco delle porte alla pagina.
    func refresh() {
        guard started else { return }
        for src in connectedSources { MIDIPortDisconnectSource(inPort, src) }
        connectedSources.removeAll()

        let sources = endpoints(sources: true)
        for (endpoint, uid, _) in sources where uid != 0 {
            let refCon = UnsafeMutableRawPointer(bitPattern: Int(uid))
            if MIDIPortConnectSource(inPort, endpoint, refCon) == noErr {
                connectedSources.append(endpoint)
            }
        }
        let destinations = endpoints(sources: false)
        emit([
            "type": "ports",
            "inputs": sources.filter { $0.1 != 0 }.map { ["id": String($0.1), "name": $0.2] },
            "outputs": destinations.filter { $0.1 != 0 }.map { ["id": String($0.1), "name": $0.2] }
        ])
    }

    func send(to id: String, bytes: [UInt8]) {
        guard started, !bytes.isEmpty, let uid = Int32(id),
              let destination = endpoints(sources: false).first(where: { $0.1 == uid })?.0 else { return }
        let size = bytes.count + 256
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { buffer.deallocate() }
        let list = buffer.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let packet = MIDIPacketListInit(list)
        bytes.withUnsafeBufferPointer { data in
            _ = MIDIPacketListAdd(list, size, packet, 0, bytes.count, data.baseAddress!)
        }
        MIDISend(outPort, destination, list)
    }

    // MARK: - Lettura

    private func handle(_ list: UnsafePointer<MIDIPacketList>, from uid: Int32) {
        parserLock.lock()
        let parser = parsers[uid] ?? MessageParser()
        parsers[uid] = parser
        parserLock.unlock()

        var messages: [[UInt8]] = []
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data) ?? 10
        for packet in list.unsafeSequence() {
            let length = Int(packet.pointee.length)
            let start = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
            let bytes = UnsafeBufferPointer(start: start, count: length)
            messages.append(contentsOf: parser.feed(bytes))
        }
        let id = String(uid)
        for message in messages {
            emit(["type": "msg", "id": id, "data": message.map { Int($0) }])
        }
    }

    private func emit(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    private func endpoints(sources: Bool) -> [(MIDIEndpointRef, Int32, String)] {
        let count = sources ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
        var result: [(MIDIEndpointRef, Int32, String)] = []
        for i in 0..<count {
            let endpoint = sources ? MIDIGetSource(i) : MIDIGetDestination(i)
            if endpoint == 0 { continue }
            var uid: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
            let text = (name?.takeRetainedValue() as String?) ?? "MIDI"
            result.append((endpoint, uid, text))
        }
        return result
    }
}

/// Ricompone i messaggi MIDI completi (anche SysEx divisi su più pacchetti).
final class MessageParser {
    private var sysex: [UInt8]? = nil
    private var status: UInt8 = 0
    private var pending: [UInt8] = []

    func feed(_ bytes: UnsafeBufferPointer<UInt8>) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for byte in bytes {
            if byte >= 0xF8 { continue }                       // clock e simili: ignorati
            if sysex != nil {
                if byte == 0xF7 { sysex!.append(byte); out.append(sysex!); sysex = nil; continue }
                if byte & 0x80 == 0 { sysex!.append(byte); continue }
                sysex = nil                                     // SysEx interrotto da un altro stato
            }
            if byte == 0xF0 { sysex = [0xF0]; status = 0; continue }
            if byte & 0x80 != 0 {
                status = byte
                pending = []
                if MessageParser.dataLength(byte) == 0 { out.append([byte]); status = 0 }
                continue
            }
            guard status != 0 else { continue }
            pending.append(byte)
            if pending.count == MessageParser.dataLength(status) {
                out.append([status] + pending)
                pending = []
                if status >= 0xF0 { status = 0 }                 // niente running status per i messaggi di sistema
            }
        }
        return out
    }

    private static func dataLength(_ status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0xC0, 0xD0: return 1
        case 0xF0:
            switch status {
            case 0xF1, 0xF3: return 1
            case 0xF2: return 2
            default: return 0
            }
        default: return 2
        }
    }
}
