import Foundation

exit(Tool.run(Array(CommandLine.arguments.dropFirst()), host: .process()))
