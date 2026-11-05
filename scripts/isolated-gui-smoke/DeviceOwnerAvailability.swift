import Foundation
import LocalAuthentication
let env=ProcessInfo.processInfo.environment
guard env["GITHUB_ACTIONS"]=="true",env["RUNNER_ENVIRONMENT"]=="github-hosted",env["USER"]=="runner" else {exit(2)}
let context=LAContext();var error:NSError?
let available=context.canEvaluatePolicy(.deviceOwnerAuthentication,error:&error)
print("SYNTHETIC_DEVICE_OWNER_AUTH_AVAILABLE=\(available ? "YES" : "NO")")
if let error { print("SYNTHETIC_DEVICE_OWNER_AUTH_ERROR_DOMAIN=\(error.domain) CODE=\(error.code)") }
