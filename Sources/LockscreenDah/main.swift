import AppKit

if CommandLine.arguments.dropFirst().first == "--evaluate-model" {
    do {
        try RecognitionEvaluator.run(arguments: Array(CommandLine.arguments.dropFirst(2)))
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        FileHandle.standardError.write(Data("\(RecognitionEvaluator.usage)\n".utf8))
        exit(2)
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
