// GooglyEyes — menü çubuğunda mouse'u takip eden googly gözler + bölge ekran görüntüsü + işaretleme
import Cocoa
import Carbon.HIToolbox
import ServiceManagement
import CoreImage
import ScreenCaptureKit
import ApplicationServices
import CoreText
import ImageIO

// MARK: - Dokular

enum Tex {
    static func load(_ name: String) -> NSImage {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url) { return img }
        return NSImage(size: NSSize(width: 1, height: 1))
    }
    static let sclera = load("sclera")
    static let pupil  = load("pupil")
    static let shine  = load("shine")
    static let lid    = load("lid")
    static let spiral = load("spiral")
}

// MARK: - Ayarlar

enum Pref {
    static let d = UserDefaults.standard
    /// saniye; 0 = uyku kapalı
    static var sleepAfter: Double {
        get { d.object(forKey: "sleepAfter") as? Double ?? 60 }
        set { d.set(newValue, forKey: "sleepAfter") }
    }
    static var randomBehaviors: Bool {
        get { d.object(forKey: "randomBehaviors") as? Bool ?? true }
        set { d.set(newValue, forKey: "randomBehaviors") }
    }
    /// true: panoya + masaüstüne, false: sadece panoya
    static var saveToDesktop: Bool {
        get { d.object(forKey: "saveToDesktop") as? Bool ?? true }
        set { d.set(newValue, forKey: "saveToDesktop") }
    }
    static var webpToPng: Bool {
        get { d.object(forKey: "webpToPng") as? Bool ?? true }
        set { d.set(newValue, forKey: "webpToPng") }
    }
    static var autoAnnotate: Bool {
        get { d.bool(forKey: "autoAnnotate") }
        set { d.set(newValue, forKey: "autoAnnotate") }
    }
}

// MARK: - Tek göz (googly fizik)

final class Eye {
    var pos = CGPoint.zero        // bebeğin merkezden ofseti (pt)
    var vel = CGPoint.zero
    var held = false              // fare tuşu basılı mı
    var closedUntil: CFTimeInterval = 0

    /// Kısa göz kırpma (basılı tutma ayrıca `held` ile yönetilir)
    func blink(_ duration: CFTimeInterval = 0.16) {
        closedUntil = max(closedUntil, CACurrentMediaTime() + duration)
    }
    var isClosed: Bool { held || CACurrentMediaTime() < closedUntil }

    /// target: bebeğin gitmek istediği ofset; maxR: gidebileceği en uzak mesafe
    func step(target: CGPoint, maxR: CGFloat) {
        // yay + sönüm → hafif "googly" sallantı
        let k: CGFloat = 0.22, damping: CGFloat = 0.72
        vel.x = (vel.x + (target.x - pos.x) * k) * damping
        vel.y = (vel.y + (target.y - pos.y) * k) * damping
        pos.x += vel.x; pos.y += vel.y
        let d = hypot(pos.x, pos.y)
        if d > maxR {
            // kenara çarpınca sek
            let nx = pos.x / d, ny = pos.y / d
            pos = CGPoint(x: nx * maxR, y: ny * maxR)
            let vn = vel.x * nx + vel.y * ny
            if vn > 0 { vel.x -= 1.6 * vn * nx; vel.y -= 1.6 * vn * ny }
        }
    }
}

enum Special { case none, roll, cross, spiral }

// MARK: - Uygulama

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let leftEye = Eye(), rightEye = Eye()
    var timer: Timer?
    var hotKeyRef: EventHotKeyRef?
    var globalClickMonitor: Any?
    var localClickMonitor: Any?
    var capturing = false
    var selectionWindows: [NSWindow] = []
    var frozen: [CGDirectDisplayID: CGImage] = [:]
    let webpWatcher = WebpWatcher()
    var updateAvailable = false
    var settings: SettingsWindowController?
    var updating = false

    // çöp kutusu korkusu
    var fear: CGFloat = 0
    var trashOpen = false
    var lastTrashCheck: CFTimeInterval = 0
    var forcedFearUntil: CFTimeInterval = 0
    var previousApp: NSRunningApplication?
    var annotationWindows: [AnnotationWindowController] = []
    var lastDrawKey = ""

    // görsel boyutlar (pt) — göz boyu menü çubuğu yüksekliğine göre ayarlanır
    var eyeSize: CGFloat = 22
    var barHeight: CGFloat = 24
    let gap: CGFloat = 2
    let pad: CGFloat = 3
    var pupilSize: CGFloat { eyeSize * 0.56 }
    var maxR: CGFloat { (eyeSize - pupilSize) / 2 - 0.6 }
    var eyesWidth: CGFloat { pad * 2 + eyeSize * 2 + gap }
    var zzzWidth: CGFloat { barHeight * 1.0 }

    // davranış durumu
    var lastMouse = CGPoint.zero
    var lastActivity = CACurrentMediaTime()
    var sleeping = false
    var sleepStart: CFTimeInterval = 0
    var shakeSamples: [(t: CFTimeInterval, x: CGFloat)] = []
    var dizzyStart: CFTimeInterval = -100
    let dizzyDuration: CFTimeInterval = 2.4
    var spinPhase: CGFloat = 0
    var surpriseStart: CFTimeInterval = -100
    var surpriseStrength: CGFloat = 1
    let surpriseDuration: CFTimeInterval = 1.1
    let spiralDuration: CFTimeInterval = 3.2
    var special: Special = .none
    var specialStart: CFTimeInterval = 0
    var nextBlinkAt = CACurrentMediaTime() + 4
    var nextSpecialAt = CACurrentMediaTime() + 40
    var lastChangeCount = NSPasteboard.general.changeCount
    var lastPasteboardCheck: CFTimeInterval = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: eyesWidth)
        statusItem.button?.imageScaling = .scaleNone
        statusItem.menu = buildMenu()
        installEditMenu()

        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)

        // Ekranın herhangi bir yerinde tık: sol → sol göz, sağ → sağ göz
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            self?.handleClick(e)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            self?.handleClick(e)
            return e
        }

        lastMouse = NSEvent.mouseLocation
        if !AXIsProcessTrusted() && !UserDefaults.standard.bool(forKey: "askedAX") {
            UserDefaults.standard.set(true, forKey: "askedAX")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        registerHotKey()
        webpWatcher.onConverted = { [weak self] in self?.surprise(0.6) }
        // açılıştan biraz sonra bir kez güncelleme var mı bak; sadece menüde haber verir, kendiliğinden kurmaz
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkForUpdates(manual: false) }
        if Pref.webpToPng { webpWatcher.start() }
        tick()
    }

    func handleClick(_ e: NSEvent) {
        noteActivity(CACurrentMediaTime())
        if capturing { return }
        if e.type == .leftMouseDown { leftEye.blink() } else { rightEye.blink() }
    }

    /// Yazı kutularında ⌘C / ⌘V / ⌘Z çalışsın diye görünmez bir Düzen menüsü
    func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem); appItem.submenu = NSMenu()
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Düzen")
        edit.addItem(withTitle: "Geri Al", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tümünü Seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: Menü

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        let shot = NSMenuItem(title: "Bölge Ekran Görüntüsü Al", action: #selector(captureRegion), keyEquivalent: "")
        shot.target = self; shot.tag = 47
        m.addItem(shot)
        m.addItem(item("Panodaki Görseli Aç ve İşaretle…", #selector(openAnnotatorFromClipboard)))
        m.addItem(.separator())

        let tryItem = NSMenuItem(title: "Hareketleri Dene", action: nil, keyEquivalent: "")
        let tryMenu = NSMenu()
        for (title, tag) in [("Şaşır 😮", 3), ("Göz Devir 🙄", 4), ("Spiral Göz 🌀", 6),
                             ("Sersemle 💫", 7), ("Uyu 😴", 8), ("Kork 😱", 9)] {
            let i = item(title, #selector(playMove(_:))); i.tag = 200 + tag
            tryMenu.addItem(i)
        }
        tryItem.submenu = tryMenu
        m.addItem(tryItem)
        m.addItem(.separator())

        // sadece yeni sürüm varken / güncellenirken görünür
        let upd = item("✨ Güncelleme Var: Yükle", #selector(checkForUpdatesManually)); upd.tag = 46
        upd.isHidden = true
        m.addItem(upd)
        let settingsItem = NSMenuItem(title: "Ayarlar…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        m.addItem(settingsItem)
        m.addItem(item("GooglyEyes Hakkında", #selector(showAbout)))
        m.addItem(NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return m
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let i = menu.item(withTag: 47) {
            let hk = Hotkey.load()
            i.keyEquivalent = hk.menuKey
            i.keyEquivalentModifierMask = hk.cocoaMods
        }
    }

    // MARK: Ayarlar

    @objc func openSettings() {
        if settings == nil { settings = SettingsWindowController(app: self) }
        NSApp.activate(ignoringOtherApps: true)
        settings?.refresh()
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    func setLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert("Girişte başlatma ayarlanamadı", error.localizedDescription)
        }
    }

    func setWebp(_ on: Bool) {
        Pref.webpToPng = on
        if on { webpWatcher.start() } else { webpWatcher.stop() }
    }

    /// Kısayol kutusu seçiliyken genel kısayolu geçici olarak kapat (yazarken ekran görüntüsü başlamasın)
    func suspendHotKey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    }

    @objc func toggleAutoAnnotate() { Pref.autoAnnotate.toggle() }
    // MARK: Hakkında

    @objc func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let commit = Updater.installedCommit
        let build = commit == "unknown" ? "yerel derleme" : String(commit.prefix(7))

        let center = NSMutableParagraphStyle(); center.alignment = .center
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                     .foregroundColor: NSColor.secondaryLabelColor,
                                                     .paragraphStyle: center]
        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(string: "Ece Gener tarafından yapıldı 👀\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: center]))
        credits.append(NSAttributedString(string: "Menü çubuğunda mouse'u takip eden gözler,\nbölge ekran görüntüsü ve işaretleme.\n\n", attributes: small))
        var link = small
        link[.link] = URL(string: "https://github.com/\(Updater.repo)")!
        credits.append(NSAttributedString(string: "github.com/\(Updater.repo)", attributes: link))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "GooglyEyes",
            .applicationVersion: version,
            .version: build,
            .credits: credits,
        ])
    }

    // MARK: Güncelleme

    func setUpdateMenu(_ title: String, enabled: Bool = true) {
        if let i = statusItem.menu?.item(withTag: 46) {
            i.title = title
            i.isEnabled = enabled
            i.isHidden = !(updateAvailable || updating)
        }
        settings?.refresh()
    }

    @objc func checkForUpdatesManually() {
        if updateAvailable { confirmUpdate(); return }
        checkForUpdates(manual: true)
    }

    func checkForUpdates(manual: Bool) {
        if updating { return }
        if manual { setUpdateMenu("Kontrol ediliyor…", enabled: false) }
        Updater.latestCommit { [weak self] latest in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let latest = latest else {
                    self.setUpdateMenu("Güncellemeleri Kontrol Et")
                    if manual { self.alert("Kontrol edilemedi", "GitHub'a ulaşılamadı. İnternet bağlantını kontrol edip tekrar dene.") }
                    return
                }
                if latest != Updater.installedCommit {
                    self.updateAvailable = true
                    self.setUpdateMenu("✨ Güncelleme Var: Yükle")
                    self.surprise(0.8)
                    if manual { self.confirmUpdate() }
                } else {
                    self.updateAvailable = false
                    self.setUpdateMenu("Güncellemeleri Kontrol Et")
                    if manual { self.alert("Güncelsin ✓", "GooglyEyes'ın en son sürümünü kullanıyorsun.") }
                }
            }
        }
    }

    func confirmUpdate() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Yeni sürüm hazır"
        a.informativeText = "GooglyEyes son sürümü indirip bu Mac'te kuracak ve kendini yeniden başlatacak. Bu 10–30 saniye sürebilir."
        a.addButton(withTitle: "Güncelle")
        a.addButton(withTitle: "Sonra")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        updating = true
        setUpdateMenu("Güncelleniyor…", enabled: false)
        Updater.install { [weak self] ok, log in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if ok {
                    // kurulum bitti ama bu (eski) kopya hâlâ açıksa: kendini kapat, yenisini aç
                    let app = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Applications/GooglyEyes.app").path
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/sh")
                    p.arguments = ["-c", "sleep 1; open \"$1\"", "relaunch", app]
                    try? p.run()
                    NSApp.terminate(nil)
                    return
                }
                self.updating = false
                self.setUpdateMenu("✨ Güncelleme Var: Yükle")
                let needsTools = log.contains("Swift derleyicisi yok")
                self.alert("Güncelleme tamamlanamadı",
                           needsTools
                           ? "Bu Mac'te Xcode Komut Satırı Araçları yok. Açılan Apple penceresinde 'Yükle'ye bas; kurulum bitince menüden tekrar 'Güncelleme Var: Yükle'yi seç."
                           : "Ayrıntı:\n" + String(log.suffix(600)))
            }
        }
    }

    @objc func setSaveTarget(_ sender: NSMenuItem) { Pref.saveToDesktop = sender.tag == 301 }
    @objc func toggleWebp() {
        Pref.webpToPng.toggle()
        if Pref.webpToPng { webpWatcher.start() } else { webpWatcher.stop() }
    }
    @objc func toggleRandom() { Pref.randomBehaviors.toggle() }
    @objc func setSleep(_ sender: NSMenuItem) {
        Pref.sleepAfter = sender.representedObject as? Double ?? 60
        lastActivity = CACurrentMediaTime()
    }
    @objc func sleepNow() { goToSleep(CACurrentMediaTime()) }
    /// Menüden bir hareketi elle oynat
    @objc func playMove(_ sender: NSMenuItem) {
        let now = CACurrentMediaTime()
        if sender.tag != 208 { sleeping = false; lastActivity = now }
        switch sender.tag - 200 {
        case 1: leftEye.blink(0.25); rightEye.blink(0.25)
        case 2: (Bool.random() ? leftEye : rightEye).blink(0.35)
        case 3: surprise(1.0)
        case 4: special = .roll; specialStart = now
        case 5: special = .cross; specialStart = now
        case 6: special = .spiral; specialStart = now
        case 7: special = .none; dizzyStart = now
        case 8: goToSleep(now)
        case 9: forcedFearUntil = now + 2.5
        default: break
        }
    }

    @objc func toggleLogin(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Girişte başlatma ayarlanamadı", error.localizedDescription)
        }
    }

    @objc func openAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    // MARK: Davranışlar

    func noteActivity(_ now: CFTimeInterval) {
        lastActivity = now
        if sleeping {
            sleeping = false
            surprise(1.0)            // uyanınca irkilme
        }
    }

    func goToSleep(_ now: CFTimeInterval) {
        sleeping = true
        sleepStart = now
        special = .none
    }

    func surprise(_ strength: CGFloat) {
        surpriseStart = CACurrentMediaTime()
        surpriseStrength = strength
        leftEye.closedUntil = 0; rightEye.closedUntil = 0
    }

    /// 0…1 arası, şaşırma ne kadar güçlü
    func surpriseAmount(_ now: CFTimeInterval) -> CGFloat {
        if capturing {
            // seçim sürerken göz bebekleri büyük kalır
            let u = min(1, (now - surpriseStart) / (0.14 * surpriseDuration))
            return CGFloat(1 - pow(1 - u, 3))
        }
        let t = (now - surpriseStart) / surpriseDuration
        if t < 0 || t >= 1 { return 0 }
        let a = t < 0.14 ? 1 - pow(1 - t / 0.14, 3) : pow(1 - (t - 0.14) / 0.86, 2)
        return CGFloat(a) * surpriseStrength
    }

    func isDizzy(_ now: CFTimeInterval) -> Bool { now - dizzyStart < dizzyDuration }

    /// Mouse'u hızla sağa sola sallamayı algıla
    func trackShake(_ now: CFTimeInterval, _ x: CGFloat) {
        shakeSamples.append((now, x))
        shakeSamples.removeAll { now - $0.t > 0.8 }
        guard shakeSamples.count > 6 else { return }
        var reversals = 0, dir: CGFloat = 0, seg: CGFloat = 0, total: CGFloat = 0
        for i in 1..<shakeSamples.count {
            let dx = shakeSamples[i].x - shakeSamples[i - 1].x
            if abs(dx) < 1 { continue }
            total += abs(dx)
            let s: CGFloat = dx > 0 ? 1 : -1
            if s == dir { seg += abs(dx) }
            else {
                if dir != 0 && seg > 30 { reversals += 1 }
                dir = s; seg = abs(dx)
            }
        }
        if reversals >= 4 && total > 600 && now - dizzyStart > dizzyDuration + 0.5 {
            dizzyStart = now
            special = .none
            shakeSamples.removeAll()
        }
    }

    // MARK: Animasyon

    func tick() {
        let now = CACurrentMediaTime()
        guard let button = statusItem.button, let win = button.window else { return }

        // menü çubuğu yüksekliğine göre boyut (çentikli ekranlarda daha büyük)
        let bh = max(22, button.bounds.height)
        let size = min(28, max(20, bh - 2))
        if size != eyeSize || bh != barHeight {
            eyeSize = size; barHeight = bh
            lastDrawKey = ""
        }
        let wantLength = eyesWidth + (sleeping ? zzzWidth : 0)
        if abs(statusItem.length - wantLength) > 0.1 { statusItem.length = wantLength; lastDrawKey = "" }

        // basılı tutulan tuşlar: sol → sol göz, sağ → sağ göz kapalı kalır
        let pressed = NSEvent.pressedMouseButtons
        leftEye.held = pressed & 1 != 0
        rightEye.held = pressed & 2 != 0

        let mouse = NSEvent.mouseLocation

        // çöp kutusu korkusu: Dock'taki çöp kutusunun üstündeyken ya da çöp kutusu penceresi açıkken
        if now - lastTrashCheck > 0.4 {
            lastTrashCheck = now
            trashOpen = TrashWatch.trashWindowOpen()
        }
        var overTrash = false
        if let f = TrashWatch.trashFrame(now), let primary = NSScreen.screens.first {
            let p = CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)   // AX koordinatları: sol-üst orijin
            overTrash = f.insetBy(dx: -3, dy: -3).contains(p)
        }
        let scared = (overTrash || trashOpen || now < forcedFearUntil) && !sleeping
        fear += ((scared ? 1 : 0) - fear) * (scared ? 0.25 : 0.07)
        if fear < 0.003 { fear = 0 }

        if hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) > 0.5 {
            noteActivity(now)
            trackShake(now, mouse.x)
        }
        lastMouse = mouse
        if pressed != 0 { noteActivity(now) }

        // uyku
        if !sleeping && Pref.sleepAfter > 0 && now - lastActivity > Pref.sleepAfter { goToSleep(now) }

        // panoya bir şey kopyalanınca hafif şaşırma
        if now - lastPasteboardCheck > 0.3 {
            lastPasteboardCheck = now
            let c = NSPasteboard.general.changeCount
            if c != lastChangeCount { lastChangeCount = c; if !sleeping { surprise(0.6) } }
        }

        // rastgele davranışlar
        let dizzy = isDizzy(now)
        if Pref.randomBehaviors && !sleeping && !dizzy {
            if now >= nextBlinkAt && special != .spiral {
                if Double.random(in: 0..<1) < 0.15 { (Bool.random() ? leftEye : rightEye).blink(0.28) }
                else { leftEye.blink(); rightEye.blink() }
                nextBlinkAt = now + Double.random(in: 3...9)
            }
            if now >= nextSpecialAt && special == .none {
                special = [Special.roll, .cross, .spiral].randomElement()!
                specialStart = now
                nextSpecialAt = now + Double.random(in: 25...70)
            }
        }
        let st = now - specialStart
        if (special == .roll && st > 1.3) || (special == .cross && st > 1.5)
            || (special == .spiral && st > spiralDuration) { special = .none }

        // hedefler
        let bRect = win.convertToScreen(button.convert(button.bounds, to: nil))
        let centers = (0..<2).map { i in
            CGPoint(x: bRect.minX + pad + eyeSize / 2 + CGFloat(i) * (eyeSize + gap), y: bRect.midY)
        }
        if dizzy {
            let p = CGFloat((now - dizzyStart) / dizzyDuration)
            spinPhase += (32 * (1 - p) * (1 - p) + 3) / 60     // çılgın dönüş, yavaşlayarak sersemleme
        }
        for (i, eye) in [leftEye, rightEye].enumerated() {
            let c = centers[i]
            var target: CGPoint
            if dizzy {
                let ph = i == 0 ? spinPhase : -spinPhase + .pi / 2
                target = CGPoint(x: cos(ph) * maxR, y: sin(ph) * maxR)
            } else if special == .roll {
                let a = CGFloat.pi - CGFloat(st / 1.3) * 2 * .pi   // soldan başlayıp yukarıdan tam tur
                target = CGPoint(x: cos(a) * maxR, y: sin(a) * maxR)
            } else if special == .spiral {
                target = .zero                                     // spiral göz ortada döner
            } else if special == .cross {
                target = CGPoint(x: (i == 0 ? 1 : -1) * maxR, y: -maxR * 0.2)
            } else {
                let dx = mouse.x - c.x, dy = mouse.y - c.y
                let d = max(hypot(dx, dy), 0.001)
                // fare tam üstündeyse ortaya döner; iki gözün arasındaysa birbirlerine bakarlar
                let reach = min(1, d / (eyeSize * 0.45)) * maxR
                target = CGPoint(x: dx / d * reach, y: dy / d * reach)
            }
            eye.step(target: target, maxR: maxR)
        }

        // değişmediyse yeniden çizme (CPU dostu)
        let sAmt = surpriseAmount(now)
        var key = [leftEye, rightEye].map {
            String(format: "%.2f,%.2f,%d", $0.pos.x, $0.pos.y, $0.isClosed ? 1 : 0)
        }.joined(separator: "|") + String(format: "|%.3f|%d|%.3f", sAmt, sleeping ? 1 : 0, fear)
        if sleeping { key += "|\(Int(now * 30))" }
        if special == .spiral || fear > 0.01 { key += "|s\(Int(now * 60))" }
        if key == lastDrawKey { return }
        lastDrawKey = key
        button.image = renderEyes(now: now, surprise: sAmt)
    }

    func renderEyes(now: CFTimeInterval, surprise s: CGFloat) -> NSImage {
        let w = eyesWidth + (sleeping ? zzzWidth : 0)
        let h = barHeight
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { [self] _ in
            for (i, eye) in [leftEye, rightEye].enumerated() {
                let cx = pad + eyeSize / 2 + CGFloat(i) * (eyeSize + gap)
                drawEye(eye, index: i, center: CGPoint(x: cx, y: h / 2), surprise: s, now: now)
            }
            if sleeping { drawZzz(x0: eyesWidth - pad + 1, height: h, now: now) }
            return true
        }
        img.isTemplate = false
        return img
    }

    func drawEye(_ eye: Eye, index: Int, center c: CGPoint, surprise s: CGFloat, now: CFTimeInterval) {
        let es = eyeSize
        if sleeping || (eye.isClosed && s < 0.01) || (eye.held && !capturing) {
            // kapalıyken: göz akı açık kalır, üstünde siyah tire, en üstte kubbe parlaması
            let sRect = NSRect(x: c.x - es / 2, y: c.y - es / 2, width: es, height: es)
            Tex.sclera.draw(in: sRect)
            let lw = es * 0.7
            let lh = max(2.5, lw * (Tex.lid.size.height / max(Tex.lid.size.width, 1)))
            Tex.lid.draw(in: NSRect(x: c.x - lw / 2, y: c.y - lh / 2, width: lw, height: lh))
            Tex.shine.draw(in: sRect, from: .zero, operation: .sourceOver, fraction: 0.9)
            return
        }
        // şaşırınca göz akı sabit kalır, göz bebeği beyazın neredeyse tamamını kaplayacak kadar büyür
        var ps = pupilSize + (es * 0.88 - pupilSize) * s
        ps *= 1 - 0.55 * fear                      // korkunca göz bebeği küçülür
        let range = (es - ps) / 2 - 0.6
        let sRect = NSRect(x: c.x - es / 2, y: c.y - es / 2, width: es, height: es)
        Tex.sclera.draw(in: sRect)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: sRect.insetBy(dx: 0.5, dy: 0.5)).addClip()
        let k = maxR > 0 ? range / maxR : 1
        let jitter = fear * eyeSize * 0.05         // korkunca titrer
        let p = CGPoint(x: c.x + eye.pos.x * k + CGFloat.random(in: -1...1) * jitter,
                        y: c.y + eye.pos.y * k + CGFloat.random(in: -1...1) * jitter)
        if special == .spiral {
            // spiral göz bebeği: büyüyerek gelir, kendi merkezinde içe doğru akar gibi döner
            let st = now - specialStart
            let grow = CGFloat(min(1, min(st, spiralDuration - st) / 0.25))
            let e = grow * grow * (3 - 2 * grow)
            let size = ps + (es * 0.86 - ps) * max(0, e)
            let angle = CGFloat(st) * 2 * .pi * 0.9
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: p.x, yBy: p.y)
            if index == 1 {
                // sağ göz: orijinal spiral, saat yönü tersi → üstü buruna (sola) döner, kollar içe akar
                t.rotate(byRadians: angle)
            } else {
                // sol göz: aynalanmış spiral, saat yönü → üstü buruna (sağa) döner, kollar yine içe akar
                t.rotate(byRadians: -angle)
                t.scaleX(by: -1, yBy: 1)
            }
            t.concat()
            Tex.spiral.draw(in: NSRect(x: -size / 2, y: -size / 2, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
        } else {
            Tex.pupil.draw(in: NSRect(x: p.x - ps / 2, y: p.y - ps / 2, width: ps, height: ps))
        }
        NSGraphicsContext.restoreGraphicsState()
        Tex.shine.draw(in: sRect, from: .zero, operation: .sourceOver, fraction: 0.9)
    }

    /// Küçükten büyüğe sırayla beliren, hafifçe salınan "z Z Z"
    func drawZzz(x0: CGFloat, height h: CGFloat, now: CFTimeInterval) {
        let cycle = 2.8
        let t = (now - sleepStart).truncatingRemainder(dividingBy: cycle)
        let specs: [(size: CGFloat, x: CGFloat, y: CGFloat, delay: Double)] = [
            (h * 0.32, x0,            h * 0.10, 0.0),
            (h * 0.44, x0 + h * 0.22, h * 0.26, 0.45),
            (h * 0.58, x0 + h * 0.46, h * 0.38, 0.9),
        ]
        for (i, z) in specs.enumerated() {
            let local = t - z.delay
            if local < 0 { continue }
            var alpha = min(1, local / 0.35)
            let fadeOutStart = cycle - 0.45
            if t > fadeOutStart { alpha *= max(0, 1 - (t - fadeOutStart) / 0.45) }
            if alpha <= 0 { continue }
            let bob = CGFloat(sin(now * 2.4 + Double(i))) * h * 0.025
            let rise = CGFloat(min(1, local / 0.35)) * h * 0.04
            ZGlyph.draw(in: NSRect(x: z.x, y: z.y + bob + rise - h * 0.04, width: z.size * 0.82, height: z.size),
                        alpha: CGFloat(alpha))
        }
    }

    func blinkBoth() { leftEye.blink(); rightEye.blink() }

    // MARK: Kısayol (varsayılan ⌥⇧S, menüden değiştirilebilir)

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData = userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.captureRegion() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let hk = Hotkey.load()
        if applyHotKey(hk) != noErr {
            alert("\(hk.display) kısayolu kaydedilemedi",
                  "Başka bir uygulama bu kısayolu kullanıyor olabilir. Ayarlar'dan başka bir kısayol seçebilirsin.")
        }
    }

    /// Kısayolu (yeniden) kaydet; başarılıysa noErr döner
    @discardableResult
    func applyHotKey(_ hk: Hotkey) -> OSStatus {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        let id = EventHotKeyID(signature: OSType(0x47457965), id: 1) // 'GEye'
        return RegisterEventHotKey(hk.keyCode, hk.carbonMods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // MARK: Ekran görüntüsü

    /// Kendi seçim ekranımız: seçim sürdüğü sürece `capturing` kesin olarak açık kalır
    @objc func captureRegion() {
        if capturing { return }
        // izin yoksa macOS kendi seçim arayüzünü açıp kafa karıştırıyor; önce izni kontrol et
        if #available(macOS 10.15, *), !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            alert("Ekran Kaydı izni gerekiyor",
                  "Sistem Ayarları > Gizlilik ve Güvenlik > Ekran ve Sistem Ses Kaydı'nda GooglyEyes'ı aç, sonra uygulamadan çıkıp yeniden başlat.")
            return
        }
        capturing = true
        sleeping = false
        lastActivity = CACurrentMediaTime()
        surprise(1.0)

        // seçimden sonra odağı geri vermek için önceki uygulamayı hatırla
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        // Ekranı HEMEN dondur: odağı almadan önce görüntüyü al. Böylece tarayıcıda açık olan
        // menü/sekme/açılır pencere odak değişince kapansa bile görüntü kısayola basılan anın hali olur.
        frozen = [:]
        if #available(macOS 14.0, *) {
            Grabber.captureScreens(NSScreen.screens) { [weak self] images in
                DispatchQueue.main.async {
                    guard let self = self, self.capturing else { return }
                    self.frozen = images
                    self.showSelection()
                }
            }
        } else {
            showSelection()
        }
    }

    /// Seçim katmanını göster (varsa donmuş görüntünün üstünde)
    func showSelection() {
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let w = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            if let cg = frozen[displayID(of: screen)] {
                v.frozen = NSImage(cgImage: cg, size: screen.frame.size)
            }
            v.onDone = { [weak self] r in self?.endSelection(r) }
            w.contentView = v
            w.orderFrontRegardless()
            selectionWindows.append(w)
            if NSMouseInRect(mouse, screen.frame, false) {
                w.makeKey(); w.makeFirstResponder(v)
            }
            w.invalidateCursorRects(for: v)
        }
    }

    func endSelection(_ rect: NSRect?) {
        // imleç bölgelerini kaldırıp oku biz hâlâ öndeyken geri yükle, sonra pencereleri kapat
        for w in selectionWindows {
            if let v = w.contentView { v.discardCursorRects() }
            w.disableCursorRects()
        }
        NSCursor.arrow.set()
        for w in selectionWindows { w.orderOut(nil) }
        selectionWindows.removeAll()
        // odağı biraz sonra önceki uygulamaya geri ver
        let app = previousApp
        previousApp = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSCursor.arrow.set()
            if let app = app, !app.isTerminated { app.activate(options: []) } else { NSApp.hide(nil) }
        }
        let shots = frozen
        frozen = [:]
        guard let r = rect else { endCapture(); return }
        let mid = NSPoint(x: r.midX, y: r.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(mid, $0.frame, false) } ?? NSScreen.main

        // donmuş görüntüden kes
        if let screen = screen, let full = shots[displayID(of: screen)] {
            let f = screen.frame
            let clipped = r.intersection(f)
            let sx = CGFloat(full.width) / f.width, sy = CGFloat(full.height) / f.height
            let px = CGRect(x: (clipped.minX - f.minX) * sx, y: (f.maxY - clipped.maxY) * sy,
                            width: clipped.width * sx, height: clipped.height * sy).integral
            if let part = full.cropping(to: px) {
                let rep = NSBitmapImageRep(cgImage: part)
                rep.size = clipped.size
                if let data = rep.representation(using: .png, properties: [:]) { finishCapture(data); return }
            }
        }
        // seçim katmanı ekrandan tamamen kalksın diye kısa bir bekleme
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self else { return }
            guard let screen = screen else { self.endCapture(); return }
            if #available(macOS 14.0, *) {
                Grabber.capture(rect: r, on: screen) { data, err in
                    DispatchQueue.main.async {
                        if let data = data { self.finishCapture(data) }
                        else {
                            self.endCapture()
                            self.alert("Ekran görüntüsü alınamadı", err ?? "Bilinmeyen hata")
                        }
                    }
                }
            } else {
                self.legacyCapture(r)
            }
        }
    }

    /// macOS 13 ve öncesi için yedek yol
    func legacyCapture(_ r: NSRect) {
        guard let primary = NSScreen.screens.first else { endCapture(); return }
        let x = Int(r.minX.rounded()), y = Int((primary.frame.maxY - r.maxY).rounded())
        let w = Int(r.width.rounded()), h = Int(r.height.rounded())
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("googly-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R\(x),\(y),\(w),\(h)", tmp.path]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                let data = try? Data(contentsOf: tmp)
                try? FileManager.default.removeItem(at: tmp)
                if let d = data, !d.isEmpty { self?.finishCapture(d) } else { self?.endCapture() }
            }
        }
        do { try p.run() } catch { endCapture(); alert("Ekran görüntüsü alınamadı", error.localizedDescription) }
    }

    /// Seçim/çekim bitti: göz bebekleri en büyük halden yavaşça küçülmeye başlar
    func endCapture() {
        capturing = false
        surpriseStrength = 1.0
        surpriseStart = CACurrentMediaTime() - 0.14 * surpriseDuration
    }

    func finishCapture(_ data: Data) {
        endCapture()
        Output.toClipboard(png: data)
        lastChangeCount = NSPasteboard.general.changeCount
        if Pref.saveToDesktop, let err = Output.saveToDesktop(png: data, prefix: "Googly") {
            alert("Masaüstüne kaydedilemedi", err)
        }
        noteActivity(CACurrentMediaTime())
        if Pref.autoAnnotate, let img = NSImage(data: data) { openAnnotator(with: img) }
    }

    // MARK: İşaretleme

    @objc func openAnnotatorFromClipboard() {
        guard let img = NSImage(pasteboard: NSPasteboard.general), img.size.width > 0 else {
            alert("Panoda görsel yok", "Önce \(Hotkey.load().display) ile bir ekran görüntüsü al ya da bir görsel kopyala.")
            return
        }
        openAnnotator(with: img)
    }

    func openAnnotator(with img: NSImage) {
        let wc = AnnotationWindowController(image: img) { [weak self] wc in
            self?.annotationWindows.removeAll { $0 === wc }
        } onSaved: { [weak self] in
            guard let self = self else { return }
            self.lastChangeCount = NSPasteboard.general.changeCount
            self.surprise(0.8)
        }
        annotationWindows.append(wc)
        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}

// MARK: - Çöp kutusu takibi

enum TrashWatch {
    static var cachedFrame: CGRect?
    static var lastFetch: CFTimeInterval = -100

    static let trashNames: Set<String> = {
        var n: Set<String> = ["Trash", "Çöp Sepeti", "Çöp Kutusu"]
        n.insert(FileManager.default.displayName(atPath: NSHomeDirectory() + "/.Trash"))
        return n
    }()

    /// Dock'taki çöp kutusu simgesinin yeri (AX koordinatları). Erişilebilirlik izni gerekir.
    static func trashFrame(_ now: CFTimeInterval) -> CGRect? {
        if now - lastFetch < 2 { return cachedFrame }      // Dock nadiren değişir; 2 sn'de bir sor
        lastFetch = now
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { cachedFrame = nil; return nil }
        cachedFrame = find(AXUIElementCreateApplication(dock.processIdentifier), depth: 0)
        return cachedFrame
    }

    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func find(_ e: AXUIElement, depth: Int) -> CGRect? {
        if (attr(e, kAXSubroleAttribute as String) as? String) == "AXTrashDockItem" { return frame(e) }
        guard depth < 3, let kids = attr(e, kAXChildrenAttribute as String) as? [AXUIElement] else { return nil }
        for k in kids { if let f = find(k, depth: depth + 1) { return f } }
        return nil
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute as String), let s = attr(e, kAXSizeAttribute as String) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// Ekranda açık bir Çöp Sepeti penceresi var mı (pencere adları Ekran Kaydı izniyle okunur)
    static func trashWindowOpen() -> Bool {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { w in
            (w[kCGWindowOwnerPID as String] as? Int32) == finder.processIdentifier
                && (w[kCGWindowLayer as String] as? Int) == 0
                && trashNames.contains(w[kCGWindowName as String] as? String ?? "")
        }
    }
}

// MARK: - Kısayol

struct Hotkey {
    var keyCode: UInt32
    var cocoaMods: NSEvent.ModifierFlags
    var keyName: String

    static let defaultKey = Hotkey(keyCode: UInt32(kVK_ANSI_S), cocoaMods: [.option, .shift], keyName: "S")

    static func load() -> Hotkey {
        let d = UserDefaults.standard
        guard d.object(forKey: "hkCode") != nil, let name = d.string(forKey: "hkName") else { return defaultKey }
        return Hotkey(keyCode: UInt32(d.integer(forKey: "hkCode")),
                      cocoaMods: NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "hkMods"))),
                      keyName: name)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(Int(keyCode), forKey: "hkCode")
        d.set(Int(cocoaMods.rawValue), forKey: "hkMods")
        d.set(keyName, forKey: "hkName")
    }

    var carbonMods: UInt32 {
        var m = 0
        if cocoaMods.contains(.command) { m |= cmdKey }
        if cocoaMods.contains(.option) { m |= optionKey }
        if cocoaMods.contains(.control) { m |= controlKey }
        if cocoaMods.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }

    var display: String {
        var s = ""
        if cocoaMods.contains(.control) { s += "⌃" }
        if cocoaMods.contains(.option) { s += "⌥" }
        if cocoaMods.contains(.shift) { s += "⇧" }
        if cocoaMods.contains(.command) { s += "⌘" }
        return s + keyName
    }

    /// Menüde gösterilecek tuş (tek karakterli tuşlar için)
    var menuKey: String { keyName.count == 1 ? keyName.lowercased() : "" }

    static let fKeys: [UInt16: String] = [122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                                          98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]

    static func name(for e: NSEvent) -> String? {
        if let f = fKeys[e.keyCode] { return f }
        switch e.keyCode {
        case 49: return "Space"
        case 36, 76: return "↩"
        case 48: return "⇥"
        case 51, 53: return nil          // sil ve Esc kullanılamaz
        default: break
        }
        // tuşun kendisi (shift/option'ın değiştirdiği karakter değil)
        guard let c = e.charactersIgnoringModifiers?.uppercased(), !c.isEmpty else { return nil }
        return c
    }
}

/// Basılan tuş kombinasyonunu yakalayan kutu
final class HotkeyRecorder: NSView {
    var hotkey = Hotkey.defaultKey { didSet { needsDisplay = true } }
    var hint: String? { didSet { needsDisplay = true } }
    var focused = false { didSet { needsDisplay = true } }
    var onRecord: ((Hotkey) -> Void)?
    var onFocus: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }      // pencere açılınca kendiliğinden seçilmesin; tıklayınca seçilir
    override func becomeFirstResponder() -> Bool { focused = true; onFocus?(true); return true }
    override func resignFirstResponder() -> Bool { focused = false; onFocus?(false); return true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 4)
        let p = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.setFill(); p.fill()
        p.lineWidth = focused ? 2 : 1
        (focused ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke(); p.stroke()
        let text = hint ?? hotkey.display
        let s = NSAttributedString(string: text, attributes: [
            .font: hint == nil ? NSFont.systemFont(ofSize: 17, weight: .semibold) : NSFont.systemFont(ofSize: 12),
            .foregroundColor: hint == nil ? NSColor.labelColor : NSColor.systemRed])
        let sz = s.size()
        s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }

    /// true: tuşu biz aldık
    func record(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        // düz Enter / Esc / Tab pencerenin düğmelerine gitsin
        if mods.isEmpty && [36, 76, 53, 48].contains(e.keyCode) { return false }
        guard let name = Hotkey.name(for: e) else { return false }
        let isF = Hotkey.fKeys[e.keyCode] != nil
        if !isF && mods.intersection([.command, .option, .control]).isEmpty {
            hint = "⌘, ⌥ ya da ⌃ ile birlikte bas"
            return true
        }
        hint = nil
        hotkey = Hotkey(keyCode: UInt32(e.keyCode), cocoaMods: mods, keyName: name)
        onRecord?(hotkey)
        return true
    }

    override func keyDown(with e: NSEvent) { if !record(e) { super.keyDown(with: e) } }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.type == .keyDown else { return false }
        return record(e)
    }
}

// MARK: - Ayarlar penceresi

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    weak var app: AppDelegate?

    let recorder = HotkeyRecorder(frame: NSRect(x: 0, y: 0, width: 150, height: 36))
    let hotkeyNote = NSTextField(labelWithString: "")
    let savePopup = NSPopUpButton()
    let annotateCheck = NSButton(checkboxWithTitle: "Çektikten sonra işaretleme penceresini aç", target: nil, action: nil)
    let sleepPopup = NSPopUpButton()
    let randomCheck = NSButton(checkboxWithTitle: "Rastgele davranışlar (göz devirme, spiral göz…)", target: nil, action: nil)
    let webpCheck = NSButton(checkboxWithTitle: "İndirilen WebP görselleri otomatik PNG'ye çevir", target: nil, action: nil)
    let loginCheck = NSButton(checkboxWithTitle: "Mac açılınca GooglyEyes'ı başlat", target: nil, action: nil)
    let screenStatus = NSTextField(labelWithString: "")
    let screenButton = NSButton(title: "İzin Ver…", target: nil, action: nil)
    let axStatus = NSTextField(labelWithString: "")
    let axButton = NSButton(title: "İzin Ver…", target: nil, action: nil)
    let versionLabel = NSTextField(labelWithString: "")
    let updateButton = NSButton(title: "Güncellemeleri Kontrol Et", target: nil, action: nil)

    static let sleepOptions: [(String, Double)] = [("30 saniye sonra", 30), ("1 dakika sonra", 60), ("5 dakika sonra", 300), ("Kapalı", 0)]

    init(app: AppDelegate) {
        self.app = app
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "GooglyEyes Ayarlar"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        build()
        win.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Kurulum

    func label(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.alignment = .right
        return l
    }

    func section(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = 8
        s.alignment = .centerY
        return s
    }

    func build() {
        guard let content = window?.contentView else { return }

        // kısayol
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 36).isActive = true
        recorder.onFocus = { [weak self] focused in
            guard let app = self?.app else { return }
            if focused {
                app.suspendHotKey()
                self?.hotkeyNote.stringValue = "Yeni kısayola bas…"
                self?.hotkeyNote.textColor = .secondaryLabelColor
            } else {
                app.applyHotKey(Hotkey.load())
                if self?.hotkeyNote.textColor != .systemRed { self?.hotkeyNote.stringValue = "" }
            }
        }
        recorder.onRecord = { [weak self] hk in self?.tryHotKey(hk) }
        hotkeyNote.font = NSFont.systemFont(ofSize: 11)
        let resetKey = NSButton(title: "Varsayılan", target: self, action: #selector(resetHotKey))
        resetKey.controlSize = .small

        // kaydetme
        savePopup.addItems(withTitles: ["Sadece panoya", "Panoya + masaüstüne"])
        savePopup.target = self; savePopup.action = #selector(saveChanged)
        annotateCheck.target = self; annotateCheck.action = #selector(annotateChanged)

        // gözler
        sleepPopup.addItems(withTitles: Self.sleepOptions.map { $0.0 })
        sleepPopup.target = self; sleepPopup.action = #selector(sleepChanged)
        randomCheck.target = self; randomCheck.action = #selector(randomChanged)

        // dosyalar / genel
        webpCheck.target = self; webpCheck.action = #selector(webpChanged)
        loginCheck.target = self; loginCheck.action = #selector(loginChanged)
        screenButton.target = self; screenButton.action = #selector(askScreen)
        axButton.target = self; axButton.action = #selector(askAX)
        for b in [screenButton, axButton] { b.controlSize = .small }
        let permNote = NSTextField(labelWithString: "İzin verdikten sonra GooglyEyes'ı kapatıp yeniden aç.")
        permNote.font = NSFont.systemFont(ofSize: 11); permNote.textColor = .secondaryLabelColor

        // güncelleme
        updateButton.target = self; updateButton.action = #selector(checkUpdates)

        let e = NSGridCell.emptyContentView
        let rows: [[NSView]] = [
            [section("Ekran Görüntüsü"), e],
            [label("Kısayol:"), row([recorder, resetKey, hotkeyNote])],
            [label("Kaydet:"), savePopup],
            [e, annotateCheck],
            [section("Gözler"), e],
            [label("Uyku:"), sleepPopup],
            [e, randomCheck],
            [section("Dosyalar"), e],
            [e, webpCheck],
            [section("Genel"), e],
            [e, loginCheck],
            [label("Ekran Kaydı:"), row([screenStatus, screenButton])],
            [label("Erişilebilirlik:"), row([axStatus, axButton])],
            [e, permNote],
            [section("Güncelleme"), e],
            [label("Sürüm:"), row([versionLabel, updateButton])],
        ]
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 9
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for (i, r) in rows.enumerated() where r[1] === e && r[0] is NSTextField && (r[0] as! NSTextField).font?.pointSize == 13 {
            let gr = grid.row(at: i)
            gr.mergeCells(in: NSRange(location: 0, length: 2))
            gr.cell(at: 0).xPlacement = .leading
            if i > 0 { gr.topPadding = 12 }
        }
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        if #unavailable(macOS 13.0) { loginCheck.isHidden = true }
    }

    // MARK: Değerleri göster

    func refresh() {
        guard let app = app else { return }
        if !recorder.focused { recorder.hotkey = Hotkey.load() }
        savePopup.selectItem(at: Pref.saveToDesktop ? 1 : 0)
        annotateCheck.state = Pref.autoAnnotate ? .on : .off
        sleepPopup.selectItem(at: Self.sleepOptions.firstIndex { $0.1 == Pref.sleepAfter } ?? 1)
        randomCheck.state = Pref.randomBehaviors ? .on : .off
        webpCheck.state = Pref.webpToPng ? .on : .off
        if #available(macOS 13.0, *) { loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off }

        let screenOK = CGPreflightScreenCaptureAccess(), axOK = AXIsProcessTrusted()
        screenStatus.stringValue = screenOK ? "Verildi ✓" : "Verilmedi"
        screenStatus.textColor = screenOK ? .systemGreen : .secondaryLabelColor
        screenButton.isHidden = screenOK
        axStatus.stringValue = axOK ? "Verildi ✓" : "Verilmedi"
        axStatus.textColor = axOK ? .systemGreen : .secondaryLabelColor
        axButton.isHidden = axOK

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let commit = Updater.installedCommit
        versionLabel.stringValue = "\(version) (\(commit == "unknown" ? "yerel derleme" : String(commit.prefix(7))))"
        if app.updating {
            updateButton.title = "Güncelleniyor…"; updateButton.isEnabled = false
        } else if app.updateAvailable {
            updateButton.title = "✨ Güncellemeyi Yükle"; updateButton.isEnabled = true
        } else {
            updateButton.title = "Güncellemeleri Kontrol Et"; updateButton.isEnabled = true
        }
    }

    func windowDidBecomeKey(_ n: Notification) { refresh() }   // izin ekranından dönünce durumu tazele

    // MARK: Eylemler

    func tryHotKey(_ hk: Hotkey) {
        guard let app = app else { return }
        let old = Hotkey.load()
        // gerçekten kaydedilebiliyor mu dene, sonra kutu seçili kaldıkça tekrar kapat
        if app.applyHotKey(hk) == noErr {
            hk.save()
            hotkeyNote.stringValue = "Kaydedildi ✓"
            hotkeyNote.textColor = .systemGreen
        } else {
            recorder.hotkey = old
            hotkeyNote.stringValue = "\(hk.display) başka bir uygulamada kullanılıyor"
            hotkeyNote.textColor = .systemRed
        }
        if recorder.focused { app.suspendHotKey() } else { app.applyHotKey(Hotkey.load()) }
    }

    @objc func resetHotKey() {
        window?.makeFirstResponder(nil)
        tryHotKey(Hotkey.defaultKey)
        recorder.hotkey = Hotkey.load()
    }

    @objc func saveChanged() { Pref.saveToDesktop = savePopup.indexOfSelectedItem == 1 }
    @objc func annotateChanged() { Pref.autoAnnotate = annotateCheck.state == .on }
    @objc func sleepChanged() {
        Pref.sleepAfter = Self.sleepOptions[sleepPopup.indexOfSelectedItem].1
        app?.lastActivity = CACurrentMediaTime()
    }
    @objc func randomChanged() { Pref.randomBehaviors = randomCheck.state == .on }
    @objc func webpChanged() { app?.setWebp(webpCheck.state == .on) }
    @objc func loginChanged() { app?.setLogin(loginCheck.state == .on); refresh() }
    @objc func askScreen() { _ = CGRequestScreenCaptureAccess(); app?.openPrivacy() }
    @objc func askAX() { app?.openAccessibility() }
    @objc func checkUpdates() { app?.checkForUpdatesManually() }

    func windowWillClose(_ n: Notification) {
        window?.makeFirstResponder(nil)          // kutu seçiliyse kısayolu geri aç
        app?.applyHotKey(Hotkey.load())
    }
}

// MARK: - Güncelleyici

enum Updater {
    static let repo = "generece/GooglyEyes"

    /// Bu kopyanın derlendiği commit (build.sh Info.plist'e yazar)
    static var installedCommit: String {
        Bundle.main.object(forInfoDictionaryKey: "GooglyCommit") as? String ?? "unknown"
    }

    /// GitHub'daki main dalının son commit'i
    static func latestCommit(_ completion: @escaping (String?) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/commits/main")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sha = obj["sha"] as? String else { completion(nil); return }
            completion(sha)
        }.resume()
    }

    /// install.sh'ı GitHub'dan çalıştırır: indir, derle, kur, yeniden başlat.
    /// Çıktı dosyaya yazılır: kurulum bu uygulamayı kapattığında script yarıda kalmasın diye.
    static func install(_ completion: @escaping (Bool, String) -> Void) {
        let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/GooglyEyes-update.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "set -o pipefail; curl -fsSL https://raw.githubusercontent.com/\(repo)/main/install.sh | bash > \"$1\" 2>&1",
                       "googly-update", logURL.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            completion(proc.terminationStatus == 0, text)
        }
        do { try p.run() } catch { completion(false, error.localizedDescription) }
    }
}

// MARK: - WebP → PNG

/// İndirilenler ve Masaüstü'nü izler; yeni gelen .webp dosyalarını aynı isimle .png'ye çevirir.
final class WebpWatcher {
    var onConverted: (() -> Void)?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var seen: Set<String> = []          // zaten bilinen / işlenmiş webp dosyaları
    private var pendingScan: DispatchWorkItem?
    private let fm = FileManager.default

    private var folders: [URL] {
        [fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
         fm.urls(for: .desktopDirectory, in: .userDomainMask).first].compactMap { $0 }
    }

    func start() {
        guard sources.isEmpty else { return }
        // izleme başladığında var olan eski webp'lere dokunma
        for d in folders { for f in webps(in: d) { seen.insert(f.path) } }
        for d in folders {
            let fd = open(d.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            src.setEventHandler { [weak self] in self?.scheduleScan() }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources.append(src)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        pendingScan?.cancel()
    }

    private func webps(in dir: URL) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension.lowercased() == "webp" }
    }

    private func scheduleScan() {
        pendingScan?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.scan() }
        pendingScan = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    private func scan() {
        for d in folders {
            for f in webps(in: d) where !seen.contains(f.path) {
                waitUntilStable(f, lastSize: -1, tries: 0)
            }
        }
    }

    private func size(of url: URL) -> Int {
        ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? -1
    }

    /// Tarayıcı dosyayı yazmayı bitirene kadar bekle (boyut iki kontrolde aynı kalmalı)
    private func waitUntilStable(_ url: URL, lastSize: Int, tries: Int) {
        let s = size(of: url)
        if s < 0 { return }                                    // dosya kaybolmuş
        if s > 0 && s == lastSize { seen.insert(url.path); convert(url); return }
        if tries > 40 { return }                               // ~30 sn sonra vazgeç
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.waitUntilStable(url, lastSize: s, tries: tries + 1)
        }
    }

    private func convert(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        // hareketli webp'ler PNG'ye çevrilince animasyon kaybolur: onlara dokunma
        guard CGImageSourceGetCount(src) == 1,
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        let base = url.deletingPathExtension()
        var out = base.appendingPathExtension("png")
        var i = 2
        while fm.fileExists(atPath: out.path) {
            out = URL(fileURLWithPath: base.path + " (\(i))").appendingPathExtension("png"); i += 1
        }
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return }
        try? fm.trashItem(at: url, resultingItemURL: nil)     // aslı Çöp Sepeti'ne (geri alınabilir)
        onConverted?()
    }
}

// MARK: - Ekran yakalama (ScreenCaptureKit)

func displayID(of screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
}

@available(macOS 14.0, *)
enum Grabber {
    /// Bütün ekranların tam çözünürlüklü görüntüsü (seçimden önce "dondurmak" için)
    static func captureScreens(_ screens: [NSScreen], completion: @escaping ([CGDirectDisplayID: CGImage]) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let content = content else { completion([:]); return }
            let group = DispatchGroup()
            let lock = NSLock()
            var out: [CGDirectDisplayID: CGImage] = [:]
            for screen in screens {
                let id = displayID(of: screen)
                guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                let cfg = SCStreamConfiguration()
                cfg.width = Int((screen.frame.width * screen.backingScaleFactor).rounded())
                cfg.height = Int((screen.frame.height * screen.backingScaleFactor).rounded())
                cfg.showsCursor = false
                cfg.captureResolution = .best
                group.enter()
                SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                                 configuration: cfg) { img, _ in
                    if let img = img { lock.lock(); out[id] = img; lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(out) }
        }
    }

    /// rect: genel ekran koordinatları (Cocoa, sol-alt orijin); sonuç PNG
    static func capture(rect r: NSRect, on screen: NSScreen, completion: @escaping (Data?, String?) -> Void) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let content = content,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                completion(nil, error?.localizedDescription ?? "Ekran bulunamadı"); return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            // ekranın kendi koordinatları: sol-üst orijin, nokta cinsinden
            let clipped = r.intersection(screen.frame)
            cfg.sourceRect = CGRect(x: clipped.minX - screen.frame.minX,
                                    y: screen.frame.maxY - clipped.maxY,
                                    width: clipped.width, height: clipped.height)
            let scale = screen.backingScaleFactor
            cfg.width = max(1, Int((clipped.width * scale).rounded()))
            cfg.height = max(1, Int((clipped.height * scale).rounded()))
            cfg.showsCursor = false
            cfg.captureResolution = .best
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { image, err in
                guard let image = image else { completion(nil, err?.localizedDescription ?? "Görüntü alınamadı"); return }
                let rep = NSBitmapImageRep(cgImage: image)
                rep.size = NSSize(width: clipped.width, height: clipped.height)
                completion(rep.representation(using: .png, properties: [:]), nil)
            }
        }
    }
}

// MARK: - Bölge seçimi

final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    var start: NSPoint?
    var current: NSPoint?
    var menuBarHeight: CGFloat = 0
    var frozen: NSImage?
    var onDone: ((NSRect?) -> Void)?
    var finished = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    var selRect: NSRect? {
        guard let a = start, let b = current else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func draw(_ dirty: NSRect) {
        // menü çubuğu karartılmaz (gözler görünsün), ama tıklamayı yakalamak için neredeyse saydam doldurulur
        let bar = NSRect(x: 0, y: bounds.maxY - menuBarHeight, width: bounds.width, height: menuBarHeight)
        let rest = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - menuBarHeight)
        NSColor.black.withAlphaComponent(0.01).setFill(); bar.fill(using: .copy)
        if let img = frozen {
            // donmuş ekran: menü çubuğu dışındaki alana çiz, seçim dışını hafif karart
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rest).addClip()
            img.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
            let dim = NSBezierPath(rect: rest)
            if let s = selRect, s.width > 0, s.height > 0 { dim.append(NSBezierPath(rect: s)); dim.windingRule = .evenOdd }
            NSColor.black.withAlphaComponent(0.12).setFill(); dim.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSColor.black.withAlphaComponent(0.12).setFill(); rest.fill(using: .copy)
        }
        guard let s = selRect, s.width > 0, s.height > 0 else { return }
        if frozen == nil { NSColor.clear.setFill(); s.fill(using: .copy) }
        let p = NSBezierPath(rect: s.insetBy(dx: 0.5, dy: 0.5))
        p.lineWidth = 1
        NSColor.white.withAlphaComponent(0.95).setStroke(); p.stroke()

        let str = NSAttributedString(string: "\(Int(s.width)) × \(Int(s.height))", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white])
        let sz = str.size()
        var lp = NSPoint(x: s.maxX + 8, y: s.minY - sz.height - 8)
        if lp.y < 4 { lp.y = s.minY + 6 }
        if lp.x + sz.width + 8 > bounds.maxX { lp.x = s.maxX - sz.width - 10 }
        let bg = NSRect(x: lp.x - 5, y: lp.y - 2, width: sz.width + 10, height: sz.height + 4)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 5, yRadius: 5).fill()
        str.draw(at: lp)
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        start = p; current = p; needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        current = convert(e.locationInWindow, from: nil); needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        current = convert(e.locationInWindow, from: nil)
        guard let r = selRect, r.width >= 3, r.height >= 3, let w = window else {
            start = nil; current = nil; needsDisplay = true   // sürüklemeden tık: seçim sürer
            return
        }
        finish(w.convertToScreen(r))
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { finish(nil) } else { super.keyDown(with: e) }   // Esc
    }
    override func cancelOperation(_ sender: Any?) { finish(nil) }
    override func rightMouseDown(with e: NSEvent) { finish(nil) }

    func finish(_ r: NSRect?) {
        if finished { return }
        finished = true
        onDone?(r)
    }
}

// MARK: - Z harfi (zZz dokusunun stiline uygun: parlak siyah tüp)

enum ZGlyph {
    static func draw(in r: NSRect, alpha: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let sw = max(1.4, r.height * 0.26)
        let b = r.insetBy(dx: sw / 2, dy: sw / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: b.minX, y: b.maxY))
        path.line(to: NSPoint(x: b.maxX, y: b.maxY))
        path.line(to: NSPoint(x: b.minX, y: b.minY))
        path.line(to: NSPoint(x: b.maxX, y: b.minY))
        path.lineCapStyle = .round; path.lineJoinStyle = .round

        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        // hafif beyaz hale (koyu menü çubuğunda da görünsün)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor.white.withAlphaComponent(0.45)
        glow.shadowBlurRadius = max(1.5, r.height * 0.22)
        glow.shadowOffset = .zero
        glow.set()
        path.lineWidth = sw
        NSColor(white: 0.32, alpha: 1).setStroke()      // ince gri kenar
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        path.lineWidth = max(0.8, sw - max(0.6, sw * 0.16))
        NSColor(white: 0.03, alpha: 1).setStroke()      // parlak siyah gövde
        path.stroke()

        // sağ üstteki parlama
        let hl = NSBezierPath()
        hl.move(to: NSPoint(x: b.maxX - b.width * 0.30, y: b.maxY + sw * 0.12))
        hl.line(to: NSPoint(x: b.maxX - b.width * 0.02, y: b.maxY + sw * 0.08))
        hl.lineWidth = max(0.5, sw * 0.28); hl.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.75).setStroke()
        hl.stroke()

        // çaprazda soluk ışık
        let dl = NSBezierPath()
        dl.move(to: NSPoint(x: b.maxX - b.width * 0.18, y: b.maxY - b.height * 0.14))
        dl.line(to: NSPoint(x: b.minX + b.width * 0.30, y: b.minY + b.height * 0.32))
        dl.lineWidth = max(0.4, sw * 0.14); dl.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.16).setStroke()
        dl.stroke()

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

// MARK: - Pano / Masaüstü

enum Output {
    static func toClipboard(png: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    /// Hata varsa mesaj döner
    static func saveToDesktop(png: Data, prefix: String) -> String? {
        let fm = FileManager.default
        guard let desk = fm.urls(for: .desktopDirectory, in: .userDomainMask).first else { return "Masaüstü bulunamadı" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'saat' HH.mm.ss"
        var url = desk.appendingPathComponent("\(prefix) \(f.string(from: Date())).png")
        var i = 2
        while fm.fileExists(atPath: url.path) {
            url = desk.appendingPathComponent("\(prefix) \(f.string(from: Date())) (\(i)).png"); i += 1
        }
        do { try png.write(to: url); return nil } catch { return error.localizedDescription }
    }
}

// MARK: - İşaretleme görünümü

enum Tool: Int { case pen, arrow, rect, marker, text, number, pixelate, blur, eraser, crop }

/// Yazı aracı için font seçenekleri
enum TextFont: Int, CaseIterable {
    case rounded, montserrat

    var title: String {
        switch self {
        case .rounded: return "Yuvarlak"
        case .montserrat: return "Montserrat"
        }
    }

    /// Uygulamanın içine gömülü Montserrat'ı bir kez kaydet
    static let registerOnce: Void = {
        if let url = Bundle.main.url(forResource: "Montserrat-Bold", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    func font(size: CGFloat) -> NSFont {
        switch self {
        case .rounded:
            let base = NSFont.systemFont(ofSize: size, weight: .heavy)
            if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
            return base
        case .montserrat:
            _ = TextFont.registerOnce
            return NSFont(name: "Montserrat-Bold", size: size) ?? NSFont.boldSystemFont(ofSize: size)
        }
    }
}

enum ArrowStyle: Int { case sharp, soft }
enum EraserMode: Int { case whole, partial }
enum CropHandle { case none, move, l, r, t, b, tl, tr, bl, br }

struct Mark {
    var tool: Tool
    var color: NSColor
    var width: CGFloat          // görsel pikseli: çizgi kalınlığı / yazı boyu / numara çapı / silgi çapı
    var points: [CGPoint]       // görsel pikseli cinsinden (sol-alt orijin)
    var text: String = ""
    var font: TextFont = .rounded
    var arrow: ArrowStyle = .sharp
    var curved = false
}

// MARK: - Yol yardımcıları

enum PathMath {
    static func segDist(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        if l2 < 0.0001 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func polyDist(_ p: CGPoint, _ pts: [CGPoint]) -> CGFloat {
        guard let f = pts.first else { return .greatestFiniteMagnitude }
        if pts.count == 1 { return hypot(p.x - f.x, p.y - f.y) }
        var d = CGFloat.greatestFiniteMagnitude
        for i in 1..<pts.count { d = min(d, segDist(p, pts[i - 1], pts[i])) }
        return d
    }

    /// Ramer–Douglas–Peucker: titrek elle çizimdeki gereksiz noktaları at
    static func simplify(_ pts: [CGPoint], _ eps: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var maxD: CGFloat = 0, idx = 0
        for i in 1..<(pts.count - 1) {
            let d = segDist(pts[i], pts[0], pts[pts.count - 1])
            if d > maxD { maxD = d; idx = i }
        }
        if maxD <= eps { return [pts[0], pts[pts.count - 1]] }
        let a = simplify(Array(pts[0...idx]), eps), b = simplify(Array(pts[idx...]), eps)
        return Array(a.dropLast()) + b
    }

    /// Chaikin: köşeleri yuvarlat (uçlar sabit)
    static func chaikin(_ pts: [CGPoint], iterations: Int) -> [CGPoint] {
        var p = pts
        for _ in 0..<iterations {
            guard p.count > 2 else { return p }
            var q: [CGPoint] = [p[0]]
            for i in 0..<(p.count - 1) {
                let a = p[i], b = p[i + 1]
                q.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
                q.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
            }
            q.append(p[p.count - 1])
            p = q
        }
        return p
    }

    static func length(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return 0 }
        var l: CGFloat = 0
        for i in 1..<pts.count { l += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
        return l
    }

    /// Yolun başından `s` uzunluk kadar ilerideki nokta
    static func point(at s: CGFloat, _ pts: [CGPoint]) -> CGPoint {
        guard pts.count > 1 else { return pts.first ?? .zero }
        var acc: CGFloat = 0
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let seg = hypot(b.x - a.x, b.y - a.y)
            if acc + seg >= s, seg > 0 {
                let t = (s - acc) / seg
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            acc += seg
        }
        return pts[pts.count - 1]
    }

    /// Yolun başından `s` uzunluğa kadarki kısmı
    static func prefix(upTo s: CGFloat, _ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count > 1, s > 0 else { return Array(pts.prefix(1)) }
        var out: [CGPoint] = [pts[0]]
        var acc: CGFloat = 0
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let seg = hypot(b.x - a.x, b.y - a.y)
            if acc + seg >= s {
                let t = seg > 0 ? (s - acc) / seg : 0
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                return out
            }
            out.append(b); acc += seg
        }
        return out
    }
}

final class AnnotationView: NSView, NSTextFieldDelegate {
    let image: NSImage
    let pixelSize: CGSize
    var marks: [Mark] = [] { didSet { needsDisplay = true; onChange?() } }
    /// Uygulanmış kırpma (görsel pikseli). Başlangıçta görselin tamamı.
    var crop: CGRect = .zero { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self); onChange?() } }
    /// Kırpma aracı açıkken düzenlenen kırpma çerçevesi
    var cropEditing: CGRect? { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var cropDrag: (handle: CropHandle, start: CGPoint, orig: CGRect)?
    /// Geri Al geçmişi: her değişiklikten önceki işaretler + kırpma
    var history: [(marks: [Mark], crop: CGRect)] = [] { didSet { onChange?() } }
    var current: Mark? { didSet { needsDisplay = true } }
    var tool: Tool = .pen {
        didSet {
            commitText()
            if oldValue == .crop && tool != .crop { applyCrop() }
            if tool == .crop && cropEditing == nil { cropEditing = crop }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4 { didSet { if tool == .eraser { window?.invalidateCursorRects(for: self) } } }
    var textFont = TextFont(rawValue: UserDefaults.standard.integer(forKey: "textFont")) ?? .rounded {
        didSet {
            UserDefaults.standard.set(textFont.rawValue, forKey: "textFont")
            if let f = editor { f.font = textFont.font(size: editorFontPx * scale); resizeEditor() }
        }
    }
    var arrowStyle = ArrowStyle(rawValue: UserDefaults.standard.integer(forKey: "arrowStyle")) ?? .sharp {
        didSet { UserDefaults.standard.set(arrowStyle.rawValue, forKey: "arrowStyle") }
    }
    var arrowCurved = UserDefaults.standard.bool(forKey: "arrowCurved") {
        didSet { UserDefaults.standard.set(arrowCurved, forKey: "arrowCurved") }
    }
    var eraserMode = EraserMode(rawValue: UserDefaults.standard.integer(forKey: "eraserMode")) ?? .whole {
        didSet { UserDefaults.standard.set(eraserMode.rawValue, forKey: "eraserMode") }
    }
    var onChange: (() -> Void)?
    var onCommand: ((String) -> Void)?
    var onCropped: ((Bool) -> Void)?

    // yazı aracı
    var editor: NSTextField?
    var editorFontPx: CGFloat = 0

    // silgi
    var erasedThisDrag = false
    var eraserRadius: CGFloat { 4 + lineWidth * 1.5 }   // ekran noktası; Boyut kaydırıcısıyla değişir
    var cursorCache: (r: CGFloat, c: NSCursor)?

    lazy var pixelated: NSImage? = makeEffect(.pixelate)
    lazy var blurred: NSImage? = makeEffect(.blur)

    init(image: NSImage) {
        self.image = image
        let px = image.representations.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
            .max { $0.width < $1.width } ?? .zero
        pixelSize = px.width > 0 ? px : CGSize(width: image.size.width * 2, height: image.size.height * 2)
        super.init(frame: .zero)
        crop = fullRect
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let ir = imageRect()
        switch tool {
        case .text: addCursorRect(ir, cursor: .iBeam)
        case .eraser: addCursorRect(ir, cursor: eraserCursor())
        case .crop:
            guard let c = cropEditing else { break }
            let v = viewRect(of: c), t: CGFloat = 8
            addCursorRect(v.insetBy(dx: t, dy: t), cursor: .openHand)
            addCursorRect(NSRect(x: v.minX - t, y: v.minY + t, width: 2 * t, height: v.height - 2 * t), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: v.maxX - t, y: v.minY + t, width: 2 * t, height: v.height - 2 * t), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: v.minX + t, y: v.minY - t, width: v.width - 2 * t, height: 2 * t), cursor: .resizeUpDown)
            addCursorRect(NSRect(x: v.minX + t, y: v.maxY - t, width: v.width - 2 * t, height: 2 * t), cursor: .resizeUpDown)
            for p in [NSPoint(x: v.minX, y: v.minY), NSPoint(x: v.maxX, y: v.minY),
                      NSPoint(x: v.minX, y: v.maxY), NSPoint(x: v.maxX, y: v.maxY)] {
                addCursorRect(NSRect(x: p.x - t, y: p.y - t, width: 2 * t, height: 2 * t), cursor: .crosshair)
            }
        default: addCursorRect(ir, cursor: .crosshair)
        }
    }

    func eraserCursor() -> NSCursor {
        let r = eraserRadius
        if let c = cursorCache, c.r == r { return c.c }
        let d = r * 2 + 2
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            let o = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSColor.white.withAlphaComponent(0.3).setFill(); o.fill()
            o.lineWidth = 2; NSColor.black.withAlphaComponent(0.8).setStroke(); o.stroke()
            o.lineWidth = 1; NSColor.white.setStroke(); o.stroke()
            return true
        }
        let c = NSCursor(image: img, hotSpot: NSPoint(x: d / 2, y: d / 2))
        cursorCache = (r, c)
        return c
    }

    // MARK: Koordinatlar

    var fullRect: NSRect { NSRect(origin: .zero, size: pixelSize) }
    /// Ekranda gösterilen bölge: kırpma düzenlenirken görselin tamamı, yoksa kırpılmış alan
    var viewRegion: CGRect { cropEditing != nil ? fullRect : crop }

    func imageRect() -> NSRect {
        let b = bounds.insetBy(dx: 20, dy: 20)
        let cw = max(viewRegion.width, 1), ch = max(viewRegion.height, 1)
        let s = min(b.width / cw, b.height / ch)
        let w = cw * s, h = ch * s
        return NSRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
    }
    var scale: CGFloat { max(imageRect().width / max(viewRegion.width, 1), 0.0001) }

    func toImage(_ p: NSPoint) -> CGPoint {
        let r = imageRect(), v = viewRegion
        return CGPoint(x: v.minX + (p.x - r.minX) / scale, y: v.minY + (p.y - r.minY) / scale)
    }

    func viewRect(of rr: CGRect) -> NSRect {
        let r = imageRect(), v = viewRegion, s = scale
        return NSRect(x: r.minX + (rr.minX - v.minX) * s, y: r.minY + (rr.minY - v.minY) * s,
                      width: rr.width * s, height: rr.height * s)
    }

    // MARK: Geçmiş

    func pushHistory() {
        history.append((marks, crop))
        if history.count > 300 { history.removeFirst() }
    }

    func undoLast() {
        commitText()
        if let e = cropEditing, e != crop { cropEditing = crop; return }   // önce kırpma düzenlemesini geri al
        guard let h = history.popLast() else { return }
        marks = h.marks
        crop = h.crop
        if cropEditing != nil { cropEditing = crop }
    }

    func clearAll() {
        cancelText()
        guard !marks.isEmpty || crop != fullRect else { return }
        pushHistory()
        marks = []
        crop = fullRect
        if cropEditing != nil { cropEditing = fullRect }
    }

    // MARK: Kırpma

    /// Düzenlenen kırpma çerçevesini uygula
    func applyCrop() {
        guard let e = cropEditing else { return }
        cropEditing = nil
        let n = e.integral.intersection(fullRect)
        if n != crop && n.width >= 1 && n.height >= 1 { pushHistory(); crop = n }
    }

    func cropHandle(at vp: NSPoint) -> CropHandle {
        guard let c = cropEditing else { return .none }
        let v = viewRect(of: c), t: CGFloat = 10
        let nL = abs(vp.x - v.minX) <= t, nR = abs(vp.x - v.maxX) <= t
        let nB = abs(vp.y - v.minY) <= t, nT = abs(vp.y - v.maxY) <= t
        let inX = vp.x >= v.minX - t && vp.x <= v.maxX + t
        let inY = vp.y >= v.minY - t && vp.y <= v.maxY + t
        if nL && nT { return .tl }
        if nR && nT { return .tr }
        if nL && nB { return .bl }
        if nR && nB { return .br }
        if nL && inY { return .l }
        if nR && inY { return .r }
        if nT && inX { return .t }
        if nB && inX { return .b }
        if v.contains(vp) { return .move }
        return .none
    }

    func dragCrop(to p: CGPoint) {
        guard let d = cropDrag else { return }
        let o = d.orig, f = fullRect, minS: CGFloat = 12
        let dx = p.x - d.start.x, dy = p.y - d.start.y
        var minX = o.minX, maxX = o.maxX, minY = o.minY, maxY = o.maxY
        switch d.handle {
        case .move:
            let mx = max(f.minX - o.minX, min(f.maxX - o.maxX, dx))
            let my = max(f.minY - o.minY, min(f.maxY - o.maxY, dy))
            minX += mx; maxX += mx; minY += my; maxY += my
        default:
            if [.l, .tl, .bl].contains(d.handle) { minX = max(f.minX, min(o.maxX - minS, o.minX + dx)) }
            if [.r, .tr, .br].contains(d.handle) { maxX = min(f.maxX, max(o.minX + minS, o.maxX + dx)) }
            if [.b, .bl, .br].contains(d.handle) { minY = max(f.minY, min(o.maxY - minS, o.minY + dy)) }
            if [.t, .tl, .tr].contains(d.handle) { maxY = min(f.maxY, max(o.minY + minS, o.maxY + dy)) }
        }
        cropEditing = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func drawCropOverlay() {
        guard let c = cropEditing else { return }
        let ir = imageRect(), v = viewRect(of: c)
        let dim = NSBezierPath(rect: ir)
        dim.append(NSBezierPath(rect: v))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill(); dim.fill()

        // üçte bir çizgileri
        let thirds = NSBezierPath()
        for i in 1...2 {
            let x = v.minX + v.width * CGFloat(i) / 3, y = v.minY + v.height * CGFloat(i) / 3
            thirds.move(to: NSPoint(x: x, y: v.minY)); thirds.line(to: NSPoint(x: x, y: v.maxY))
            thirds.move(to: NSPoint(x: v.minX, y: y)); thirds.line(to: NSPoint(x: v.maxX, y: y))
        }
        thirds.lineWidth = 0.5; NSColor.white.withAlphaComponent(0.35).setStroke(); thirds.stroke()

        let border = NSBezierPath(rect: v.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1; NSColor.white.withAlphaComponent(0.9).setStroke(); border.stroke()

        // köşe ve kenar tutamaçları
        let h = NSBezierPath()
        let L = min(18, v.width / 3, v.height / 3), w: CGFloat = 4
        for (cx, cy, sx, sy) in [(v.minX, v.minY, 1.0, 1.0), (v.maxX, v.minY, -1.0, 1.0),
                                 (v.minX, v.maxY, 1.0, -1.0), (v.maxX, v.maxY, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            h.move(to: NSPoint(x: cx + sx * L, y: cy)); h.line(to: NSPoint(x: cx, y: cy)); h.line(to: NSPoint(x: cx, y: cy + sy * L))
        }
        let m = min(14, v.width / 4, v.height / 4)
        h.move(to: NSPoint(x: v.midX - m, y: v.minY)); h.line(to: NSPoint(x: v.midX + m, y: v.minY))
        h.move(to: NSPoint(x: v.midX - m, y: v.maxY)); h.line(to: NSPoint(x: v.midX + m, y: v.maxY))
        h.move(to: NSPoint(x: v.minX, y: v.midY - m)); h.line(to: NSPoint(x: v.minX, y: v.midY + m))
        h.move(to: NSPoint(x: v.maxX, y: v.midY - m)); h.line(to: NSPoint(x: v.maxX, y: v.midY + m))
        h.lineWidth = w; h.lineCapStyle = .square
        NSColor.white.setStroke(); h.stroke()

        let label = NSAttributedString(string: "\(Int(c.width.rounded())) × \(Int(c.height.rounded()))", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white])
        let sz = label.size()
        let bg = NSRect(x: v.midX - sz.width / 2 - 6, y: v.minY + 10, width: sz.width + 12, height: sz.height + 4)
        if bg.maxY < v.maxY - 10 {
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: bg, xRadius: 5, yRadius: 5).fill()
            label.draw(at: NSPoint(x: bg.minX + 6, y: bg.minY + 2))
        }
    }

    // MARK: Efektler

    func makeEffect(_ kind: Tool) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        let ext = ci.extent
        let f: CIFilter?
        if kind == .pixelate {
            f = CIFilter(name: "CIPixellate")
            f?.setValue(max(8, ext.width / 70), forKey: kCIInputScaleKey)
            f?.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        } else {
            f = CIFilter(name: "CIGaussianBlur")
            f?.setValue(max(10, ext.width / 80), forKey: kCIInputRadiusKey)
        }
        f?.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        guard let out = f?.outputImage?.cropped(to: ext),
              let res = CIContext().createCGImage(out, from: ext) else { return nil }
        return NSImage(cgImage: res, size: pixelSize)
    }

    static func contrast(for c: NSColor) -> NSColor {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        let lum = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return lum > 0.6 ? .black : .white
    }

    // MARK: Çizim

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0.13, alpha: 1).setFill(); bounds.fill()
        let r = imageRect(), v = viewRegion
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowBlurRadius = 12; sh.shadowColor = NSColor.black.withAlphaComponent(0.5)
        sh.set()
        NSColor.black.setFill(); r.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        let t = NSAffineTransform()
        t.translateX(by: r.minX, yBy: r.minY)
        t.scale(by: scale)
        t.translateX(by: -v.minX, yBy: -v.minY)
        t.concat()
        image.draw(in: fullRect)
        drawAll(includeCurrent: true)

        if let c = current, c.tool == .pixelate || c.tool == .blur, let rr = rectOf(c) {
            let p = NSBezierPath(rect: rr); p.lineWidth = 1.5 / scale
            p.setLineDash([6 / scale, 4 / scale], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.9).setStroke(); p.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        if tool == .crop { drawCropOverlay() }
    }

    /// İşaretler ayrı bir katmana çizilir; böylece silgi sadece işaretleri siler, görseli değil
    func drawAll(includeCurrent: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        var n = 0
        for m in marks {
            if m.tool == .number { n += 1 }
            drawMark(m, number: n)
        }
        if includeCurrent, let c = current { drawMark(c, number: n + 1) }
        ctx.endTransparencyLayer()
    }

    func rectOf(_ m: Mark) -> NSRect? {
        guard let a = m.points.first, let b = m.points.last, m.points.count > 1 else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    func textAttributes(_ m: Mark) -> (outline: [NSAttributedString.Key: Any], fill: [NSAttributedString.Key: Any]) {
        let f = m.font.font(size: m.width)
        return ([.font: f, .strokeColor: AnnotationView.contrast(for: m.color), .strokeWidth: 14],
                [.font: f, .foregroundColor: m.color])
    }

    /// Okun izlediği yol: düz okta iki nokta, eğri okta yumuşatılmış el çizimi
    func arrowPath(_ m: Mark) -> [CGPoint] {
        guard let f = m.points.first, let l = m.points.last else { return [] }
        if !m.curved || m.points.count < 3 { return [f, l] }
        return PathMath.chaikin(PathMath.simplify(m.points, max(m.width * 2.5, 3)), iterations: 4)
    }

    func arrowHeadSize(_ m: Mark) -> CGFloat {
        m.arrow == .soft ? max(m.width * 4, 14) : max(m.width * 4.5, 14)
    }

    func drawArrow(_ m: Mark) {
        let pts = arrowPath(m)
        let len = PathMath.length(pts)
        guard len > 1, let tip0 = pts.last else { return }
        let head = min(len * 0.6, arrowHeadSize(m))
        let shaftW = max(m.width * 1.6, head * 0.3)         // gövde kafaya oranla kalın
        // kafanın yönü: yolun son kısmının yönü
        let back = PathMath.point(at: max(0, len - head), pts)
        let dl = max(hypot(tip0.x - back.x, tip0.y - back.y), 0.001)
        let ux = (tip0.x - back.x) / dl, uy = (tip0.y - back.y) / dl
        m.color.setStroke(); m.color.setFill()

        let soft = m.arrow == .soft
        let round = soft ? max(m.width * 1.3, head * 0.45) : 0
        let tip = CGPoint(x: tip0.x - ux * round / 2, y: tip0.y - uy * round / 2)
        let headLen = head - round / 2
        let bx = tip.x - ux * headLen, by = tip.y - uy * headLen
        let half = head * (soft ? 0.62 : 0.55)

        // gövde: kafanın içine kadar uzanır
        let shaft = PathMath.prefix(upTo: max(0, len - head * (soft ? 0.55 : 0.75)), pts)
        let sp = NSBezierPath()
        sp.lineCapStyle = .round; sp.lineJoinStyle = .round
        if let s0 = shaft.first {
            sp.move(to: s0)
            if shaft.count == 1 { sp.line(to: s0) }
            for p in shaft.dropFirst() { sp.line(to: p) }
        }
        sp.lineWidth = shaftW; sp.stroke()

        let tri = NSBezierPath()
        tri.lineJoinStyle = .round
        tri.move(to: tip)
        tri.line(to: CGPoint(x: bx - uy * half, y: by + ux * half))
        tri.line(to: CGPoint(x: bx + uy * half, y: by - ux * half))
        tri.close()
        tri.fill()
        if soft { tri.lineWidth = round; tri.stroke() }
    }

    func drawMark(_ m: Mark, number: Int) {
        guard let first = m.points.first else { return }
        let path = NSBezierPath()
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        switch m.tool {
        case .pen, .marker:
            path.move(to: first)
            if m.points.count == 1 { path.line(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            for p in m.points.dropFirst() { path.line(to: p) }
            path.lineWidth = m.tool == .marker ? m.width * 4 : m.width
            (m.tool == .marker ? m.color.withAlphaComponent(0.35) : m.color).setStroke()
            path.stroke()
        case .rect:
            guard let rr = rectOf(m) else { return }
            let p = NSBezierPath(roundedRect: rr, xRadius: m.width, yRadius: m.width)
            p.lineWidth = m.width; m.color.setStroke(); p.stroke()
        case .arrow:
            drawArrow(m)
        case .pixelate, .blur:
            guard let rr = rectOf(m), let fx = (m.tool == .pixelate ? pixelated : blurred) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rr).addClip()
            fx.draw(in: fullRect)
            NSGraphicsContext.restoreGraphicsState()
        case .text:
            let a = textAttributes(m)
            NSAttributedString(string: m.text, attributes: a.outline).draw(at: first)
            NSAttributedString(string: m.text, attributes: a.fill).draw(at: first)
        case .number:
            let d = m.width
            let circle = NSRect(x: first.x - d / 2, y: first.y - d / 2, width: d, height: d)
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowBlurRadius = d * 0.12
            sh.shadowOffset = NSSize(width: 0, height: -d * 0.04)
            sh.shadowColor = NSColor.black.withAlphaComponent(0.45); sh.set()
            m.color.setFill(); NSBezierPath(ovalIn: circle).fill()
            NSGraphicsContext.restoreGraphicsState()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: d * 0.04, dy: d * 0.04))
            ring.lineWidth = d * 0.08; NSColor.white.setStroke(); ring.stroke()
            let s = NSAttributedString(string: "\(number)", attributes: [
                .font: TextFont.rounded.font(size: d * 0.55),
                .foregroundColor: AnnotationView.contrast(for: m.color)])
            let sz = s.size()
            s.draw(at: NSPoint(x: first.x - sz.width / 2, y: first.y - sz.height / 2))
        case .eraser:
            // kısmi silgi: işaret katmanındaki pikselleri temizler (görsel etkilenmez)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let cp = CGMutablePath()
            cp.move(to: first)
            if m.points.count == 1 { cp.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            for p in m.points.dropFirst() { cp.addLine(to: p) }
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(m.width)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addPath(cp)
            ctx.strokePath()
            ctx.restoreGState()
        case .crop:
            break
        }
    }

    // MARK: Silgi (bütün işaret)

    /// p noktası (görsel pikseli) bu işarete değiyor mu
    func hit(_ m: Mark, _ p: CGPoint, tol: CGFloat) -> Bool {
        guard let first = m.points.first else { return false }
        switch m.tool {
        case .pen, .marker:
            let half = (m.tool == .marker ? m.width * 4 : m.width) / 2 + tol
            return PathMath.polyDist(p, m.points) <= half
        case .arrow:
            let pts = arrowPath(m)
            guard let last = pts.last else { return false }
            return PathMath.polyDist(p, pts) <= max(m.width * 1.6, arrowHeadSize(m) * 0.3) / 2 + tol
                || hypot(p.x - last.x, p.y - last.y) <= arrowHeadSize(m) * 0.7 + tol
        case .rect:
            guard let rr = rectOf(m) else { return false }
            let outer = rr.insetBy(dx: -(m.width / 2 + tol), dy: -(m.width / 2 + tol))
            let inset = m.width / 2 + tol
            let inner = rr.insetBy(dx: inset, dy: inset)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        case .pixelate, .blur:
            guard let rr = rectOf(m) else { return false }
            return rr.insetBy(dx: -tol, dy: -tol).contains(p)
        case .text:
            let sz = NSAttributedString(string: m.text, attributes: textAttributes(m).fill).size()
            return NSRect(origin: first, size: sz).insetBy(dx: -tol, dy: -tol).contains(p)
        case .number:
            return hypot(p.x - first.x, p.y - first.y) <= m.width / 2 + tol
        case .eraser, .crop:
            return false
        }
    }

    func eraseWholeAt(_ p: CGPoint) {
        let tol = eraserRadius / scale
        let kept = marks.filter { !hit($0, p, tol: tol) }
        guard kept.count != marks.count else { return }
        if !erasedThisDrag { pushHistory(); erasedThisDrag = true }   // bir sürükleme = tek Geri Al adımı
        marks = kept
    }

    // MARK: Fare

    override func mouseDown(with e: NSEvent) {
        let vp = convert(e.locationInWindow, from: nil)
        if editor != nil { commitText() }
        window?.makeFirstResponder(self)
        let p = toImage(vp)
        switch tool {
        case .text:
            beginText(at: vp)
        case .number:
            pushHistory()
            marks.append(Mark(tool: .number, color: color, width: (18 + lineWidth * 2) / scale, points: [p]))
        case .eraser:
            if eraserMode == .whole {
                erasedThisDrag = false
                eraseWholeAt(p)
            } else {
                current = Mark(tool: .eraser, color: .clear, width: eraserRadius * 2 / scale, points: [p])
            }
        case .crop:
            let h = cropHandle(at: vp)
            if h != .none, let c = cropEditing {
                cropDrag = (h, p, c)
                if h == .move { NSCursor.closedHand.set() }
            }
        default:
            current = Mark(tool: tool, color: color, width: lineWidth / scale, points: [p],
                           arrow: arrowStyle, curved: arrowCurved)
        }
    }
    override func mouseDragged(with e: NSEvent) {
        let p = toImage(convert(e.locationInWindow, from: nil))
        switch tool {
        case .eraser where eraserMode == .whole: eraseWholeAt(p); return
        case .crop: dragCrop(to: p); return
        default: break
        }
        guard var c = current else { return }
        if c.tool == .pen || c.tool == .marker || c.tool == .eraser || (c.tool == .arrow && c.curved) {
            c.points.append(p)
        } else {
            c.points = [c.points[0], p]
        }
        current = c
    }
    override func mouseUp(with e: NSEvent) {
        if tool == .crop { cropDrag = nil; window?.invalidateCursorRects(for: self); return }
        if tool == .eraser && eraserMode == .whole { erasedThisDrag = false; return }
        guard let c = current else { return }
        current = nil
        switch c.tool {
        case .pen, .marker, .eraser:
            break
        case .arrow:
            guard PathMath.length(c.points) > 3 / scale else { return }
        default:
            guard let rr = rectOf(c), hypot(rr.width, rr.height) > 3 / scale else { return }
        }
        pushHistory()
        marks.append(c)
    }

    // MARK: Yazı

    func beginText(at vp: NSPoint) {
        editorFontPx = (10 + lineWidth * 2.5) / scale
        let f = NSTextField(string: "")
        f.font = textFont.font(size: editorFontPx * scale)
        f.textColor = color
        f.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        f.drawsBackground = true
        f.isBordered = false
        f.focusRingType = .none
        f.placeholderString = "Yaz, Enter ile bitir"
        f.delegate = self
        f.sizeToFit()
        let h = f.frame.height
        f.frame = NSRect(x: vp.x, y: vp.y - h / 2, width: max(180, f.frame.width), height: h)
        addSubview(f)
        window?.makeFirstResponder(f)
        editor = f
    }

    func resizeEditor() {
        guard let f = editor else { return }
        let minY = f.frame.minY, minX = f.frame.minX
        f.sizeToFit()
        let w = f.attributedStringValue.size().width + 24
        f.frame = NSRect(x: minX, y: minY, width: max(180, w), height: f.frame.height)
    }

    func controlTextDidChange(_ n: Notification) { resizeEditor() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { commitText(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancelText(); return true }
        return false
    }

    func commitText() {
        guard let f = editor else { return }
        let s = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = toImage(NSPoint(x: f.frame.minX + 2, y: f.frame.minY))
        let c = f.textColor ?? color
        editor = nil
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        if !s.isEmpty {
            pushHistory()
            marks.append(Mark(tool: .text, color: c, width: editorFontPx, points: [origin], text: s, font: textFont))
        }
    }

    func cancelText() {
        editor?.removeFromSuperview(); editor = nil
        window?.makeFirstResponder(self)
    }

    // MARK: Klavye

    override func keyDown(with e: NSEvent) {
        if tool == .crop, cropEditing != nil, e.keyCode == 36 || e.keyCode == 76 {   // Enter: kırpmayı uygula
            applyCrop()
            onCropped?(true)
            return
        }
        super.keyDown(with: e)
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if editor != nil { return super.performKeyEquivalent(with: e) }  // yazı yazarken ⌘C/⌘V yazı kutusuna
        guard e.modifierFlags.contains(.command), let ch = e.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: e)
        }
        switch ch {
        case "z": onCommand?("undo"); return true
        case "s", "c": onCommand?("save"); return true
        case "w": window?.performClose(nil); return true
        default: return super.performKeyEquivalent(with: e)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if tool == .crop, cropEditing != nil {        // Esc: kırpmadan vazgeç
            cropEditing = crop
            onCropped?(false)
            return
        }
        window?.performClose(nil)
    }

    /// İşaretlenmiş (ve kırpılmış) görseli tam çözünürlükte PNG olarak üretir
    func renderPNG() -> Data? {
        commitText()
        applyCrop()
        let w = Int(crop.width.rounded()), h = Int(crop.height.rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let t = NSAffineTransform(); t.translateX(by: -crop.minX, yBy: -crop.minY); t.concat()
        image.draw(in: fullRect)
        drawAll(includeCurrent: false)
        NSGraphicsContext.restoreGraphicsState()
        if tool == .crop { cropEditing = crop }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - İşaretleme penceresi

final class AnnotationWindowController: NSWindowController, NSWindowDelegate {
    let canvas: AnnotationView
    let onClose: (AnnotationWindowController) -> Void
    let onSaved: () -> Void
    var colorButtons: [NSButton] = []
    let status = NSTextField(labelWithString: "")
    let undoButton = NSButton(title: "Geri Al", target: nil, action: nil)
    var toolControl: NSSegmentedControl!
    var lastDrawTool: Tool = .pen

    static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                     .systemBlue, .systemPurple, .black, .white]
    /// label: yedek metin; symbol: varsa kullanılacak SF Symbol
    static let tools: [(label: String, symbol: String?, tip: String)] = [
        ("✏️", nil, "Kalem"),
        ("↗", nil, "Ok: tıklayınca sivri/yumuşak ve düz/eğri seç"),
        ("▢", nil, "Kutu"),
        ("🖍", nil, "Fosforlu kalem"),
        ("T", nil, "Yazı: tıklayınca font seç; resme tıkla, yaz, Enter"),
        ("①", nil, "Numaralı işaret: her tık 1, 2, 3…"),
        ("▦", nil, "Pikselleştir: alanı sürükleyerek seç"),
        ("◌", nil, "Bulanıklaştır: alanı sürükleyerek seç"),
        ("Silgi", "eraser", "Silgi: tıklayınca bütün işaret / sadece dokunduğun yer seç"),
        ("Kırp", "crop", "Kırp: kenarları sürükle, Enter ile uygula")]

    init(image: NSImage, onClose: @escaping (AnnotationWindowController) -> Void, onSaved: @escaping () -> Void) {
        let cv = AnnotationView(image: image)
        canvas = cv
        self.onClose = onClose; self.onSaved = onSaved

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let ptSize = NSSize(width: cv.pixelSize.width / 2, height: cv.pixelSize.height / 2)
        let maxW = screen.width * 0.85, maxH = screen.height * 0.85 - 56
        let s = min(1, maxW / max(ptSize.width + 40, 1), maxH / max(ptSize.height + 40, 1))
        let size = NSSize(width: max(1000, (ptSize.width + 40) * s), height: max(440, (ptSize.height + 40) * s + 56))

        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Googly İşaretle"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 960, height: 360)
        win.center()
        super.init(window: win)
        win.delegate = self
        buildUI()
        canvas.onChange = { [weak self] in self?.undoButton.isEnabled = !(self?.canvas.history.isEmpty ?? true) }
        canvas.onCommand = { [weak self] cmd in
            if cmd == "undo" { self?.undo() } else { self?.save() }
        }
        canvas.onCropped = { [weak self] applied in
            // Enter / Esc sonrası son çizim aracına dön
            guard let self = self else { return }
            self.toolControl.selectedSegment = self.lastDrawTool.rawValue
            self.canvas.tool = self.lastDrawTool
            self.status.stringValue = applied ? "Kırpıldı ✓ (Geri Al ile eski haline dönebilirsin)" : ""
        }
        canvas.onChange?()
    }
    required init?(coder: NSCoder) { fatalError() }

    func buildUI() {
        guard let content = window?.contentView else { return }

        let tools = NSSegmentedControl(labels: Self.tools.map { $0.label },
                                       trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        for (i, t) in Self.tools.enumerated() {
            tools.setToolTip(t.tip, forSegment: i)
            if let name = t.symbol, let img = NSImage(systemSymbolName: name, accessibilityDescription: t.label) {
                tools.setImage(img, forSegment: i)
                tools.setLabel("", forSegment: i)
            }
        }
        tools.selectedSegment = 0
        toolControl = tools

        let colors = NSStackView(); colors.spacing = 5
        for (i, c) in Self.palette.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(colorChanged(_:)))
            b.tag = i; b.isBordered = false; b.wantsLayer = true
            b.layer?.backgroundColor = c.cgColor
            b.layer?.cornerRadius = 9
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 18).isActive = true
            b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            colors.addArrangedSubview(b); colorButtons.append(b)
        }
        highlightColor(0)

        let slider = NSSlider(value: 4, minValue: 1, maxValue: 16, target: self, action: #selector(widthChanged(_:)))
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        slider.toolTip = "Kalınlık / yazı boyu / numara boyu / silgi boyu"

        undoButton.target = self; undoButton.action = #selector(undo); undoButton.bezelStyle = .rounded
        undoButton.toolTip = "⌘Z"
        let clear = NSButton(title: "Temizle", target: self, action: #selector(clearAll))
        clear.toolTip = "Tüm işaretleri ve kırpmayı kaldırır"
        let save = NSButton(title: Pref.saveToDesktop ? "Panoya + Masaüstüne" : "Panoya Kopyala",
                            target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.toolTip = "⌘S"
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [tools, colors, NSTextField(labelWithString: "Boyut"), slider,
                                      spacer, status, undoButton, clear, save])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        bar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar); content.addSubview(canvas)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.initialFirstResponder = canvas
    }

    func highlightColor(_ idx: Int) {
        for (i, b) in colorButtons.enumerated() {
            let selected = i == idx
            b.layer?.borderWidth = selected ? 2.5 : (Self.palette[i] == .white ? 1 : 0)
            b.layer?.borderColor = (selected ? NSColor.controlAccentColor : NSColor.systemGray).cgColor
        }
    }

    @objc func toolChanged(_ s: NSSegmentedControl) {
        let t = Tool(rawValue: s.selectedSegment) ?? .pen
        canvas.tool = t
        window?.makeFirstResponder(canvas)
        if t != .crop && t != .eraser { lastDrawTool = t }
        switch t {
        case .arrow: popUpMenu(arrowMenu(), under: s, segment: s.selectedSegment)
        case .text: popUpMenu(fontMenu(), under: s, segment: s.selectedSegment)
        case .eraser:
            status.stringValue = ""
            popUpMenu(eraserMenu(), under: s, segment: s.selectedSegment)
        case .crop: status.stringValue = "Kenarları ya da köşeleri sürükle · Enter: uygula · Esc: vazgeç"
        default: status.stringValue = ""
        }
    }

    /// Seçilen aracın altında küçük bir seçenek menüsü aç
    func popUpMenu(_ menu: NSMenu, under s: NSSegmentedControl, segment: Int) {
        var x: CGFloat = 0
        for i in 0..<segment { x += s.width(forSegment: i) > 0 ? s.width(forSegment: i) : s.bounds.width / CGFloat(s.segmentCount) }
        let y = s.isFlipped ? s.bounds.height + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: s)
    }

    func menuItem(_ title: String, _ action: Selector, tag: Int, on: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self; i.tag = tag; i.state = on ? .on : .off
        return i
    }

    func arrowMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(menuItem("Sivri Ok", #selector(setArrowStyle(_:)), tag: 0, on: canvas.arrowStyle == .sharp))
        m.addItem(menuItem("Yumuşak Ok", #selector(setArrowStyle(_:)), tag: 1, on: canvas.arrowStyle == .soft))
        m.addItem(.separator())
        m.addItem(menuItem("Düz", #selector(setArrowShape(_:)), tag: 0, on: !canvas.arrowCurved))
        m.addItem(menuItem("Eğri (çizdiğim gibi)", #selector(setArrowShape(_:)), tag: 1, on: canvas.arrowCurved))
        return m
    }

    func eraserMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(menuItem("Bütün işareti sil", #selector(setEraserMode(_:)), tag: 0, on: canvas.eraserMode == .whole))
        m.addItem(menuItem("Sadece dokunduğum yeri sil", #selector(setEraserMode(_:)), tag: 1, on: canvas.eraserMode == .partial))
        return m
    }

    func fontMenu() -> NSMenu {
        let m = NSMenu()
        for f in TextFont.allCases {
            let i = menuItem(f.title, #selector(setTextFont(_:)), tag: f.rawValue, on: canvas.textFont == f)
            i.attributedTitle = NSAttributedString(string: f.title, attributes: [.font: f.font(size: 14)])
            m.addItem(i)
        }
        return m
    }

    @objc func setArrowStyle(_ i: NSMenuItem) { canvas.arrowStyle = ArrowStyle(rawValue: i.tag) ?? .sharp }
    @objc func setArrowShape(_ i: NSMenuItem) { canvas.arrowCurved = i.tag == 1 }
    @objc func setEraserMode(_ i: NSMenuItem) { canvas.eraserMode = EraserMode(rawValue: i.tag) ?? .whole }
    @objc func setTextFont(_ i: NSMenuItem) { canvas.textFont = TextFont(rawValue: i.tag) ?? .rounded }

    @objc func colorChanged(_ b: NSButton) {
        canvas.color = Self.palette[b.tag]; highlightColor(b.tag)
        canvas.editor?.textColor = canvas.color
    }
    @objc func widthChanged(_ s: NSSlider) { canvas.lineWidth = CGFloat(s.doubleValue) }
    @objc func undo() { canvas.undoLast() }
    @objc func clearAll() { canvas.clearAll() }

    @objc func save() {
        guard let png = canvas.renderPNG() else { return }
        Output.toClipboard(png: png)
        if !Pref.saveToDesktop {
            status.stringValue = "Panoya kopyalandı ✓"
            onSaved()
        } else if let err = Output.saveToDesktop(png: png, prefix: "Googly İşaretli") {
            status.stringValue = "Kaydedilemedi: \(err)"
        } else {
            status.stringValue = "Panoya kopyalandı ✓ Masaüstüne kaydedildi ✓"
            onSaved()
        }
    }

    func windowWillClose(_ n: Notification) { onClose(self) }
}

// MARK: - Başlat

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
