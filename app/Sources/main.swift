import AppKit

guard let engine = Engine() else {
    log("cannot load Plustek's engine at \(Engine.defaultPath)")
    exit(1)
}
let app = NSApplication.shared
let controller = Controller(engine: engine)
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
