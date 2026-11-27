// Drives the real Cora.app on a clean Mac as a person would, with the mouse and the keyboard, and checks each step.
// Usage: swiftc -O drive.swift -o drive && E2E_KEY=… ./drive <out dir>
import AppKit
import ApplicationServices
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "out"
let started = Date()
setvbuf(stdout, nil, _IOLBF, 0)
DispatchQueue.global().asyncAfter(deadline: .now() + 3900) {
    print("FAIL: the journey took more than 65 minutes")
    exit(3)
}

func log(_ text: String) { print(String(format: "[%6.1fs] ", Date().timeIntervalSince(started)) + text) }
func pause(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

@discardableResult
func run(_ path: String, _ arguments: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

var shots = 0
func shot(_ name: String) {
    shots += 1
    run("/usr/sbin/screencapture", ["-x", "-C", "\(out)/\(String(format: "%02d", shots))-\(name).png"])
}

func fail(_ text: String) -> Never {
    log("FAIL: \(text)")
    shot("failure")
    exit(1)
}

func wait<T>(_ what: String, timeout: Double, every: Double = 0.5, _ probe: () -> T?) -> T {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let value = probe() { return value }
        pause(every)
    }
    fail("timed out after \(Int(timeout))s waiting for \(what)")
}

// MARK: Accessibility

func application(_ bundle: String) -> AXUIElement? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first.map { AXUIElementCreateApplication($0.processIdentifier) }
}

func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var result: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}

func string(_ element: AXUIElement, _ name: String) -> String { value(element, name) as? String ?? "" }

func children(_ element: AXUIElement) -> [AXUIElement] { value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

func find(_ root: AXUIElement, limit: Int = 6000, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    var queue = [root]
    var seen = 0
    while !queue.isEmpty && seen < limit {
        let element = queue.removeFirst()
        seen += 1
        if match(element) { return element }
        queue.append(contentsOf: children(element))
    }
    return nil
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &point)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGRect(origin: point, size: extent)
}

func identified(_ id: String) -> (AXUIElement) -> Bool { { string($0, "AXIdentifier") == id } }

/// The smallest element titled one of `names`, windows aside: a Finder icon rather than the window it is in.
func icon(_ root: AXUIElement, _ names: [String]) -> AXUIElement? {
    var best: (AXUIElement, CGFloat)?
    var queue = [root]
    var seen = 0
    while !queue.isEmpty && seen < 4000 {
        let element = queue.removeFirst()
        seen += 1
        queue.append(contentsOf: children(element))
        let titles = [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute), string(element, kAXFilenameAttribute)]
        guard titles.contains(where: names.contains), !["AXWindow", "AXStaticText", "AXMenuItem", "AXMenuBarItem"].contains(string(element, kAXRoleAttribute)),
              let rect = frame(element), rect.width > 8, rect.width < 220 else { continue }
        let area = rect.width * rect.height
        if best == nil || area < best!.1 { best = (element, area) }
    }
    return best?.0
}

/// Starts a program without waiting: `open` waits while macOS asks about an app from the internet.
func launch(_ path: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

/// The agent that asks about apps from the internet (its bundle id has changed across macOS versions).
func gatekeeperAgent() -> AXUIElement? {
    NSWorkspace.shared.runningApplications.first {
        $0.localizedName == "CoreServicesUIAgent" || ($0.bundleIdentifier ?? "").lowercased().contains("coreservices.uiagent") || ($0.bundleIdentifier ?? "") == "com.apple.CoreServicesUIAgent"
    }.map { AXUIElementCreateApplication($0.processIdentifier) }
}

// MARK: Mouse and keyboard

var cursor = CGEvent(source: nil)?.location ?? CGPoint(x: 512, y: 384)

func move(to target: CGPoint, seconds: Double = 0.55) {
    let steps = max(8, Int(seconds * 60))
    let from = cursor
    for index in 1...steps {
        let t = Double(index) / Double(steps)
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        let point = CGPoint(x: from.x + (target.x - from.x) * eased, y: from.y + (target.y - from.y) * eased)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(useconds_t(seconds / Double(steps) * 1_000_000))
    }
    cursor = target
}

func click(_ point: CGPoint) {
    move(to: point)
    pause(0.15)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(70_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    pause(0.25)
}

func click(_ element: AXUIElement, _ name: String) {
    guard let rect = frame(element), rect.width > 0 else { fail("\(name) has no frame") }
    log("click \(name) at \(Int(rect.midX)),\(Int(rect.midY))")
    click(CGPoint(x: rect.midX, y: rect.midY))
}

func drag(from: CGPoint, to: CGPoint) {
    move(to: from)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
    pause(0.3)
    let steps = 50
    for index in 1...steps {
        let t = Double(index) / Double(steps)
        let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(16_000)
    }
    cursor = to
    pause(0.4)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
    pause(0.5)
}

func type(_ text: String, every: useconds_t = 45_000) {
    for character in text {
        let units = Array(String(character).utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event?.post(tap: .cghidEventTap)
        }
        usleep(every)
    }
}

func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
    pause(0.2)
}

// MARK: The panel, a web page in the window

/// What a web element says: its title, description, value and the text inside it.
func label(_ element: AXUIElement, depth: Int = 2) -> String {
    var parts = [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute), string(element, kAXValueAttribute)]
    if depth > 0 { parts += children(element).map { label($0, depth: depth - 1) } }
    return parts.filter { !$0.isEmpty }.joined(separator: " ")
}

/// Scrolls the panel until the element is on screen, then clicks it like a person.
func reveal(_ element: AXUIElement, _ name: String) {
    AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
    pause(0.8)
    click(element, name)
}

// MARK: The journey

let bundle = "space.usecora.app"
let appPath = "/Applications/Cora.app"
guard let key = ProcessInfo.processInfo.environment["E2E_KEY"], !key.isEmpty else { fail("E2E_KEY is not set") }
let marker = "dal-mac-\(Int(Date().timeIntervalSince1970))"
let question = ProcessInfo.processInfo.environment["E2E_QUESTION"] ?? "Ciao Lia! Usa la tua shell: esegui uname -a e cat /etc/debian_version, poi scrivi \(marker) nel file ~/work/\(marker).txt. Poi apri https://example.com nel browser del tuo desktop e leggi il titolo della pagina. Dimmi in tre frasi cosa hai visto, il titolo e su quale modello giri."
log("AX trusted: \(AXIsProcessTrusted())")

// 1. The DMG, as it opens from Downloads: drag Cora into Applications.
let volume = "/Volumes/Cora"
run("/usr/bin/open", [volume])
pause(3)
shot("dmg")
if let finder = application("com.apple.finder") {
    let source = icon(finder, ["Cora", "Cora.app"])
    let target = icon(finder, ["Applications", "Applicazioni"])
    if let source, let target, let a = frame(source), let b = frame(target) {
        log("drag Cora.app (\(Int(a.midX)),\(Int(a.midY)) \(string(source, kAXRoleAttribute))) onto Applications (\(Int(b.midX)),\(Int(b.midY)) \(string(target, kAXRoleAttribute)))")
        drag(from: CGPoint(x: a.midX, y: a.midY), to: CGPoint(x: b.midX, y: b.midY))
    } else {
        log("Finder icons not found by accessibility: copying with ditto")
    }
}
let copied = Date().addingTimeInterval(40)
while Date() < copied && !FileManager.default.fileExists(atPath: appPath + "/Contents/MacOS/Cora") { pause(1) }
pause(4)
if FileManager.default.fileExists(atPath: appPath + "/Contents/MacOS/Cora") {
    log("Cora.app is in Applications, copied by Finder")
} else {
    log("Finder did not copy it: ditto")
    run("/usr/bin/ditto", ["\(volume)/Cora.app", appPath])
}
shot("installed")
let (gk, gatekeeper) = run("/usr/sbin/spctl", ["-a", "-vvv", "-t", "exec", appPath])
log("Gatekeeper (\(gk)): \(gatekeeper.replacingOccurrences(of: "\n", with: " | "))")
if let finder = application("com.apple.finder"), let window = find(finder, { string($0, kAXRoleAttribute) == "AXWindow" }),
   let close = value(window, kAXCloseButtonAttribute) {
    click(close as! AXUIElement, "close the DMG window")
}

// 2. First launch: macOS asks about an app from the internet, then Cora asks where the space runs.
launch("/usr/bin/open", [appPath])
log("opened Cora from Applications")
let opened = Date().addingTimeInterval(60)
while Date() < opened {
    if let agent = gatekeeperAgent(),
       let button = find(agent, { string($0, kAXRoleAttribute) == "AXButton" && ["Apri", "Open"].contains(string($0, kAXTitleAttribute)) }) {
        pause(2)
        shot("gatekeeper")
        click(button, "Open in the Gatekeeper dialog")
        break
    }
    if let cora = application(bundle), find(cora, identified("choice-local")) != nil { break }
    pause(0.5)
}
let cora = wait("Cora to launch", timeout: 30) { application(bundle) }
let local = wait("the choice of where the space runs", timeout: 30) { find(cora, identified("choice-local")) }
pause(1.5)
shot("welcome")
click(local, "On this Mac")
pause(1)

// 3. Nothing to configure: the app installs and prepares the space.
pause(1.5)
shot("install")
let create = wait("Create the space", timeout: 10) { find(cora, identified("create-space")) }
click(create, "Create the space")
log("creating the space")
var lastStep = ""
var lastActivity = ""
let ready = Date().addingTimeInterval(2100)
while Date() < ready {
    if find(cora, identified("space-ready")) != nil { shot("created"); break }
    if find(cora, { string($0, kAXRoleAttribute) == "AXWebArea" }) != nil { break }
    if let again = find(cora, identified("create-space")), [string(again, kAXTitleAttribute), string(again, kAXDescriptionAttribute)].contains(where: { $0 == "Riprova" || $0 == "Try again" }) {
        fail("a step of the creation failed")
    }
    let texts = run("/bin/sh", ["-c", "tail -n 1 \"$HOME/Library/Application Support/Cora/Local/cora.log\" 2>/dev/null"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
    if texts != lastStep, !texts.isEmpty { lastStep = texts; log("server: \(texts.prefix(140))") }
    let step = (find(cora, { string($0, kAXRoleAttribute) == "AXStaticText" && string($0, "AXIdentifier") == "space-activity" }).map { string($0, kAXValueAttribute) }) ?? ""
    if !step.isEmpty, step != lastActivity { lastActivity = step; log("wizard: \(step.prefix(140))") }
    pause(0.3)
}
guard find(cora, identified("space-ready")) != nil || find(cora, { string($0, kAXRoleAttribute) == "AXWebArea" }) != nil else { fail("the space was not ready within 35 minutes") }
log("space ready")

// 4. The panel opens in the window, signed in: a new agent, then a real question to it.
func webArea() -> AXUIElement? { find(cora, { string($0, kAXRoleAttribute) == "AXWebArea" }) }
func composer(_ web: AXUIElement) -> AXUIElement? {
    find(web, limit: 20000) { element in
        let role = string(element, kAXRoleAttribute)
        guard ["AXTextArea", "AXTextField"].contains(role), (frame(element)?.width ?? 0) > 100 else { return false }
        let hint = [string(element, "AXPlaceholderValue"), string(element, kAXDescriptionAttribute), string(element, kAXTitleAttribute)].joined(separator: " ")
        return role == "AXTextArea" || hint.contains("Scrivi")
    }
}
_ = wait("the panel in the window", timeout: 60) { webArea() }
pause(3)

// The panel opens on its New agent page: the agent is made there, as in any Cora space.
let nameField = wait("the New agent page's name field", timeout: 40) { () -> AXUIElement? in
    guard let web = webArea() else { return nil }
    return find(web, limit: 20000) { string($0, kAXRoleAttribute) == "AXTextField" && string($0, "AXPlaceholderValue").contains("Marta") }
}
shot("new-agent")
click(nameField, "the agent's name")
type("Lia")
pause(0.8)
press(36)
log("created the agent Lia from the panel's New agent page")
/// An agent's tab is a link to #/agent/<id>/<tab>.
func tab(_ key: String) -> AXUIElement {
    wait("the agent's \(key) tab", timeout: 30) { () -> AXUIElement? in
        guard let web = webArea() else { return nil }
        return find(web, limit: 20000) { element in
            guard string(element, kAXRoleAttribute) == "AXLink" else { return false }
            let url = (value(element, "AXURL") as? URL)?.absoluteString ?? (value(element, "AXURL") as? String) ?? ""
            return url.contains("#/agent/") && url.hasSuffix("/\(key)")
        }
    }
}
pause(1.5)
shot("agent-created")

// The model and its key go where a person puts them: the agent's Brain tab.
reveal(tab("cervello"), "Cervello")
pause(2)
let harness = wait("the Harness menu", timeout: 30) { () -> AXUIElement? in
    guard let web = webArea() else { return nil }
    return find(web, limit: 20000) { string($0, kAXRoleAttribute) == "AXPopUpButton" && label($0).contains("Harness di Cora") }
}
shot("brain")
reveal(harness, "Harness")
pause(1)
if let item = find(cora, limit: 20000, { string($0, kAXRoleAttribute) == "AXMenuItem" && string($0, kAXTitleAttribute) == "DeepSeek Harness" }) {
    click(item, "DeepSeek Harness")
} else {
    log("menu item not found by accessibility: choosing it with the keyboard")
    type("DeepSeek H")
    press(36)
}
pause(1.5)
let keyField = wait("the API key field", timeout: 20) { () -> AXUIElement? in
    guard let web = webArea() else { return nil }
    return find(web, limit: 20000) { ["AXTextField", "AXSecureTextField"].contains(string($0, kAXRoleAttribute)) && string($0, "AXPlaceholderValue").contains("chiave API") }
}
reveal(keyField, "DeepSeek Platform key")
type(key, every: 12_000)
pause(0.6)
shot("brain-key")
func webButton(_ text: String) -> AXUIElement {
    wait("the button \(text)", timeout: 20) { () -> AXUIElement? in
        guard let web = webArea() else { return nil }
        return find(web, limit: 20000) { string($0, kAXRoleAttribute) == "AXButton" && label($0, depth: 4).contains(text) }
    }
}
reveal(webButton("Aggiungi la tua chiave"), "Aggiungi la tua chiave")
pause(2.5)
// DeepSeek V4.1 Flash comes already chosen with the key; a click keeps it.
if let web = webArea(), let flash = find(web, limit: 20000, { string($0, kAXRoleAttribute) == "AXButton" && label($0, depth: 5).contains("V4.1 Flash") }) {
    reveal(flash, "DeepSeek V4.1 Flash")
    pause(1)
} else {
    log("DeepSeek V4.1 Flash is already the chosen model")
}
reveal(webButton("Salva"), "Salva")
pause(2.5)
shot("brain-saved")
let agentModel = run("/Applications/Cora.app/Contents/MacOS/cora-node", ["--no-warnings", "-e", "const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv[1],{readOnly:true});process.stdout.write(JSON.stringify(db.prepare(\"select json_extract(data,'$.name') name, json_extract(data,'$.model') model, json_extract(data,'$.credentialId') credential from agents\").all()))", NSHomeDirectory() + "/Library/Application Support/Cora/Local/home/cora.db"]).1
log("agents in the space's database: \(agentModel)")
guard agentModel.contains("deepseek") else { fail("the agent did not take DeepSeek from its Brain tab") }

reveal(tab("chat"), "Chat")
pause(2)
var box: AXUIElement?
let looking = Date().addingTimeInterval(30)
while Date() < looking, box == nil {
    if let web = webArea() { box = composer(web) }
    if box == nil { pause(1) }
}
shot("panel")
if let box {
    click(box, "chat box")
} else if let web = webArea(), let rect = frame(web) {
    var roles: [String: Int] = [:]
    var queue = [web], seen = 0
    while !queue.isEmpty && seen < 3000 { let e = queue.removeFirst(); seen += 1; roles[string(e, kAXRoleAttribute), default: 0] += 1; queue.append(contentsOf: children(e)) }
    log("composer not found by accessibility; web area \(rect) roles \(roles)")
    click(CGPoint(x: rect.maxX - rect.width * 0.35, y: rect.maxY - 22))
} else {
    fail("no panel in the window")
}
type(question)
pause(0.5)
press(36)
log("asked: \(question)")
let db = NSHomeDirectory() + "/Library/Application Support/Cora/Local/home/cora.db"
let node = appPath + "/Contents/MacOS/cora-node"
let reader = "const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv[1],{readOnly:true});const r=db.prepare(\"select author_name a, content c from messages where kind='agent' order by id desc limit 1\").get();process.stdout.write(r?JSON.stringify(r):'')"
let reply = wait("the agent's reply", timeout: 480, every: 2) { () -> String? in
    let text = run(node, ["--no-warnings", "-e", reader, db]).1.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.hasPrefix("{") ? text : nil
}
log("reply in the space's database: \(reply)")
pause(5)
shot("reply")

// 4b. The agent's computer: its own cora-box container in the VM, where its shell really ran.
let docker = appPath + "/Contents/Resources/cora-vm/bin/docker"
let env = (try? String(contentsOfFile: NSHomeDirectory() + "/Library/Application Support/Cora/Local/env", encoding: .utf8)) ?? ""
let host = env.split(separator: "\n").first { $0.hasPrefix("DOCKER_HOST=") }.map { String($0.dropFirst(12)).trimmingCharacters(in: CharacterSet(charactersIn: "'")) } ?? ""
setenv("DOCKER_HOST", host, 1)
setenv("DOCKER_CONFIG", NSHomeDirectory() + "/.cora-local/docker", 1)
let agentId = run(node, ["--no-warnings", "-e", "const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv[1],{readOnly:true});process.stdout.write(db.prepare(\"select id from agents order by position limit 1\").get().id)", db]).1
let (ps, containers) = run(docker, ["ps", "--format", "{{.Names}} {{.Image}} {{.Status}}"])
log("containers in the VM (\(ps)): \(containers.replacingOccurrences(of: "\n", with: " | "))")
guard containers.contains("cora-box-\(agentId)") else { fail("no cora-box container for agent \(agentId)") }
let (catCode, written) = run(docker, ["exec", "-u", "agent", "cora-box-\(agentId)", "sh", "-c", "cat ~/work/\(marker).txt; echo; uname -m; cat /etc/debian_version"])
log("inside cora-box-\(agentId) (\(catCode)): \(written.replacingOccurrences(of: "\n", with: " | "))")
guard catCode == 0, written.contains(marker) else { fail("the file the agent wrote with its shell is not in its container") }
let steps = run(node, ["--no-warnings", "-e", "const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv[1],{readOnly:true});const r=db.prepare(\"select model, steps from traces where agent_id=? order by started_at desc limit 1\").get(process.argv[2]);process.stdout.write(r?r.model+' '+r.steps.slice(0,1500):'')", db, agentId]).1
log("the turn's trace: \(steps)")
guard steps.contains("open_url") || steps.contains("browser") else { fail("the agent did not use its browser") }

// 4c. Its desktop: Xvfb, the window manager, VNC and noVNC running in the container, Chromium on example.com,
// and the panel's Desktop tab showing it through the port Lima forwards from the VM.
let (svCode, services) = run(docker, ["exec", "cora-box-\(agentId)", "sh", "-c", "for p in '[X]vfb' '[x]fce4-session' '[x]11vnc' '[w]ebsockify' '[c]hrom'; do printf '%s ' "$p"; pgrep -c -f "$p" || true; done"])
log("desktop in cora-box-\(agentId) (\(svCode)): \(services.replacingOccurrences(of: "\n", with: " | "))")
for line in services.split(separator: "\n") {
    let parts = line.split(separator: " ")
    guard parts.count == 2, (Int(parts[1]) ?? 0) > 0 else { fail("\(parts.first ?? "") is not running on the agent's desktop") }
}
let (_, published) = run(docker, ["port", "cora-box-\(agentId)", "6080"])
log("noVNC published on \(published.trimmingCharacters(in: .whitespacesAndNewlines))")
if let hostPort = published.split(separator: "\n").first?.split(separator: ":").last {
    let (vncCode, vncPage) = run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "http://127.0.0.1:\(hostPort)/vnc.html"])
    log("noVNC from the Mac: \(vncCode) \(vncPage)")
    guard vncPage == "200" else { fail("the desktop is not reachable from the Mac") }
} else {
    fail("the desktop's port is not published")
}
reveal(tab("desktop"), "Desktop")
pause(12)
shot("desktop")

// 5. The menu bar, untouched: the same popover, now on the space of this Mac.
if let bar = value(cora, "AXExtrasMenuBar"), let item = children(bar as! AXUIElement).first {
    click(item, "Cora in the menu bar")
    pause(3)
    shot("menubar")
    press(53)
} else {
    log("menu bar item not found by accessibility")
}
pause(2)
shot("end")
log("done")
