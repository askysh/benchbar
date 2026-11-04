import Foundation
import JavaScriptCore

/// Runs lib/frappe-local/share/cpace-map.js, bundled unmodified as a resource, in
/// JavaScriptCore: one Elligator2 implementation for host and guest (R3.3, J8).
/// Only the 32 hashed bytes cross into JavaScript, as a Uint8Array built through the
/// context's constructor, never through script text (J9). A JSContext is not thread
/// safe: an instance belongs to the one task that made it.
nonisolated final class CPaceMap {
    static let resourceName = "cpace-map"

    private let context: JSContext
    private let mapFunction: JSValue
    private let uint8Array: JSValue

    /// The app bundle's copy is the only one production loads (J9).
    static func bundled() throws(CPace.Failure) -> CPaceMap {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "js") else { throw .mapUnavailable }
        return try CPaceMap(scriptURL: url)
    }

    init(scriptURL: URL) throws(CPace.Failure) {
        guard let source = try? String(contentsOf: scriptURL, encoding: .utf8), let context = JSContext() else { throw .mapUnavailable }
        // Swallow the message: an exception must never carry an input into a log (J9).
        context.exceptionHandler = { context, _ in context?.exception = nil }
        context.evaluateScript(source, withSourceURL: scriptURL)
        guard let function = context.objectForKeyedSubscript("elligator2"), !function.isUndefined,
              let constructor = context.objectForKeyedSubscript("Uint8Array"), !constructor.isUndefined
        else { throw .mapUnavailable }
        self.context = context
        mapFunction = function
        uint8Array = constructor
    }

    func elligator2(_ u: Data) throws(CPace.Failure) -> Data {
        guard u.count == 32,
              let input = uint8Array.construct(withArguments: [u.map { Int($0) }]),
              let output = mapFunction.call(withArguments: [input]),
              output.isObject, output.forProperty("length").toInt32() == 32
        else { throw .abort }
        var bytes = Data(count: 32)
        for index in 0..<32 {
            let value = output.atIndex(index).toInt32()
            guard (0...255).contains(value) else { throw .abort }
            bytes[index] = UInt8(value)
        }
        return bytes
    }
}
