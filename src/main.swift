import Foundation
import CoreGraphics
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

final class ScreenSampler {
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

    let sampler = ScreenSampler(width: config.sampleWidth, height: config.sampleHeight)

    // Первый замер нужен до инициализации состояния: baseline бессмыслен без
    // светлоты, при которой он был задан.
    var smoothedLuma: Double
    do {
        smoothedLuma = try await sampler.luma()
    } catch {
        log("ОШИБКА захвата экрана: \(error.localizedDescription)")
        log("Скорее всего не выдано разрешение Screen Recording. Смотри README, раздел «Разрешения».")
        exit(2)
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

    // Шаг контура и коэффициенты сглаживания. Инерция задаётся постоянной
    // времени, а не долей на такт: так она не зависит от выбранной частоты.
    let dtControl = 1.0 / max(1, config.controlHz)
    let captureEvery = max(1, Int((config.controlHz / max(0.1, config.captureHz)).rounded()))
    let dtCapture = dtControl * Double(captureEvery)
    let alphaLuma = 1 - exp(-dtCapture / max(0.01, config.tauLuma))
    // Собственная частота пружины. При критическом демпфировании путь пройден
    // на ~98% к моменту omega·t ≈ 6 — отсюда пересчёт из travelTime.
    let omega = 6.0 / max(0.05, config.travelTime)

    if config.legacyTauBrightness {
        log("ВНИМАНИЕ: в конфиге есть tauBrightness — прежний контур первого порядка убран, " +
            "ключ игнорируется. Скорость хода теперь задаёт travelTime (сек до прихода), сейчас \(config.travelTime).")
    }

    log("Запуск. control=\(Int(config.controlHz))Гц capture=\(Int(config.captureHz))Гц " +
        "tauLuma=\(config.tauLuma)s travel=\(config.travelTime)s span=\(config.span) " +
        "dark=\(config.darkPoint) light=\(config.lightPoint) " +
        "range=[\(pct(config.minBrightness)), \(pct(config.maxBrightness))]\(dryRun ? " [DRY RUN]" : "")")

    var tick = 0
    var current = initialBrightness
    var velocity = 0.0

    // Пауза после ручной правки: пока контент не сменился заметно, выставленная
    // рукой яркость и есть правильная — лезть туда не за чем.
    // Паузу переживаем перезапуск: иначе kickstart демона отменял бы решение,
    // которое ты принял руками.
    var holding = state.holdLuma != nil
    var holdLuma = state.holdLuma ?? smoothedLuma
    var manualPending = false
    var manualAt = Date.distantPast

    // Начало текущего хода — только ради строчки в логе «откуда и за сколько».
    var moveFrom: Double? = nil
    var moveStarted = Date()

    while true {
        try? await Task.sleep(nanoseconds: UInt64(dtControl * 1_000_000_000))

        guard screenIsUsable(display) else {
            velocity = 0
            moveFrom = nil
            sampler.invalidate()
            continue
        }

        if tick % captureEvery == 0 {
            do {
                let raw = try await sampler.luma()
                smoothedLuma += (raw - smoothedLuma) * alphaLuma
            } catch {
                log("захват не удался: \(error.localizedDescription)")
                sampler.invalidate()
                velocity = 0
                moveFrom = nil
                continue
            }
        }
        tick &+= 1

        guard let actual = backlight.read(display) else { continue }

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
        let x = omega * dtControl
        let decay = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
        let offset = current - target
        let temp = (velocity + omega * offset) * dtControl
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
                   && abs(velocity) * dtControl < config.stopThreshold
        if settled {
            current = target
            velocity = 0
        }

        // Писать одно и то же значение по тридцать раз в секунду не за чем,
        // и лишние записи размывали бы детект внешней правки.
        if abs(current - state.lastWritten) > 1e-5 {
            if !dryRun { backlight.write(display, current) }
            state.lastWritten = current
        }

        if settled, let from = moveFrom {
            if !dryRun { state.save() }
            log(String(format: "luma=%.3f (norm %.2f)  %@ → %@ за %.1fс%@",
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
