import Darwin
import AndromedaAppModel
import Foundation

switch Array(CommandLine.arguments.dropFirst()) {
case ["--version"]:
    print(FolderAutomationWorker.version)
case []:
    FolderAutomationWorker.run()
default:
    FileHandle.standardError.write(Data("usage: diskplain-automation-worker [--version]\n".utf8))
    exit(EX_USAGE)
}
