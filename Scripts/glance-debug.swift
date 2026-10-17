// Sends a command to a Glance launched with --debug. Usage: glance-debug <command>
import Foundation
DistributedNotificationCenter.default().postNotificationName(Notification.Name("app.glanceformac.glance.debug"), object: CommandLine.arguments.dropFirst().first ?? "", userInfo: nil, deliverImmediately: true)
