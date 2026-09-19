import AppKit
import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

// ─────────────────────────────────────────────────────────────────────────────
// Пути
// ─────────────────────────────────────────────────────────────────────────────

let home = FileManager.default.homeDirectoryForCurrentUser
let configDir = home.appendingPathComponent(".config/adaptive-brightness", isDirectory: true)
let stateDir  = home.appendingPathComponent(".local/state/adaptive-brightness", isDirectory: true)
let configURL = configDir.appendingPathComponent("config.json")
let stateURL  = stateDir.appendingPathComponent("state.json")
let logURL    = stateDir.appendingPathComponent("daemon.log")

func ensureDirs() {
    for d in [configDir, stateDir] {
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Конфиг
// ─────────────────────────────────────────────────────────────────────────────

struct Config {
    /// В конфиге остался ключ от прежнего контура первого порядка. Смысла у него
    /// больше нет, но молча игнорировать чужую настройку нельзя — скажем в логе.
    var legacyTauBrightness = false

    /// Частота контура управления, Гц. Яркость пересчитывается и пишется с этим темпом.
    var controlHz: Double = 30
    /// Частота съёма кадра, Гц. Кадр дешевле записи яркости, но composition не бесплатен.
    var captureHz: Double = 10

    /// Во сколько раз яркость на полностью светлом контенте ниже, чем на тёмном.
    /// 0.6 ≈ «85% на тёмном → 51% на светлом».
    var span: Double = 0.6
    /// Светлота кадра, которая считается «полностью тёмным» экраном (тёмная IDE ≈ 0.12–0.22).
    var darkPoint: Double = 0.15
    /// Светлота кадра, которая считается «полностью светлым» (светлый браузер ≈ 0.75–0.88).
    var lightPoint: Double = 0.80

    /// Жёсткие границы, за которые демон не выходит.
    var minBrightness: Double = 0.15
    var maxBrightness: Double = 1.0

    /// Постоянная времени сглаживания светлоты, сек. За tau проходится 63% пути.
    /// Больше — инертнее к вспышкам и скроллу, но медленнее реакция на смену приложения.
    var tauLuma: Double = 0.6
    /// Время фактического прихода яркости к цели, сек. Ход ведёт критически
    /// демпфированная пружина: мягкий старт, максимум скорости в середине,
    /// приход без перелёта. Цель пересчитывается каждый такт, поэтому смена
    /// контента посреди хода подхватывается сразу.
    var travelTime: Double = 0.8

    /// Из покоя трогаемся, только когда цель разошлась с яркостью больше этого.
    /// Гистерезис против мелкой ряби контента; уже идущий ход не тормозит.
    var startThreshold: Double = 0.015
    /// Ход завершён, когда и остаток, и шаг за такт стали меньше этого.
    var stopThreshold: Double = 0.002
    /// Расхождение «что я записал» vs «что стоит», которое считается внешней
    /// правкой. Чтение возвращает записанное бит-в-бит, поэтому порог держим
    /// много ниже шага клавиш яркости (1/16 = 0.0625).
    var manualEpsilon: Double = 0.01
    /// Тишина после последнего внешнего изменения, после которой серия нажатий
    /// считается законченной и пишется одной строкой в лог, сек.
    var manualQuietPeriod: Double = 0.6
    /// Насколько должна уехать нормированная светлота от той, при которой ты
    /// правил яркость, чтобы демон счёл контент сменившимся и снова взялся вести.
    var resumeLumaDelta: Double = 0.12

    /// Не трогать яркость, пока macOS держит Game Mode.
    ///
    /// Ловится по `com.apple.system.console_mode_changed` («Console Mode» —
    /// внутреннее имя Game Mode): 0 — выключен, 1 — включён, после выхода из
    /// игры сам возвращается в 0.
    ///
    /// Срабатывает только для игр, которые macOS сама опознала как игры —
    /// список лежит в `com.apple.GamePolicyAgent`, ключ `installedGames`. Для
    /// игр под CrossOver, Wine и прочими обёртками Game Mode не включается
    /// вообще: система видит только обёртку, у которой нет категории
    /// «игра». Для них есть `pauseApps`.
    var pauseOnGameMode = true

    /// Не трогать яркость, пока впереди приложение с таким bundle id.
    /// Сравнение по префиксу, поэтому "com.codeweavers." накрывает все
    /// CrossOver-игры разом, а "org.ryujinx." — конкретный эмулятор.
    var pauseApps: [String] = ["com.codeweavers."]

    /// Как снимать кадры.
    ///
    /// `shot` — одиночные снимки в отдельной задаче. Постоянной сессии захвата
    /// нет, поэтому macOS не показывает индикатор «идёт запись экрана» в
    /// меню-баре. Каждый снимок стоит ~35 мс независимо от того, менялась ли
    /// картинка.
    ///
    /// `stream` — постоянный SCStream. На статичном экране кадры не приходят
    /// вовсе, так что съём почти бесплатен, но индикатор записи экрана висит
    /// всё время работы демона. Скрыть его нельзя: это привилегия системы.
    var captureMode = "shot"

    /// Разрешение кадра для анализа.
    var sampleWidth: Int = 96
    var sampleHeight: Int = 62

    static func load() -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: configURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        func d(_ k: String, _ cur: Double) -> Double { (raw[k] as? NSNumber)?.doubleValue ?? cur }
        func i(_ k: String, _ cur: Int) -> Int { (raw[k] as? NSNumber)?.intValue ?? cur }
        c.controlHz       = d("controlHz", c.controlHz)
        c.captureHz       = d("captureHz", c.captureHz)
        c.span            = d("span", c.span)
        c.darkPoint       = d("darkPoint", c.darkPoint)
        c.lightPoint      = d("lightPoint", c.lightPoint)
        c.minBrightness   = d("minBrightness", c.minBrightness)
        c.maxBrightness   = d("maxBrightness", c.maxBrightness)
        c.tauLuma         = d("tauLuma", c.tauLuma)
        c.travelTime      = d("travelTime", c.travelTime)
        c.manualQuietPeriod = d("manualQuietPeriod", c.manualQuietPeriod)
        c.resumeLumaDelta = d("resumeLumaDelta", c.resumeLumaDelta)
        if raw["travelTime"] == nil, raw["tauBrightness"] != nil { c.legacyTauBrightness = true }
        c.startThreshold  = d("startThreshold", c.startThreshold)
        c.stopThreshold   = d("stopThreshold", c.stopThreshold)
        c.manualEpsilon   = d("manualEpsilon", c.manualEpsilon)
        c.captureMode     = (raw["captureMode"] as? String) ?? c.captureMode
        c.pauseOnGameMode = (raw["pauseOnGameMode"] as? NSNumber)?.boolValue ?? c.pauseOnGameMode
        c.pauseApps       = (raw["pauseApps"] as? [String]) ?? c.pauseApps
        c.sampleWidth     = i("sampleWidth", c.sampleWidth)
        c.sampleHeight    = i("sampleHeight", c.sampleHeight)
        return c
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Состояние: baseline, который задаёт пользователь руками
// ─────────────────────────────────────────────────────────────────────────────

struct State {
    /// Яркость, которую пользователь выставил руками.
    var baseline: Double
    /// Светлота экрана в момент, когда он её выставил.
    var baselineLuma: Double
    /// Последнее значение, которое демон записал сам, — чтобы отличить ручную правку.
    var lastWritten: Double
    /// Светлота, при которой была ручная правка, пока демон держит паузу.
    /// nil — паузы нет, демон ведёт яркость. Лежит в state, чтобы `status` мог
    /// объяснить, почему яркость не двигается.
    var holdLuma: Double?

    func save() {
        var obj: [String: Any] = [
            "baseline": baseline,
            "baselineLuma": baselineLuma,
            "lastWritten": lastWritten,
        ]
        if let h = holdLuma { obj["holdLuma"] = h }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    static func load() -> State? {
        guard let data = try? Data(contentsOf: stateURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b = (raw["baseline"] as? NSNumber)?.doubleValue,
              let l = (raw["baselineLuma"] as? NSNumber)?.doubleValue else { return nil }
        let w = (raw["lastWritten"] as? NSNumber)?.doubleValue ?? b
        let h = (raw["holdLuma"] as? NSNumber)?.doubleValue
        return State(baseline: b, baselineLuma: l, lastWritten: w, holdLuma: h)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Подсветка встроенного дисплея (приватный DisplayServices)
// ─────────────────────────────────────────────────────────────────────────────

final class Backlight {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getFn: GetFn
    private let setFn: SetFn

    init?() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW),
              let g = dlsym(handle, "DisplayServicesGetBrightness"),
              let s = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        getFn = unsafeBitCast(g, to: GetFn.self)
        setFn = unsafeBitCast(s, to: SetFn.self)
    }

    func read(_ display: CGDirectDisplayID) -> Double? {
        var v: Float = 0
        guard getFn(display, &v) == 0 else { return nil }
        return Double(v)
    }

    @discardableResult
    func write(_ display: CGDirectDisplayID, _ value: Double) -> Bool {
        setFn(display, Float(max(0, min(1, value)))) == 0
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Снятие кадра и расчёт воспринимаемой светлоты
// ─────────────────────────────────────────────────────────────────────────────

/// sRGB → линейный свет. Усреднять надо именно линейные величины: усреднение
/// гамма-кодированных байт завысило бы вклад тёмных областей.
let linearLUT: [Double] = (0...255).map { i -> Double in
    let c = Double(i) / 255.0
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

final class ScreenSampler: @unchecked Sendable {
    private let config: SCStreamConfiguration
    private var filter: SCContentFilter?
    private var filterRefreshed = Date.distantPast

    init(width: Int, height: Int) {
        let c = SCStreamConfiguration()
        c.width = width
        c.height = height
        c.showsCursor = false
        c.capturesAudio = false
        config = c
    }

    private func currentFilter() async throws -> SCContentFilter {
        // Фильтр кэшируем: SCShareableContent — заметно дороже самого кадра.
        if let f = filter, Date().timeIntervalSince(filterRefreshed) < 60 { return f }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw NSError(domain: "adaptive-brightness", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "нет доступных дисплеев"])
        }
        let f = SCContentFilter(display: display, excludingWindows: [])
        filter = f
        filterRefreshed = Date()
        return f
    }

    func invalidate() { filter = nil }

    /// Воспринимаемая светлота кадра в [0..1].
    func luma() async throws -> Double {
        let f = try await currentFilter()
        let image = try await SCScreenshotManager.captureImage(contentFilter: f, configuration: config)
        return ScreenSampler.perceivedLuma(image)
    }

    static func perceivedLuma(_ image: CGImage) -> Double {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return 0 }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var sum = 0.0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            sum += 0.2126 * linearLUT[Int(buf[i])]
                 + 0.7152 * linearLUT[Int(buf[i + 1])]
                 + 0.0722 * linearLUT[Int(buf[i + 2])]
        }
        let meanLinear = sum / Double(w * h)
        // Обратно в перцептивную шкалу — чтобы шкала совпадала с тем, как глаз
        // оценивает «тёмный / светлый» интерфейс.
        return pow(max(0, min(1, meanLinear)), 1.0 / 2.2)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Когда яркость трогать не надо
// ─────────────────────────────────────────────────────────────────────────────

// Функции notify(3) в модуль Darwin не экспортированы — объявляем сами.
@_silgen_name("notify_register_check")
func notify_register_check(_ name: UnsafePointer<CChar>, _ token: UnsafeMutablePointer<Int32>) -> UInt32
@_silgen_name("notify_get_state")
func notify_get_state(_ token: Int32, _ state: UnsafeMutablePointer<UInt64>) -> UInt32

/// Состояние Game Mode через Darwin-уведомление. Замерено: при запуске игры,
/// которую macOS считает игрой, значение уходит 0 → 1, после выхода само
/// возвращается в 0. Чтение дешёвое — это разделяемая память, не XPC.
final class GameModeWatch {
    private var token: Int32 = -1
    private let registered: Bool

    init() {
        var t: Int32 = 0
        registered = notify_register_check("com.apple.system.console_mode_changed", &t) == 0
        if registered { token = t }
    }

    /// false и в случае, когда уведомление недоступно: лучше продолжать вести
    /// яркость, чем молча замереть навсегда из-за неопознанного состояния.
    var active: Bool {
        guard registered else { return false }
        var v: UInt64 = 0
        guard notify_get_state(token, &v) == 0 else { return false }
        return v != 0
    }

    var available: Bool { registered }
}

/// Bundle id приложения на переднем плане. NSWorkspace не требует никаких
/// разрешений — в отличие от AppleScript, которому нужен Automation.
func frontmostBundleID() -> String? {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
}

// ─────────────────────────────────────────────────────────────────────────────
// Источник светлоты для демона: два режима с одним интерфейсом
// ─────────────────────────────────────────────────────────────────────────────

/// Главное требование к обоим режимам: контур управления не должен блокироваться
/// на съёме. Раньше захват стоял прямо в цикле, каждый третий такт выходил вдвое
/// длиннее, и это читалось как биение на 10 Гц.
protocol LumaSource: AnyObject {
    /// Последняя посчитанная светлота; nil — кадров ещё не было.
    var luma: Double? { get }
    /// Сколько прошло с последнего кадра. Растёт, только если съём встал.
    var silence: TimeInterval { get }
    /// Забирает и очищает последнюю ошибку.
    func takeFailure() -> String?
    func start() async throws
    func stop() async
}

/// Одиночные снимки в отдельной задаче.
///
/// Постоянной сессии захвата нет, поэтому macOS не показывает индикатор записи
/// экрана. Платим тем, что снимок стоит одинаково всегда: `SCStream` на
/// статичной картинке не присылает ничего, а здесь мы снимаем по расписанию
/// независимо от того, менялось что-то или нет.
final class ShotSampler: LumaSource, @unchecked Sendable {
    private let shooter: ScreenSampler
    private let interval: TimeInterval

    private let lock = NSLock()
    private var _luma: Double?
    private var _lastDelivery = Date.distantPast
    private var _failure: String?

    private var task: Task<Void, Never>?

    init(width: Int, height: Int, fps: Double) {
        shooter = ScreenSampler(width: width, height: height)
        interval = 1.0 / max(0.1, fps)
    }

    var luma: Double? { lock.lock(); defer { lock.unlock() }; return _luma }

    var silence: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_lastDelivery)
    }

    func takeFailure() -> String? {
        lock.lock(); defer { lock.unlock() }
        let f = _failure; _failure = nil; return f
    }

    private func publish(_ value: Double) {
        lock.lock(); _luma = value; _lastDelivery = Date(); lock.unlock()
    }

    private func publish(failure: String) {
        lock.lock(); _failure = failure; lock.unlock()
    }

    func start() async throws {
        await stop()
        // Первый снимок делаем синхронно: если разрешения нет, демон должен
        // узнать об этом сразу, а не через пять секунд молчания.
        publish(try await shooter.luma())

        let shooter = self.shooter
        let interval = self.interval
        task = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                do {
                    self.publish(try await shooter.luma())
                } catch {
                    shooter.invalidate()
                    self.publish(failure: error.localizedDescription)
                    return
                }
            }
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Непрерывный поток кадров — то, чем пользуется демон
// ─────────────────────────────────────────────────────────────────────────────

/// Одноразовый `SCScreenshotManager.captureImage` стоит ~35 мс на вызов, и он
/// стоял прямо в контуре управления: каждый третий такт выходил вдвое длиннее
/// остальных, что читалось как биение на 10 Гц. Поток отдаёт кадры сам, в своей
/// очереди, а контур только забирает последнее посчитанное значение и не
/// блокируется никогда.
///
/// Вдобавок поток не присылает картинку, когда она не изменилась, — на
/// статичном экране съём почти ничего не стоит.
final class LiveSampler: NSObject, LumaSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let width: Int
    private let height: Int
    private let fps: Double

    private let lock = NSLock()
    private var _luma: Double?
    private var _lastDelivery = Date.distantPast
    private var _failure: String?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.geforester.adaptive-brightness.capture",
                                      qos: .userInitiated)

    init(width: Int, height: Int, fps: Double) {
        self.width = width
        self.height = height
        self.fps = max(1, fps)
        super.init()
    }

    /// Последняя посчитанная светлота; nil — кадров ещё не было.
    var luma: Double? { lock.lock(); defer { lock.unlock() }; return _luma }

    /// Сколько прошло с последнего кадра любого рода. Растёт только если поток
    /// действительно встал: статичный экран всё равно шлёт кадры со статусом
    /// «без изменений», и они здесь учитываются.
    var silence: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_lastDelivery)
    }

    /// Забирает и очищает последнюю ошибку потока.
    func takeFailure() -> String? {
        lock.lock(); defer { lock.unlock() }
        let f = _failure; _failure = nil; return f
    }

    func start() async throws {
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw NSError(domain: "adaptive-brightness", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "нет доступных дисплеев"])
        }
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 3
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))

        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                         configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        noteStreamStarted()
        stream = s
    }

    /// Синхронная обёртка: NSLock нельзя брать прямо из async-контекста.
    private func noteStreamStarted() {
        lock.lock(); _lastDelivery = Date(); _failure = nil; lock.unlock()
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        lock.lock(); _lastDelivery = Date(); lock.unlock()

        // Кадр без изменений приходит пустым: светлоты он не несёт, прежнее
        // значение остаётся в силе.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = sb.imageBuffer else { return }

        let l = LiveSampler.perceivedLuma(pixels)
        lock.lock(); _luma = l; lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); _failure = error.localizedDescription; lock.unlock()
    }

    /// Та же метрика, что у одноразового сэмплера, но по BGRA-буферу потока.
    static func perceivedLuma(_ px: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return 0 }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        guard w > 0, h > 0 else { return 0 }
        let rowBytes = CVPixelBufferGetBytesPerRow(px)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        for y in 0..<h {
            let row = p + y * rowBytes
            for x in 0..<w {
                let i = x * 4                       // BGRA
                sum += 0.0722 * linearLUT[Int(row[i])]
                     + 0.7152 * linearLUT[Int(row[i + 1])]
                     + 0.2126 * linearLUT[Int(row[i + 2])]
            }
        }
        return pow(max(0, min(1, sum / Double(w * h))), 1.0 / 2.2)
    }
}

/// Состояние, доступное обработчику SIGTERM. launchd шлёт SIGTERM при kickstart
/// и bootout, а state.json пишется только по приходу к цели — без сохранения
/// здесь перезапуск посреди хода оставлял бы в файле устаревший lastWritten, и
/// на следующем старте демон принимал бы расхождение за ручную правку и замирал
/// на случайной яркости.
final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State?
    func set(_ s: State) { lock.lock(); state = s; lock.unlock() }
    func snapshot() -> State? { lock.lock(); defer { lock.unlock() }; return state }
}

let liveState = StateBox()

// ─────────────────────────────────────────────────────────────────────────────
// Модель яркости
// ─────────────────────────────────────────────────────────────────────────────

func normalizedLuma(_ luma: Double, _ c: Config) -> Double {
    let span = max(1e-6, c.lightPoint - c.darkPoint)
    return max(0, min(1, (luma - c.darkPoint) / span))
}

/// target = baseline × span^(L_now − L_baseline), зажатый в [min, max].
func targetBrightness(luma: Double, state: State, config c: Config) -> Double {
    let now = normalizedLuma(luma, c)
    let ref = normalizedLuma(state.baselineLuma, c)
    let factor = pow(c.span, now - ref)
    return max(c.minBrightness, min(c.maxBrightness, state.baseline * factor))
}

// ─────────────────────────────────────────────────────────────────────────────
// Логирование
// ─────────────────────────────────────────────────────────────────────────────

let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

var logToFile = false

func log(_ message: String) {
    let line = "\(logFormatter.string(from: Date()))  \(message)"
    print(line)
    fflush(stdout)
    guard logToFile else { return }
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
       let size = attrs[.size] as? UInt64, size > 1_000_000 {
        // Простая ротация: держим только последнюю половину.
        if let data = try? Data(contentsOf: logURL) {
            try? data.suffix(500_000).write(to: logURL, options: .atomic)
        }
    }
    if let data = (line + "\n").data(using: .utf8) {
        if let fh = try? FileHandle(forWritingTo: logURL) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}

func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

// ─────────────────────────────────────────────────────────────────────────────
// Состояние сессии: не работаем на спящем/заблокированном экране
// ─────────────────────────────────────────────────────────────────────────────

func screenIsUsable(_ display: CGDirectDisplayID) -> Bool {
    if CGDisplayIsAsleep(display) != 0 { return false }
    if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
       let locked = session["CGSSessionScreenIsLocked"] as? Bool, locked { return false }
    return true
}

// ─────────────────────────────────────────────────────────────────────────────
// Основной цикл
// ─────────────────────────────────────────────────────────────────────────────

func runDaemon(dryRun: Bool, singleShot: Bool) async {
    ensureDirs()
    let config = Config.load()
    let display = CGMainDisplayID()

    guard let backlight = Backlight() else {
        log("ОШИБКА: не удалось подключиться к DisplayServices — управление подсветкой недоступно")
        exit(1)
    }
    guard let initialBrightness = backlight.read(display) else {
        log("ОШИБКА: не удалось прочитать текущую яркость")
        exit(1)
    }

    let useStream = config.captureMode.lowercased() == "stream"
    let sampler: LumaSource = useStream
        ? LiveSampler(width: config.sampleWidth, height: config.sampleHeight, fps: config.captureHz)
        : ShotSampler(width: config.sampleWidth, height: config.sampleHeight, fps: config.captureHz)
    do {
        try await sampler.start()
    } catch {
        log("ОШИБКА захвата экрана: \(error.localizedDescription)")
        log("Скорее всего не выдано разрешение Screen Recording. Смотри README, раздел «Разрешения».")
        exit(2)
    }

    // Ждём первый кадр: baseline бессмыслен без светлоты, при которой он задан.
    var smoothedLuma = 0.0
    var waited = 0.0
    while true {
        if let l = sampler.luma { smoothedLuma = l; break }
        if let f = sampler.takeFailure() {
            log("ОШИБКА захвата экрана: \(f)")
            log("Скорее всего не выдано разрешение Screen Recording. Смотри README, раздел «Разрешения».")
            exit(2)
        }
        if waited > 5 {
            log("ОШИБКА: съём не дал ни одного кадра за 5с")
            exit(2)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        waited += 0.05
    }

    let hadState = State.load() != nil
    var state = State.load() ?? State(baseline: initialBrightness,
                                      baselineLuma: smoothedLuma,
                                      lastWritten: initialBrightness,
                                      holdLuma: nil)
    if !hadState {
        log("Стартовый baseline: \(pct(state.baseline)) при светлоте \(String(format: "%.3f", state.baselineLuma))")
        state.save()
    }

    // launchd шлёт SIGTERM при kickstart и bootout. Сохраняем состояние, иначе
    // в файле останется значение с последнего прихода к цели.
    liveState.set(state)
    let signalQueue = DispatchQueue(label: "com.geforester.adaptive-brightness.signal")
    signal(SIGTERM, SIG_IGN)
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
    termSource.setEventHandler {
        if !dryRun, let s = liveState.snapshot() { s.save() }
        log("SIGTERM — состояние сохранено, выхожу")
        exit(0)
    }
    termSource.resume()

    let dtControl = 1.0 / max(1, config.controlHz)
    // Потолок на шаг времени. После долгой паузы (спящий экран, перегруженная
    // система) честный dt дал бы один гигантский шаг — это выглядело бы скачком.
    // Лучше доехать за пару тактов.
    let maxTick = 0.1
    // Собственная частота пружины. При критическом демпфировании путь пройден
    // на ~98% к моменту omega·t ≈ 6 — отсюда пересчёт из travelTime.
    let omega = 6.0 / max(0.05, config.travelTime)

    if config.legacyTauBrightness {
        log("ВНИМАНИЕ: в конфиге есть tauBrightness — прежний контур первого порядка убран, " +
            "ключ игнорируется. Скорость хода теперь задаёт travelTime (сек до прихода), сейчас \(config.travelTime).")
    }

    log("Запуск. control=\(Int(config.controlHz))Гц " +
        "capture=\(Int(config.captureHz))Гц/\(useStream ? "stream" : "shot") " +
        "tauLuma=\(config.tauLuma)s travel=\(config.travelTime)s span=\(config.span) " +
        "dark=\(config.darkPoint) light=\(config.lightPoint) " +
        "range=[\(pct(config.minBrightness)), \(pct(config.maxBrightness))]\(dryRun ? " [DRY RUN]" : "")")

    var current = initialBrightness
    var velocity = 0.0
    var lastTick = Date()

    // Пауза после ручной правки: пока контент не сменился заметно, выставленная
    // рукой яркость и есть правильная — лезть туда не за чем.
    var holding = state.holdLuma != nil
    var holdLuma = state.holdLuma ?? smoothedLuma
    var manualPending = false
    var manualAt = Date.distantPast

    // Начало текущего хода — ради строчки в логе «откуда и за сколько».
    var moveFrom: Double? = nil
    var moveStarted = Date()

    // Пауза на время игры: яркость не трогаем вообще и съём кадров глушим —
    // он стоит около 20% одного ядра, а игре эти такты нужнее.
    let gameMode = GameModeWatch()
    if config.pauseOnGameMode && !gameMode.available {
        log("ВНИМАНИЕ: состояние Game Mode недоступно, пауза по нему работать не будет")
    }
    var paused = false
    var pauseBrightness = initialBrightness
    var pauseCheckTick = 0
    var pauseReason = ""

    while true {
        try? await Task.sleep(nanoseconds: UInt64(dtControl * 1_000_000_000))

        // Реальный шаг времени, а не предполагаемый. Раньше пружина считала,
        // что прошло ровно 1/controlHz, и при любом подтормаживании цикла шла
        // во столько же раз медленнее заявленного.
        let tickNow = Date()
        let dt = min(max(tickNow.timeIntervalSince(lastTick), dtControl * 0.25), maxTick)
        lastTick = tickNow

        guard screenIsUsable(display) else {
            velocity = 0
            moveFrom = nil
            continue
        }

        guard let actual = backlight.read(display) else { continue }

        // ── Пауза на время игры ──────────────────────────────────────────────
        // Опрашиваем не каждый такт: для входа в игру и выхода из неё хватает
        // с запасом, а лишние обращения к NSWorkspace ни к чему.
        pauseCheckTick += 1
        if pauseCheckTick >= 5 {
            pauseCheckTick = 0
            var reason = ""
            if config.pauseOnGameMode && gameMode.active {
                reason = "Game Mode"
            } else if let front = frontmostBundleID(),
                      let hit = config.pauseApps.first(where: { !$0.isEmpty && front.hasPrefix($0) }) {
                reason = "впереди \(front) (совпало с «\(hit)»)"
            }

            if !reason.isEmpty, !paused {
                paused = true
                pauseReason = reason
                pauseBrightness = actual
                velocity = 0
                moveFrom = nil
                await sampler.stop()
                log("пауза: \(reason). Яркость оставляю на \(pct(actual)), съём остановлен")
            } else if reason.isEmpty, paused {
                paused = false
                do {
                    try await sampler.start()
                } catch {
                    log("выход из паузы: съём не поднялся (\(error.localizedDescription))")
                }
                // Свежий кадр: за время игры прежняя светлота протухла, и
                // сглаживать от неё означало бы ехать от выдуманной точки.
                var waitedResume = 0.0
                while sampler.luma == nil, waitedResume < 3 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    waitedResume += 0.05
                }
                if let fresh = sampler.luma { smoothedLuma = fresh }

                current = actual
                state.lastWritten = actual
                holding = false
                state.holdLuma = nil

                // Если яркость за время игры крутили руками — это новая точка
                // отсчёта. Если нет, прежний baseline остаётся в силе: иначе
                // каждая игра незаметно сбивала бы калибровку.
                if abs(actual - pauseBrightness) > config.manualEpsilon {
                    state.baseline = actual
                    state.baselineLuma = smoothedLuma
                    log("выход из паузы (\(pauseReason)): яркость меняли вручную → новый baseline \(pct(actual))")
                } else {
                    log("выход из паузы (\(pauseReason)): веду от прежнего baseline \(pct(state.baseline))")
                }
                state.save()
                liveState.set(state)
                lastTick = Date()
                pauseReason = ""
                continue
            }
        }
        if paused { continue }

        // Поток мог встать: смена конфигурации дисплея, пробуждение, ошибка.
        if let f = sampler.takeFailure() {
            log("съём остановлен (\(f)) — перезапускаю")
            try? await sampler.start()
            velocity = 0
            moveFrom = nil
            continue
        }
        if sampler.silence > 5 {
            log("съём молчит больше 5с — перезапускаю")
            try? await sampler.start()
            velocity = 0
            moveFrom = nil
            continue
        }

        if let raw = sampler.luma {
            smoothedLuma += (raw - smoothedLuma) * (1 - exp(-dt / max(0.01, config.tauLuma)))
        }

        // ── Внешняя правка ───────────────────────────────────────────────────
        // Чтение возвращает записанное бит-в-бит, поэтому любое расхождение —
        // это не мы: клавиши, Control Center или системный датчик освещённости.
        // Ловим всегда, в том числе посреди хода: гасим скорость и замираем
        // ровно там, где нас остановили, а выставленное значение принимаем за
        // новый baseline при текущей светлоте.
        if !dryRun, abs(actual - state.lastWritten) > config.manualEpsilon {
            velocity = 0
            current = actual
            moveFrom = nil
            state.baseline = actual
            state.baselineLuma = smoothedLuma
            state.lastWritten = actual
            holding = true
            holdLuma = smoothedLuma
            state.holdLuma = smoothedLuma
            state.save()
            liveState.set(state)
            manualPending = true
            manualAt = Date()
            continue
        }
        if dryRun {
            state.lastWritten = actual
            if moveFrom == nil { current = actual }
        }

        // Серия нажатий — это одна правка. Строку пишем, когда клавиши затихли.
        if manualPending, Date().timeIntervalSince(manualAt) > config.manualQuietPeriod {
            manualPending = false
            log(String(format: "ручная правка → baseline %@ при светлоте %.3f (norm %.2f); держу, пока контент не сменится",
                       pct(state.baseline), state.baselineLuma,
                       normalizedLuma(state.baselineLuma, config)))
            if singleShot { return }
        }

        // ── Пауза до смены контента ──────────────────────────────────────────
        // Сравниваем с исходной точкой, а не с прошлым тактом: медленный дрейф
        // контента накапливается и в конце концов порог всё равно перешагнёт.
        if holding {
            let drift = abs(normalizedLuma(smoothedLuma, config) - normalizedLuma(holdLuma, config))
            guard drift > config.resumeLumaDelta else {
                current = actual
                continue
            }
            holding = false
            state.holdLuma = nil
            if !dryRun { state.save() }
            liveState.set(state)
            manualPending = false
            log(String(format: "контент сменился (norm %.2f → %.2f) → снова веду",
                       normalizedLuma(holdLuma, config), normalizedLuma(smoothedLuma, config)))
        }

        // ── Ведение ──────────────────────────────────────────────────────────
        let target = targetBrightness(luma: smoothedLuma, state: state, config: config)

        // Из покоя трогаемся только на заметном расхождении, иначе рябь контента
        // вызывала бы мелкую дрожь. Уже идущий ход этот порог не тормозит.
        if moveFrom == nil {
            guard abs(target - current) > config.startThreshold else { continue }
            moveFrom = current
            moveStarted = Date()
        }

        // Критически демпфированная пружина в устойчивой дискретной форме.
        // Перелёта не даёт по построению, а цель можно менять на каждом такте —
        // поэтому смена контента посреди хода подхватывается без разрыва.
        let x = omega * dt
        let decay = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
        let offset = current - target
        let temp = (velocity + omega * offset) * dt
        velocity = (velocity - omega * temp) * decay
        current = target + (offset + temp) * decay

        // Упор в потолок или пол гасит скорость, иначе пружина «заводится»
        // на рельсе и потом выстреливает обратно.
        let clamped = max(config.minBrightness, min(config.maxBrightness, current))
        if clamped != current {
            current = clamped
            velocity = 0
        }

        let settled = abs(target - current) < config.stopThreshold
                   && abs(velocity) * dt < config.stopThreshold
        if settled {
            current = target
            velocity = 0
        }

        // Писать одно и то же значение по тридцать раз в секунду не за чем,
        // и лишние записи размывали бы детект внешней правки.
        if abs(current - state.lastWritten) > 1e-5 {
            if !dryRun { backlight.write(display, current) }
            state.lastWritten = current
            liveState.set(state)
        }

        if settled, let from = moveFrom {
            if !dryRun { state.save() }
            liveState.set(state)
            log(String(format: "luma=%.3f (norm %.2f)  вёл %@ → %@, %.1fс%@",
                       smoothedLuma, normalizedLuma(smoothedLuma, config),
                       pct(from), pct(target), Date().timeIntervalSince(moveStarted),
                       dryRun ? "  [не применено]" : ""))
            moveFrom = nil
            if singleShot { return }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Вспомогательные команды
// ─────────────────────────────────────────────────────────────────────────────

func runProbe() async {
    let config = Config.load()
    let display = CGMainDisplayID()
    guard let backlight = Backlight() else { log("нет доступа к DisplayServices"); exit(1) }
    let sampler = ScreenSampler(width: config.sampleWidth, height: config.sampleHeight)

    print("Переключайся между приложениями. Ctrl-C чтобы выйти.")
    print("luma — сырая светлота экрана, norm — она же после darkPoint/lightPoint.\n")
    while true {
        do {
            let l = try await sampler.luma()
            let b = backlight.read(display) ?? -1
            print(String(format: "luma=%.3f   norm=%.2f   яркость=%@",
                         l, normalizedLuma(l, config), pct(b)))
        } catch {
            print("захват не удался: \(error.localizedDescription)")
            sampler.invalidate()
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
}

func runStatus() async {
    let config = Config.load()
    let display = CGMainDisplayID()
    guard let backlight = Backlight() else { print("нет доступа к DisplayServices"); exit(1) }
    let actual = backlight.read(display) ?? -1

    print("Яркость сейчас:   \(pct(actual))")
    if let s = State.load() {
        print("Baseline:         \(pct(s.baseline)) при светлоте \(String(format: "%.3f", s.baselineLuma)) (norm \(String(format: "%.2f", normalizedLuma(s.baselineLuma, config))))")
        print("Демон выставлял:  \(pct(s.lastWritten))")
        if let h = s.holdLuma {
            print("Пауза:            держу после ручной правки, жду смены контента")
            print("                  снимется, когда norm уедет от \(String(format: "%.2f", normalizedLuma(h, config))) больше чем на \(config.resumeLumaDelta)")
        }
        do {
            let l = try await ScreenSampler(width: config.sampleWidth, height: config.sampleHeight).luma()
            print("Светлота сейчас:  \(String(format: "%.3f", l)) (norm \(String(format: "%.2f", normalizedLuma(l, config))))")
            print("Цель:             \(pct(targetBrightness(luma: l, state: s, config: config)))")
        } catch {
            print("Светлота сейчас:  недоступна (\(error.localizedDescription))")
        }
    } else {
        print("Baseline:         не задан (демон ещё не запускался)")
    }
    print("")
    print("Конфиг:           \(FileManager.default.fileExists(atPath: configURL.path) ? configURL.path : "\(configURL.path) (нет, используются дефолты)")")
    print("span=\(config.span)  dark=\(config.darkPoint)  light=\(config.lightPoint)")
    print("tauLuma=\(config.tauLuma)s  travelTime=\(config.travelTime)s  resumeLumaDelta=\(config.resumeLumaDelta)")
    print("control=\(Int(config.controlHz))Гц  capture=\(Int(config.captureHz))Гц")
    print("range=[\(pct(config.minBrightness)), \(pct(config.maxBrightness))]")
}

func runReset() async {
    ensureDirs()
    let config = Config.load()
    let display = CGMainDisplayID()
    guard let backlight = Backlight(), let actual = backlight.read(display) else {
        print("нет доступа к подсветке"); exit(1)
    }
    do {
        let l = try await ScreenSampler(width: config.sampleWidth, height: config.sampleHeight).luma()
        State(baseline: actual, baselineLuma: l, lastWritten: actual, holdLuma: nil).save()
        print("Baseline сброшен: \(pct(actual)) при светлоте \(String(format: "%.3f", l))")
    } catch {
        print("не удалось снять кадр: \(error.localizedDescription)"); exit(2)
    }
}

func usage() {
    print("""
    adaptive-brightness — адаптивная яркость по содержимому экрана

      run            цикл демона (это запускает launchd)
      once           один такт с применением, затем выход
      dry-run        цикл без изменения яркости, только лог того, что сделал бы
      probe          печатать светлоту экрана раз в секунду (подбор darkPoint/lightPoint)
      status         текущее состояние, baseline и цель
      reset          принять текущую яркость как новый baseline

    Конфиг: ~/.config/adaptive-brightness/config.json
    Лог:    ~/.local/state/adaptive-brightness/daemon.log
    """)
}

// ─────────────────────────────────────────────────────────────────────────────

let args = CommandLine.arguments.dropFirst()
switch args.first ?? "run" {
case "run":
    logToFile = true
    await runDaemon(dryRun: false, singleShot: false)
case "once":
    await runDaemon(dryRun: false, singleShot: true)
case "dry-run":
    await runDaemon(dryRun: true, singleShot: false)
case "probe":
    await runProbe()
case "status":
    await runStatus()
case "reset":
    await runReset()
default:
    usage()
}
