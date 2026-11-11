import SwiftUI
import CoreImage.CIFilterBuiltins

struct TelegramAuthView: View {
    @Bindable var store: TelegramStore
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var email = ""
    @State private var showQR = false
    private var phase: String { store.authorization.type }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "paperplane.circle.fill").font(.system(size: 70)).foregroundStyle(.cyan).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your Telegram.\nYour cinema.").font(.largeTitle.bold())
                    Text("Browse your groups, find movies and series, and play your files in Velagram.").foregroundStyle(.secondary)
                }
                Group {
                    switch phase {
                    case "authorizationStateWaitPhoneNumber":
                        TextField("Phone number with country code", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber).accessibilityIdentifier("telegram.phone")
                        action("Continue with phone number") { await store.phone(phone) }
                        Button("Log in with another Telegram device") { Task { await store.requestQR() } }
                    case "authorizationStateWaitCode":
                        Text(store.authorization["code_info"]["type"].type == "authenticationCodeTypeTelegramMessage" ? "Enter the code sent to your Telegram app." : "Enter the login code sent by Telegram.")
                        TextField("Login code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).accessibilityIdentifier("telegram.code")
                        action("Verify code") { await store.code(code); code = "" }
                        Button("Resend code") { Task { await store.resendCode() } }.disabled(store.busy)
                    case "authorizationStateWaitPassword":
                        Text("Enter your Telegram two-step verification password.")
                        if let hint = store.authorization["password_hint"].string, !hint.isEmpty { Text("Hint: \(hint)").font(.caption).foregroundStyle(.secondary) }
                        SecureField("Two-step verification password", text: $password).textContentType(.password).accessibilityIdentifier("telegram.password")
                        action("Unlock Telegram") { await store.password(password); password = "" }
                    case "authorizationStateWaitOtherDeviceConfirmation":
                        if let link = store.authorization["link"].string {
                            TelegramQRCode(text: link).frame(width: 224, height: 224).frame(maxWidth: .infinity)
                            Text("In Telegram on your other device, open Settings → Devices → Link Desktop Device and scan this code.")
                            if let url = URL(string: link) { Link("Approve in Telegram", destination: url) }
                        }
                    case "authorizationStateWaitEmailAddress":
                        Text("Telegram requires an email address to deliver your login code.")
                        TextField("Email address", text: $email).keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never)
                        action("Send email code") { await store.email(email) }
                    case "authorizationStateWaitEmailCode":
                        Text("Enter the code sent to your email address.")
                        TextField("Email code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                        action("Verify email") { await store.emailCode(code); code = "" }
                    case "authorizationStateWaitRegistration":
                        ContentUnavailableView("Create your Telegram account first", systemImage: "person.crop.circle.badge.plus", description: Text("Complete account registration in the official Telegram app, then return here to sign in."))
                        Link("Open Telegram", destination: URL(string: "https://telegram.org/apps")!)
                    case "authorizationStateWaitPremiumPurchase":
                        Text("Telegram requires an account verification purchase for this phone number. Complete that step in the official Telegram app, then return to Velagram.")
                    case "authorizationStateClosed":
                        Text("The Telegram session is closed. Reopen Velagram to start a new login.")
                    default:
                        ProgressView(phase == "authorizationStateLoggingOut" ? "Signing out…" : "Starting Telegram…")
                    }
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                if let notice = store.notice { Label(notice, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).accessibilityIdentifier("telegram.error") }
                Text("Your session stays encrypted on this device. Velagram does not send your login code or password to a separate server.").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.navigationTitle("Telegram").navigationBarTitleDisplayMode(.inline)
    }
    private func action(_ title: String, run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: {
            HStack { Spacer(); if store.busy { ProgressView() } else { Text(title).fontWeight(.semibold) }; Spacer() }.padding(.vertical, 8)
        }.buttonStyle(.borderedProminent).disabled(store.busy)
    }
}

private struct TelegramQRCode: View {
    let text: String
    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
    var body: some View {
        if let image { Image(uiImage: image).interpolation(.none).resizable().scaledToFit().padding(12).background(.white, in: RoundedRectangle(cornerRadius: 20)).accessibilityLabel("Telegram login QR code") }
    }
}
