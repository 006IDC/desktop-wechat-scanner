import Foundation

/// Transport only. All callers still parse the original authoritative task tree.
enum ActivityTaskDumpReader {
    static let maximumBytes=2*1024*1024
    static func read(native:(() throws ->Data)?,legacy:() throws ->String,
                     nativeFailed:()->Void) throws ->String {
        guard let native else{return try legacy()}
        do {
            let data=try native()
            guard !data.isEmpty,data.count<=maximumBytes,let text=String(data:data,encoding:.utf8) else {
                throw ScanError("手机任务树响应无效。")
            }
            return text.trimmingCharacters(in:.whitespacesAndNewlines)
        }catch {
            nativeFailed()
            if let error=error as? ScanError,error.message=="Activity task dump timed out" {
                throw ScanError("手机任务读取超时，请重试打开应用。")
            }
            // Only the fixed server-side unavailable reply permits one legacy
            // retry. Timeout, transport loss and corrupt data remain failures.
            guard let error=error as? ScanError,error.message=="Activity task dump unavailable" else{throw error}
            return try legacy()
        }
    }
}
