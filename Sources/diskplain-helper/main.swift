import Foundation
import AndromedaHelperProtocol
import AndromedaHelperCore

let delegate = ListenerDelegate(service: HelperService())
let listener = NSXPCListener(machServiceName: HelperIdentity.helperBundleID)
listener.delegate = delegate
listener.resume()
delegate.start()
dispatchMain()
